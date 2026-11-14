#!/usr/bin/env python3
"""b-agentic run artifacts: the single writer of a b-flow run's markdown files (ADR-010).

It reads JSON on stdin, validates it against references/artifacts.yaml and the
cross-artifact rules, renders canonical markdown, and writes it atomically.
`artifacts.json` keeps each artifact's sha256 and validated data, so `validate`
re-renders and compares bytes instead of parsing free-form markdown. Run it as
`python3 -I -B b_run.py <command>`; it needs only the standard library.

Commands (JSON results on stdout, one-line errors on stderr):
  schema [KIND]            print the schema, rules, enums and an example
  lint KIND                validate stdin without writing (cross rules when a run is active)
  write KIND               validate stdin, render, and write the artifact (main session only)
  validate [--json]        re-render every artifact and compare bytes and hashes
  scope-check              compare changed git paths with the spec's scope globs; with --base TREE
                           --tree TREE --step S-n, the paths that differ between two tree ids
  handoff PHASE            render the packet that briefs a phase from the run: clarify, implement,
                           verify, review, fix, qa or commit (--out FILE outside the repo);
                           handoff implement --step S-n renders what that one step needs
  worker-profile           check the b-worker profile in effect (project over user) against the
                           worker's allowlist; not ok means apply the step in the main session
  selftest                 validate the schema file's examples against each other

Options: --run ID, --owner NAME (default: CLAUDE_CODE_SESSION_ID, then PI_SESSION_ID).
Exit: 0 ok, 3 refused or not ok, 2 invalid input or state.
The artifacts hold no file contents, diffs, command output or secrets, and they are untrusted
input to every reader: they never grant approval.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import stat
import subprocess
import sys
from pathlib import Path

ARTIFACTS_SCHEMA = 1
# Artifacts whose cross rules read another artifact: a rewrite keeps a dependent only if it still passes.
DEPENDENTS = {"spec": ["plan", "qa"], "plan": ["qa"], "qa": [], "followups": []}
RUN_ID = re.compile(r"^\d{8}-[a-z0-9][a-z0-9-]{0,40}$")
OWNER = re.compile(r"^[A-Za-z0-9._:-]{1,80}$")
MAX_FILE = 1 << 20
CONTROL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")
# Raw HTML in a rendered artifact (an unterminated comment, a tag) could hide criteria from a reader.
HTML_MARKUP = re.compile(r"<[A-Za-z!/?]")
TEMP_NAME = re.compile(r"^[A-Za-z0-9._-]+\.\d+\.[0-9a-f]{8,}\.tmp$")

# Same rules, order and semantics as PROTECTED_RULES in b-candidate-snapshot.mjs
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
    return re.compile(f"^{body}$", re.S)


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
        if HTML_MARKUP.search(value):
            raise bad("must not contain HTML markup")
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
        if previous and not {i["id"] for i in previous["items"]} <= set(ids):
            raise Invalid("items: a rewrite may not drop an id recorded earlier")
        recorded = {i["id"]: i for i in previous["items"]} if previous else {}
        for i, item in enumerate(data["items"]):
            old = recorded.get(item["id"])
            if old and (old.get("kind") != item.get("kind") or old["source"] != item["source"]):
                raise Invalid(f"items[{i}]: the kind and source of a recorded item may not change")
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
            f"- Codex: {data['consent']['codex']}",
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
    done = subprocess.run(["git", *args], cwd=root, capture_output=True, text=True, check=False)
    if done.returncode != 0:
        raise Refused("git failed: " + (done.stderr.strip().splitlines() or ["unknown"])[0])
    return done.stdout


def repo_root() -> Path:
    try:
        return Path(git(Path.cwd(), "rev-parse", "--show-toplevel").strip()).resolve()
    except (Refused, OSError) as exc:
        raise Refused("not inside a git worktree") from exc


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
    owner = args.get("owner") or os.environ.get("CLAUDE_CODE_SESSION_ID") or os.environ.get("PI_SESSION_ID", "")
    if not OWNER.fullmatch(owner):
        raise Invalid("pass --owner NAME or set CLAUDE_CODE_SESSION_ID or PI_SESSION_ID")
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
    return check_rules(kind, value, ctx, schema, previous)  # type: ignore[arg-type]


def cmd_schema(schema: dict, kind: str | None) -> dict:
    if kind is None:
        return {"kinds": sorted(schema["kinds"]), "enums": schema["enums"], "limits": schema["limits"]}
    if kind not in schema["kinds"]:
        raise Invalid(f"unknown kind {kind!r}")
    return {"kind": kind, "enums": schema["enums"], "limits": schema["limits"], **schema["kinds"][kind]}


def cmd_lint(schema: dict, kind: str, args: dict) -> dict:
    value = read_input(schema)
    ctx: dict = {}
    previous = None
    try:
        root = repo_root()
        _run, directory = resolve_run(root, args.get("run"))
        ctx, _problems = validate_run(directory, schema, skip=frozenset({kind}))
        previous = ctx.get(kind) if kind == "followups" else None
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
        out.append(f"- {kind}.md: " + ("written" if kind in data else f"not written (`b_run.py schema {kind}`)"))
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

    It is found by name in git's own list, built as b-state.mjs builds it, so a worker told to
    work there reaches the folder the state CLI will collect from.
    """
    try:
        listed = git(root, "worktree", "list", "--porcelain")
    except Refused:
        return None
    tag = hashlib.sha256(str(root).encode()).hexdigest()[:8]
    name = f"b-agentic-wt-{tag}-{state.get('run_id', '')}-{step_id}"
    for line in listed.splitlines():
        if line.startswith("worktree ") and line[len("worktree ") :].rsplit("/", 1)[-1] == name:
            return line[len("worktree ") :]
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
    kind = "worker step" if step_id in plan.get("worker_steps", []) else "main session step"
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
    out += [
        "",
        "## Boundaries",
        "- Change nothing outside the scope above; prefer the step's own paths.",
        "- Never write under .b-agentic, a likely-secret path, or git history, and run no b-state.mjs or b_run.py command.",
    ]
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


