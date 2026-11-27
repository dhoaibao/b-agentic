#!/usr/bin/env python3
"""b-agentic run artifacts: the single writer of a b-flow run's markdown files (ADR-010).

It reads JSON on stdin, validates it against references/artifacts.yaml and the
cross-artifact rules, renders canonical markdown, and writes it atomically.
`artifacts.json` keeps each artifact's sha256 and validated data, so `validate`
re-renders and compares bytes instead of parsing free-form markdown. Run it as
`~/.claude/b-agentic/bin/b-run <command>` (the wrapper that runs `python3 -I -B b_run.py`); it
needs only the standard library, and it finds the repository from the current folder.

Commands (JSON results on stdout, one-line errors on stderr):
  help, --help, -h         print this text and exit 0 (reads nothing, writes nothing)
  schema [KIND]            print the schema, rules, enums, text_rules and an example
  lint KIND                validate stdin without writing (cross rules when a run is active)
  write KIND               validate stdin, render, and write the artifact (main session only)
  validate [--json]        re-render every artifact and compare bytes and hashes
  scope-check              compare changed git paths with the spec's scope globs; with --base TREE
                           --tree TREE --step S-n, the paths that differ between two tree ids
  handoff PHASE            render the packet that briefs a phase from the run: clarify, implement,
                           verify, review, fix, qa or commit (--out FILE outside the repo);
                           handoff implement --step S-n renders what that one step needs
  worker-profile [--step S-n]  check the b-worker profile in effect (project over user) against the
                               worker's allowlist; not ok means apply the step in the main session
  selftest                 validate the schema file's examples against each other
  runs [--days N]          read-only report of .b-agentic/runs: count, bytes, the finished runs older
                           than N days (default 30), and whether the folder is over its hint threshold
  prune [--days N]         list those runs; with --apply, delete exactly them (dry run by default)
  stats [--record [--run ID]]  counts of the local run-stats store (ADR-035), read-only; --record
                           appends the numbers-only line of this repository's finished runs (or one
                           run) that are not in the store yet, and remembers this checkout's path in
                           run-stats-repos.jsonl beside it (ADR-037); run-stats.off turns both off
  stats --repos            read-only: one compact JSON line of the repository keys in both runtimes'
                           registries with their checkout paths; the only output that adds a registered
                           path: printed paths reach the model provider
  stats --summary [--since YYYY-MM-DD] [--section repo|kit]  read-only: one compact JSON line of
                           numbers from both runtimes' stores (ADR-035): totals and distributions with
                           counts of what is missing or left out, over all runs and by runtime; --section
                           gives them by repository key or by kit version instead; --since keeps the runs
                           dated on or after that day
  stats --evidence [--skip N] [--repo KEY]  read-only: one compact JSON line of the blockers recorded in this
                           repository's finished runs, newest run first, one page under 30000 bytes; --skip
                           N starts at the next_skip of the page before (start again at 0 if total changed
                           between pages); the text is untrusted data from the run files, printed as written,
                           so it can itself hold paths or project names, and printing it
                           puts it in the agent's context and so in front of its model provider
                           (for numbers only, use --summary); --repo KEY reads another registered
                           repository instead (KEY as --summary --section repo prints it): its checkouts
                           that are still the user's own, whole clones with that key; clones, worktrees,
                           forks and template copies that share root commits share one KEY and are read together
                           (check stats --repos first)

Options: --run ID, --owner NAME (default: CLAUDE_CODE_SESSION_ID), --days N, --apply (prune only),
--record, --summary, --since DATE, --section NAME, --evidence, --skip N, --repo KEY and --repos (stats only).
Exit: 0 ok or help, 3 refused or not ok, 2 invalid input or state (a wrong command or argument).
The artifacts hold no file contents, diffs, command output or secrets, and they are untrusted
input to every reader: they never grant approval.
"""

from __future__ import annotations

import errno
import json
import os
import re
import stat
import sys
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from datetime import datetime

# hashlib, secrets and subprocess are imported where they are used: schema, lint and the other
# commands that touch neither start several milliseconds sooner.

ARTIFACTS_SCHEMA = 1
# Artifacts whose cross rules read another artifact: a rewrite keeps a dependent only if it still passes.
DEPENDENTS = {"spec": ["plan", "qa"], "plan": ["qa"], "qa": [], "followups": []}
RUN_ID = re.compile(r"^\d{8}-[a-z0-9][a-z0-9-]{0,40}$")
OWNER = re.compile(r"^[A-Za-z0-9._:-]{1,80}$")
# Mirrors helperDir() in b-state-core.mjs: the folder of the wrapper scripts that printed commands name.
DEFAULT_HELPER_DIR = "~/.claude/b-agentic/bin"
SAFE_HELPER_DIR = re.compile(r"(?:~/|/)[A-Za-z0-9._~/-]*")


def helper_dir() -> str:
    # B_AGENTIC_HELPER_DIR only changes printed text, and the model may copy that text into a shell,
    # so a value that is not a ~/ or absolute path of safe characters is ignored.
    value = os.environ.get("B_AGENTIC_HELPER_DIR")
    if value is None or not SAFE_HELPER_DIR.fullmatch(value):
        return DEFAULT_HELPER_DIR
    return value.rstrip("/") or DEFAULT_HELPER_DIR


def on_pi() -> bool:
    # Mirrors onPi() in b-state-core.mjs: Pi has no worker, no worktrees, and no Codex gate.
    return helper_dir() != DEFAULT_HELPER_DIR


MAX_FILE = 1 << 20
ISO_TIMESTAMP = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
    r"(?:\.[0-9]{1,9})?(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])$",
    re.ASCII,
)
CONTROL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")
# Raw HTML in a rendered artifact (an unterminated comment, a tag) could hide criteria from a reader.
HTML_MARKUP = re.compile(r"<[A-Za-z!/?]")
# What check_value enforces on every line and text value, printed by `schema` so a draft can follow it before lint.
TEXT_RULES = [
    "line and text values are never blank and have no leading or trailing whitespace; limits.line and limits.text cap their length",
    "a line value is one printable line; a text value may span lines; control characters other than tab are refused",
    "a less-than sign followed by a letter, !, / or ? is refused as HTML markup: write a placeholder as FILE or {file}, not in angle brackets",
    "a field marked no_backtick (commands, scope paths) must not contain a backtick",
]
TEMP_NAME = re.compile(r"^[A-Za-z0-9._-]+\.\d+\.[0-9a-f]{8,}\.tmp$")

# Same rules, order and semantics as PROTECTED_RULES in b-protected.mjs
# (`*` spans `/`, `?` is one character, the whole path must match, the last match
# wins). registry_sync.py keeps the two in step.
PROTECTED_RULES = [
    ("*.env", "deny"),
    ("*.env.*", "deny"),
    ("*.env.example", "allow"),
    ("*.pem", "deny"),
    ("*credentials.*", "deny"),
    ("*secrets.*", "deny"),
]


class Refused(Exception):
    """A guard failed: nothing was written."""


class Invalid(Exception):
    """Input or state is malformed."""


def _glob_regex(pattern: str) -> re.Pattern[str]:
    body = "".join(".*" if c == "*" else "." if c == "?" else re.escape(c) for c in pattern)
    # Case-insensitive like b-protected.mjs (`.ENV` opens `.env` on a case-insensitive filesystem); ASCII-only folding.
    return re.compile(f"^{body}$", re.S | re.I | re.A)


_PROTECTED = [(_glob_regex(p), action) for p, action in PROTECTED_RULES]


def is_protected(path: str) -> bool:
    verdict = "allow"
    for matcher, action in _PROTECTED:
        if matcher.match(path):
            verdict = action
    return verdict == "deny"


def scope_regex(glob: str) -> re.Pattern[str]:
    """`**/` spans directories, `**` anything, `*` one segment, `?` one character."""
    out, i = [], 0
    while i < len(glob):
        if glob.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif glob.startswith("**", i):
            out.append(".*")
            i += 2
        elif glob[i] == "*":
            out.append("[^/]*")
            i += 1
        elif glob[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(glob[i]))
            i += 1
    return re.compile("^" + "".join(out) + "$", re.S)


def in_scope(path: str, globs: list[str]) -> bool:
    return any(scope_regex(g).match(path) for g in globs)


# ---- schema -------------------------------------------------------------------


def schema_path() -> Path:
    here = Path(__file__).resolve().parent
    for candidate in (
        here.parent / "references" / "artifacts.yaml",
        here.parent.parent / "references" / "artifacts.yaml",
    ):
        if candidate.is_file():
            return candidate
    raise Invalid("references/artifacts.yaml was not found next to this script")


def mcp_policy_path() -> Path:
    here = Path(__file__).resolve().parent
    for candidate in (
        here.parent / "references" / "mcp_operations.yaml",
        here.parent.parent / "references" / "mcp_operations.yaml",
    ):
        if candidate.is_file():
            return candidate
    raise Invalid("references/mcp_operations.yaml was not found next to this script")


def load_schema() -> dict:
    try:
        schema = json.loads(schema_path().read_text())
    except (OSError, ValueError) as exc:
        raise Invalid(f"artifacts.yaml is unreadable: {exc}") from exc
    if schema.get("version") != ARTIFACTS_SCHEMA or set(schema.get("kinds", {})) != {"spec", "plan", "qa", "followups"}:
        raise Invalid("artifacts.yaml: unexpected version or kinds")
    return schema


def check_value(spec: dict, value: object, path: str, schema: dict) -> None:
    kind = spec["type"]
    limits = schema["limits"]

    def bad(why: str) -> Invalid:
        return Invalid(f"{path}: {why}")

    if kind in ("line", "text", "id", "enum"):
        if not isinstance(value, str):
            raise bad("expected a string")
        if kind == "enum":
            values = spec.get("values") or schema["enums"][spec["enum"]]
            if value not in values:
                raise bad(f"expected one of {values}")
            return
        if kind == "id":
            if not re.fullmatch(spec["pattern"], value):
                raise bad(f"does not match {spec['pattern']}")
            return
        maximum = spec.get("max", limits["line"] if kind == "line" else limits["text"])
        if not value.strip() or len(value) > maximum:
            raise bad(f"expected 1-{maximum} characters")
        if CONTROL.search(value) or (kind == "line" and ("\n" in value or "\r" in value)):
            raise bad("contains control characters" if kind == "text" else "must be one printable line")
        if value != value.strip():
            raise bad("has leading or trailing whitespace")
        html = HTML_MARKUP.search(value)
        if html:
            raise bad(
                f"must not contain HTML markup (found {html.group(0)!r}); write a placeholder as FILE or {{file}}"
            )
        if spec.get("no_backtick") and "`" in value:
            raise bad("must not contain a backtick")
    elif kind == "list":
        if not isinstance(value, list):
            raise bad("expected a list")
        low, high = spec.get("min", 0), min(spec.get("max", limits["list_items"]), limits["list_items"])
        if not low <= len(value) <= high:
            raise bad(f"expected {low}-{high} items")
        for index, item in enumerate(value):
            check_value(spec["items"], item, f"{path}[{index}]", schema)
    elif kind == "object":
        if not isinstance(value, dict):
            raise bad("expected an object")
        fields = spec["fields"]
        for key in value:
            if key not in fields:
                raise bad(f"unknown field {key!r}")
        for key, sub in fields.items():
            if key not in value:
                if not sub.get("optional"):
                    raise Invalid(f"{path}.{key}: required")
                continue
            check_value(sub, value[key], f"{path}.{key}", schema)
    else:
        raise Invalid(f"artifacts.yaml: unknown type {kind!r}")


def _contiguous(ids: list[str], prefix: str, path: str) -> None:
    if ids != [f"{prefix}-{n}" for n in range(1, len(ids) + 1)]:
        raise Invalid(f"{path}: ids must run {prefix}-1..{prefix}-{len(ids)} in order")


def _command_or_source(item: dict, path: str, schema: dict) -> None:
    needs_command = item["evidence"] in schema["enums"]["command_evidence"]
    if needs_command and ("command" not in item or "source" in item):
        raise Invalid(f"{path}: {item['evidence']} evidence needs a command and no source")
    if not needs_command and ("source" not in item or "command" in item):
        raise Invalid(f"{path}: {item['evidence']} evidence needs a source and no command")


def _scope_glob_ok(glob: str, path: str) -> None:
    if glob.startswith("/") or ".." in glob.split("/") or "\\" in glob or is_protected(glob):
        raise Invalid(f"{path}: must be a relative, non-protected glob")


def _paths_overlap(first: str, second: str) -> bool:
    a, b = first.rstrip("/"), second.rstrip("/")
    return a == b or a.startswith(b + "/") or b.startswith(a + "/")


def _batch_rules(data: dict, applied: list[str]) -> None:
    """parallel_steps: worker steps whose literal paths never overlap and that can be ready together."""
    batch = data.get("parallel_steps", [])
    if not batch:
        return
    if len(set(batch)) != len(batch) or not set(batch) <= set(applied):
        raise Invalid("parallel_steps: must name worker steps, each once")
    steps = {s["id"]: s for s in data["steps"]}
    for step_id in batch:
        for step_path in steps[step_id]["paths"]:
            if any(ch in step_path for ch in "*?[]{}"):
                raise Invalid(f"parallel_steps: {step_id} path {step_path!r} must be literal")
            if step_path.startswith("/") or any(part in ("", ".", "..") for part in step_path.split("/")):
                # An alias such as src/./a.txt would pass the overlap test and name one file twice.
                raise Invalid(
                    f"parallel_steps: {step_id} path {step_path!r} must be canonical (no '.', '..', repeated or trailing separators)"
                )
    for i, first in enumerate(batch):
        for second in batch[i + 1 :]:
            for a in steps[first]["paths"]:
                for b in steps[second]["paths"]:
                    if _paths_overlap(a, b):
                        raise Invalid(f"parallel_steps: {first} and {second} share a path ({a} / {b})")
    needs = {n["id"]: n["depends_on"] for n in step_needs(data["steps"])}
    waits: dict[str, set[str]] = {}
    for step_id in needs:  # steps are listed in dependency order
        waits[step_id] = set(needs[step_id]).union(*(waits[d] for d in needs[step_id]))
    if not any(
        first not in waits[second] and second not in waits[first]
        for i, first in enumerate(batch)
        for second in batch[i + 1 :]
    ):
        raise Invalid("parallel_steps: no two listed steps can be ready together")


def check_rules(kind: str, data: dict, ctx: dict, schema: dict, previous: dict | None) -> bool:
    """Cross-field and cross-artifact rules. Returns whether the cross rules ran."""
    if kind == "spec":
        _contiguous([c["id"] for c in data["criteria"]], "AC", "criteria")
        for i, criterion in enumerate(data["criteria"]):
            _command_or_source(criterion, f"criteria[{i}]", schema)
        for i, glob in enumerate(data["scope_paths"]):
            _scope_glob_ok(glob, f"scope_paths[{i}]")
        return True
    if kind == "plan":
        _contiguous([s["id"] for s in data["steps"]], "S", "steps")
        if len(set(data["checks"])) != len(data["checks"]):
            raise Invalid("checks: duplicate command")
        together = data.get("parallel_checks", [])
        if len(set(together)) != len(together) or not set(together) <= set(data["checks"]):
            raise Invalid("parallel_checks: must name plan checks, each once")
        applied = data.get("worker_steps", [])
        if len(set(applied)) != len(applied) or not set(applied) <= {s["id"] for s in data["steps"]}:
            raise Invalid("worker_steps: must name plan steps, each once")
        for i, step in enumerate(data["steps"]):
            needs = step.get("depends_on", [])
            if len(set(needs)) != len(needs) or not set(needs) <= {s["id"] for s in data["steps"][:i]}:
                raise Invalid(f"steps[{i}].depends_on: must name earlier steps, each once")
        _batch_rules(data, applied)
        spec = ctx.get("spec")
        if spec is None:
            return False
        for i, step in enumerate(data["steps"]):
            for j, step_path in enumerate(step["paths"]):
                _scope_glob_ok(step_path, f"steps[{i}].paths[{j}]")
                if not in_scope(step_path, spec["scope_paths"]):
                    raise Invalid(f"steps[{i}].paths[{j}]: outside the spec scope")
        for criterion in spec["criteria"]:
            if (
                criterion["evidence"] in schema["enums"]["command_evidence"]
                and criterion["command"] not in data["checks"]
            ):
                raise Invalid(f"checks: missing the command of {criterion['id']}")
        return True
    if kind == "qa":
        spec, plan = ctx.get("spec"), ctx.get("plan")
        for i, row in enumerate(data["rows"]):
            _command_or_source(row, f"rows[{i}]", schema)
            if (row["result"] == "waived") != (row.get("waived_by") == "user"):
                raise Invalid(f"rows[{i}].waived_by: exactly the waived rows carry waived_by user")
        results = [r["result"] for r in data["rows"]]
        if data["verdict"] == "QA PASS" and any(r not in ("pass", "waived") for r in results):
            raise Invalid("verdict: QA PASS needs every row pass or waived")
        if data["verdict"] == "QA FAIL" and not any(r in ("fail", "gap") for r in results):
            raise Invalid("verdict: QA FAIL needs a fail or gap row")
        if spec is None or plan is None:
            return False
        criteria = {c["id"]: c for c in spec["criteria"]}
        if [r["ac"] for r in data["rows"]] != list(criteria):
            raise Invalid("rows: must cover every spec criterion once, in order")
        for i, row in enumerate(data["rows"]):
            criterion = criteria[row["ac"]]
            if row["evidence"] != criterion["evidence"]:
                raise Invalid(f"rows[{i}].evidence: differs from the spec")
            if "command" in row:
                if row["command"] != criterion.get("command") and row["command"] not in plan["checks"]:
                    raise Invalid(f"rows[{i}].command: not the spec command or a plan check")
            elif row["source"] != criterion.get("source"):
                raise Invalid(f"rows[{i}].source: differs from the spec")
        return True
    if kind == "followups":
        ids = [item["id"] for item in data["items"]]
        if len(set(ids)) != len(ids):
            raise Invalid("items: duplicate id")
        for i, item in enumerate(data["items"]):
            if item["disposition"] != "open" and "reason" not in item:
                raise Invalid(f"items[{i}].reason: required unless the item is open")
            blocker = item.get("kind") == "blocker"
            if blocker and item["source"] not in ("review", "qa"):
                raise Invalid(f"items[{i}].kind: a blocker comes from review or qa")
            if "sweep" in item and not blocker:
                raise Invalid(f"items[{i}].sweep: only a blocker carries a sweep")
            if blocker and item["disposition"] == "fixed" and "sweep" not in item:
                raise Invalid(f"items[{i}].sweep: required for a fixed blocker")
            if "blocker_class" in item and not blocker:
                raise Invalid(f"items[{i}].blocker_class: only a blocker carries a class")
            if "escaped_from" in item:
                stages = schema["enums"]["escape_stage"]
                if item["source"] not in ("review", "qa"):
                    raise Invalid(f"items[{i}].escaped_from: only a review or qa item carries it")
                # A review item can only have escaped the stages before review; a qa item can also have escaped review.
                earlier = stages[: stages.index("review")] if item["source"] == "review" else stages
                if item["escaped_from"] not in (*earlier, "unknown"):
                    raise Invalid(f"items[{i}].escaped_from: must be earlier than the {item['source']} source")
        if previous and not {i["id"] for i in previous["items"]} <= set(ids):
            raise Invalid("items: a rewrite may not drop an id recorded earlier")
        recorded = {i["id"]: i for i in previous["items"]} if previous else {}
        for i, item in enumerate(data["items"]):
            old = recorded.get(item["id"])
            if old and (old.get("kind") != item.get("kind") or old["source"] != item["source"]):
                raise Invalid(f"items[{i}]: the kind and source of a recorded item may not change")
            for field in ("blocker_class", "escaped_from"):
                # An unknown stage may be named once its cause is found; a named stage stays.
                refined = field == "escaped_from" and old and old.get(field) == "unknown" and field in item
                if old and field in old and old[field] != item.get(field) and not refined:
                    raise Invalid(f"items[{i}].{field}: a recorded value may not change or be dropped")
        return True
    raise Invalid(f"unknown kind {kind!r}")


