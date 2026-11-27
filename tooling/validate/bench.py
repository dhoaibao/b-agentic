#!/usr/bin/env python3
"""Time the scripts b-agentic runs on a hot path and report medians as JSON.

Not part of validate-skills.sh: timings are noisy. `--check` compares the
medians with the speed targets (plus a tolerance) and exits 1 on a miss.
"""

import argparse
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOOKS = ROOT / "claude" / "hooks"
BIN = ROOT / "claude" / "bin"

# (name, runtime) -> milliseconds. A runtime of "py" is python3. Claude Code runs the hooks and CLIs with bun
# (ADR-018); the snapshot CLI is a Bun script.
TARGETS = {
    ("path-guard", "bun"): 15,
    ("codex-guard", "bun"): 17,
    ("statusline", "bun"): 20,
    ("snapshot", "bun"): 45,
    ("snapshot", "node"): 70,
    ("b_run-startup", "py"): 40,
    ("mcp_policy", "py"): 200,
}
# The command that starts each runtime: bun with the flags the installer writes into the managed commands.
BUN_FLAGS = ["--no-env-file", "--config=/dev/null"]

PATH_GUARD_INPUT = {"tool_name": "Read", "tool_input": {"file_path": "/repo/src/app.ts"}}
CODEX_GUARD_INPUT = {"tool_name": "Bash", "cwd": "/tmp", "tool_input": {"command": "rtk git status --short"}}
VERIFY_GATE_INPUT = {
    "hook_event_name": "PostToolUse",
    "session_id": "bench",
    "tool_name": "Edit",
    "tool_input": {"file_path": "/repo/src/a.ts"},
    "stop_hook_active": False,
}
STATUSLINE_INPUT = {
    "model": {"display_name": "Opus"},
    "effort": {"level": "high"},
    "context_window": {
        "used_percentage": 55.4,
        "context_window_size": 1000000,
        "current_usage": {"input_tokens": 10, "cache_read_input_tokens": 554000},
    },
    "rate_limits": {"five_hour": {"used_percentage": 12, "resets_at": int(time.time()) + 5000}},
}