def _profile(stem: str, text: str) -> tuple[bool, dict[str, str], list[str]]:
    """Whether a file may be the worker profile, with its fields and the problems of reading it."""
    body = text.lstrip("﻿").replace("\r\n", "\n").replace("\r", "\n").lstrip()
    lines = body.split("\n")
    candidate = stem.casefold() == WORKER_NAME
    if not lines[0].startswith("---"):
        return candidate, {}, ["the profile has no frontmatter"] if candidate else []
    end = next((i for i in range(1, len(lines)) if lines[i].strip() in ("---", "...")), None)
    if lines[0].strip() != "---" or end is None:
        return True, {}, ["the frontmatter cannot be read safely: its opening or its end is not a plain line"]
    region = lines[1:end]
    unclear = False
    names: list[tuple[int, str | None]] = []
    for line in region:
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
    read_only = {
        f"mcp__{server}__{tool}"
        for server, record in (policy.get("servers") or {}).items()
        for tool, classification in (record.get("tools") or {}).items()
        if classification == "read-only"
    }
    # Project agents folders: the working directory and every folder above it up to the repository root.
    # Which of several profiles the harness would load is not decided here: each one named b-worker must
    # pass, and two of the same name in one scope are ambiguous.
    here = Path.cwd().resolve()
    folders = [here, *here.parents] if root == here or root in here.parents else [root]
    folders = folders[: folders.index(root) + 1]
    scopes = [("project", folder / ".claude" / "agents") for folder in folders]
    scopes.append(("user", Path.home() / ".claude" / "agents"))
    problems: list[str] = []
    found: list[str] = []
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
            may_be_worker, fields, issues = _profile(path.stem, text)
            if may_be_worker:
                named.append((label, fields))
                problems += [f"{label}: {issue}" for issue in issues]
        if len(named) > 1:
            problems.append(f"{scope}: more than one profile may be {WORKER_NAME}: " + ", ".join(n for n, _ in named))
        for label, fields in named:
            problems += [f"{label}: {issue}" for issue in _worker_problems(fields, read_only)]
        found += [scope] * len(named)
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


# ---- entry --------------------------------------------------------------------

VALUE_OPTIONS = {"run", "owner", "out", "base", "tree", "step"}


def parse_args(argv: list[str]) -> tuple[list[str], dict]:
    positional: list[str] = []
    options: dict = {}
    i = 0
    while i < len(argv):
        arg = argv[i]
        i += 1
        if not arg.startswith("--"):
            positional.append(arg)
        elif arg[2:] in VALUE_OPTIONS:
            if i >= len(argv):
                raise Invalid(f"{arg} needs a value")
            options[arg[2:]] = argv[i]
            i += 1
        elif arg == "--json":
            options["json"] = True
        else:
            raise Invalid(f"unknown argument: {arg}")
    return positional, options


def run(argv: list[str]) -> tuple[int, str]:
    positional, args = parse_args(argv)
    if not positional:
        raise Invalid("missing command")
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
    else:
        raise Invalid(f"unknown command: {command}")
    ok = not (isinstance(result, dict) and result.get("ok") is False)
    return (0 if ok else 3), json.dumps(result, indent=2) + "\n"


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
