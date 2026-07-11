#!/usr/bin/env python3
"""Check the active session has the shell tools required by b-agentic."""

from __future__ import annotations

import argparse
import shutil
import sys
from collections.abc import Callable

REQUIRED_TOOLS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("rtk", ("rtk",)),
    ("rg", ("rg",)),
    ("fd/fdfind", ("fd", "fdfind")),
    ("bat/batcat", ("bat", "batcat")),
    ("eza/exa", ("eza", "exa")),
    ("sd", ("sd",)),
    ("jq", ("jq",)),
)
REMEDIATION = "Install the missing prerequisites, then restart the runtime session; see references/contract/shell-tools.md."


def missing_tools(which: Callable[[str], str | None] = shutil.which) -> list[str]:
    return [label for label, commands in REQUIRED_TOOLS if not any(which(command) for command in commands)]


def check_session_tools(which: Callable[[str], str | None] = shutil.which) -> tuple[bool, str]:
    missing = missing_tools(which)
    if not missing:
        return True, "ready: rtk, rg, fd/fdfind, bat/batcat, eza/exa, sd, and jq available"
    return False, f"blocked: missing {', '.join(missing)}. {REMEDIATION}"


def self_test() -> int:
    available = {command for _, commands in REQUIRED_TOOLS for command in commands}
    ok, _ = check_session_tools(lambda command: command if command in available else None)
    if not ok:
        print("complete-tool fixture unexpectedly failed", file=sys.stderr)
        return 1
    ok, detail = check_session_tools(lambda command: command if command in available - {"fd", "fdfind"} else None)
    if ok or "fd/fdfind" not in detail or REMEDIATION not in detail:
        print("missing-tool fixture unexpectedly passed", file=sys.stderr)
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