def run_once(argv, stdin, env, cwd):
    start = time.perf_counter()
    subprocess.run(
        argv,
        input=stdin,
        env=env,
        cwd=cwd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return (time.perf_counter() - start) * 1000


def median_ms(argv, stdin, env, cwd, reps):
    run_once(argv, stdin, env, cwd)  # warm the file cache
    return round(statistics.median(run_once(argv, stdin, env, cwd) for _ in range(reps)), 1)


def make_repo(path):
    env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"}
    for args in (
        ["init", "-q", "."],
        ["config", "user.email", "bench@example.invalid"],
        ["config", "user.name", "bench"],
    ):
        subprocess.run(["git", "-C", str(path), *args], env=env, check=True, stdout=subprocess.DEVNULL)
    (path / "a.txt").write_text("a\n")
    (path / "b.txt").write_text("b\n")
    for args in (["add", "."], ["commit", "-qm", "init"]):
        subprocess.run(["git", "-C", str(path), *args], env=env, check=True, stdout=subprocess.DEVNULL)
    (path / "a.txt").write_text("changed\n")
    (path / "new.txt").write_text("new\n")


def install_git_shim(shim_dir, log):
    real = shutil.which("git")
    shim = shim_dir / "git"
    shim.write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" >> "{log}"\nexec "{real}" "$@"\n')
    shim.chmod(0o755)


def count_git(argv, env, cwd, log, lines=None):
    log.write_text("")
    run_once(argv, None, env, cwd)
    calls = log.read_text().splitlines()
    if lines is not None:
        lines.extend(calls)
    return len(calls)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reps", type=int, default=15)
    parser.add_argument("--git-calls", action="store_true", help="also list the git command lines each item runs")
    parser.add_argument("--check", action="store_true", help="exit 1 when a target is missed")
    parser.add_argument("--tolerance", type=float, default=1.15, help="multiplier on each target for --check")
    args = parser.parse_args()

    runtimes = {}
    if shutil.which("bun"):
        runtimes["bun"] = [shutil.which("bun"), *BUN_FLAGS]
    if shutil.which("node"):
        runtimes["node"] = [shutil.which("node")]
    if "bun" not in runtimes:
        sys.exit("bench.py needs bun on PATH")

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        repo = tmp / "repo"
        repo.mkdir()
        make_repo(repo)
        env = {
            **os.environ,
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_CEILING_DIRECTORIES": str(tmp),
            "B_AGENTIC_GATE_DIR": str(tmp / "gate"),
            "CLAUDE_CODE_SESSION_ID": "bench",
        }
        shim_dir = tmp / "shim"
        shim_dir.mkdir()
        log = tmp / "git.log"
        install_git_shim(shim_dir, log)
        shim_env = {**env, "PATH": f"{shim_dir}{os.pathsep}{env['PATH']}"}

        hook_cases = {
            "path-guard": (HOOKS / "b-path-guard.mjs", PATH_GUARD_INPUT),
            "codex-guard": (HOOKS / "b-codex-guard.mjs", {**CODEX_GUARD_INPUT, "cwd": str(repo)}),
            "verify-gate": (HOOKS / "b-verify-gate.mjs", VERIFY_GATE_INPUT),
            "statusline": (BIN / "b-statusline.mjs", STATUSLINE_INPUT),
        }
        subprocess.run(
            [*runtimes["bun"], str(BIN / "b-state.mjs"), "init", "bench", "--owner", "bench"],
            env=env,
            cwd=str(repo),
            check=True,
            stdout=subprocess.DEVNULL,
        )
        medians = {}
        git_lines = {}
        for name, (script, payload) in hook_cases.items():
            for runtime, binary in runtimes.items():
                medians[f"{name}/{runtime}"] = median_ms(
                    [*binary, str(script)], json.dumps(payload).encode(), env, str(repo), args.reps
                )
        for runtime, binary in runtimes.items():
            snap = [*binary, str(BIN / "b-candidate-snapshot.mjs")]
            medians[f"snapshot/{runtime}"] = median_ms(snap, None, env, str(repo), args.reps)
            medians[f"snapshot-git-runs/{runtime}"] = count_git(
                snap, shim_env, str(repo), log, git_lines.setdefault(f"snapshot/{runtime}", [])
            )
            state = [*binary, str(BIN / "b-state.mjs"), "check", "--owner", "bench"]
            medians[f"b-state-check/{runtime}"] = median_ms(state, None, env, str(repo), args.reps)
            medians[f"b-state-check-git-runs/{runtime}"] = count_git(
                state, shim_env, str(repo), log, git_lines.setdefault(f"b-state-check/{runtime}", [])
            )
        py = sys.executable or "python3"
        # An install ships this bytecode with the CLI (ADR-040), so the target is for a run that has it.
        module = str(BIN / "b_run_lib.py")
        compile_args = ["-I", "-m", "compileall", "-q", "-f", "--invalidation-mode", "checked-hash", module]
        subprocess.run([py, *compile_args], check=True)
        medians["b_run-startup/py"] = median_ms(
            [py, "-I", "-B", str(BIN / "b_run.py"), "schema", "spec"], None, env, str(repo), args.reps
        )
        medians["mcp_policy/py"] = median_ms(
            [py, "-I", "-B", str(ROOT / "tooling" / "validate" / "mcp_policy.py")], None, env, str(ROOT), 3
        )

    report = {"reps": args.reps, "medians_ms": medians}
    if args.git_calls:
        report["git_calls"] = git_lines
    misses = []
    if args.check:
        for (name, runtime), target in TARGETS.items():
            value = medians.get(f"{name}/{runtime}")
            if value is None:
                continue  # runtime not installed here
            if value > target * args.tolerance:
                misses.append(f"{name}/{runtime}: {value} ms > {target} ms (x{args.tolerance})")
        report["misses"] = misses
    print(json.dumps(report, indent=2))
    return 1 if misses else 0


if __name__ == "__main__":
    sys.exit(main())
