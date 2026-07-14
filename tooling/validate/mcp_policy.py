#!/usr/bin/env python3

"""Regression checks for the Pi MCP operation policy.

Canonical source: references/mcp_operations.yaml. Pi's permission extension is
b-agentic's enforced operation boundary.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
POLICY_PATH = ROOT / "references" / "mcp_operations.yaml"
PI_VALIDATOR = ROOT / "pi" / "scripts" / "validate_mcp_policy.py"
GATED_CLASSES = {"local-upload", "external-mutation", "monitor-lifecycle", "local-mutation", "auth"}
READ_ONLY = "read-only"
MANAGED_SERVERS = {"serena", "codegraph", "context7", "brave-search", "firecrawl", "playwright"}


def load_policy() -> dict:
    try:
        return json.loads(POLICY_PATH.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"{POLICY_PATH.relative_to(ROOT)}: invalid policy: {exc}") from exc


def validate_policy_shape(policy: dict, errors: list[str]) -> None:
    classes = policy.get("classes")
    if not isinstance(classes, dict) or not classes:
        errors.append("references/mcp_operations.yaml: missing classes map")
        classes = {}
    for required in [READ_ONLY, *sorted(GATED_CLASSES)]:
        if required not in classes:
            errors.append(f"references/mcp_operations.yaml: missing class {required!r}")

    servers = policy.get("servers")
    if not isinstance(servers, dict) or set(servers) != MANAGED_SERVERS:
        found = sorted(servers) if isinstance(servers, dict) else []
        errors.append(f"references/mcp_operations.yaml: expected servers {sorted(MANAGED_SERVERS)}, found {found}")
        return
    for server, record in servers.items():
        tools = record.get("tools") if isinstance(record, dict) else None
        if not isinstance(tools, dict) or not tools:
            errors.append(f"references/mcp_operations.yaml: server {server!r} has no tools")
            continue
        for tool, classification in tools.items():
            if classification not in classes:
                errors.append(f"references/mcp_operations.yaml: tool {server}:{tool} has unknown class {classification!r}")


def main() -> int:
    errors: list[str] = []
    if not POLICY_PATH.is_file():
        print("references/mcp_operations.yaml: missing canonical MCP operations policy", file=sys.stderr)
        return 1
    try:
        policy = load_policy()
    except ValueError as exc:
        print(exc, file=sys.stderr)
        return 1
    validate_policy_shape(policy, errors)

    if not PI_VALIDATOR.is_file():
        errors.append("pi/scripts/validate_mcp_policy.py: missing Pi MCP policy validator")
    elif not errors:
        result = subprocess.run(
            [sys.executable, str(PI_VALIDATOR), "--policy", str(POLICY_PATH)],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        if result.returncode:
            errors.append(f"Pi MCP policy validation failed: {(result.stderr or result.stdout).strip()}")

    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Pi MCP operation policy regression passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
