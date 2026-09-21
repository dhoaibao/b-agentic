#!/usr/bin/env python3
"""Native OpenCode MCP inventory policy note.

OpenCode's native configuration exposes direct MCP tools but does not supply a
repository-local, argument-aware probe or classification hook. Live server
connections are intentionally outside this static validator; use OpenCode's
own MCP diagnostics when an operator explicitly requests them.
"""

from __future__ import annotations

import argparse


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        print("Native OpenCode MCP probe boundary self-test passed.")
    else:
        print("Native OpenCode MCP schema probing is intentionally unavailable without a custom plugin.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
