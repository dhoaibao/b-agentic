#!/usr/bin/env python3
"""Pi adapter validation for the canonical MCP operation policy."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


READ_ONLY = "read-only"
GATED_CLASSES = {"local-upload", "external-mutation", "monitor-lifecycle", "local-mutation", "auth"}
GATEWAY_TRUSTED_SET_NAME = "MCP_TRUSTED_GATEWAY_OPERATIONS"
TRUSTED_SET_NAMES = {
    "serena": "SERENA_TRUSTED_TOOLS",
    "codegraph": "CODEGRAPH_TRUSTED_TOOLS",
    "context7": "CONTEXT7_TRUSTED_TOOLS",
    "brave-search": "BRAVE_SEARCH_TRUSTED_TOOLS",
    "firecrawl": "FIRECRAWL_TRUSTED_TOOLS",
    "playwright": "PLAYWRIGHT_TRUSTED_TOOLS",
}


def parse_set_literal(source: str, const_name: str) -> set[str]:
    match = re.search(rf"const {const_name} = new Set\(\[(.*?)\]\);", source, re.DOTALL)
    return set(re.findall(r'"([^"]+)"', match.group(1))) if match else set()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", required=True, type=Path)
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    extension = root / "pi/extensions/b-agentic-permissions.ts"
    try:
        policy = json.loads(args.policy.read_text())
        text = extension.read_text()
    except (OSError, json.JSONDecodeError) as exc:
        print(f"failed to load Pi MCP policy inputs: {exc}", file=sys.stderr)
        return 2
    errors: list[str] = []

    gateway_operations = policy.get("gateway_operations", {})
    if not isinstance(gateway_operations, dict) or not gateway_operations:
        errors.append("references/mcp_operations.yaml: missing gateway_operations map")
    else:
        trusted_gateway = parse_set_literal(text, GATEWAY_TRUSTED_SET_NAME)
        if not trusted_gateway:
            errors.append(f"{extension.relative_to(root)}: {GATEWAY_TRUSTED_SET_NAME} missing or unparsable")
        for operation in sorted(trusted_gateway - set(gateway_operations)):
            errors.append(
                f"{extension.relative_to(root)}: {GATEWAY_TRUSTED_SET_NAME} includes unclassified gateway operation {operation!r}"
            )
        for operation, classification in gateway_operations.items():
            if classification == READ_ONLY and operation not in trusted_gateway:
                errors.append(f"{extension.relative_to(root)}: read-only gateway operation {operation!r} must be trusted")
            elif classification in GATED_CLASSES and operation in trusted_gateway:
                errors.append(f"{extension.relative_to(root)}: gated gateway operation {operation!r} must not be trusted")

    for server, record in policy.get("servers", {}).items():
        tools = record.get("tools", {}) if isinstance(record, dict) else {}
        set_name = TRUSTED_SET_NAMES.get(server)
        if set_name is None:
            errors.append(f"{extension.relative_to(root)}: no trusted-set mapping for managed server {server!r}")
            continue
        trusted_tools = parse_set_literal(text, set_name)
        if not trusted_tools:
            errors.append(f"{extension.relative_to(root)}: {set_name} missing or unparsable")
            continue
        for tool in sorted(trusted_tools - set(tools)):
            if not tool.endswith("*"):
                errors.append(
                    f"{extension.relative_to(root)}: {set_name} includes unclassified managed tool {tool!r}; "
                    "add it to references/mcp_operations.yaml"
                )
        for tool, classification in tools.items():
            if classification == READ_ONLY and tool not in trusted_tools:
                errors.append(f"{extension.relative_to(root)}: read-only {server} tool {tool!r} must be trusted")
            elif classification in GATED_CLASSES and tool in trusted_tools:
                errors.append(f"{extension.relative_to(root)}: gated {server} tool {tool!r} must not be trusted")

    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Pi MCP operation-policy adapter validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
