#!/usr/bin/env python3
"""Keep the per-runtime kit path lists equal to what each install really reads (ADR-036).

The lists in tooling/install/claude_install.py (KIT_PATHS) decide which commits change a runtime's kit
version. This runs a dry-run install of each runtime, and of both together, with every optional component
in a throwaway HOME, records each source file Python opens and each source module it imports, and traces
the Pi render on its own because the installer starts it as a subprocess. It fails when a runtime reads a
file its list does not match, or a list matches a file that runtime's install does not read.
"""

from __future__ import annotations

import json
import os
import runpy
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
INSTALL = ROOT / "tooling" / "install"
sys.path.insert(0, str(INSTALL))

# Listed although a single-runtime Python install never reads them: the shell entry point of every install,
# and the combined installer that only --runtime=all runs.
UNTRACED = {"install.sh", "tooling/install/all_install.py"}
SCRIPTS = {
    "claude": "tooling/install/claude_install.py",
    "pi": "tooling/install/pi_install.py",
    "all": "tooling/install/all_install.py",
}
TIMEOUT = 300


def source_relative(value: object) -> str | None:
    """The repository-relative name of a source file, or None for anything else."""
    if isinstance(value, bytes):
        value = os.fsdecode(value)
    if not isinstance(value, (str, os.PathLike)):
        return None
    path = Path(os.path.abspath(os.fspath(value)))
    if not path.is_relative_to(ROOT):
        return None
    relative = path.relative_to(ROOT)
    if relative.parts[:1] == (".git",) or "__pycache__" in relative.parts or not path.is_file():
        return None
    return relative.as_posix()


def trace(out: str, script: str, args: list[str]) -> int:
    """Run one source script in this process and write every source file it opened or imported to `out`."""
    opened: set[object] = set()

    def hook(event: str, details: tuple) -> None:
        if event == "open" and details and isinstance(details[0], (str, bytes)):
            opened.add(details[0])

    target = ROOT / script
    sys.path.insert(0, str(target.parent))
    sys.argv = [str(target), *args]
    code = 0
    sys.addaudithook(hook)
    try:
        runpy.run_path(str(target), run_name="__main__")
    except SystemExit as exc:
        code = exc.code if isinstance(exc.code, int) else (0 if exc.code is None else 1)
    read = {source_relative(value) for value in list(opened)}
    read.add(source_relative(target))
    read.update(source_relative(getattr(module, "__file__", None)) for module in list(sys.modules.values()))
    read.discard(None)
    # This tracer is loaded too; it is not part of any install.
    read.discard(Path(__file__).resolve().relative_to(ROOT).as_posix())
    Path(out).write_text(json.dumps(sorted(read)))
    return code


def traced_reads(work: Path, name: str, script: str, args: list[str]) -> set[str]:
    home = work / name
    home.mkdir()
    out = work / f"{name}.json"
    env = {key: os.environ[key] for key in ("PATH", "LANG", "LC_ALL", "TMPDIR") if key in os.environ}
    env["HOME"] = str(home)
    done = subprocess.run(
        [sys.executable, "-I", "-B", str(Path(__file__).resolve()), "--trace", str(out), script, *args],
        capture_output=True,
        text=True,
        env=env,
        cwd=str(ROOT),
        stdin=subprocess.DEVNULL,
        timeout=TIMEOUT,
    )
    if done.returncode != 0 or not out.is_file():
        raise RuntimeError(f"traced {name} run failed ({done.returncode}): {(done.stderr or done.stdout).strip()}")
    return set(json.loads(out.read_text()))


def listed_files(pathspecs: list[str]) -> set[str]:
    """Tracked and untracked, not ignored, files that git matches with these pathspecs."""
    done = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", *pathspecs],
        capture_output=True,
        text=True,
        check=True,
        timeout=TIMEOUT,
    )
    return {name for name in done.stdout.split("\0") if name and (ROOT / name).is_file()}


def compare(label: str, read: set[str], listed: set[str], untraced: set[str]) -> list[str]:
    errors = [f"{label}: reads {name}, which its kit path list does not match" for name in sorted(read - listed)]
    errors += [
        f"{label}: the kit path list matches {name}, which this install does not read"
        for name in sorted(listed - read - untraced)
    ]
    return errors


def self_test() -> list[str]:
    errors = []
    if not compare("t", {"a", "planted"}, {"a"}, set()):
        errors.append("self-test: an unlisted read must fail")
    if not compare("t", {"a"}, {"a", "stale"}, set()):
        errors.append("self-test: a listed file nothing reads must fail")
    if compare("t", {"a"}, {"a", "exempt"}, {"exempt"}):
        errors.append("self-test: an exempt file must pass")
    return errors


def planted_read(work: Path, listed: set[str]) -> list[str]:
    """A real unlisted read, through the real tracer, must be reported."""
    script = work / "planted.py"
    script.write_text(f"from pathlib import Path\nPath({str(ROOT / 'AGENTS.md')!r}).read_bytes()\n")
    found = compare("planted", traced_reads(work, "planted", str(script), []), listed, listed)
    if found != ["planted: reads AGENTS.md, which its kit path list does not match"]:
        return [f"self-test: a planted unlisted read must fail, got {found}"]
    return []


def check() -> list[str]:
    import claude_install
    import optional_components

    errors = self_test()
    components = ",".join(sorted(optional_components.load(ROOT)))
    flags = ["--dry-run", "-y", "--source", str(ROOT), *(["--with", components] if components else [])]
    listed = {runtime: listed_files(claude_install.kit_pathspecs(runtime)) for runtime in ("claude", "pi")}
    with tempfile.TemporaryDirectory(prefix="b-agentic-kit-paths-") as folder:
        work = Path(folder).resolve()
        errors += planted_read(work, listed["claude"])
        reads = {name: traced_reads(work, name, script, flags) for name, script in SCRIPTS.items()}
        render = traced_reads(
            work, "render", "tooling/generate/registry_sync.py", ["--render", "pi", "--out", str(work / "tree")]
        )
    errors += compare("claude", reads["claude"], listed["claude"], UNTRACED)
    errors += compare("pi", reads["pi"] | render, listed["pi"], UNTRACED)
    errors += compare("all", reads["all"] | render, listed["claude"] | listed["pi"], UNTRACED)
    return errors


def main(argv: list[str]) -> int:
    if argv[:1] == ["--trace"]:
        return trace(argv[1], argv[2], argv[3:])
    if argv:
        print("usage: kit_paths.py", file=sys.stderr)
        return 2
    try:
        errors = check()
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as exc:
        errors = [str(exc)]
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    if not errors:
        print("kit paths: each runtime's list matches what its install reads")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
