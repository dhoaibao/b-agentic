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
PI_VALIDATOR = ROOT / "tooling" / "validate" / "validate_mcp_policy.py"
GATED_CLASSES = {"local-upload", "external-mutation", "monitor-lifecycle", "local-mutation", "auth"}
READ_ONLY = "read-only"
CONDITIONAL_CLASSES = {"conditional-read", "conditional-local"}
MANAGED_SERVERS = {"codegraph", "context7", "brave-search", "firecrawl", "playwright"}
MCP_SCRIPT_NUMERIC_FIELDS = {
    "max_total_operations",
    "max_tool_calls",
    "max_sources_or_routes",
    "max_results_per_source",
    "max_normalized_records",
    "max_primary_scrapes",
}


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
    for required in [READ_ONLY, *sorted(CONDITIONAL_CLASSES), *sorted(GATED_CLASSES)]:
        if required not in classes:
            errors.append(f"references/mcp_operations.yaml: missing class {required!r}")

    servers = policy.get("servers")
    if not isinstance(servers, dict) or set(servers) != MANAGED_SERVERS:
        found = sorted(servers) if isinstance(servers, dict) else []
        errors.append(f"references/mcp_operations.yaml: expected servers {sorted(MANAGED_SERVERS)}, found {found}")
        return
    conditional_tools: set[str] = set()
    for server, record in servers.items():
        tools = record.get("tools") if isinstance(record, dict) else None
        if not isinstance(tools, dict) or not tools:
            errors.append(f"references/mcp_operations.yaml: server {server!r} has no tools")
            continue
        for tool, classification in tools.items():
            if classification not in classes:
                errors.append(
                    f"references/mcp_operations.yaml: tool {server}:{tool} has unknown class {classification!r}"
                )
            if classification in CONDITIONAL_CLASSES:
                conditional_tools.add(f"{server}:{tool}")

    conditional_arguments = policy.get("conditional_arguments")
    if not isinstance(conditional_arguments, dict) or set(conditional_arguments) != conditional_tools:
        found = sorted(conditional_arguments) if isinstance(conditional_arguments, dict) else []
        errors.append(
            "references/mcp_operations.yaml: conditional_arguments must match conditional tools "
            f"(expected {sorted(conditional_tools)}, found {found})"
        )
    elif any(
        not isinstance(record, dict)
        or not isinstance(record.get("known"), list)
        or not record["known"]
        or not all(isinstance(name, str) for name in record["known"])
        for record in conditional_arguments.values()
    ):
        errors.append(
            "references/mcp_operations.yaml: each conditional argument record needs a non-empty known string list"
        )

    runtime_policy = policy.get("runtime_enforcement", {}).get("pi", "")
    for marker in (
        "tools.search",
        "tools.describe",
        "nested tools.call",
        "normal approval/auth/output-guard policy",
        "bounded multi-call",
        "browser mutations",
    ):
        if marker not in runtime_policy:
            errors.append(f"references/mcp_operations.yaml: mcpScript runtime policy missing {marker!r}")


def validate_mcp_script_contract(policy: dict, errors: list[str]) -> None:
    contract = policy.get("mcpScript")
    if not isinstance(contract, dict):
        errors.append("references/mcp_operations.yaml: missing mcpScript contract")
        return

    for field in MCP_SCRIPT_NUMERIC_FIELDS:
        value = contract.get(field)
        if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
            errors.append(f"references/mcp_operations.yaml: mcpScript {field} must be a positive integer")
    if all(
        isinstance(contract.get(field), int) and not isinstance(contract.get(field), bool)
        for field in MCP_SCRIPT_NUMERIC_FIELDS
    ):
        if contract["max_tool_calls"] > contract["max_total_operations"]:
            errors.append("references/mcp_operations.yaml: mcpScript max_tool_calls cannot exceed max_total_operations")
        if contract["max_primary_scrapes"] > contract["max_sources_or_routes"]:
            errors.append(
                "references/mcp_operations.yaml: mcpScript max_primary_scrapes cannot exceed max_sources_or_routes"
            )

    if contract.get("allowed_operations") != ["tools.search", "tools.describe", "tools.call"]:
        errors.append(
            "references/mcp_operations.yaml: mcpScript allowed_operations must be search/describe/call in order"
        )

    envelope = contract.get("result_envelope")
    if not isinstance(envelope, dict):
        errors.append("references/mcp_operations.yaml: mcpScript result_envelope is required")
        return
    if envelope.get("success") != ["ok", "data"]:
        errors.append("references/mcp_operations.yaml: mcpScript success envelope must be {ok, data}")
    if envelope.get("failure") != ["ok", "error"]:
        errors.append("references/mcp_operations.yaml: mcpScript failure envelope must be {ok, error}")
    if envelope.get("content_block_types") != ["text", "image", "audio", "resource", "resource_link"]:
        errors.append("references/mcp_operations.yaml: mcpScript content block types are incomplete or reordered")
    if envelope.get("normalized_fields") != ["title", "url", "claim", "error"]:
        errors.append("references/mcp_operations.yaml: mcpScript normalized fields must be title/url/claim/error")
    if envelope.get("deduplicate_by") != ["url", "title+claim"]:
        errors.append("references/mcp_operations.yaml: mcpScript deduplication keys must be URL then title+claim")
    if (
        not isinstance(envelope.get("partial_failure"), str)
        or "partial" not in envelope["partial_failure"].lower()
        or "error" not in envelope["partial_failure"].lower()
    ):
        errors.append("references/mcp_operations.yaml: mcpScript must define bounded partial-failure reporting")
    if not isinstance(contract.get("fallback"), str) or "direct top-level mcp" not in contract["fallback"]:
        errors.append("references/mcp_operations.yaml: mcpScript must define direct-mcp fallback guidance")


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
    validate_mcp_script_contract(policy, errors)

    if not PI_VALIDATOR.is_file():
        errors.append("tooling/validate/validate_mcp_policy.py: missing Pi MCP policy validator")
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
