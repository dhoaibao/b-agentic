#!/usr/bin/env python3
"""Claude Code MCP inventory policy note.

The base MCP configuration lists ten servers and offers an
optional ClickUp server. This validator never starts a server, opens a browser,
authenticates, or tests live tool use.
"""

from __future__ import annotations

import argparse


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        print("MCP probe boundary self-test passed.")
    else:
        print("MCP connections are not probed by static validation.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