# ---- rendering ----------------------------------------------------------------


def _bullets(items: list[str], empty: str = "None") -> list[str]:
    return [f"- {i}" for i in items] or [f"- {empty}"]


def render(kind: str, data: dict) -> str:
    out = [f"<!-- b-run:{kind} v1 -->"]
    if kind == "spec":
        b = data["behavior"]
        out += ["# Spec", "", "## Request", *(f"> {line}" for line in data["request"].split("\n")), "", "## Answers"]
        out += [f"- Q: {a['q']}\n  A: {a['a']}" for a in data["answers"]] or ["- None"]
        out += ["", "## Behavior", "", "### Current"]
        out += [f"- {c['text']} (basis: {c['basis']})" for c in b["current"]] or ["- None"]
        out += ["", "### New", *_bullets(b["new"]), "", "### Examples"]
        out += [f"- Input: {e['input']} -> Output: {e['output']}" for e in b["examples"]]
        out += ["", "### Non-goals", *_bullets(b["non_goals"]), "", "## Acceptance criteria"]
        for c in data["criteria"]:
            out.append(f"- {c['id']}: WHEN {c['when']} THEN {c['then']}")
            out.append(f"  - Evidence: {c['evidence']}")
            out.append(f"  - Command: `{c['command']}`" if "command" in c else f"  - Source: {c['source']}")
        out += [
            "",
            "## Scope",
            *(f"- `{p}`" for p in data["scope_paths"]),
            "",
            "## Out of scope",
            *_bullets(data["out_of_scope"]),
            "",
            "## Consent",
            f"- Commit: {data['consent']['commit']}",
            f"- Branch target: {data['consent']['branch_target']}",
            *([f"- Codex: {data['consent']['codex']}"] if "codex" in data["consent"] else []),
            "- Push or PR: never",
        ]
        if "size" in data:
            out += ["", "## Size", data["size"]]
    elif kind == "plan":
        out += ["# Plan", "", "## Steps"]
        for s in data["steps"]:
            out += [
                f"- {s['id']}: {s['action']}",
                "  - Paths: " + ", ".join(f"`{p}`" for p in s["paths"]),
                f"  - Done when: {s['done_when']}",
            ]
            if "depends_on" in s:
                out.append("  - Depends on: " + (", ".join(s["depends_on"]) or "none"))
        out += [
            "",
            "## Checks",
            *(f"- `{c}`" for c in data["checks"]),
        ]
        if "parallel_checks" in data:
            out += ["", "## Checks that may run together", *(f"- `{c}`" for c in data["parallel_checks"])]
        if "worker_steps" in data:
            out += ["", "## Worker steps", *(f"- {s}" for s in data["worker_steps"])]
        if "parallel_steps" in data:
            out += ["", "## Steps that may run together", *(f"- {s}" for s in data["parallel_steps"])]
        out += [
            "",
            "## Invariants",
            *_bullets(data["invariants"]),
        ]
        out += ["", "## Stop conditions", *_bullets(data["stop_conditions"])]
    elif kind == "qa":
        out += ["# QA", "", "## Matrix"]
        for r in data["rows"]:
            out += [f"- {r['ac']}: {r['result']}", f"  - Evidence: {r['evidence']}"]
            out.append(f"  - Command: `{r['command']}`" if "command" in r else f"  - Source: {r['source']}")
            if "waived_by" in r:
                out.append(f"  - Waived by: {r['waived_by']}")
            if "note" in r:
                out.append(f"  - Note: {r['note']}")
        out += [
            "",
            "## Regression scope",
            data["regression_scope"],
            "",
            "## Not covered",
            *_bullets(data["not_covered"]),
        ]
        out += ["", "## Verdict", data["verdict"]]
    else:
        out += ["# Follow-ups", ""]
        for item in data["items"]:
            out.append(f"- {item['id']} [{item['source']}] {item['disposition']}: {item['summary']}")
            if "kind" in item:
                out.append(f"  - Kind: {item['kind']}")
            if "blocker_class" in item:
                out.append(f"  - Class: {item['blocker_class']}")
            if "escaped_from" in item:
                out.append(f"  - Escaped from: {item['escaped_from']}")
            if "reason" in item:
                out.append(f"  - Reason: {item['reason']}")
            if "sweep" in item:
                out.append(f"  - Sweep: {item['sweep']}")
        if not data["items"]:
            out.append("- None")
    return "\n".join(out) + "\n"


# ---- safe files, git, run resolution -------------------------------------------


def read_file(path: Path, limit: int = MAX_FILE) -> bytes:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise Refused(f"{path.name} is not a regular file within the size limit")
        return os.read(fd, info.st_size) if info.st_size else b""
    finally:
        os.close(fd)


def write_atomic(path: Path, text: str) -> None:
    import secrets

    temp = path.with_name(f"{path.name}.{os.getpid()}.{secrets.token_hex(8)}.tmp")
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        os.write(fd, text.encode())
    finally:
        os.close(fd)
    try:
        os.replace(temp, path)
    except OSError:
        temp.unlink(missing_ok=True)
        raise


def is_plain_dir(path: Path) -> bool:
    return path.is_dir() and not path.is_symlink()


def git(root: Path | str, *args: str) -> str:
    import subprocess

    done = subprocess.run(["git", *args], cwd=root, capture_output=True, text=True, check=False)
    if done.returncode != 0:
        raise Refused("git failed: " + (done.stderr.strip().splitlines() or ["unknown"])[0])
    return done.stdout


# Under the 10 s b-state gives the live stats call, so a stuck lookup ends as "no key" instead of killing that call.
KEY_GIT_SECONDS = 8.0

# git runs from inside folders the registry names, where a relative or empty entry would load that folder's files.
# Each variable with the characters its loader splits it at: glibc splits the library path at semicolons too.
SEARCH_PATHS = {
    "PATH": ":",
    "LD_LIBRARY_PATH": ":;",
    "GCONV_PATH": ":",
    "DYLD_LIBRARY_PATH": ":",
    "DYLD_FRAMEWORK_PATH": ":",
    "DYLD_FALLBACK_LIBRARY_PATH": ":",
    "DYLD_FALLBACK_FRAMEWORK_PATH": ":",
}
PRELOADS = ("LD_PRELOAD", "LD_AUDIT", "DYLD_INSERT_LIBRARIES")


def hardened_git(
    root: Path | str, *args: str, ok: tuple[int, ...] = (0,), ends: float | None = None
) -> tuple[int, str]:
    """git for asking which repository a folder is, which may be a folder named by the registry.

    Nothing inherited (every GIT_ variable is dropped) or held in that folder may pick the program that runs,
    point git elsewhere, start its filesystem monitor, fetch missing objects, wait for input, or hang. Every
    failure is a refusal.
    """
    import shutil
    import subprocess
    import time

    env = {name: value for name, value in os.environ.items() if not name.startswith("GIT_") and name not in PRELOADS}
    env.setdefault("PATH", os.defpath)
    for name, separators in SEARCH_PATHS.items():
        if name in env:
            entries = re.split(f"[{separators}]", env[name])
            env[name] = os.pathsep.join(entry for entry in entries if os.path.isabs(entry))
            if not env[name] and name != "PATH":  # an unset PATH would bring back the system's default one
                del env[name]
    env.update({"GIT_NO_LAZY_FETCH": "1", "GIT_OPTIONAL_LOCKS": "0"})
    program = shutil.which("git", path=env["PATH"]) if env["PATH"] else None
    if program is None:
        raise Refused("git was not found in an absolute PATH entry")
    # Taken at the launch: finding git on a slow search path counts against a shared limit too.
    seconds = KEY_GIT_SECONDS if ends is None else ends - time.monotonic()
    if seconds <= 0:
        raise Refused("git took too long")
    try:
        done = subprocess.run(
            [program, "-c", "core.fsmonitor=false", *args],
            cwd=root,
            env=env,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            encoding="utf-8",
            errors="surrogateescape",
            timeout=seconds,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Refused("git could not be run, or took too long") from exc
    if done.returncode not in ok:
        raise Refused(f"git exited {done.returncode}")
    return done.returncode, done.stdout


def _cwd_text() -> str:
    # A deleted cwd makes getcwd fail; the refusal must stay a refusal, never turn into an invalid-input exit.
    try:
        return CONTROL.sub("?", os.getcwd())
    except OSError:
        return "unavailable"


def repo_root() -> Path:
    try:
        return Path(git(Path.cwd(), "rev-parse", "--show-toplevel").strip()).resolve()
    except (Refused, OSError) as exc:
        raise Refused(f"not inside a git worktree (cwd: {_cwd_text()}); run it from inside the repository") from exc


def resolve_run(root: Path, run: str | None) -> tuple[str, Path]:
    base = root / ".b-agentic"
    runs = base / "runs"
    if not is_plain_dir(base) or not is_plain_dir(runs):
        raise Refused("no .b-agentic/runs folder")
    if run is None:
        try:
            run = read_file(base / "active", 256).decode().strip()
        except (OSError, Refused) as exc:
            raise Refused("no active run (pass --run)") from exc
    if not RUN_ID.fullmatch(run):
        raise Invalid("bad run id")
    directory = runs / run
    if not is_plain_dir(directory):
        raise Refused(f"run {run} does not exist")
    return run, directory


def read_json(path: Path, what: str) -> dict:
    try:
        value = json.loads(read_file(path))
    except (OSError, ValueError, Refused) as exc:
        raise Invalid(f"{what} is unreadable or not JSON") from exc
    if not isinstance(value, dict):
        raise Invalid(f"{what} is not an object")
    return value


def read_state(directory: Path) -> dict:
    state = read_json(directory / "state.json", "state.json")
    if not isinstance(state.get("phase"), str) or not RUN_ID.fullmatch(str(state.get("run_id", ""))):
        raise Invalid("state.json is malformed")
    return state


def load_artifacts(directory: Path) -> dict:
    path = directory / "artifacts.json"
    if not path.exists():
        return {"schema": ARTIFACTS_SCHEMA, "artifacts": {}}
    value = read_json(path, "artifacts.json")
    if value.get("schema") != ARTIFACTS_SCHEMA or not isinstance(value.get("artifacts"), dict):
        raise Invalid("artifacts.json is malformed")
    return value


def sha(text: str) -> str:
    import hashlib

    return hashlib.sha256(text.encode()).hexdigest()


# ---- validation of a run folder -----------------------------------------------


def validate_run(directory: Path, schema: dict, skip: frozenset[str] = frozenset()) -> tuple[dict, list[str]]:
    """Re-render every recorded artifact; returns (data by kind, problems)."""
    problems: list[str] = []
    allowed = set(schema["run_files"])
    for entry in sorted(directory.iterdir()):
        if entry.name in allowed:
            if entry.is_symlink() or entry.is_dir():
                problems.append(f"{entry.name} must be a regular file")
        elif not TEMP_NAME.fullmatch(entry.name):
            problems.append(f"unknown file {entry.name!r} in the run folder")
    recorded = load_artifacts(directory)["artifacts"]
    data: dict[str, dict] = {}
    for kind, spec in schema["kinds"].items():
        entry = recorded.get(kind)
        present = (directory / spec["file"]).exists()
        if entry is None:
            if present:
                problems.append(f"{spec['file']} is not recorded in artifacts.json")
            continue
        if kind in skip:
            continue
        try:
            body = read_file(directory / spec["file"]).decode()
        except (OSError, Refused, UnicodeDecodeError):
            problems.append(f"{spec['file']} is missing or unreadable")
            continue
        try:
            value = entry["data"]
            check_value({"type": "object", "fields": spec["fields"]}, value, kind, schema)
            if not check_rules(kind, value, data, schema, None):
                raise Invalid("cross-artifact rules could not run: a required artifact is missing")
            rendered = render(kind, value)
        except (Invalid, KeyError, TypeError) as exc:
            problems.append(f"{kind}: recorded data is invalid ({exc})")
            continue
        if body != rendered or sha(body) != entry.get("sha256"):
            problems.append(f"{spec['file']} differs from its recorded content")
            continue
        data[kind] = value
    return data, problems


def step_needs(steps: list[dict]) -> list[dict]:
    """Each step with the steps it waits for: the listed ones, or the step before it when none are listed."""
    return [
        {"id": s["id"], "depends_on": s.get("depends_on", [steps[i - 1]["id"]] if i else [])}
        for i, s in enumerate(steps)
    ]


def summary(data: dict) -> dict:
    out: dict = {}
    if "spec" in data:
        out["spec"] = {
            "criteria": [{k: c[k] for k in ("id", "evidence")} for c in data["spec"]["criteria"]],
            "scope_paths": data["spec"]["scope_paths"],
            "consent": data["spec"]["consent"],
            # b-state checks a quick run against its limits from these.
            "size": data["spec"].get("size", "full"),
            "answers": len(data["spec"]["answers"]),
        }
    if "plan" in data:
        out["plan"] = {
            "checks": data["plan"]["checks"],
            # b-state binds each of these to the fingerprint it was started on.
            "parallel_checks": data["plan"].get("parallel_checks", []),
            # b-state requires --by on these steps and refuses them in a quick run.
            "worker_steps": data["plan"].get("worker_steps", []),
            # b-state starts at most two of the ready ones together, each in its own worktree.
            "parallel_steps": data["plan"].get("parallel_steps", []),
            "step_ids": [s["id"] for s in data["plan"]["steps"]],
            "steps": step_needs(data["plan"]["steps"]),
        }
    if "qa" in data:
        out["qa"] = {
            "verdict": data["qa"]["verdict"],
            "rows": [{"ac": r["ac"], "result": r["result"]} for r in data["qa"]["rows"]],
        }
    if "followups" in data:
        items = data["followups"]["items"]
        out["followups"] = {
            "ids": [i["id"] for i in items],
            # b-state reads the kind and disposition: a verdict needs its round's findings recorded.
            "items": [
                {"id": i["id"], "kind": i.get("kind", "followup"), "disposition": i["disposition"]} for i in items
            ],
        }
    return out


# ---- mutex and lock (same protocol as b-state.mjs) ------------------------------


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


class Mutex:
    """The per-run command mutex: a file created atomically by hard-linking a finished temp file."""

    def __init__(self, directory: Path):
        import secrets

        self.path = directory / "mutex"
        self.token = secrets.token_hex(16)
        self.directory = directory

    def __enter__(self) -> "Mutex":
        temp = self.directory / f"mutex.{os.getpid()}.{self.token}.tmp"
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, (json.dumps({"pid": os.getpid(), "token": self.token}) + "\n").encode())
        finally:
            os.close(fd)
        try:
            os.link(temp, self.path)
        except FileExistsError:
            holder: dict = {}
            try:
                holder = json.loads(read_file(self.path, 4096))
            except (OSError, ValueError, Refused):
                pass
            pid = holder.get("pid")
            if isinstance(pid, int) and not _pid_alive(pid):
                raise Refused(
                    f"a command (pid {pid}) died holding the run mutex; if no other b-state or b_run command is "
                    "running, delete .b-agentic/runs/<id>/mutex by hand"
                ) from None
            raise Refused("another b-state or b_run command is running for this run") from None
        finally:
            temp.unlink(missing_ok=True)
        return self

    def __exit__(self, *_exc: object) -> None:
        try:
            if json.loads(read_file(self.path, 4096)).get("token") == self.token:
                self.path.unlink(missing_ok=True)
        except (OSError, ValueError, Refused):
            pass


