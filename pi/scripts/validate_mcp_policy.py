#!/usr/bin/env python3
"""Validate Pi's managed-MCP approval policy against its runtime sets."""

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


def check_set(errors: list[str], source: str, name: str, expected: set[str], extension: Path, root: Path) -> None:
    actual = parse_set_literal(source, name)
    if actual is None:
        errors.append(f"{extension.relative_to(root)}: {name} is missing or unparsable")
    elif actual != expected:
        errors.append(
            f"{extension.relative_to(root)}: {name} must match canonical policy "
            f"(expected {sorted(expected)}, found {sorted(actual)})"
        )


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

    check_set(errors, source, "MANAGED_MCP_SERVERS", set(servers), extension, root)

    classes = policy.get("classes", {})
    expected_policies = {
        "read-only": "Auto-approved for managed servers",
        "conditional-read": "Auto-approved for safe arguments",
        "local-upload": "Approval required",
        "external-mutation": "Approval required",
        "monitor-lifecycle": "Approval required",
        "local-mutation": "Approval required",
        "auth": "Approval required",
    }
    for name, expected in expected_policies.items():
        if classes.get(name, {}).get("policy") != expected:
            errors.append(f"{args.policy}: {name} must be {expected!r}")

    runtime_sets = {
        "serena": "SERENA_TRUSTED_TOOLS",
        "codegraph": "CODEGRAPH_TRUSTED_TOOLS",
        "context7": "CONTEXT7_TRUSTED_TOOLS",
        "brave-search": "BRAVE_SEARCH_TRUSTED_TOOLS",
        "firecrawl": "FIRECRAWL_TRUSTED_TOOLS",
        "playwright": "PLAYWRIGHT_TRUSTED_TOOLS",
    }
    conditional: set[str] = set()
    for server, runtime_set in runtime_sets.items():
        tools = servers.get(server, {}).get("tools", {})
        if not isinstance(tools, dict):
            errors.append(f"{args.policy}: {server!r} must declare tools")
            continue
        safe_tools = {tool for tool, operation in tools.items() if operation in {"read-only", "conditional-read"}}
        check_set(errors, source, runtime_set, safe_tools, extension, root)
        conditional.update(f"{server}:{tool}" for tool, operation in tools.items() if operation == "conditional-read")

    check_set(errors, source, "MCP_CONDITIONAL_TOOLS", conditional, extension, root)
    gateway = policy.get("gateway_operations", {})
    if isinstance(gateway, dict):
        check_set(
            errors,
            source,
            "MCP_TRUSTED_GATEWAY_OPERATIONS",
            {name for name, operation in gateway.items() if operation == "read-only"},
            extension,
            root,
        )
    else:
        errors.append(f"{args.policy}: missing gateway operations")

    for marker in [
        "isConditionallyTrustedTool(server, base, input)",
        "SERENA_TRUSTED_TOOLS.has(base)",
        "return false;\n  }\n\n  if (hasTool)",
    ]:
        if marker not in source:
            errors.append(f"{extension.relative_to(root)}: missing managed-operation gate {marker!r}")

    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Pi managed-MCP approval policy validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
