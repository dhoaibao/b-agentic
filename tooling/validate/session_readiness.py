#!/usr/bin/env python3
"""Check the active OpenCode session has the RTK prerequisite b-agentic uses."""

from __future__ import annotations

import argparse
import shutil
import sys

REMEDIATION = "Install RTK, then restart the OpenCode session; see the kernel's Shell commands section."


def check_session_tools(which=shutil.which) -> tuple[bool, str]:
    if which("rtk") is None:
        return False, f"blocked: missing rtk. {REMEDIATION}"
    return True, "ready: rtk available"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        ready, _ = check_session_tools(lambda tool: tool if tool == "rtk" else None)
        missing, detail = check_session_tools(lambda _tool: None)
        if not ready or missing or "missing rtk" not in detail:
            print("Session tool readiness self-test failed.", file=sys.stderr)
            return 1
        print("Session tool readiness self-test passed.")
        return 0
    ready, detail = check_session_tools()
    print(f"session-tools: {detail}")
    return 0 if ready else 1


if __name__ == "__main__":
    raise SystemExit(main())