def require_lock(directory: Path, owner: str) -> None:
    try:
        held = json.loads(read_file(directory / "lock", 4096))
    except (OSError, ValueError, Refused):
        raise Refused("run is not locked; the main session takes the lock first") from None
    if held.get("owner") != owner:
        raise Refused(f"run is locked by another session ({held.get('owner')})")


def default_owner(args: dict) -> str:
    # The same order as b-state.mjs, which takes the lock this owner must hold.
    # An explicit --owner, even an empty one, is never replaced by a session variable.
    owner = args.get("owner")
    if owner is None:
        owner = os.environ.get("CLAUDE_CODE_SESSION_ID", "") or os.environ.get("PI_SESSION_ID", "")
    if not OWNER.fullmatch(owner):
        variable = "PI_SESSION_ID" if on_pi() else "CLAUDE_CODE_SESSION_ID"
        raise Invalid(f"pass --owner NAME or set {variable}")
    return owner


# ---- commands -----------------------------------------------------------------


def read_input(schema: dict) -> dict:
    raw = sys.stdin.buffer.read(schema["limits"]["data_bytes"] + 1)
    if len(raw) > schema["limits"]["data_bytes"]:
        raise Invalid("input is too large")
    try:
        value = json.loads(raw)
    except ValueError as exc:
        raise Invalid("input is not JSON") from exc
    return value


def validate_input(kind: str, value: object, ctx: dict, schema: dict, previous: dict | None) -> bool:
    if kind not in schema["kinds"]:
        raise Invalid(f"unknown kind {kind!r}; expected one of {sorted(schema['kinds'])}")
    check_value({"type": "object", "fields": schema["kinds"][kind]["fields"]}, value, kind, schema)
    # Older specs keep their codex consent so they still render the same; new data omits it (ADR-021).
    if kind == "spec" and isinstance(value, dict) and "codex" in value.get("consent", {}):
        raise Invalid("consent.codex is retired (ADR-021); omit it")
    crossed = check_rules(kind, value, ctx, schema, previous)  # type: ignore[arg-type]
    if kind == "followups":
        require_analytics(value, previous, schema)  # type: ignore[arg-type]
    return crossed


def require_analytics(data: dict, previous: dict | None, schema: dict) -> None:
    """A blocker new to the run names its class and stage. Input only: older recorded data lacks them."""
    # An install can keep an older, user-edited artifacts.yaml beside newer helpers, as in _kit_stats:
    # require only what that schema can record, so a writer never has to invent a stage.
    fields = schema["kinds"]["followups"]["fields"]["items"]["items"]["fields"]
    needed = ["blocker_class"] if "blocker_class" in fields else []
    if "escaped_from" in fields and "unknown" in schema["enums"]["escape_stage"]:
        needed.append("escaped_from")
    recorded = {item["id"] for item in previous["items"]} if previous else set()
    for i, item in enumerate(data["items"]):
        if item.get("kind") != "blocker" or item["id"] in recorded:
            continue
        for field in needed:
            if field not in item:
                raise Invalid(f"items[{i}].{field}: required on a new blocker")


def cmd_schema(schema: dict, kind: str | None) -> dict:
    if kind is None:
        return {
            "kinds": sorted(schema["kinds"]),
            "enums": schema["enums"],
            "limits": schema["limits"],
            "text_rules": TEXT_RULES,
        }
    if kind not in schema["kinds"]:
        raise Invalid(f"unknown kind {kind!r}")
    return {
        "kind": kind,
        "enums": schema["enums"],
        "limits": schema["limits"],
        **schema["kinds"][kind],
        "text_rules": TEXT_RULES,
    }


def cmd_lint(schema: dict, kind: str, args: dict) -> dict:
    value = read_input(schema)
    ctx: dict = {}
    previous = None
    try:
        root = repo_root()
        _run, directory = resolve_run(root, args.get("run"))
        ctx, _problems = validate_run(directory, schema, skip=frozenset({kind}))
        # validate_run skips the linted kind, so read the recorded follow-ups as write does.
        if kind == "followups":
            previous = (load_artifacts(directory)["artifacts"].get(kind) or {}).get("data")
    except (Refused, Invalid):
        pass
    crossed = validate_input(kind, value, ctx, schema, previous)
    return {"ok": True, "kind": kind, "cross_checked": crossed}


def cmd_write(schema: dict, kind: str, args: dict) -> dict:
    if kind not in schema["kinds"]:
        raise Invalid(f"unknown kind {kind!r}; expected one of {sorted(schema['kinds'])}")
    root = repo_root()
    run_id, directory = resolve_run(root, args.get("run"))
    value = read_input(schema)
    owner = default_owner(args)
    with Mutex(directory):
        require_lock(directory, owner)
        state = read_state(directory)
        if state["phase"] not in schema["kinds"][kind]["phases"]:
            raise Refused(f"{kind} is written in {schema['kinds'][kind]['phases']}, not in phase {state['phase']}")
        skip = frozenset({kind, *DEPENDENTS[kind]})
        ctx, problems = validate_run(directory, schema, skip=skip)
        files = tuple(f"{schema['kinds'][k]['file']} " for k in skip)
        others = [p for p in problems if not p.startswith(files)]
        if others:
            raise Refused("the run folder is not valid: " + others[0])
        recorded = load_artifacts(directory)
        previous = (recorded["artifacts"].get(kind) or {}).get("data") if kind == "followups" else None
        if not validate_input(kind, value, ctx, schema, previous):
            raise Refused("write the artifacts this one depends on first (spec, then plan, then qa)")
        body = render(kind, value)
        # Dependents that the rewrite would invalidate are dropped; the others stay.
        fresh = {**ctx, kind: value}
        dropped: list[str] = []
        for dependent in DEPENDENTS[kind]:
            entry = recorded["artifacts"].get(dependent)
            if entry is None:
                continue
            try:
                if not check_rules(dependent, entry["data"], fresh, schema, None):
                    raise Invalid("incomplete")
                fresh[dependent] = entry["data"]
            except (Invalid, KeyError, TypeError):
                dropped.append(dependent)
        write_atomic(directory / schema["kinds"][kind]["file"], body)
        for dependent in dropped:
            recorded["artifacts"].pop(dependent, None)
            (directory / schema["kinds"][dependent]["file"]).unlink(missing_ok=True)
        revision = int((recorded["artifacts"].get(kind) or {}).get("rev", 0)) + 1
        recorded["artifacts"][kind] = {"sha256": sha(body), "data": value, "rev": revision}
        write_atomic(directory / "artifacts.json", json.dumps(recorded, indent=2, sort_keys=True) + "\n")
    return {
        "ok": True,
        "run": run_id,
        "kind": kind,
        "file": schema["kinds"][kind]["file"],
        "sha256": sha(body),
        "dropped": dropped,
    }


def cmd_validate(schema: dict, args: dict) -> dict:
    root = repo_root()
    run_id, directory = resolve_run(root, args.get("run"))
    data, problems = validate_run(directory, schema)
    result = {"ok": not problems, "run": run_id, "problems": problems, "artifacts": summary(data)}
    if args.get("json"):
        entries = load_artifacts(directory)["artifacts"]
        result["hashes"] = {k: v["sha256"] for k, v in entries.items()}
        result["revs"] = {k: int(v.get("rev", 0)) for k, v in entries.items()}
    return result


def changed_paths(root: Path) -> list[str]:
    raw = git(root, "status", "--porcelain=v1", "-z", "--untracked-files=all")
    tokens = raw.split("\0")
    paths: list[str] = []
    i = 0
    while i < len(tokens):
        token = tokens[i]
        i += 1
        if len(token) < 4:
            continue
        paths.append(token[3:])
        if token[0] in "RC":
            paths.append(tokens[i])
            i += 1
    return sorted({p for p in paths if p and not p.startswith(".b-agentic/")})


MAX_DIRTY_BYTES = 64 << 20


