#!/usr/bin/env python3
"""Validate Pi's managed-MCP auto-approval policy."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


def parse_set_literal(source: str, const_name: str) -> set[str] | None:
    match = re.search(rf"const {const_name} = new Set\(\[(.*?)\]\);", source, re.DOTALL)
    if not match:
        return None
    return set(re.findall(r'"([^"]+)"', match.group(1)))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", required=True, type=Path)
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    extension = root / "pi/extensions/b-agentic-permissions.ts"
    try:
        policy = json.loads(args.policy.read_text())
        source = extension.read_text()
    except (OSError, json.JSONDecodeError) as exc:
        print(f"failed to load Pi MCP policy inputs: {exc}", file=sys.stderr)
        return 2

    errors: list[str] = []
    servers = policy.get("servers")
    if not isinstance(servers, dict) or not servers:
        errors.append(f"{args.policy}: missing managed servers")
        servers = {}

    managed_servers = set(servers)
    runtime_servers = parse_set_literal(source, "MANAGED_MCP_SERVERS")
    if runtime_servers is None:
        errors.append(f"{extension.relative_to(root)}: MANAGED_MCP_SERVERS is missing or unparsable")
    elif runtime_servers != managed_servers:
        errors.append(
            f"{extension.relative_to(root)}: MANAGED_MCP_SERVERS must equal canonical managed servers "
            f"(expected {sorted(managed_servers)}, found {sorted(runtime_servers)})"
        )

    for server, record in servers.items():
        if not isinstance(record, dict) or not isinstance(record.get("tools"), dict) or not record["tools"]:
            errors.append(f"{args.policy}: {server!r} must declare tools")

    for marker in [
        "function isTrustedManagedTool(server: string, _toolName: string, _input?: unknown): boolean",
        "return isManagedServer(server);",
    ]:
        if marker not in source:
            errors.append(f"{extension.relative_to(root)}: missing managed-server auto-approval marker {marker!r}")

    auth = policy.get("classes", {}).get("auth", {})
    if auth.get("policy") != "Approval required":
        errors.append(f"{args.policy}: auth must remain approval-required because gateway auth is gated at runtime")

    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Pi managed-MCP auto-approval policy validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
