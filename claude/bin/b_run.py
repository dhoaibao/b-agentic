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
  scope-check              compare changed git paths with the spec's scope globs
  handoff review|qa        render the review or QA packet from the run (--out FILE outside the repo)
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
    elif kind == "plan":
        out += ["# Plan", "", "## Steps"]
        for s in data["steps"]:
            out += [
                f"- {s['id']}: {s['action']}",
                "  - Paths: " + ", ".join(f"`{p}`" for p in s["paths"]),
                f"  - Done when: {s['done_when']}",
            ]
        out += [
            "",
            "## Checks",
            *(f"- `{c}`" for c in data["checks"]),
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


def summary(data: dict) -> dict:
    out: dict = {}
    if "spec" in data:
        out["spec"] = {
            "criteria": [{k: c[k] for k in ("id", "evidence")} for c in data["spec"]["criteria"]],
            "scope_paths": data["spec"]["scope_paths"],
            "consent": data["spec"]["consent"],
        }
    if "plan" in data:
        out["plan"] = {"checks": data["plan"]["checks"], "step_ids": [s["id"] for s in data["plan"]["steps"]]}
    if "qa" in data:
        out["qa"] = {
            "verdict": data["qa"]["verdict"],
            "rows": [{"ac": r["ac"], "result": r["result"]} for r in data["qa"]["rows"]],
        }
    if "followups" in data:
        out["followups"] = {"ids": [i["id"] for i in data["followups"]["items"]]}
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


def cmd_scope_check(schema: dict, args: dict) -> dict:
    root = repo_root()
    _run, directory = resolve_run(root, args.get("run"))
    data, problems = validate_run(directory, schema)
    if problems or "spec" not in data:
        raise Refused("the run artifacts are not valid; scope cannot be checked")
    globs = data["spec"]["scope_paths"]
    changed = changed_paths(root)
    # Ignored artifacts that the candidate names are part of what ships: same rules.
    included = (read_state(directory).get("candidate") or {}).get("include_ignored") or []
    for path in expand_included(root, included):
        if path not in changed:
            changed.append(path)
    outside = [p for p in changed if not in_scope(p, globs)]
    protected = [p for p in changed if is_protected(p)]
    return {
        "ok": not outside and not protected,
        "changed": len(changed),
        "outside_scope": outside,
        "protected": protected,
    }


def cmd_handoff(schema: dict, which: str, args: dict) -> str:
    if which not in ("review", "qa"):
        raise Invalid("handoff needs review or qa")
    root = repo_root()
    run_id, directory = resolve_run(root, args.get("run"))
    data, problems = validate_run(directory, schema)
    if problems or "spec" not in data or "plan" not in data:
        raise Refused("the run artifacts are not valid; no packet can be rendered")
    state = read_state(directory)
    out = [f"# {which.upper()} handoff for run {run_id}", "", f"Phase: {state['phase']}"]
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
    out += ["", "## Acceptance criteria"]
    for c in data["spec"]["criteria"]:
        ref = f"command `{c['command']}`" if "command" in c else f"source {c['source']}"
        out.append(f"- {c['id']}: WHEN {c['when']} THEN {c['then']} ({c['evidence']}; {ref})")
    out += ["", "## Scope", *(f"- {p}" for p in data["spec"]["scope_paths"]), "", "## Recorded checks"]
    out += [f"- `{c['cmd']}` exit {c['exit']}" for c in candidate.get("checks", [])] or ["- none"]
    out += ["", "## Changed paths", *(f"- {p}" for p in changed_paths(root))]
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


def cmd_selftest(schema: dict) -> dict:
    ctx: dict = {}
    for kind in ("spec", "plan", "qa", "followups"):
        example = schema["kinds"][kind]["example"]
        validate_input(kind, example, ctx, schema, None)
        render(kind, example)
        ctx[kind] = example
    return {"ok": True, "kinds": sorted(ctx)}


# ---- entry --------------------------------------------------------------------

VALUE_OPTIONS = {"run", "owner", "out"}


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