def path_digest(root: Path, rel: str) -> str:
    """The identity of one path's content: the same rule as pathDigest in b-state.mjs, which records it."""
    # The read never leaves the tree: a link anywhere above the path makes it unidentifiable (""),
    # and the path itself is opened without following a link. The digest carries the executable bit.
    parts = rel.split("/")
    if rel.startswith("/") or ".." in parts or "" in parts:
        return ""
    above = root
    for part in parts[:-1]:
        above = above / part
        try:
            info = os.lstat(above)
        except OSError:
            return "absent"
        if stat.S_ISLNK(info.st_mode):
            return ""
        if not stat.S_ISDIR(info.st_mode):
            return "absent"
    full = root / rel
    try:
        info = os.lstat(full)
    except OSError:
        return "absent"
    if stat.S_ISLNK(info.st_mode):
        return "link:" + sha(os.readlink(full))
    if not stat.S_ISREG(info.st_mode):
        return ""
    try:
        fd = os.open(full, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return ""
    with os.fdopen(fd, "rb") as handle:
        opened = os.fstat(handle.fileno())
        if not stat.S_ISREG(opened.st_mode) or opened.st_size > MAX_DIRTY_BYTES:
            return ""
        import hashlib

        digest = hashlib.sha256()
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return ("x:" if opened.st_mode & 0o100 else "") + digest.hexdigest()


def run_paths(root: Path, state: dict) -> tuple[list[str], list[str]]:
    """Changed paths split into the run's own and those that were in the tree, unchanged, before it started.

    A path the state recorded at run start still belongs to the user while its content and mode are
    the same; once they differ, the run changed it and it is checked like any other path. That
    includes a recorded path git no longer reports: it was deleted or reverted since run start.
    """
    recorded = (state.get("baseline") or {}).get("dirty")
    recorded = {p: d for p, d in recorded.items() if isinstance(p, str)} if isinstance(recorded, dict) else {}
    changed = set(changed_paths(root))
    mine: list[str] = []
    earlier: list[str] = []
    for path in sorted(changed | set(recorded)):
        # The state is untrusted input: a likely-secret path is never read, whatever it records.
        known = isinstance(recorded.get(path), str) and not is_protected(path)
        same = known and recorded[path] == path_digest(root, path)
        if not same:
            mine.append(path)
        elif path in changed:
            earlier.append(path)
    return mine, earlier


def _tree_lines(root: Path, state: dict, empty: str | None = "- none") -> list[str]:
    """The packet sections for the tree: the run's changed paths, then any the user had before it."""
    mine, earlier = run_paths(root, state)
    out = ["## Changed paths", *([f"- {p}" for p in mine] or ([empty] if empty else []))]
    if earlier:
        out += ["", "## Changes in the tree before the run (not part of it)", *(f"- {p}" for p in earlier)]
    return out


MAX_INCLUDED_FILES = 5000


def expand_included(root: Path, paths: list) -> list[str]:
    """Every file an included ignored path stands for: a directory is walked, never assumed."""
    out: list[str] = []
    for raw in paths:
        if not isinstance(raw, str) or not raw or raw.startswith("/") or ".." in raw.split("/"):
            raise Refused("an included ignored path is not a safe relative path")
        rel = raw.rstrip("/")
        full = root / rel
        if full.is_dir() and not full.is_symlink():
            for folder, names, files in os.walk(full, followlinks=False):
                names[:] = [n for n in names if n != ".git"]
                # A symlinked directory is listed among the names, not the files: it still
                # ships as a path, so it is checked itself and never followed.
                links = [n for n in names if Path(folder, n).is_symlink()]
                names[:] = [n for n in names if n not in links]
                out.extend(str(Path(folder, f).relative_to(root)) for f in [*files, *links])
                if len(out) > MAX_INCLUDED_FILES:
                    raise Refused("too many included ignored files to check against the scope")
        else:
            out.append(rel)
    return sorted(set(out))


TREE_ID = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")
DELTA_OPTIONS = ("base", "tree", "step")


def _step_delta(root: Path, data: dict, args: dict) -> dict:
    """What one plan step changed: the paths that differ between the tree before it and the tree after."""
    if "plan" not in data:
        raise Refused("the run artifacts are not valid; scope cannot be checked")
    step = next((s for s in data["plan"]["steps"] if s["id"] == args["step"]), None)
    if step is None:
        raise Invalid("--step must name a plan step")
    if not TREE_ID.fullmatch(args["base"]) or not TREE_ID.fullmatch(args["tree"]):
        raise Invalid("--base and --tree must be tree ids")
    raw = git(root, "diff-tree", "-r", "-z", "--name-only", "--no-renames", args["base"], args["tree"])
    changed = [p for p in raw.split("\0") if p]
    outside = [p for p in changed if not in_scope(p, data["spec"]["scope_paths"])]
    protected = [p for p in changed if is_protected(p)]
    return {
        "ok": not outside and not protected,
        "changed": len(changed),
        "outside_scope": outside,
        "protected": protected,
        # Inside the approved scope but not among the step's own paths: counted, never refused.
        "outside_step": sum(1 for p in changed if not in_scope(p, step["paths"])),
    }


def cmd_scope_check(schema: dict, args: dict) -> dict:
    root = repo_root()
    _run, directory = resolve_run(root, args.get("run"))
    data, problems = validate_run(directory, schema)
    if problems or "spec" not in data:
        raise Refused("the run artifacts are not valid; scope cannot be checked")
    given = [name for name in DELTA_OPTIONS if name in args]
    if given:
        if len(given) != len(DELTA_OPTIONS):
            raise Invalid("--base, --tree, and --step are given together")
        return _step_delta(root, data, args)
    globs = data["spec"]["scope_paths"]
    state = read_state(directory)
    # Changes that were in the tree before the run, and are still the same, are not the run's.
    changed, earlier = run_paths(root, state)
    # Ignored artifacts that the candidate names are part of what ships: same rules.
    included = (state.get("candidate") or {}).get("include_ignored") or []
    for path in expand_included(root, included):
        if path not in changed:
            changed.append(path)
    outside = [p for p in changed if not in_scope(p, globs)]
    protected = [p for p in changed if is_protected(p)]
    return {
        "ok": not outside and not protected,
        "changed": len(changed),
        "preexisting": len(earlier),
        "outside_scope": outside,
        "protected": protected,
    }


# Every phase a skill is briefed for has a packet: what the run folder and the tree say that phase
# needs, so the brief never depends on a session's memory. registry_sync.py keeps the registry's
# phase contracts within this list.
HANDOFF_PHASES = ("clarify", "implement", "verify", "review", "fix", "qa", "commit")


def _criteria_lines(spec: dict) -> list[str]:
    out = []
    for c in spec["criteria"]:
        ref = f"command `{c['command']}`" if "command" in c else f"source {c['source']}"
        out.append(f"- {c['id']}: WHEN {c['when']} THEN {c['then']} ({c['evidence']}; {ref})")
    return out


def _path_lines(paths: list[str]) -> list[str]:
    return [f"- {p}" for p in paths] or ["- none"]


def _packet_clarify(root: Path, state: dict, data: dict) -> list[str]:
    baseline = state.get("baseline") or {}
    out = [f"Branch: {state.get('branch') or 'unknown'}", f"Baseline HEAD: {baseline.get('head') or 'unknown'}"]
    out += ["", "## Artifacts"]
    for kind in ("spec", "plan"):
        out.append(
            f"- {kind}.md: " + ("written" if kind in data else f"not written (`{helper_dir()}/b-run schema {kind}`)")
        )
    if "spec" in data:
        out += ["", "## Acceptance criteria", *_criteria_lines(data["spec"])]
        out += ["", "## Scope", *_path_lines(data["spec"]["scope_paths"])]
    # Why the run came back to clarify: only the reasons the state CLI recorded.
    reasons = []
    for entry in state.get("history") or []:
        detail = entry.get("detail") if isinstance(entry, dict) else None
        if isinstance(detail, dict) and isinstance(detail.get("reason"), str):
            if entry.get("to") == "blocked" or entry.get("op") == "unblock":
                reasons.append(f"- {entry.get('op')} to {entry.get('to')}: {detail['reason']}")
    return [*out, "", "## Earlier blocks and unblocks", *(reasons[-10:] or ["- none"])]


def _packet_implement(root: Path, state: dict, data: dict) -> list[str]:
    spec, plan = data["spec"], data["plan"]
    recorded = state.get("steps") or {}
    applied = set(plan.get("worker_steps", []))
    out = ["", "## Acceptance criteria", *_criteria_lines(spec)]
    out += ["", "## Scope", *_path_lines(spec["scope_paths"])]
    out += ["", "## Out of scope", *_bullets(spec["out_of_scope"], "none"), "", "## Steps"]
    for step, needs in zip(plan["steps"], step_needs(plan["steps"])):
        out += [
            f"- {step['id']} [{'recorded' if step['id'] in recorded else 'open'}]: {step['action']}"
            + (" (worker step)" if step["id"] in applied else ""),
            "  - Paths: " + ", ".join(f"`{p}`" for p in step["paths"]),
            f"  - Done when: {step['done_when']}",
            "  - Depends on: " + (", ".join(needs["depends_on"]) or "none"),
        ]
    out += ["", "## Invariants", *_bullets(plan["invariants"], "none")]
    out += ["", "## Stop conditions", *_bullets(plan["stop_conditions"], "none")]
    return [*out, "", *_tree_lines(root, state)]


def _worktree_dir(root: Path, state: dict, step_id: str) -> str | None:
    """The registered worktree b-state.mjs made for this step of this run, if one exists.

    Uses NUL-delimited porcelain listing and fails closed on git errors so paths
    containing newlines are never split and a failed listing never reads as absent.
    """
    listed = git(root, "worktree", "list", "--porcelain", "-z")
    import hashlib

    tag = hashlib.sha256(str(root).encode()).hexdigest()[:8]
    name = f"b-agentic-wt-{tag}-{state.get('run_id', '')}-{step_id}"
    for field in listed.split("\0"):
        if field.startswith("worktree "):
            path = field[len("worktree ") :]
            if path.rsplit("/", 1)[-1] == name:
                return path
    return None


def _packet_step(root: Path, state: dict, data: dict, step_id: str, followups_rev: int) -> list[str]:
    """What one plan step needs, for the main session or for the b-worker it hands the step to.

    The two revision lines are what the main session compares after the worker's report: the run
    state and the follow-ups were written only by it, so both must be as they were when it handed
    the step over.
    """
    spec, plan = data["spec"], data["plan"]
    steps = plan["steps"]
    index = next((i for i, s in enumerate(steps) if s["id"] == step_id), None)
    if index is None:
        raise Invalid("--step must name a plan step")
    step = steps[index]
    recorded = state.get("steps") or {}
    base = state.get("step_base") or {}
    needs = step_needs(steps)[index]["depends_on"]
    kind = "main session step"
    if step_id in plan.get("worker_steps", []):
        kind = "worker step"
    out = [
        f"Step: {step_id} ({kind})",
        f"Step base tree: {base.get('tree') or 'not recorded'}",
        f"State revision: {int(state.get('rev', 0))}",
        f"Follow-ups revision: {followups_rev}",
        *(
            [f"Working directory: {where}"]
            if plan.get("parallel_steps") and (where := _worktree_dir(root, state, step_id))
            else []
        ),
        "",
        "## Step",
        f"- {step_id} [{'recorded' if step_id in recorded else 'open'}]: {step['action']}",
        "  - Paths: " + ", ".join(f"`{p}`" for p in step["paths"]),
        f"  - Done when: {step['done_when']}",
        "  - Depends on: " + (", ".join(f"{d} ({'recorded' if d in recorded else 'open'})" for d in needs) or "none"),
    ]
    out += ["", "## Acceptance criteria", *_criteria_lines(spec)]
    out += ["", "## Scope", *_path_lines(spec["scope_paths"])]
    out += ["", "## Out of scope", *_bullets(spec["out_of_scope"], "none")]
    out += ["", "## Invariants", *_bullets(plan["invariants"], "none")]
    out += ["", "## Stop conditions", *_bullets(plan["stop_conditions"], "none")]
    out += ["", "## Boundaries", "- Change nothing outside the scope above; prefer the step's own paths."]
    out.append(
        "- Never write under .b-agentic, a likely-secret path, or git history, and run no b-state.mjs or b_run.py command (nor its b-state or b-run wrapper)."
    )
    return [*out, "", *_tree_lines(root, state)]


def _packet_verify(root: Path, state: dict, data: dict) -> list[str]:
    candidate = state.get("candidate") or {}
    review = state.get("review") or {}
    passed = {c.get("cmd"): c.get("exit") for c in candidate.get("checks", []) if isinstance(c, dict)}
    out = [
        f"Candidate fingerprint: {candidate.get('fingerprint') or 'not recorded'}",
        f"Failed verify attempts: {int((state.get('attempts') or {}).get('verify', 0))}",
        "",
        "## Plan checks",
    ]
    together = set(data["plan"].get("parallel_checks", []))
    for c in data["plan"]["checks"]:
        result = f"exit {passed[c]}" if c in passed else "not recorded"
        out.append(f"- `{c}`: {result}" + (" (may run together)" if c in together else ""))
    out += ["", "## Included ignored artifacts", *_path_lines(candidate.get("include_ignored") or [])]
    out += [
        "",
        "## Review",
        f"- Trigger: {review.get('trigger') or 'none recorded'}",
        f"- Completed rounds: {int(review.get('round', 0))}",
        f"- Low-risk exception: {review.get('low_risk_exception') or 'none'}",
    ]
    return [*out, "", *_tree_lines(root, state)]


def _packet_fix(root: Path, state: dict, data: dict) -> list[str]:
    blockers = [i for i in data.get("followups", {}).get("items", []) if i.get("kind") == "blocker"]
    out = ["", "## Open blockers"]
    out += [f"- {i['id']}: {i['summary']}" for i in blockers if i["disposition"] == "open"] or ["- none"]
    out += ["", "## QA results to correct"]
    failed = [r for r in data.get("qa", {}).get("rows", []) if r["result"] in ("fail", "gap")]
    if (state.get("qa") or {}).get("verdict") != "QA FAIL":
        failed = []
    out += [f"- {r['ac']}: {r['result']}" for r in failed] or ["- none"]
    out += ["", "## Acceptance criteria", *_criteria_lines(data["spec"])]
    out += ["", "## Scope", *_path_lines(data["spec"]["scope_paths"])]
    out += ["", "## Stop conditions", *_bullets(data["plan"]["stop_conditions"], "none"), "", "## Earlier sweeps"]
    out += [f"- {i['id']} {i['disposition']}: {i['sweep']}" for i in blockers if "sweep" in i] or ["- none"]
    return [*out, "", *_tree_lines(root, state)]


def _packet_commit(root: Path, state: dict, data: dict) -> list[str]:
    consent = data["spec"]["consent"]
    plan = state.get("commit_plan") or {}
    out = ["", "## Consent", f"- Commit: {consent['commit']}", f"- Branch target: {consent['branch_target']}"]
    out += ["- Push or PR: never", "", "## Approved candidate"]
    out += [
        f"- Base: {plan.get('base') or 'not recorded'}",
        f"- Tree: {plan.get('tree') or 'not recorded'}",
        f"- Fingerprint: {plan.get('fingerprint') or 'not recorded'}",
    ]
    out += ["", "## Recorded commits", *_path_lines([c for c in state.get("commits") or [] if isinstance(c, str)])]
    out += ["", *_tree_lines(root, state), "", "## Follow-ups not closed"]
    open_items = [i for i in data.get("followups", {}).get("items", []) if i["disposition"] in ("open", "deferred")]
    return [*out, *([f"- {i['id']} {i['disposition']}: {i['summary']}" for i in open_items] or ["- none"])]


def _review_gate(review: dict) -> str:
    """The gate that gave the verdict, and why Codex was not used; legacy runs name none."""
    gate = review.get("gate") or ""
    if not gate:
        return "not recorded"
    reason = review.get("gate_reason") or ""
    return f"{gate} ({reason})" if reason else gate


def _packet_review_qa(which: str, root: Path, state: dict, data: dict) -> list[str]:
    out: list[str] = []
    candidate = state.get("candidate") or {}
    review = state.get("review") or {}
    out += [f"Candidate fingerprint: {candidate.get('fingerprint') or 'not recorded'}"]
    if which == "review":
        out += [
            f"Round: {int(review.get('round', 0)) + 1}",
            f"Review trigger: {review.get('trigger') or 'none recorded'}",
        ]
    else:
        out += [
            f"Review verdict: {review.get('verdict') or review.get('low_risk_exception') or 'none'}",
            f"Review fingerprint: {review.get('fingerprint') or 'none'}",
            "Review gate: " + _review_gate(review),
        ]
    out += ["", "## Acceptance criteria", *_criteria_lines(data["spec"])]
    out += ["", "## Scope", *(f"- {p}" for p in data["spec"]["scope_paths"]), "", "## Recorded checks"]
    out += [f"- `{c['cmd']}` exit {c['exit']}" for c in candidate.get("checks", [])] or ["- none"]
    out += ["", *_tree_lines(root, state, None)]
    ignored = candidate.get("include_ignored") or []
    out += ["", "## Included ignored artifacts", *([f"- {p}" for p in ignored] or ["- none"])]
    if which == "review" and int(review.get("round", 0)) > 0:
        attempts = state.get("attempts") or {}
        out += [
            "",
            "## Prior review",
            f"Completed rounds: {int(review.get('round', 0))}",
            f"Consecutive NEEDS FIXES: {int(attempts.get('review_needs_fixes', 0))}",
        ]
        blockers = [i for i in data.get("followups", {}).get("items", []) if i.get("kind") == "blocker"]
        for i in blockers:
            out.append(f"- {i['id']} {i['disposition']}: {i['summary']}")
            out.append(f"  - Reason: {i.get('reason', 'none recorded')}")
            out.append(f"  - Sweep: {i.get('sweep', 'none recorded')}")
        if not blockers:
            out.append("- no blockers recorded")
    if "followups" in data:
        out += ["", "## Earlier follow-ups"]
        out += [f"- {i['id']} {i['disposition']}: {i['summary']}" for i in data["followups"]["items"]] or ["- none"]
    return out


PACKETS = {
    "clarify": _packet_clarify,
    "implement": _packet_implement,
    "verify": _packet_verify,
    "fix": _packet_fix,
    "commit": _packet_commit,
}


def cmd_handoff(schema: dict, which: str, args: dict) -> str:
    if which not in HANDOFF_PHASES:
        raise Invalid(f"handoff needs one of: {', '.join(HANDOFF_PHASES)}")
    if "step" in args and which != "implement":
        raise Invalid("--step is given only with handoff implement")
    root = repo_root()
    run_id, directory = resolve_run(root, args.get("run"))
    data, problems = validate_run(directory, schema)
    # Only clarify is briefed before the spec and the plan exist.
    if problems or (which != "clarify" and ("spec" not in data or "plan" not in data)):
        raise Refused("the run artifacts are not valid; no packet can be rendered")
    state = read_state(directory)
    out = [f"# {which.upper()} handoff for run {run_id}", "", f"Phase: {state['phase']}"]
    if "step" in args:
        followups = load_artifacts(directory)["artifacts"].get("followups") or {}
        out += _packet_step(root, state, data, args["step"], int(followups.get("rev", 0)))
    else:
        out += PACKETS[which](root, state, data) if which in PACKETS else _packet_review_qa(which, root, state, data)
    text = "\n".join(out) + "\n"
    target = args.get("out")
    if target:
        destination = Path(target)
        resolved = destination.resolve()
        if not destination.is_absolute() or resolved == root or root in resolved.parents:
            raise Refused("--out must be an absolute path outside the repository")
        write_atomic(destination, text)
        return json.dumps({"ok": True, "out": str(destination)})
    return text


# What the b-worker profile may grant (ADR-015): the generator renders exactly the native tools below
# plus the read-only MCP tools of the policy. The harness identifies an agent by the `name` in its
# frontmatter (YAML), not by its file name, and reads agent folders recursively, so the worker is
# started only when every file that could be the b-worker profile stays inside that allowlist.
#
# This code does not parse YAML. It over-approximates instead: a file is a candidate when its name
# reads as b-worker, when it is called b-worker.md, or when its name cannot be established with
# certainty (a quoted key, a folded, tagged, anchored, or escaped value, a flow or indented mapping,
# a repeated name, an unclosed header). A candidate is then held to a strict reading of its own
# frontmatter, so anything unusual in it is refused rather than interpreted.
WORKER_NAME = "b-worker"
WORKER_NATIVE_TOOLS = frozenset({"Read", "Grep", "Glob", "Edit", "Write", "Bash"})
WORKER_FRONTMATTER = frozenset({"name", "description", "tools", "model", "effort", "maxTurns"})
PI_WORKER_NATIVE_TOOLS = frozenset({"read", "grep", "find", "ls", "bash", "edit", "write"})
PI_WORKER_FRONTMATTER = frozenset(
    {
        "name",
        "description",
        "tools",
        "excludeTools",
        "systemPromptMode",
        "inheritProjectContext",
        "inheritGlobalContext",
        "allowNestedSubagents",
        "model",
        "thinking",
    }
)
PI_WORKER_EXCLUDED = ("subagent", "ask_user_question")
MAX_AGENT_FILES = 2000
_NAME_LINE = re.compile(r"^(\s*)(\?\s*)?([\"']?)name\3\s*:(.*)$", re.IGNORECASE)
_PLAIN_LINE = re.compile(r"([A-Za-z][A-Za-z0-9_-]*):(?:[ \t]+(.*))?")


def _scalar(raw: str) -> str | None:
    """A plain or simply quoted one-line value without its comment; None when YAML could read it another way."""
    value = re.sub(r"\s+#.*$", "", raw.strip()).strip()
    if not value or value[0] in "&*!|>[{%@`" or "\\" in value:
        return None
    if value[0] in "\"'":
        if len(value) < 2 or value[-1] != value[0] or value[0] in value[1:-1]:
            return None
        return value[1:-1]
    return value


def _profile(stem: str, text: str, pi_mode: bool = False) -> tuple[bool, dict[str, str], list[str]]:
    """Whether a file may be the worker profile, with its fields and the problems of reading it."""
    body = text.lstrip("﻿").replace("\r\n", "\n").replace("\r", "\n").lstrip()
    lines = body.split("\n")
    candidate = stem.casefold() == WORKER_NAME
    if not lines[0].startswith("---"):
        return candidate, {}, ["the profile has no frontmatter"] if candidate else []
    closers = ("---",) if pi_mode else ("---", "...")
    end = next((i for i in range(1, len(lines)) if lines[i].strip() in closers), None)
    if lines[0].strip() != "---" or end is None:
        return True, {}, ["the frontmatter cannot be read safely: its opening or its end is not a plain line"]
    region = lines[1:end]
    unclear = False
    names: list[tuple[int, str | None]] = []
    for line in region:
        if pi_mode and line.strip() == "...":
            unclear = True
        found = _NAME_LINE.match(line)
        if found:
            value = None if found.group(2) or found.group(3) else _scalar(found.group(4))
            names.append((len(found.group(1)), value))
        # At the left margin these start a flow mapping, a complex key, or a quoted key (which can spell
        # "name" with an escape): none of them is read here.
        if line and line[0] in "{[?\"'":
            unclear = True
    content = next((line for line in region if line.strip() and not line.lstrip().startswith("#")), "")
    unclear = unclear or content[:1] in (" ", "\t") or content.lstrip()[:1] in ("{", "[")
    unclear = unclear or any(value is None for _, value in names)
    unclear = unclear or sum(1 for indent, _ in names if indent == 0) > 1
    unclear = unclear or any(
        indent > 0 and value and value.strip().casefold() == WORKER_NAME for indent, value in names
    )
    # A merge key can bring a name in from an anchor defined anywhere.
    unclear = unclear or any("<<" in line for line in region)
    named = any(value and value.strip().casefold() == WORKER_NAME for _, value in names)
    if not (candidate or named or unclear):
        return False, {}, []
    fields: dict[str, str] = {}
    problems: list[str] = []
    for line in region:
        if not line.strip() or line.startswith("#"):
            continue
        if pi_mode and line.strip() == "...":
            problems.append("non-Pi '...' delimiter line in frontmatter")
            continue
        plain = _PLAIN_LINE.fullmatch(line.rstrip())
        if not plain:
            problems.append("the frontmatter must be plain `key: value` lines (no indentation, quoted keys, or lists)")
            continue
        key, raw = plain.group(1), plain.group(2) or ""
        value = _scalar(raw) if raw.strip() else ""
        if key in fields:
            problems.append(f"frontmatter key {key!r} appears twice")
        elif value is None:
            problems.append(f"the value of {key!r} cannot be read safely")
        else:
            fields[key] = value
    if unclear:
        problems.append("the profile's name cannot be established from its frontmatter")
    return True, fields, problems


def _worker_problems(fields: dict[str, str], read_only: set[str]) -> list[str]:
    problems: list[str] = []
    for key in sorted(set(fields) - WORKER_FRONTMATTER):
        problems.append(f"frontmatter key {key!r} is not one the worker profile carries")
    tools = [tool.strip() for tool in fields.get("tools", "").split(",") if tool.strip()]
    if not tools:
        problems.append("the tools list is missing or empty: an omitted list grants every tool")
    for tool in tools:
        if tool not in WORKER_NATIVE_TOOLS and tool not in read_only:
            problems.append(f"tool {tool!r} is neither a worker tool nor a read-only MCP tool")
    return problems


def _pi_worker_problems(fields: dict[str, str], read_only: set[str]) -> list[str]:
    problems: list[str] = []
    for key in sorted(set(fields) - PI_WORKER_FRONTMATTER):
        problems.append(f"frontmatter key {key!r} is not one the Pi worker profile carries")
    tools = [tool.strip() for tool in fields.get("tools", "").split(",") if tool.strip()]
    if not tools:
        problems.append("the tools list is missing or empty: an omitted list grants every tool")
    for tool in tools:
        if tool not in PI_WORKER_NATIVE_TOOLS and tool not in read_only:
            problems.append(f"tool {tool!r} is neither a Pi worker tool nor a read-only MCP tool")
    excluded = {item.strip() for item in fields.get("excludeTools", "").split(",") if item.strip()}
    for required in PI_WORKER_EXCLUDED:
        if required not in excluded:
            problems.append(f"excludeTools must include {required!r}")
    if fields.get("allowNestedSubagents") != "false":
        problems.append("allowNestedSubagents must be 'false'")
    return problems


def _pi_settings_problems(scopes: list[tuple[str, Path]]) -> list[str]:
    problems: list[str] = []
    for scope, path in scopes:
        if not path.exists() and not path.is_symlink():
            continue
        try:
            data = json.loads(read_file(path).decode())
        except (OSError, Refused, UnicodeDecodeError, ValueError):
            problems.append(f"{scope} settings {path} could not be read safely")
            continue
        subagents = data.get("subagents") if isinstance(data, dict) else None
        if not isinstance(subagents, dict):
            continue
        overrides = subagents.get("agentOverrides")
        if isinstance(overrides, dict) and WORKER_NAME in overrides:
            problems.append(f"{scope} settings {path}: subagents.agentOverrides.{WORKER_NAME} overrides the worker")
        by_provider = subagents.get("agentOverridesByProvider")
        if isinstance(by_provider, dict) and any(
            isinstance(entry, dict) and WORKER_NAME in entry for entry in by_provider.values()
        ):
            problems.append(f"{scope} settings {path}: subagents.agentOverridesByProvider overrides {WORKER_NAME}")
        for key in ("agentScanDirs", "agentExcludeDirs", "defaultSubagentOnlyExtensions"):
            if key in subagents and subagents[key] != []:
                problems.append(
                    f"{scope} settings {path}: subagents.{key} alters child discovery or extensions outside the profile"
                )
        if "defaultExtensions" in subagents:
            problems.append(
                f"{scope} settings {path}: subagents.defaultExtensions alters child extensions outside the profile"
            )
    return problems


def _agent_files(folder: Path) -> tuple[list[Path], list[str]]:
    """Every markdown file under an agents folder; a link inside it cannot be checked, so it is a problem."""
    files: list[Path] = []
    problems: list[str] = []
    for current, dirs, names in os.walk(folder):
        for entry in sorted([*dirs, *names]):
            path = Path(current) / entry
            if path.is_symlink():
                problems.append(
                    f"a symbolic link under the agents folder cannot be checked: {path.relative_to(folder)}"
                )
        files += [Path(current) / name for name in sorted(names) if name.endswith(".md")]
        dirs[:] = sorted(d for d in dirs if not (Path(current) / d).is_symlink())
        if len(files) > MAX_AGENT_FILES:
            return files[:MAX_AGENT_FILES], [*problems, "too many files under the agents folder to check"]
    return [path for path in files if not path.is_symlink()], problems


def cmd_worker_profile(args: dict) -> dict:
    """Check the b-worker profile in effect against the worker's allowlist (read-only)."""
    root = repo_root()
    policy = read_json(mcp_policy_path(), "mcp_operations.yaml")
    pi_mode = on_pi()
    read_only = {
        (f"mcp:{server}/{tool}" if pi_mode else f"mcp__{server}__{tool}")
        for server, record in (policy.get("servers") or {}).items()
        for tool, classification in (record.get("tools") or {}).items()
        if classification == "read-only"
    }
    here = Path.cwd().resolve()
    step_id = args.get("step")
    if step_id is not None:
        if not re.fullmatch(r"S-[1-9][0-9]*", step_id):
            raise Invalid("--step must name a plan step like S-1")
        _, directory = resolve_run(root, args.get("run"))
        state = read_state(directory)
        if wt := _worktree_dir(root, state, step_id):
            here = Path(wt).resolve()
    # Project agents folders: from the effective launch cwd up to the repository root (or up to HOME
    # for an isolated worktree outside the repository).
    if root == here or root in here.parents:
        all_parents = [here, *here.parents]
        folders = all_parents[: all_parents.index(root) + 1]
    else:
        home_resolved = Path.home().resolve()
        folders = []
        for folder in (here, *here.parents):
            if folder == home_resolved:
                break
            folders.append(folder)
    if pi_mode:
        pi_home = Path(os.environ.get("PI_CODING_AGENT_DIR") or (Path.home() / ".pi" / "agent")).expanduser()
        scopes = [
            item
            for folder in folders
            for item in (("project", folder / ".pi" / "agents"), ("project", folder / ".agents"))
        ]
        scopes.extend([("user", pi_home / "agents"), ("user", Path.home() / ".agents")])
        settings_scopes = [("project", folder / ".pi" / "settings.json") for folder in folders]
        settings_scopes.append(("user", pi_home / "settings.json"))
    else:
        scopes = [("project", folder / ".claude" / "agents") for folder in folders]
        scopes.append(("user", Path.home() / ".claude" / "agents"))
        settings_scopes = []
    problems: list[str] = []
    found: list[str] = []
    user_named: list[tuple[str, dict[str, str]]] = []
    check_profile = _pi_worker_problems if pi_mode else _worker_problems
    for scope, folder in scopes:
        if not folder.is_dir():
            continue
        files, issues = _agent_files(folder)
        problems += [f"{scope}: {issue}" for issue in issues]
        named: list[tuple[str, dict[str, str]]] = []
        for path in files:
            label = f"{scope} profile {path.relative_to(folder)}"
            try:
                text = read_file(path).decode()
            except (OSError, Refused, UnicodeDecodeError):
                problems.append(f"{label} is not a readable regular text file")
                continue
            may_be_worker, fields, issues = _profile(path.stem, text, pi_mode=pi_mode)
            if may_be_worker:
                named.append((label, fields))
                problems += [f"{label}: {issue}" for issue in issues]
        if scope == "user":
            user_named.extend(named)
        elif len(named) > 1:
            problems.append(f"{scope}: more than one profile may be {WORKER_NAME}: " + ", ".join(n for n, _ in named))
        for label, fields in named:
            problems += [f"{label}: {issue}" for issue in check_profile(fields, read_only)]
        found += [scope] * len(named)
    if len(user_named) > 1:
        problems.append(f"user: more than one profile may be {WORKER_NAME}: " + ", ".join(n for n, _ in user_named))
    if pi_mode:
        problems += _pi_settings_problems(settings_scopes)
    if not found:
        problems.append("no b-worker profile is installed")
    return {"ok": not problems, "source": found[0] if found else "none", "profiles": len(found), "problems": problems}


def cmd_selftest(schema: dict) -> dict:
    ctx: dict = {}
    for kind in ("spec", "plan", "qa", "followups"):
        example = schema["kinds"][kind]["example"]
        validate_input(kind, example, ctx, schema, None)
        render(kind, example)
        ctx[kind] = example
    return {"ok": True, "kinds": sorted(ctx)}


# ---- run folder cleanup -----------------------------------------------------------
# Only finished runs (phase done) are ever listed for removal. Every other phase may be resumed, so it is
# kept. Reads and deletes go through directory file descriptors opened without following links, so a link
# planted under .b-agentic cannot point a removal outside the run folders. Nothing here recurses.

PRUNE_DAYS = 30
MAX_PRUNE_DAYS = 3650
HINT_RUNS = 40
HINT_BYTES = 50 << 20
OPEN_DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def prune_days(args: dict) -> int:
    raw = args.get("days")
    if raw is None:
        return PRUNE_DAYS
    if not re.fullmatch(r"[1-9][0-9]{0,3}", raw) or int(raw) > MAX_PRUNE_DAYS:
        raise Invalid(f"--days needs a whole number from 1 to {MAX_PRUNE_DAYS}")
    return int(raw)


def _read_json_at(dir_fd: int, name: str) -> dict | None:
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dir_fd)
    except OSError:
        return None
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_FILE:
            return None
        value = json.loads(os.read(fd, info.st_size) if info.st_size else b"")
    except (OSError, ValueError):
        return None
    finally:
        os.close(fd)
    return value if isinstance(value, dict) else None


