#!/usr/bin/env python3
"""Check the active session has the shell tools required by b-agentic."""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path

REQUIRED_TOOLS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("rtk", ("rtk",)),
    ("rg", ("rg",)),
    ("fd/fdfind", ("fd", "fdfind")),
    ("bat/batcat", ("bat", "batcat")),
    ("eza/exa", ("eza", "exa")),
    ("sd", ("sd",)),
    ("jq", ("jq",)),
)
REMEDIATION = "Install the missing prerequisites, then restart the runtime session; see the kernel's Shell commands section."
ROOT = Path(__file__).resolve().parents[2]
RTK_POLICY = ROOT / "pi" / "extensions" / "b-agentic-permissions.ts"


def configured_rtk_families(path: Path = RTK_POLICY) -> set[str]:
    text = path.read_text()
    match = re.search(r"const RTK_REQUIRED_COMMANDS = new Set\(\[(.*?)\]\);", text, re.DOTALL)
    if not match:
        raise ValueError("RTK_REQUIRED_COMMANDS is missing or unparsable")
    return set(re.findall(r'"([^"]+)"', match.group(1)))


def available_rtk_families(help_text: str) -> set[str]:
    return set(re.findall(r"^  ([a-z][a-z0-9-]*)\s{2,}", help_text, re.MULTILINE))


def check_rtk_policy() -> tuple[bool, str]:
    try:
        completed = subprocess.run(["rtk", "--help"], capture_output=True, text=True)
        if completed.returncode:
            return False, "blocked: rtk --help failed; cannot verify command-policy compatibility"
        configured = configured_rtk_families()
    except (OSError, ValueError) as exc:
        return False, f"blocked: cannot verify RTK command policy: {exc}"
    missing = sorted(configured - available_rtk_families(completed.stdout))
    if missing:
        return False, f"blocked: RTK command-policy drift for {', '.join(missing)}"
    return True, "RTK command policy compatible"


def missing_tools(which: Callable[[str], str | None] = shutil.which) -> list[str]:
    return [label for label, commands in REQUIRED_TOOLS if not any(which(command) for command in commands)]


def check_session_tools(
    which: Callable[[str], str | None] = shutil.which,
    *,
    verify_rtk_policy: bool = True,
) -> tuple[bool, str]:
    missing = missing_tools(which)
    if missing:
        return False, f"blocked: missing {', '.join(missing)}. {REMEDIATION}"
    if verify_rtk_policy:
        compatible, detail = check_rtk_policy()
        if not compatible:
            return False, detail
        return True, f"ready: rtk, rg, fd/fdfind, bat/batcat, eza/exa, sd, and jq available; {detail}"
    return True, "ready: rtk, rg, fd/fdfind, bat/batcat, eza/exa, sd, and jq available"


def self_test() -> int:
    available = {command for _, commands in REQUIRED_TOOLS for command in commands}
    ok, _ = check_session_tools(
        lambda command: command if command in available else None,
        verify_rtk_policy=False,
    )
    if not ok:
        print("complete-tool fixture unexpectedly failed", file=sys.stderr)
        return 1
    ok, detail = check_session_tools(
        lambda command: command if command in available - {"fd", "fdfind"} else None,
        verify_rtk_policy=False,
    )
    if ok or "fd/fdfind" not in detail or REMEDIATION not in detail:
        print("missing-tool fixture unexpectedly passed", file=sys.stderr)
        return 1
    parsed = available_rtk_families("Commands:\n  git            Git commands\n  pytest         Pytest commands\n")
    if parsed != {"git", "pytest"}:
        print("RTK help fixture unexpectedly failed", file=sys.stderr)
        return 1
    print("Session tool readiness self-test passed.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Check shell-tool readiness for the active b-agentic session.")
    parser.add_argument("--self-test", action="store_true", help="Run complete-tool and missing-tool fixtures.")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    ready, detail = check_session_tools()
    print(f"session-tools: {detail}")
    return 0 if ready else 1


if __name__ == "__main__":
    raise SystemExit(main())
