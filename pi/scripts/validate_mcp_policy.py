#!/usr/bin/env python3
"""Validate Pi's managed-MCP approval policy against its runtime sets."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


def parse_set_literal(source: str, const_name: str) -> set[str] | None:
    match = re.search(rf"(?:export )?const {const_name} = new Set\(\[(.*?)\]\);", source, re.DOTALL)
    if not match:
        return None
    return set(re.findall(r'"([^"]+)"', match.group(1)))


def check_set(errors: list[str], source: str, name: str, expected: set[str], owner: Path, root: Path) -> None:
    actual = parse_set_literal(source, name)
    if actual is None:
        errors.append(f"{owner.relative_to(root)}: {name} is missing or unparsable")
    elif actual != expected:
        errors.append(
            f"{owner.relative_to(root)}: {name} must match canonical policy "
            f"(expected {sorted(expected)}, found {sorted(actual)})"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", required=True, type=Path)
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    extension = root / "pi/extensions/b-agentic-support/mcp.ts"
    generated = root / "pi/extensions/b-agentic-support/mcp-generated-policy.ts"
    try:
        policy = json.loads(args.policy.read_text())
        extension_source = extension.read_text()
        generated_source = generated.read_text()
    except (OSError, json.JSONDecodeError) as exc:
        print(f"failed to load Pi MCP policy inputs: {exc}", file=sys.stderr)
        return 2

    errors: list[str] = []
    servers = policy.get("servers")
    if not isinstance(servers, dict) or not servers:
        errors.append(f"{args.policy}: missing managed servers")
        servers = {}

    check_set(errors, generated_source, "MANAGED_MCP_SERVERS", set(servers), generated, root)

    classes = policy.get("classes", {})
    expected_policies = {
        "read-only": "Auto-approved for managed servers",
        "conditional-read": "Auto-approved for safe arguments",
        "conditional-local": "Auto-approved inside current project",
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
        "codegraph": "CODEGRAPH_TRUSTED_TOOLS",
        "context7": "CONTEXT7_TRUSTED_TOOLS",
        "brave-search": "BRAVE_SEARCH_TRUSTED_TOOLS",
        "firecrawl": "FIRECRAWL_TRUSTED_TOOLS",
        "playwright": "PLAYWRIGHT_TRUSTED_TOOLS",
        "mobbin": "MOBBIN_TRUSTED_TOOLS",
        "shadcn": "SHADCN_TRUSTED_TOOLS",
    }
    conditional: set[str] = set()
    for server, runtime_set in runtime_sets.items():
        tools = servers.get(server, {}).get("tools", {})
        if not isinstance(tools, dict):
            errors.append(f"{args.policy}: {server!r} must declare tools")
            continue
        safe_tools = {
            tool
            for tool, operation in tools.items()
            if operation in {"read-only", "conditional-read", "conditional-local"}
        }
        check_set(errors, generated_source, runtime_set, safe_tools, generated, root)
        conditional.update(
            f"{server}:{tool}"
            for tool, operation in tools.items()
            if operation in {"conditional-read", "conditional-local"}
        )

    check_set(errors, generated_source, "MCP_CONDITIONAL_TOOLS", conditional, generated, root)

    conditional_arguments = policy.get("conditional_arguments", {})
    if not isinstance(conditional_arguments, dict):
        errors.append(f"{args.policy}: missing conditional_arguments map")
        conditional_arguments = {}
    expected_arguments: dict[str, object] = {}
    for key, value in sorted(conditional_arguments.items()):
        if not isinstance(value, dict) or "known" not in value:
            errors.append(f"{args.policy}: conditional_arguments {key!r} must be a map with a 'known' list")
            continue
        expected_arguments[key] = value["known"]
    arguments_match = re.search(
        r"(?:export )?const MCP_CONDITIONAL_ARGUMENTS: Record<string, readonly string\[\]> = (\{.*?\});",
        generated_source,
        re.DOTALL,
    )
    if arguments_match is None:
        errors.append(f"{generated.relative_to(root)}: MCP_CONDITIONAL_ARGUMENTS is missing or unparsable")
    else:
        try:
            actual_arguments = json.loads(arguments_match.group(1))
        except json.JSONDecodeError:
            actual_arguments = None
        if actual_arguments != expected_arguments:
            if isinstance(actual_arguments, dict):
                differing = sorted(
                    key
                    for key in set(expected_arguments) | set(actual_arguments)
                    if expected_arguments.get(key) != actual_arguments.get(key)
                )
                detail = "; ".join(
                    f"{key}: expected {expected_arguments.get(key)!r}, found {actual_arguments.get(key)!r}"
                    for key in differing
                )
            else:
                detail = f"found unparsable literal {actual_arguments!r}"
            errors.append(
                f"{generated.relative_to(root)}: MCP_CONDITIONAL_ARGUMENTS must match canonical "
                f"conditional_arguments ({detail})"
            )

    for marker in [
        "isConditionallyTrustedTool(server, base, input)",
        "CODEGRAPH_TRUSTED_TOOLS.has(base)",
        "isTrustedManagedGatewayCall",
    ]:
        if marker not in extension_source:
            errors.append(f"{extension.relative_to(root)}: missing managed-operation gate {marker!r}")

    # The runtime source of truth is mcp.ts; it must import the generated sets
    # rather than re-declare them locally, or validation would pass while the
    # runtime diverges.
    if 'from "./mcp-generated-policy.ts"' not in extension_source:
        errors.append(
            f"{extension.relative_to(root)}: must import generated policy sets from ./mcp-generated-policy.ts"
        )
    for identifier in ["MANAGED_MCP_SERVERS", "MCP_CONDITIONAL_TOOLS", "MCP_CONDITIONAL_ARGUMENTS"]:
        if not re.search(rf"import\s*\{{[^}}]*\b{identifier}\b", extension_source, re.DOTALL):
            errors.append(f"{extension.relative_to(root)}: must import {identifier} from the generated policy module")

    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Pi managed-MCP approval policy validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