def _updated_at(value: object) -> datetime | None:
    from datetime import datetime, timezone

    if not isinstance(value, str):
        return None
    try:
        moment = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return moment if moment.tzinfo else moment.replace(tzinfo=timezone.utc)


def _inspect_run(runs_fd: int, name: str, active: str | None, cutoff: datetime) -> tuple[str, int, int | None]:
    """Classify one entry of the runs folder: (category, bytes of its plain files, open folder fd).

    The fd is returned only for an eligible run, still open: the caller removes through that same
    descriptor, so what is deleted is exactly the folder that was inspected, never a replacement.
    """
    try:
        info = os.stat(name, dir_fd=runs_fd, follow_symlinks=False)
    except OSError:
        return "unexpected", 0, None
    if stat.S_ISLNK(info.st_mode):
        return "symlink", 0, None
    if not stat.S_ISDIR(info.st_mode):
        return "unexpected", 0, None
    try:
        fd = os.open(name, OPEN_DIR, dir_fd=runs_fd)
    except OSError:
        return "unexpected", 0, None
    keep = False
    try:
        size = 0
        plain = True
        for entry in os.listdir(fd):
            try:
                child = os.stat(entry, dir_fd=fd, follow_symlinks=False)
            except OSError:
                plain = False
                continue
            # mutex is the init lock: a run folder holding one is being created right now.
            if not stat.S_ISREG(child.st_mode) or entry == "mutex":
                plain = False
                continue
            size += child.st_size
        if not plain:
            return "unexpected", size, None
        if name == active:
            return "active", size, None
        state = _read_json_at(fd, "state.json")
        if state is None or state.get("run_id") != name or not isinstance(state.get("phase"), str):
            return "unreadable", size, None
        if state["phase"] != "done":
            return "unfinished", size, None
        updated = _updated_at(state.get("updated_at"))
        if updated is None:
            return "unreadable", size, None
        if updated > cutoff:
            return "recent", size, None
        keep = True
        return "eligible", size, fd
    finally:
        if not keep:
            os.close(fd)


def _remove_run(runs_fd: int, name: str, run_fd: int) -> None:
    """Delete the plain files of the inspected folder through its own fd, then its name if it is still that folder."""
    try:
        inspected = os.fstat(run_fd)
        for entry in os.listdir(run_fd):
            os.unlink(entry, dir_fd=run_fd)
        current = os.stat(name, dir_fd=runs_fd, follow_symlinks=False)
        if (current.st_dev, current.st_ino) != (inspected.st_dev, inspected.st_ino):
            raise OSError(errno.ESTALE, "the folder was replaced while it was being removed; the replacement is kept")
        os.rmdir(name, dir_fd=runs_fd)
    finally:
        os.close(run_fd)


def _open_dir(name: str, parent_fd: int) -> int | None:
    """Open a folder below parent_fd without following a link; None when it does not exist."""
    try:
        return os.open(name, OPEN_DIR, dir_fd=parent_fd)
    except FileNotFoundError:
        return None
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.ENOTDIR):
            raise Refused(f"{name} is a link or not a folder; nothing was read") from exc
        raise


def _read_active(base_fd: int) -> str | None:
    try:
        fd = os.open("active", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=base_fd)
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise Refused("the active run file is unreadable; nothing was classified") from exc
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > 256:
            raise Refused("the active run file is unreadable; nothing was classified")
        return os.read(fd, info.st_size).decode().strip() or None
    except (OSError, UnicodeDecodeError) as exc:
        raise Refused("the active run file is unreadable; nothing was classified") from exc
    finally:
        os.close(fd)


def _scan_runs(root: Path, days: int, remove: bool) -> dict:
    from datetime import datetime, timedelta, timezone

    kept = {"active": 0, "unfinished": 0, "recent": 0, "unreadable": 0, "unexpected": 0, "symlink": 0, "ignored": 0}
    result: dict = {"ok": True, "runs": 0, "bytes": 0, "days": days, "eligible": [], "eligible_bytes": 0, "kept": kept}
    removed: list[str] = []
    problems: list[str] = []
    # Every folder is opened relative to the one before it with no link followed, so a link swapped in
    # for .b-agentic or runs after this point cannot move the scan or a removal outside the worktree.
    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    base_fd = runs_fd = None
    try:
        base_fd = _open_dir(".b-agentic", root_fd)
        runs_fd = _open_dir("runs", base_fd) if base_fd is not None else None
        if runs_fd is None:
            result["over_threshold"] = False
            return result
        if remove:
            try:
                os.stat("mutex", dir_fd=base_fd, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                raise Refused("a run is being created (.b-agentic/mutex exists); try again when it finishes")
        active = _read_active(base_fd)
        cutoff = datetime.now(timezone.utc) - timedelta(days=days)
        for name in sorted(os.listdir(runs_fd)):
            if not RUN_ID.fullmatch(name):
                kept["ignored"] += 1
                continue
            category, size, run_fd = _inspect_run(runs_fd, name, active, cutoff)
            result["runs"] += 1
            result["bytes"] += size
            if category != "eligible":
                kept[category] += 1
                continue
            result["eligible"].append(name)
            result["eligible_bytes"] += size
            if remove and run_fd is not None:
                try:
                    _remove_run(runs_fd, name, run_fd)
                    removed.append(name)
                except OSError as exc:
                    problems.append(f"{name}: {exc.strerror or exc}")
            elif run_fd is not None:
                os.close(run_fd)
    finally:
        for fd in (runs_fd, base_fd, root_fd):
            if fd is not None:
                os.close(fd)
    result["over_threshold"] = result["runs"] > HINT_RUNS or result["bytes"] > HINT_BYTES
    if remove:
        result["removed"] = removed
        result["problems"] = problems
        result["ok"] = not problems
    return result


def _only_options(command: str, args: dict, allowed: set[str]) -> None:
    # The parser accepts the options of every command; one that prune or runs ignores would silently widen
    # what it covers (--run ID would delete every eligible run), so anything unused is refused.
    extra = sorted(set(args) - allowed - {"owner"})
    if extra:
        raise Invalid(f"{command} does not take {', '.join('--' + name for name in extra)}")


def cmd_runs(args: dict) -> dict:
    if args.get("apply"):
        raise Invalid("runs only reports; --apply belongs to prune")
    _only_options("runs", args, {"days"})
    return {**_scan_runs(repo_root(), prune_days(args), False), "thresholds": {"runs": HINT_RUNS, "bytes": HINT_BYTES}}


def cmd_prune(args: dict) -> dict:
    _only_options("prune", args, {"days", "apply"})
    days = prune_days(args)
    apply = bool(args.get("apply"))
    result = _scan_runs(repo_root(), days, apply)
    result["applied"] = apply
    return result


# ---- run stats (ADR-035) -------------------------------------------------------

STATS_SALT = "b-agentic-run-stats:v1:"
# The reason b-state-core.mjs BUDGET_REASON gives the run time budget's block (ADR-039).
BUDGET_REASON = "run time budget reached"
# The install home of each runtime, below the user's home: the store lives beside the installed helpers.
STATS_HOMES = {"claude": (".claude", "b-agentic"), "pi": (".pi", "agent", "b-agentic")}
STATS_LOCK_SECONDS = 1.0


def _stats_block(schema: dict) -> dict:
    block = schema.get("run_stats")
    if not isinstance(block, dict):
        raise Invalid("artifacts.yaml: run_stats is missing")
    return block


def _stats_value(spec: dict, value: object, path: str, schema: dict) -> None:
    kind = spec["type"]

    def bad(why: str) -> Invalid:
        return Invalid(f"run_stats.{path}: {why}")

    if kind in ("count", "seconds"):
        if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 10**9:
            raise bad("expected a non-negative whole number")
    elif kind == "bool":
        if not isinstance(value, bool):
            raise bad("expected true or false")
    elif kind == "enum":
        if value not in spec["values"]:
            raise bad(f"expected one of {spec['values']}")
    elif kind == "hexkey":
        if not isinstance(value, str) or not re.fullmatch(f"[0-9a-f]{{{spec['length']}}}", value):
            raise bad(f"expected {spec['length']} lowercase hex characters")
    elif kind == "date":
        import datetime

        try:
            if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
                raise ValueError(value)
            datetime.date.fromisoformat(value)
        except ValueError as exc:
            raise bad("expected a YYYY-MM-DD date") from exc
    elif kind == "counts":
        names = spec.get("keys") or [*schema["enums"][spec["enum"]], *spec.get("extra", [])]
        if not isinstance(value, dict) or any(key not in names for key in value):
            raise bad(f"expected counts keyed by {names}")
        for key, count in value.items():
            _stats_value({"type": "count"}, count, f"{path}.{key}", schema)
    else:
        _stats_object(spec["fields"], value, path, schema)


def _stats_object(fields: dict, value: object, path: str, schema: dict) -> None:
    prefix = f"{path}." if path else ""
    if not isinstance(value, dict):
        raise Invalid(f"run_stats.{path or 'record'}: expected an object")
    extra = sorted(set(value) - set(fields))
    if extra:
        raise Invalid(f"run_stats.{prefix}{extra[0]}: not an allowed field")
    for name, spec in fields.items():
        if name not in value:
            if not spec.get("optional"):
                raise Invalid(f"run_stats.{prefix}{name}: missing")
            continue
        _stats_value(spec, value[name], f"{prefix}{name}", schema)


def stats_check(record: dict, schema: dict) -> None:
    """Refuse any record that is not exactly the numbers the run_stats block allows (ADR-035)."""
    _stats_object(_stats_block(schema)["fields"], record, "", schema)
    _kit_group(record)


def _stats_known(line: dict, fields: dict) -> dict:
    """The line without time_stops when this schema does not list it: the other runtime's newer helper may count it."""
    if "time_stops" in fields:
        return line
    return {name: value for name, value in line.items() if name != "time_stops"}


KIT_STATS = ("kit_seq", "kit_date", "kit_commit", "kit_dirty")


def _kit_group(record: dict) -> None:
    """The rule across the kit fields (ADR-036): all four or none, a real sequence, kit_changed only beside them."""
    held = [name for name in KIT_STATS if name in record]
    if held and len(held) != len(KIT_STATS):
        raise Invalid("run_stats: the kit fields go all four or none")
    if held and record["kit_seq"] < 1:
        raise Invalid("run_stats.kit_seq: expected a positive number")
    if "kit_changed" in record and not held:
        raise Invalid("run_stats.kit_changed: needs the kit fields")


def stats_repo_key(root: Path) -> str | None:
    """Hash of the repository's root commits: stable across moves and clones, and it holds no name."""
    import hashlib
    import time

    # One limit for both runs: two limits of their own could together outlast the live record's caller.
    ends = time.monotonic() + KEY_GIT_SECONDS

    def asked(*args: str) -> str:
        return hardened_git(root, *args, ends=ends)[1]

    try:
        # A shallow clone's boundary commits look like roots, so its key would change when the clone is deepened.
        if asked("rev-parse", "--is-shallow-repository").strip() != "false":
            return None
        roots = sorted(asked("rev-list", "--max-parents=0", "HEAD").split())
    except Refused:
        return None
    if not roots:
        return None
    return hashlib.sha256((STATS_SALT + "\n".join(roots)).encode()).hexdigest()[:16]


def _is_valid_timestamp(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) <= 300
        and bool(ISO_TIMESTAMP.fullmatch(value))
        and _updated_at(value) is not None
    )


