#!/usr/bin/env python3
"""Pi MCP inventory policy note.

The Pi adapter's static configuration lists seven lazy servers. This validator
never starts a server, opens a browser, authenticates, or tests live tool use.
"""

from __future__ import annotations

import argparse


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        print("Pi MCP probe boundary self-test passed.")
    else:
        print("Pi MCP connections are not probed by static validation.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