def _safe_key_text(value: object, what: str) -> str:
    if not isinstance(value, str):
        raise Invalid(f"invalid {what}")
    try:
        value.encode("utf-8")
    except UnicodeEncodeError as exc:
        raise Invalid(f"invalid {what}") from exc
    return value


def _run_started(state: dict) -> str:
    """When the run was initialised: uses started_at when validated, or the retained init entry's timestamp."""
    history = state.get("history")
    first = history[0] if isinstance(history, list) and history and isinstance(history[0], dict) else {}
    dropped = state.get("history_dropped")
    if dropped is None:
        dropped = 0
    if dropped == 0 and first.get("op") == "init":
        return _safe_key_text(first.get("at", ""), "history[0].at")
    if "started_at" in state:
        if not _is_valid_timestamp(state["started_at"]):
            raise Invalid("invalid started_at")
        return state["started_at"]
    return _safe_key_text(first.get("at", ""), "history[0].at")


def stats_run_key(state: dict) -> str:
    """The run's key: its id and init time only, so a change of the repository's root commits never changes it."""
    import hashlib

    material = f"{STATS_SALT}run2:{state['run_id']}:{_run_started(state)}"
    return hashlib.sha256(material.encode()).hexdigest()[:16]


def stats_legacy_run_key(repo_key: str, state: dict) -> str:
    """The key lines carried before ADR-035 dropped the repository key from it: still recognised, never written."""
    import hashlib

    material = f"{STATS_SALT}run:{repo_key}:{state['run_id']}:{_run_started(state)}"
    return hashlib.sha256(material.encode()).hexdigest()[:16]


def _history_seconds(history: list) -> tuple[dict[str, int], int]:
    """Seconds per phase from the gaps between history entries, each gap given to the phase the run was in."""
    per_phase: dict[str, int] = {}
    total = 0
    previous: tuple[datetime, str] | None = None
    for entry in history:
        moment = _updated_at(entry.get("at"))
        if moment is None:
            continue
        if previous is not None:
            gap = max(0, int((moment - previous[0]).total_seconds()))
            total += gap
            per_phase[previous[1]] = per_phase.get(previous[1], 0) + gap
        previous = (moment, str(entry.get("to", "")))
    return per_phase, total


def _kit_snapshot(value: object, schema: dict) -> dict | None:
    """One kit version from state.json: all four fields valid, or nothing."""
    if not isinstance(value, dict):
        return None
    block = _stats_block(schema)["fields"]
    snapshot = {name: value.get(name) for name in KIT_STATS}
    try:
        for name in KIT_STATS:
            _stats_value(block[name], snapshot[name], name, schema)
        _kit_group(snapshot)
    except Invalid:
        return None
    return snapshot


def _kit_stats(state: dict, schema: dict) -> dict:
    """The kit fields of a run's line (ADR-036): the version at init, and whether it changed by done.

    Only state.json is read, so a catch-up never takes a version from what is installed now.
    """
    kit = state.get("kit")
    # An install can keep an older, user-edited artifacts.yaml beside newer helpers: then the line is written
    # without a version instead of being refused.
    allowed = _stats_block(schema)["fields"]
    if not isinstance(kit, dict) or any(name not in allowed for name in (*KIT_STATS, "kit_changed")):
        return {}
    init, done = _kit_snapshot(kit.get("init"), schema), _kit_snapshot(kit.get("done"), schema)
    if init is None:
        return {}
    if done is not None:
        if any(init[name] != done[name] for name in ("kit_commit", "kit_dirty")):
            return {**init, "kit_changed": True}
        # Two dirty trees at one commit may or may not differ, so that case says nothing.
        if not init["kit_dirty"]:
            return {**init, "kit_changed": False}
    return init


def stats_record(state: dict, artifacts: dict, repo_key: str, schema: dict) -> dict:
    """The numbers of one finished run, derived from state.json and artifacts.json only."""
    block = _stats_block(schema)["fields"]
    held = artifacts.get("artifacts", {})
    spec = held.get("spec", {}).get("data", {})
    plan = held.get("plan", {}).get("data", {})
    items = held.get("followups", {}).get("data", {}).get("items", [])
    history = [entry for entry in state.get("history", []) if isinstance(entry, dict)]
    run_id = str(state["run_id"])
    per_phase, total = _history_seconds(history)
    phases = block["dur_s"]["keys"]
    review, qa = state.get("review", {}), state.get("qa", {})
    gates: dict[str, int] = {}
    for entry in history:
        detail = entry.get("detail", {}) if isinstance(entry.get("detail"), dict) else {}
        if entry.get("op") == "record review" and detail.get("gate") in block["review"]["fields"]["by_gate"]["keys"]:
            gates[detail["gate"]] = gates.get(detail["gate"], 0) + 1
    checks = [e for e in history if e.get("op") == "record check"]
    classes = schema["enums"]["blocker_class"]
    stages = schema["enums"]["escape_stage"]
    by_class: dict[str, int] = {}
    escaped: dict[str, int] = {}
    blockers = {"review": 0, "qa": 0}
    for item in items:
        if not isinstance(item, dict):
            continue
        is_blocker = item.get("kind") == "blocker"
        if is_blocker and item.get("source") in blockers:
            blockers[item["source"]] += 1
            name = item.get("blocker_class") if item.get("blocker_class") in classes else "unclassified"
            by_class[name] = by_class.get(name, 0) + 1
        if item.get("escaped_from") in stages:
            escaped[item["escaped_from"]] = escaped.get(item["escaped_from"], 0) + 1
        elif is_blocker:
            escaped["unclassified"] = escaped.get("unclassified", 0) + 1
    results: dict[str, int] = {}
    for entry in state.get("ac", {}).values():
        status = entry.get("status") if isinstance(entry, dict) else None
        if status in block["ac"]["keys"]:
            results[status] = results.get(status, 0) + 1
    record: dict = {
        "v": 1,
        "repo": repo_key,
        "run": stats_run_key(state),
        "date": f"{run_id[:4]}-{run_id[4:6]}-{run_id[6:8]}",
        "size": state.get("size", "full"),
        "end": "commit" if state.get("commits") else "qa",
        "steps": len(plan.get("steps", [])),
        "criteria": len(spec.get("criteria", [])),
        "scope_paths": len(spec.get("scope_paths", [])),
        "worker_steps": len(plan.get("worker_steps", [])),
        "parallel_steps": len(plan.get("parallel_steps", [])),
        "dur_s": {name: seconds for name, seconds in per_phase.items() if name in phases},
        "total_s": total,
        "history_complete": state.get("history_dropped") == 0,
        "review": {
            "rounds": review.get("round", 0),
            "by_gate": gates,
            "low_risk": bool(review.get("low_risk_exception")),
        },
        "qa": {"rounds": qa.get("round", 0)},
        "fix_rounds": sum(1 for e in history if e.get("op") == "advance" and e.get("to") == "fix"),
        "blocked_count": sum(1 for e in history if e.get("to") == "blocked"),
        "checks_total": len(checks),
        "checks_failed": sum(
            1 for e in checks if isinstance(e.get("detail"), dict) and e["detail"].get("exit") not in (0, None)
        ),
        "commits": len(state.get("commits", [])),
        "ac": results,
        "blockers": {**blockers, "by_class": by_class},
        "escaped_from": escaped,
    }
    # An install can keep an older, user-edited artifacts.yaml beside newer helpers, as in _kit_stats.
    if "time_stops" in block:
        record["time_stops"] = sum(
            1
            for e in history
            if e.get("to") == "blocked"
            and isinstance(e.get("detail"), dict)
            and e["detail"].get("reason") == BUDGET_REASON
        )
    if state.get("runtime") in block["runtime"]["values"]:
        record["runtime"] = state["runtime"]
    if review.get("verdict") in block["review"]["fields"]["verdict"]["values"]:
        record["review"]["verdict"] = review["verdict"]
    if qa.get("verdict") in block["qa"]["fields"]["verdict"]["values"]:
        record["qa"]["verdict"] = qa["verdict"]
    record.update(_kit_stats(state, schema))
    return record


def stats_dir(runtime: str) -> Path:
    return Path.home().joinpath(*STATS_HOMES[runtime])


def _stats_shown(runtime: str, name: str) -> str:
    return "~/" + "/".join((*STATS_HOMES[runtime], name))


def _stats_off(dir_fd: int, name: str) -> str | None:
    """A reason when run-stats.off exists in any form (or cannot be read), None when it is absent."""
    try:
        os.lstat(name, dir_fd=dir_fd)
    except FileNotFoundError:
        return None
    except OSError:
        return "flag-unreadable"
    return "disabled"


def _stats_read_all(fd: int, limit: int) -> bytes:
    chunks: list[bytes] = []
    offset = 0
    while offset < limit:
        chunk = os.pread(fd, min(1 << 16, limit - offset), offset)
        if not chunk:
            break
        chunks.append(chunk)
        offset += len(chunk)
    return b"".join(chunks)


def stats_lines(data: bytes) -> list[dict | None]:
    """Each line of a store as a record, or None for a line that is not a JSON object."""
    out: list[dict | None] = []
    for raw in data.split(b"\n"):
        if not raw.strip():
            continue
        try:
            value = json.loads(raw)
        except (ValueError, RecursionError):  # RecursionError: a line nested too deeply to parse
            out.append(None)
            continue
        out.append(value if isinstance(value, dict) else None)
    return out


def _own_private_group(gid: int) -> bool:
    """True when the user is the only person in that group, by its member list and by the accounts that use it."""
    import grp
    import pwd

    try:
        uid = os.getuid()
        if set(grp.getgrgid(gid).gr_mem) - {pwd.getpwuid(uid).pw_name}:
            return False
        return all(entry.pw_uid == uid for entry in pwd.getpwall() if entry.pw_gid == gid)
    except (KeyError, OSError):
        return False


def _home_private(info: os.stat_result, dir_fd: int) -> bool:
    """The install home is the user's, closed to others, and open to a group only when that group is the user's alone."""
    if info.st_uid != os.getuid() or info.st_mode & 0o002:
        return False
    if not info.st_mode & 0o020:
        return True
    if info.st_gid != os.getgid() or not _own_private_group(info.st_gid):
        return False
    # With an access ACL the group bits are only its mask, so a named entry could let another account write:
    # a group-writable home is accepted only when no ACL is present, and refused when that cannot be checked.
    try:
        return not any(name.startswith("system.posix_acl") for name in os.listxattr(dir_fd))
    except (AttributeError, OSError):
        return False


def stats_append(runtime: str, block: dict, record: dict, line: bytes, legacy_run: str = "") -> dict:
    """Append one line to the runtime's store, creating it safely on first use. Never raises: a problem is a skip reason."""

    def recorded(data: bytes) -> bool:
        return any(known and known.get("run") in (record["run"], legacy_run) for known in stats_lines(data))

    return _locked_append(runtime, block["store"], block["off"], block["max_file"], line, recorded, "store")


def _locked_append(
    runtime: str,
    store: str,
    off: str,
    max_file: int,
    line: bytes,
    seen,
    kind: str,
    lock_seconds: float = STATS_LOCK_SECONDS,
) -> dict:
    """The one writer of a JSONL file in the install home: the run-stats store and the repository registry (kind).

    `seen` says whether the bytes already there make this line a repeat. Never raises.
    """
    import fcntl
    import time

    result = {"status": "skipped", "reason": "", "created": False}

    def skip(reason: str) -> dict:
        result["reason"] = reason
        return result

    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    try:
        dir_fd = os.open(stats_dir(runtime), flags)
    except FileNotFoundError:
        return skip("no-install-home")
    except OSError:
        return skip("home-not-plain")
    fd = -1
    try:
        if not _home_private(os.fstat(dir_fd), dir_fd):
            return skip("home-not-private")
        reason = _stats_off(dir_fd, off)
        if reason:
            return skip(reason)
        # O_NONBLOCK: a FIFO with no writer must not hang the open; the type is checked right after.
        base = os.O_RDWR | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0)
        try:
            fd = os.open(store, base, dir_fd=dir_fd)
        except FileNotFoundError:
            try:
                fd = os.open(store, base | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=dir_fd)
                result["created"] = True
            except FileExistsError:
                try:
                    fd = os.open(store, base, dir_fd=dir_fd)
                except OSError:
                    return skip(f"{kind}-unopenable")
            except OSError:
                return skip(f"{kind}-uncreatable")
        except OSError:
            return skip(f"{kind}-unopenable")
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
            return skip(f"{kind}-not-plain")
        if info.st_mode & 0o077:
            return skip(f"{kind}-loose-mode")
        if info.st_size + len(line) > max_file:
            return skip(f"{kind}-full")
        deadline = time.monotonic() + lock_seconds
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.monotonic() >= deadline:
                    return skip(f"{kind}-busy")
                time.sleep(0.05)
        info = os.fstat(fd)
        size = info.st_size
        if size + len(line) + 1 > max_file:
            return skip(f"{kind}-full")
        data = _stats_read_all(fd, size)
        if seen(data):
            result["status"] = "already"
            return result
        # An interrupted writer can leave a tail without a newline: end it so this line starts on its own.
        payload = (b"\n" if data and not data.endswith(b"\n") else b"") + line
        # Checked last, right before the write, so a flag created during the scan above is still honored.
        reason = _stats_off(dir_fd, off)
        if reason:
            return skip(reason)
        try:
            written = os.write(fd, payload)
        except OSError:
            written = -1
        if written != len(payload):
            # A partial line would corrupt the next append: cut the file back to its size before this write.
            try:
                os.ftruncate(fd, size)
            except OSError:
                pass
            return skip("short-write")
        result["status"] = "written"
        return result
    except OSError:
        return skip("io-error")
    finally:
        if fd >= 0:
            os.close(fd)
        os.close(dir_fd)


# ---- repository registry (ADR-037) ----------------------------------------------
# Where each repository key is checked out, one file per runtime beside its store. Unlike the store it holds paths.

REGISTRY = "run-stats-repos.jsonl"
REGISTRY_MAX_FILE = 1 << 20
REGISTRY_MAX_LINE = 4096
REGISTRY_MAX_PATH = 1024
REPO_KEY = re.compile(r"[0-9a-f]{16}")
# The registry waits for its lock only while the record call is younger than this: the caller of the live record
# stops waiting after 10 s, and the store line already written must still be reported.
REGISTRY_QUICK_SECONDS = 2.0


def _registry_path_ok(path: object) -> bool:
    """An absolute, normalized, printable path of bounded length: the only kind written or believed."""
    if not isinstance(path, str) or not os.path.isabs(path) or os.path.normpath(path) != path:
        return False
    if any(ord(char) < 32 or ord(char) == 127 for char in path):
        return False
    try:
        return len(path.encode("utf-8")) <= REGISTRY_MAX_PATH
    except UnicodeEncodeError:  # a name that is not UTF-8 reaches Python as lone surrogates
        return False


def _registry_entries(data: bytes) -> tuple[int, list[tuple[str, str]]]:
    """How many lines the registry bytes hold, and the (key, path) of each sound one, oldest first. The writer
    and the readers both believe only these.
    """
    lines = 0
    entries: list[tuple[str, str]] = []
    for raw in data.split(b"\n"):
        if not raw.strip():
            continue
        lines += 1
        entry = stats_lines(raw)[0] if len(raw) < REGISTRY_MAX_LINE else None
        if (
            entry is not None
            and set(entry) == {"v", "repo", "path"}
            and type(entry["v"]) is int
            and entry["v"] == 1
            and isinstance(entry["repo"], str)
            and REPO_KEY.fullmatch(entry["repo"])
            and _registry_path_ok(entry["path"])
        ):
            entries.append((entry["repo"], entry["path"]))
    return lines, entries


def _register_checkout(
    runtime: str, off: str, repo_key: str, root: Path, lock_seconds: float = STATS_LOCK_SECONDS
) -> tuple[str, bool]:
    """Remember where this repository is checked out, as (outcome, created). It never raises and never changes
    what recording the store line returns. It runs no git: the caller's deadline also covers what is already written.

    `root` is the folder the key was looked up in. It is registered only when it is the checkout around the
    working directory, so no GIT_ variable or git setting picks the path.
    """
    try:
        here = _checkout_here()
        if here is None or not os.path.samefile(here, root):
            return "skipped:other-worktree", False
        path = str(here)
        line = (json.dumps({"v": 1, "repo": repo_key, "path": path}, separators=(",", ":")) + "\n").encode()
        if not _registry_path_ok(path) or len(line) > REGISTRY_MAX_LINE:
            return "skipped:path-unusable", False

        def listed(data: bytes) -> bool:
            return (repo_key, path) in _registry_entries(data)[1]

        result = _locked_append(runtime, REGISTRY, off, REGISTRY_MAX_FILE, line, listed, "registry", lock_seconds)
        outcome = f"skipped:{result['reason']}" if result["status"] == "skipped" else result["status"]
        return outcome, result["created"]
    except Exception:  # whatever goes wrong here stays here
        return "failed", False


def _read_registry(runtime: str, off: str) -> dict:
    """One runtime's registry, opened read-only under the rules it is written by: its state, the off flag, and
    the (key, path) entries of its sound lines, oldest first. A file the writer would not write gives no entry.
    """
    out: dict = {
        "status": "unreadable",
        "disabled": False,
        "truncated": False,
        "lines": 0,
        "malformed": 0,
        "entries": [],
    }

    def ended(status: str) -> dict:
        out["status"] = status
        return out

    try:
        dir_fd = os.open(stats_dir(runtime), OPEN_DIR)
    except FileNotFoundError:
        return ended("absent")
    except OSError:
        return ended("home-not-plain")
    try:
        if not _home_private(os.fstat(dir_fd), dir_fd):
            return ended("home-not-private")
        out["disabled"] = _stats_off(dir_fd, off) is not None
        try:
            # O_NONBLOCK: a FIFO with no writer must not hang the open; the type is checked right after.
            fd = os.open(REGISTRY, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dir_fd)
        except FileNotFoundError:
            return ended("absent")
        except OSError as exc:
            return ended("not-plain" if exc.errno == errno.ELOOP else "unreadable")
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
                return ended("not-plain")
            if info.st_mode & 0o077:
                return ended("loose-mode")
            data = _stats_read_all(fd, min(info.st_size, REGISTRY_MAX_FILE))
        finally:
            os.close(fd)
    except OSError:
        return ended("unreadable")
    finally:
        os.close(dir_fd)
    out["truncated"] = info.st_size > REGISTRY_MAX_FILE
    out["lines"], out["entries"] = _registry_entries(data)
    out["malformed"] = out["lines"] - len(out["entries"])
    return ended("read")


def _finished_runs(root: Path) -> list[tuple[str, dict, Path]]:
    """This repository's runs that reached done, as (id, state, folder), oldest first."""
    base = root / ".b-agentic" / "runs"
    if not is_plain_dir(root / ".b-agentic") or not is_plain_dir(base):
        return []
    found = []
    for folder in sorted(base.iterdir()):
        if not RUN_ID.fullmatch(folder.name) or not is_plain_dir(folder):
            continue
        try:
            state = read_state(folder)
        except (Invalid, Refused):
            continue
        if state.get("phase") == "done" and state.get("run_id") == folder.name:
            found.append((folder.name, state, folder))
    return found


def _stats_read_store(runtime: str, block: dict, tolerate_errors: bool = False) -> dict:
    """One runtime's store, opened read-only: its state, the off flag, and each line when it is a regular file.

    A store that cannot be opened is reported unreadable. A failure after that raises, unless tolerate_errors
    reports it the same way, so that one bad filesystem does not hide the other runtime's store.
    """
    out: dict = {"status": "unreadable", "disabled": False, "truncated": False, "lines": []}
    try:
        dir_fd = os.open(stats_dir(runtime), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except FileNotFoundError:
        out["status"] = "absent"
        return out
    except OSError:
        return out
    try:
        out["disabled"] = _stats_off(dir_fd, block["off"]) is not None
        try:
            # O_NONBLOCK: a FIFO with no writer must not hang the open; the type is checked right after.
            fd = os.open(block["store"], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dir_fd)
        except FileNotFoundError:
            out["status"] = "absent"
            return out
        except OSError as exc:
            if exc.errno == errno.ELOOP:
                out["status"] = "not-regular"
            return out
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode):
                out["status"] = "not-regular"
                return out
            data = _stats_read_all(fd, min(info.st_size, block["max_file"]))
            out["status"] = "read"
            out["truncated"] = info.st_size > block["max_file"]
            out["lines"] = stats_lines(data)
        except OSError:
            if not tolerate_errors:
                raise
        finally:
            os.close(fd)
    finally:
        os.close(dir_fd)
    return out


def _stats_report(root: Path, schema: dict) -> dict:
    block = _stats_block(schema)
    repo_key = stats_repo_key(root)
    keys: dict[str, tuple[str, str]] = {}
    if repo_key:
        for run_id, state, _ in _finished_runs(root):
            try:
                keys[run_id] = (stats_run_key(state), stats_legacy_run_key(repo_key, state))
            except (Invalid, Refused, KeyError, TypeError, ValueError):
                continue
    recorded: set[str] = set()
    # Rows of this repository stay counted after prune removed the run folder that produced them.
    mine: set[str] = set()
    repos: set[str] = set()
    stores: dict[str, dict] = {}
    for runtime in STATS_HOMES:
        read = _stats_read_store(runtime, block)
        entry: dict = {"exists": read["status"] == "read", "disabled": read["disabled"]}
        entry.update(lines=0, valid=0, malformed=0)
        stores[runtime] = entry
        for record in read["lines"]:
            entry["lines"] += 1
            try:
                if record is None:
                    raise Invalid("not an object")
                stats_check(_stats_known(record, block["fields"]), schema)
            except Invalid:
                entry["malformed"] += 1
                continue
            entry["valid"] += 1
            repos.add(record["repo"])
            recorded.add(record["run"])
            if record["repo"] == repo_key:
                mine.add(record["run"])
    return {
        "ok": True,
        "stores": stores,
        "repos": len(repos),
        "repo": repo_key,
        "repo_lines": len(mine.union(*(recorded.intersection(pair) for pair in keys.values()))),
        "finished_runs": len(keys),
        "missing": sum(1 for pair in keys.values() if not recorded.intersection(pair)),
    }


# One output holds at most five blocks of one breakdown (kit versions share them with without_kit), so it
# does not grow with the store and stays under the roughly 30000 characters an agent's shell tool shows.
SUMMARY_REPOS = 5
SUMMARY_KITS = 4
SUMMARY_SECTIONS = ("repo", "kit")
SUMMARY_BUCKETS = (*(str(number) for number in range(10)), "10+")
# The summary's name of each stored count, and where a line holds it.
SUMMARY_COUNTS = {
    "steps": ("steps",),
    "criteria": ("criteria",),
    "scope_paths": ("scope_paths",),
    "worker_steps": ("worker_steps",),
    "parallel_steps": ("parallel_steps",),
    "review_rounds": ("review", "rounds"),
    "qa_rounds": ("qa", "rounds"),
    "fix_rounds": ("fix_rounds",),
    "blocked_count": ("blocked_count",),
    "time_stops": ("time_stops",),
    "checks_total": ("checks_total",),
    "checks_failed": ("checks_failed",),
    "commits": ("commits",),
    "review_blockers": ("blockers", "review"),
    "qa_blockers": ("blockers", "qa"),
}


def _summary_numbers(values: list[int]) -> dict:
    """n, sum, and for a non-empty list the smallest, nearest-rank p50 and p90, and largest value."""
    ordered = sorted(values)
    size = len(ordered)
    out = {"n": size, "sum": sum(ordered)}
    if size:
        out["min"] = ordered[0]
        for percent in (50, 90):
            out[f"p{percent}"] = ordered[(size * percent + 99) // 100 - 1]
        out["max"] = ordered[-1]
    return out


def _summary_histogram(values: list[int]) -> dict:
    found: dict[str, int] = {}
    for value in values:
        bucket = str(value) if value < 10 else "10+"
        found[bucket] = found.get(bucket, 0) + 1
    return {bucket: found[bucket] for bucket in SUMMARY_BUCKETS if bucket in found}


def _summary_block(rows: list[tuple[dict, bool]], phases: list[str]) -> dict:
    """The numbers of one group of checked lines; each row is a line and whether its kit fields were set aside.

    A value a line does not have is counted in missing and never read as zero. A key a line's keyed counts do not
    have is a real zero (the writer counts what it found), so those are plain sums.
    """
    counts: dict[str, list[int]] = {name: [] for name in SUMMARY_COUNTS}
    seconds: dict[str, list[int]] = {name: [] for name in ("total", *phases)}
    names = ("size", "end", "review_gate", "review_verdict", "review_low_risk", "qa_verdict", "ac")
    sums: dict[str, dict[str, int]] = {
        name: {} for name in (*names, "blockers_by_class", "escaped_from", "kit_dirty", "kit_changed")
    }
    gaps = ("runtime", "kit", "kit_unchecked", "kit_changed", "review_verdict", "qa_verdict", "durations", "time_stops")
    missing = dict.fromkeys(gaps, 0)

    def add(name: str, key: object, amount: int = 1) -> None:
        text = ("true" if key else "false") if isinstance(key, bool) else str(key)
        sums[name][text] = sums[name].get(text, 0) + amount

    def add_all(name: str, keyed: dict) -> None:
        for key, amount in keyed.items():
            add(name, key, amount)

    for line, unchecked in rows:
        for name, path in SUMMARY_COUNTS.items():
            # Lines written before the run time budget hold no count of its stops.
            if name == "time_stops" and name not in line:
                missing[name] += 1
                continue
            value = line
            for part in path:
                value = value[part]
            counts[name].append(value)
        # A trimmed history gives durations that are only a part of the run: they are not used at all.
        if line["history_complete"]:
            seconds["total"].append(line["total_s"])
            for phase, spent in line["dur_s"].items():
                seconds[phase].append(spent)
        else:
            missing["durations"] += 1
        add("size", line["size"])
        add("end", line["end"])
        add("review_low_risk", line["review"]["low_risk"])
        add_all("review_gate", line["review"]["by_gate"])
        add_all("ac", line["ac"])
        add_all("blockers_by_class", line["blockers"]["by_class"])
        add_all("escaped_from", line["escaped_from"])
        for name, holder, field in (("review_verdict", "review", "verdict"), ("qa_verdict", "qa", "verdict")):
            if field in line[holder]:
                add(name, line[holder][field])
            else:
                missing[name] += 1
        missing["runtime"] += "runtime" not in line
        missing["kit"] += "kit_seq" not in line
        missing["kit_unchecked"] += unchecked
        if "kit_dirty" in line:
            add("kit_dirty", line["kit_dirty"])
        if "kit_changed" in line:
            add("kit_changed", line["kit_changed"])
        else:
            missing["kit_changed"] += 1
    return {
        "runs": len(rows),
        "counts": {
            name: {**_summary_numbers(values), "values": _summary_histogram(values)} for name, values in counts.items()
        },
        "seconds": {name: _summary_numbers(values) for name, values in seconds.items()},
        "sums": {name: dict(sorted(keyed.items())) for name, keyed in sums.items()},
        "missing": missing,
    }


def _summary_groups(groups: dict, order: list, limit: int, label, phases: list[str]) -> dict:
    """The first groups of the order up to the limit, each with its identity, and how much the rest held."""
    listed = order[:limit]
    return {
        "groups": [{**label(key), **_summary_block(groups[key], phases)} for key in listed],
        "omitted_groups": len(order) - len(listed),
        "omitted_runs": sum(len(groups[key]) for key in order[limit:]),
    }


def _summary_by_runtime(rows: list, phases: list[str]) -> dict:
    groups: dict = {}
    for row in rows:
        # The line's own runtime, never the store it was found in.
        groups.setdefault(row[0].get("runtime", "unknown"), []).append(row)
    return {name: _summary_block(groups[name], phases) for name in sorted(groups)}


def _summary_by_repo(rows: list, phases: list[str]) -> dict:
    groups: dict = {}
    for row in rows:
        groups.setdefault(row[0]["repo"], []).append(row)
    order = sorted(groups, key=lambda key: (-len(groups[key]), key))
    return _summary_groups(groups, order, SUMMARY_REPOS, lambda key: {"repo": key}, phases)


def _summary_by_kit(rows: list, phases: list[str]) -> dict:
    groups: dict = {}
    without_kit: list = []
    for row in rows:
        line = row[0]
        if "kit_seq" in line:
            key = (line.get("runtime", "unknown"), line["kit_seq"], line["kit_commit"], line["kit_date"])
            groups.setdefault(key, []).append(row)
        else:
            without_kit.append(row)
    out = _summary_groups(
        groups,
        sorted(groups, key=lambda key: (key[3], key[1], key[0], key[2]), reverse=True),
        SUMMARY_KITS,
        lambda key: {"runtime": key[0], "kit_seq": key[1], "kit_commit": key[2], "kit_date": key[3]},
        phases,
    )
    out["without_kit"] = _summary_block(without_kit, phases)
    return out


def _stats_summary(root: Path, schema: dict, since: str | None, section: str | None) -> dict:
    """Numbers only, from the two stores' checked lines: nothing is written and no run folder is read."""
    block = _stats_block(schema)
    fields = block["fields"]
    phases = fields["dur_s"]["keys"]
    kit_names = (*KIT_STATS, "kit_changed")
    # An install can keep an older, user-edited artifacts.yaml beside newer helpers, as in _kit_stats.
    kit_known = all(name in fields for name in kit_names)
    rows: list[tuple[dict, bool]] = []
    seen: set[str] = set()
    stores: dict[str, dict] = {}
    before_since = 0
    for runtime in STATS_HOMES:
        read = _stats_read_store(runtime, block, tolerate_errors=True)
        entry = {name: read[name] for name in ("status", "disabled", "truncated")}
        entry.update(lines=len(read["lines"]), counted=0, malformed=0, unknown_version=0, duplicates=0)
        stores[runtime] = entry
        for line in read["lines"]:
            if line is None:
                entry["malformed"] += 1
                continue
            version = line.get("v")
            # Another version may mean something else by the same names: it is not checked against this one.
            if isinstance(version, int) and not isinstance(version, bool) and version != 1:
                entry["unknown_version"] += 1
                continue
            unchecked = False
            if not kit_known:
                unchecked = any(name in line for name in kit_names)
                line = {name: value for name, value in line.items() if name not in kit_names}
            line = _stats_known(line, fields)
            try:
                stats_check(line, schema)
            except Invalid:
                entry["malformed"] += 1
                continue
            if line["run"] in seen:
                entry["duplicates"] += 1
                continue
            seen.add(line["run"])
            if since is not None and line["date"] < since:
                before_since += 1
                continue
            entry["counted"] += 1
            rows.append((line, unchecked))
    out = {
        "ok": True,
        "since": since,
        "repo": stats_repo_key(root),
        "stores": stores,
        "before_since": before_since,
    }
    if section == "repo":
        out["by_repo"] = _summary_by_repo(rows, phases)
    elif section == "kit":
        out["by_kit"] = _summary_by_kit(rows, phases)
    else:
        out["all"] = _summary_block(rows, phases)
        out["by_runtime"] = _summary_by_runtime(rows, phases)
    return out


def _since_date(value: str) -> str:
    import datetime

    try:
        # ASCII digits only: the value is compared as text with the stored dates.
        if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", value):
            raise ValueError(value)
        datetime.date.fromisoformat(value)
    except ValueError as exc:
        raise Invalid("stats --since needs a real YYYY-MM-DD date") from exc
    return value


# One page of evidence stays under the roughly 30000 characters an agent's shell tool shows.
EVIDENCE_BUDGET = 28000
# Three 300-character fields escape to about 11000 bytes; past this only an id, which has no length limit, can
# have made a blocker larger. Below the page budget, so every page holds at least one blocker.
EVIDENCE_BLOCKER_MAX = 12000
EVIDENCE_FIELDS = ("id", "source", "disposition", "blocker_class", "escaped_from", "summary", "reason", "sweep")
EVIDENCE_SKIPPED = ("not-a-run", "bad-state", "not-done", "invalid")


def _compact_line(value: object) -> str:
    """One compact line of JSON, all ASCII: other characters, and any that could drive a terminal, arrive escaped."""
    return json.dumps(value, separators=(",", ":")) + "\n"


def _checkout_here() -> Path | None:
    """The nearest folder, from the working directory up, that holds .git."""
    here = Path.cwd().resolve()
    return next((folder for folder in (here, *here.parents) if os.path.lexists(folder / ".git")), None)


def _evidence_root() -> Path:
    """The checkout that holds the working directory, whatever the environment or the git config says.

    An inherited GIT_ variable or a core.worktree setting would otherwise point the evidence at another tree's
    text without a word: the variables are dropped, and git's answer must be the nearest folder, from the
    working directory up, that holds .git.
    """
    try:
        here = Path.cwd().resolve()
        root = Path(hardened_git(here, "rev-parse", "--show-toplevel")[1].strip())
        nearest = _checkout_here()
        if nearest is not None and os.path.samefile(root, nearest):
            return nearest
    except (Refused, OSError) as exc:
        raise Refused("not inside a git worktree; run it from inside the repository") from exc
    raise Refused("git names a worktree other than the checkout around the working directory; nothing was read")


def _open_runs(state_dir: Path | str, dir_fd: int | None = None) -> int | None:
    """The runs folder under a checkout's .b-agentic, held open; None when it is absent or either level is not a
    folder. `dir_fd` names a held checkout that a relative `state_dir` is under.
    """
    try:
        base = os.open(state_dir, OPEN_DIR, dir_fd=dir_fd)
        try:
            return os.open("runs", OPEN_DIR, dir_fd=base)
        finally:
            os.close(base)
    except OSError as exc:
        if exc.errno in (errno.ENOENT, errno.ENOTDIR, errno.ELOOP):
            return None
        raise


def _evidence_run(
    runs_fd: int, name: str, schema: dict, known: dict[tuple[str, str], list[dict]]
) -> tuple[str | None, str, list[dict]]:
    """One run folder's start time and blockers, or why the folder is left out. It moves the working directory.
    A run already in `known` is a "repeat": its artifacts are not read again.

    Run files are untrusted input: a folder is used only when its run is done and every recorded file agrees with
    its record. That finds damage and stray edits, not a forger: the hashes lie beside the text they cover.
    The folder is opened without following a link and read from inside, so swapping any name above or at it for a
    link, after it is opened, cannot bring another tree's files in.
    """
    if not RUN_ID.fullmatch(name):
        return "not-a-run", "", []
    try:
        run_fd = os.open(name, OPEN_DIR, dir_fd=runs_fd)
    except OSError as exc:
        return "not-a-run" if exc.errno in (errno.ENOTDIR, errno.ELOOP) else "bad-state", "", []
    reason = "bad-state"
    try:
        os.fchdir(run_fd)
        here = Path(".")
        state = read_state(here)
        if state["run_id"] != name:
            return reason, "", []
        if state["phase"] != "done":
            return "not-done", "", []
        reason = "invalid"
        try:
            started = _run_started(state)
        except Invalid:  # a damaged start time costs no blocker; such a run is never taken for a copy
            started = f"?{len(known)}"
        if (name, started) in known:
            return "repeat", started, []
        # validate_run asks of its known names only that they are no link or folder. The helpers leave regular
        # files alone here, so a FIFO or socket under any name means the folder is not as they left it.
        if any(not stat.S_ISREG(os.lstat(entry).st_mode) for entry in os.listdir(here)):
            return reason, "", []
        data, problems = validate_run(here, schema)
        if problems:
            return reason, "", []
        items = data.get("followups", {}).get("items", [])
        return (
            None,
            started,
            [
                {"run": name, **{field: item.get(field) for field in EVIDENCE_FIELDS}}
                for item in items
                if item.get("kind") == "blocker"
            ],
        )
    except Exception:  # whatever one folder's files make a reader raise drops that folder alone
        return reason, "", []
    finally:
        os.close(run_fd)


def _collect_evidence(
    runs_fd: int, schema: dict, runs: dict[tuple[str, str], list[dict]], skipped: dict[str, int]
) -> tuple[int, int]:
    """Add the finished runs of one held runs folder to `runs`, as (folders, repeats). A run is its id and start
    time, as the summary tells runs apart: two clones can use one id for two runs. A copy of a run already there
    is a repeat; a folder that is left out is counted in `skipped`. It moves the working directory.
    """
    names = sorted(os.listdir(runs_fd), reverse=True)
    repeats = 0
    for name in names:
        reason, started, blockers = _evidence_run(runs_fd, name, schema, runs)
        if reason == "repeat":
            repeats += 1
        elif reason is not None:
            skipped[reason] += 1
        else:
            runs[name, started] = blockers
    return len(names), repeats


def _evidence_page(
    folders: int,
    runs: dict[tuple[str, str], list[dict]],
    skipped: dict[str, int],
    skip: int,
    checkouts: dict | None = None,
) -> dict:
    """The page of the runs' blockers that starts at `skip`, newest run id (then start time) first."""
    found = [blocker for name in sorted(runs, reverse=True) for blocker in runs[name]]
    printable = [blocker for blocker in found if len(_compact_line(blocker)) - 1 <= EVIDENCE_BLOCKER_MAX]

    def page(shown: int) -> dict:
        end = skip + shown
        return {
            "ok": True,
            "folders": folders,
            "runs_read": len(runs),
            "skipped": skipped,
            **({} if checkouts is None else {"checkouts": checkouts}),
            "total": len(printable),
            "oversized": len(found) - len(printable),
            "skip": skip,
            "shown": shown,
            "next_skip": end if end < len(printable) else None,
            "blockers": printable[skip:end],
        }

    shown = 0
    while skip + shown < len(printable) and len(_compact_line(page(shown + 1))) <= EVIDENCE_BUDGET:
        shown += 1
    return page(shown)


def _stats_evidence(root: Path, schema: dict, skip: int) -> dict:
    """One page of this repository's blocker text, read live from its run folders; nothing is stored or written."""
    folders = 0
    skipped = dict.fromkeys(EVIDENCE_SKIPPED, 0)
    runs: dict[tuple[str, str], list[dict]] = {}
    runs_fd = _open_runs(root / ".b-agentic")
    if runs_fd is not None:
        back = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
        try:
            folders, _ = _collect_evidence(runs_fd, schema, runs, skipped)
        finally:
            os.fchdir(back)
            os.close(back)
            os.close(runs_fd)
    return _evidence_page(folders, runs, skipped, skip)


EVIDENCE_CHECKOUTS = 4
CHECKOUT_SKIPPED = ("gone", "not-owned", "not-a-checkout", "partial", "no-key", "other-key", "same-folder", "not-tried")
# Exit 0 means the checkout has one of these keys: it could fetch missing objects, which an older git does not stop.
PARTIAL_CLONE_KEYS = r"^(extensions\.partialclone|remote\..*\.promisor)$"


def _open_checkout(path: str, repo_key: str, read: set[tuple[int, int]]) -> tuple[str | None, int]:
    """Open one registered folder once, move into it, and check it there, so what is checked is what is read.

    A registry line may be stale, and another tree may sit at its path by now. Returns (None, descriptor) for
    the user's own checkout of `repo_key`, else (why it is left out, -1).
    """
    try:
        fd = os.open(path, OPEN_DIR)
    except OSError:
        return "gone", -1
    reason: str | None = "not-a-checkout"
    try:
        info = os.fstat(fd)
        if info.st_uid != os.getuid():
            reason = "not-owned"
        elif (info.st_dev, info.st_ino) in read:
            reason = "same-folder"
        else:
            os.fchdir(fd)
            top = hardened_git(".", "rev-parse", "--show-toplevel")[1].removesuffix("\n")
            if os.path.lexists(".git") and os.path.samestat(os.stat(top), info):
                if hardened_git(".", "config", "--get-regexp", PARTIAL_CLONE_KEYS, ok=(0, 1))[0] == 0:
                    reason = "partial"
                else:
                    found = stats_repo_key(Path("."))
                    reason = "no-key" if found is None else None if found == repo_key else "other-key"
    except Exception:  # an error here may name the path, so it never travels further than this count
        pass
    if reason is None:
        return None, fd
    os.close(fd)
    return reason, -1


def _stats_repo_evidence(repo_key: str, schema: dict, skip: int) -> dict:
    """One page of another registered repository's blocker text, from every checkout of it that passes the checks."""
    off = _stats_block(schema)["off"]
    paths = list(
        dict.fromkeys(
            path
            for runtime in STATS_HOMES
            for repo, path in reversed(_read_registry(runtime, off)["entries"])
            if repo == repo_key
        )
    )
    if not paths:
        raise Refused(
            f"repository {repo_key} is not registered (stats --record run inside it registers it); nothing was read"
        )
    dropped = dict.fromkeys(CHECKOUT_SKIPPED, 0)
    dropped["not-tried"] = max(0, len(paths) - EVIDENCE_CHECKOUTS)
    skipped = dict.fromkeys(EVIDENCE_SKIPPED, 0)
    runs: dict[tuple[str, str], list[dict]] = {}
    read: set[tuple[int, int]] = set()
    folders = repeats = 0
    back = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for path in paths[:EVIDENCE_CHECKOUTS]:
            reason, fd = _open_checkout(path, repo_key, read)
            if reason is not None:
                dropped[reason] += 1
                continue
            runs_fd = None
            try:
                runs_fd = _open_runs(".b-agentic", fd)
                if runs_fd is not None:
                    count, again = _collect_evidence(runs_fd, schema, runs, skipped)
                    folders += count
                    repeats += again
                info = os.fstat(fd)
                read.add((info.st_dev, info.st_ino))
            except OSError:  # its runs cannot be opened or listed
                dropped["gone"] += 1
            finally:
                if runs_fd is not None:
                    os.close(runs_fd)
                os.close(fd)
    finally:
        os.fchdir(back)
        os.close(back)
    if not read:
        why = ", ".join(f"{name} {count}" for name, count in dropped.items() if count)
        raise Refused(f"no registered checkout of repository {repo_key} passed the checks ({why}); nothing was read")
    checkouts = {"registered": len(paths), "read": len(read), "skipped": dropped, "duplicate_runs": repeats}
    return _evidence_page(folders, runs, skipped, skip, checkouts)


REPOS_BUDGET = 28000
REPOS_PATHS = 4


def _stats_repos(schema: dict) -> dict:
    """The registered repository keys with their paths, the most recently registered first. The only output
    that holds a path.
    """
    off = _stats_block(schema)["off"]
    registries: dict[str, dict] = {}
    repos: dict[str, dict[str, None]] = {}  # an insertion-ordered set of paths per key
    for runtime in STATS_HOMES:
        read = _read_registry(runtime, off)
        registries[runtime] = {name: read[name] for name in ("status", "disabled", "truncated", "lines", "malformed")}
        for repo, path in reversed(read["entries"]):
            repos.setdefault(repo, {})[path] = None
    listed = [
        {"repo": repo, "paths": list(paths)[:REPOS_PATHS], "omitted_paths": max(0, len(paths) - REPOS_PATHS)}
        for repo, paths in repos.items()
    ]

    def page(shown: int) -> dict:
        return {"ok": True, "registries": registries, "repos": listed[:shown], "omitted_repos": len(listed) - shown}

    shown = 0
    while shown < len(listed) and len(_compact_line(page(shown + 1))) <= REPOS_BUDGET:
        shown += 1
    return page(shown)


def cmd_stats(schema: dict, args: dict) -> dict:
    _only_options("stats", args, {"record", "run", "summary", "since", "section", "evidence", "skip", "repo", "repos"})
    if args.get("repos"):
        for name in args:
            if name not in ("repos", "owner"):  # every command takes --owner
                raise Invalid(f"stats --repos does not go with --{name}")
        return _stats_repos(schema)
    if args.get("evidence"):
        for name in ("record", "run", "summary", "since", "section"):
            if name in args:
                raise Invalid(f"stats --evidence does not go with --{name}")
        skip = args.get("skip", "0")
        if not re.fullmatch(r"[0-9]{1,6}", skip):
            raise Invalid("stats --skip needs a count of at most six digits")
        if "repo" not in args:
            return _stats_evidence(_evidence_root(), schema, int(skip))
        if not REPO_KEY.fullmatch(args["repo"]):
            raise Invalid("stats --repo needs a repository key: 16 lowercase hex characters")
        return _stats_repo_evidence(args["repo"], schema, int(skip))
    for name in ("skip", "repo"):
        if name in args:
            raise Invalid(f"stats --{name} belongs to stats --evidence")
    since = None
    if args.get("summary"):
        if args.get("record") or "run" in args:
            raise Invalid("stats --summary does not go with --record or --run")
        if "since" in args:
            since = _since_date(args["since"])
        section = args.get("section")
        if "section" in args and section not in SUMMARY_SECTIONS:
            raise Invalid("stats --section is repo or kit")
        return _stats_summary(repo_root(), schema, since, section)
    for name in ("since", "section"):
        if name in args:
            raise Invalid(f"stats --{name} belongs to stats --summary")
    root = repo_root()
    if not args.get("record"):
        if args.get("run"):
            raise Invalid("stats --run belongs to stats --record")
        return _stats_report(root, schema)
    import time

    started = time.monotonic()
    block = _stats_block(schema)
    repo_key = stats_repo_key(root)
    runtime = "pi" if on_pi() else "claude"
    out: dict = {"ok": True, "created": False, "appended": 0, "already": 0, "skipped": {}}
    if repo_key is None:
        out["skipped"]["no-repo-key"] = 1
        out["registry"] = "skipped:no-repo-key"
        return out
    if args.get("run"):
        run_id, folder = resolve_run(root, args["run"])
        runs = [(run_id, read_state(folder), folder)]
    else:
        runs = _finished_runs(root)
    for run_id, state, folder in runs:
        if state.get("phase") != "done":
            out["skipped"]["not-done"] = out["skipped"].get("not-done", 0) + 1
            continue
        # Each runtime writes only its own runs to its own store, whether it is called live, by name, or as a catch-up.
        if state.get("runtime", "claude") != runtime:
            out["skipped"]["other-runtime"] = out["skipped"].get("other-runtime", 0) + 1
            continue
        try:
            record = stats_record(state, load_artifacts(folder), repo_key, schema)
            stats_check(record, schema)
            legacy_key = stats_legacy_run_key(repo_key, state)
            line = (json.dumps(record, separators=(",", ":")) + "\n").encode()
            if len(line) > block["max_line"]:
                raise Invalid("line too long")
        except (Invalid, Refused, KeyError, TypeError, ValueError):
            out["skipped"]["bad-record"] = out["skipped"].get("bad-record", 0) + 1
            continue
        result = stats_append(runtime, block, record, line, legacy_key)
        if result["created"]:
            out["created"] = True
        if result["status"] == "written":
            out["appended"] += 1
        elif result["status"] == "already":
            out["already"] += 1
        else:
            out["skipped"][result["reason"]] = out["skipped"].get(result["reason"], 0) + 1
            # Every skip reason describes the store or its home, not one run: the next run would repeat it.
            break
    # After the store lines are settled: nothing the registry does can change them or their counts.
    lock_seconds = STATS_LOCK_SECONDS if time.monotonic() - started < REGISTRY_QUICK_SECONDS else 0.0
    out["registry"], registry_created = _register_checkout(runtime, block["off"], repo_key, root, lock_seconds)
    notices = []
    if out["created"]:
        notices.append(
            f"run stats: created {_stats_shown(runtime, block['store'])} (numbers only, no text or paths); "
            f"create {_stats_shown(runtime, block['off'])} to turn it off"
        )
    if registry_created:
        notices.append(
            f"run stats: created {_stats_shown(runtime, REGISTRY)} (it holds repository checkout paths); "
            f"create {_stats_shown(runtime, block['off'])} to stop new entries"
        )
    if notices:
        out["notice"] = " ".join(notices)
    return out


# ---- entry --------------------------------------------------------------------

VALUE_OPTIONS = {"run", "owner", "out", "base", "tree", "step", "days", "since", "section", "skip", "repo"}
COMMANDS = (
    "schema",
    "lint",
    "write",
    "validate",
    "scope-check",
    "handoff",
    "worker-profile",
    "selftest",
    "runs",
    "prune",
    "stats",
)
HELP_FLAGS = ("--help", "-h")


def arity_error(command: str, schema: dict) -> Invalid:
    if command in ("lint", "write"):
        return Invalid(f"{command} needs one KIND: {', '.join(sorted(schema['kinds']))}")
    if command == "handoff":
        return Invalid(f"handoff needs one PHASE: {', '.join(HANDOFF_PHASES)}")
    return Invalid(f"{command} takes no argument; --help prints usage")


def parse_args(argv: list[str]) -> tuple[list[str], dict]:
    positional: list[str] = []
    options: dict = {}
    problem: Invalid | None = None
    i = 0
    while i < len(argv):
        arg = argv[i]
        i += 1
        if arg in HELP_FLAGS:
            # Only a flag the parser reads as a flag asks for help: a value taken by --owner or --out stays a value.
            options["help"] = True
        elif not arg.startswith("--"):
            positional.append(arg)
        elif arg[2:] in VALUE_OPTIONS:
            if i >= len(argv):
                problem = problem or Invalid(f"{arg} needs a value")
                break
            options[arg[2:]] = argv[i]
            i += 1
        elif arg == "--json":
            options["json"] = True
        elif arg == "--apply":
            options["apply"] = True
        elif arg == "--record":
            options["record"] = True
        elif arg == "--summary":
            options["summary"] = True
        elif arg == "--evidence":
            options["evidence"] = True
        elif arg == "--repos":
            options["repos"] = True
        else:
            problem = problem or Invalid(f"unknown argument: {arg}")
    # A caller fixing a malformed command asks for help beside the mistake: help is answered, the mistake is not.
    if problem and not (options.get("help") or positional[:1] == ["help"]):
        raise problem
    return positional, options


def run(argv: list[str]) -> tuple[int, str]:
    positional, args = parse_args(argv)
    # Help is settled right after the arguments parse, before the schema, stdin, or the repository are touched.
    if args.get("help") or positional[:1] == ["help"]:
        text = (__doc__ or "").strip().replace(DEFAULT_HELPER_DIR, helper_dir())
        if on_pi():
            text = text.replace("(default: CLAUDE_CODE_SESSION_ID)", "(default: PI_SESSION_ID)")
        return 0, text + "\n"
    if not positional:
        raise Invalid(f"missing command; commands: {', '.join(COMMANDS)}; --help prints usage")
    command, rest = positional[0], positional[1:]
    schema = load_schema()
    if command == "schema":
        result: object = cmd_schema(schema, rest[0] if rest else None)
    elif command == "lint" and len(rest) == 1:
        result = cmd_lint(schema, rest[0], args)
    elif command == "write" and len(rest) == 1:
        result = cmd_write(schema, rest[0], args)
    elif command == "validate":
        result = cmd_validate(schema, args)
    elif command == "scope-check":
        result = cmd_scope_check(schema, args)
    elif command == "worker-profile":
        result = cmd_worker_profile(args)
    elif command == "handoff" and len(rest) == 1:
        text = cmd_handoff(schema, rest[0], args)
        return 0, text if text.endswith("\n") else text + "\n"
    elif command == "selftest":
        result = cmd_selftest(schema)
    elif command == "runs" and not rest:
        result = cmd_runs(args)
    elif command == "prune" and not rest:
        result = cmd_prune(args)
    elif command == "stats" and not rest:
        result = cmd_stats(schema, args)
    elif command in COMMANDS:
        raise arity_error(command, schema)
    else:
        raise Invalid(f"unknown command: {command}; commands: {', '.join(COMMANDS)}; --help prints usage")
    ok = not (isinstance(result, dict) and result.get("ok") is False)
    # The summary, the evidence and the repositories are read by an agent: one compact line keeps them small,
    # and it is the line the bounded outputs were measured as.
    compact = command == "stats" and bool(args.get("summary") or args.get("evidence") or args.get("repos"))
    return (0 if ok else 3), _compact_line(result) if compact else json.dumps(result, indent=2) + "\n"


def main(argv: list[str]) -> int:
    try:
        code, out = run(argv)
    except Refused as exc:
        print(str(exc), file=sys.stderr)
        return 3
    except Invalid as exc:
        print(str(exc), file=sys.stderr)
        return 2
    except OSError as exc:
        print(f"{type(exc).__name__}: {exc.strerror or exc}", file=sys.stderr)
        return 2
    sys.stdout.write(out)
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
