#!/usr/bin/env python3

"""Table-driven MCP operation policy regression.

Canonical source: references/contract/mcp_operations.yaml.
The contract table in safety-tools.md is generated from that file.

Enforced per-tool runtimes (Pi) treat adapter policy as the runtime-enforced
operation boundary. Adapters must:
- auto-allow only classified read-only tools for Firecrawl/Playwright;
- never auto-allow gated classes;
- never include an unclassified Firecrawl/Playwright tool in allow/trust sets.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
POLICY_PATH = ROOT / "references" / "contract" / "mcp_operations.yaml"

GATED_CLASSES = {"local-upload", "external-mutation", "monitor-lifecycle", "auth"}
READ_ONLY = "read-only"
# Runtime-enforced operation boundary (support_tier=operation-enforced).
ENFORCED_PER_TOOL_RUNTIMES = ("pi",)
MANAGED_SCOPED_SERVERS = ("firecrawl", "playwright")


def rel(path: Path) -> str:
    try:
        return path.relative_to(ROOT).as_posix()
    except ValueError:
        return str(path)


def load_json(path: Path) -> dict:
    return json.loads(path.read_text())


def load_policy() -> dict:
    return load_json(POLICY_PATH)


def tools_by_server(policy: dict) -> dict[str, dict[str, str]]:
    servers = policy.get("servers", {})
    result: dict[str, dict[str, str]] = {}
    for server_name, server in servers.items():
        if not isinstance(server, dict):
            continue
        tools = server.get("tools", {})
        if not isinstance(tools, dict):
            continue
        result[server_name] = {
            str(tool): str(classification)
            for tool, classification in tools.items()
        }
    return result


def parse_set_literal(source: str, const_name: str) -> set[str]:
    match = re.search(rf"const {const_name} = new Set\(\[(.*?)\]\);", source, re.DOTALL)
    if not match:
        return set()
    return set(re.findall(r'"([^"]+)"', match.group(1)))


def validate_policy_shape(policy: dict, errors: list[str]) -> dict[str, dict[str, str]]:
    label = rel(POLICY_PATH)
    classes = policy.get("classes")
    if not isinstance(classes, dict) or not classes:
        errors.append(f"{label}: missing classes map")
        classes = {}
    for required in [READ_ONLY, *sorted(GATED_CLASSES)]:
        if required not in classes:
            errors.append(f"{label}: missing class {required!r}")

    servers = tools_by_server(policy)
    if set(servers) != set(MANAGED_SCOPED_SERVERS):
        errors.append(
            f"{label}: expected servers {sorted(MANAGED_SCOPED_SERVERS)}, found {sorted(servers)}"
        )

    for server_name, tools in servers.items():
        if not tools:
            errors.append(f"{label}: server {server_name!r} has no tools")
        for tool, classification in tools.items():
            if classification not in classes:
                errors.append(
                    f"{label}: tool {server_name}:{tool} has unknown class {classification!r}"
                )

    auth_ops = policy.get("auth_operations", [])
    if not isinstance(auth_ops, list) or not auth_ops:
        errors.append(f"{label}: auth_operations must be a non-empty list")
    else:
        for auth in auth_ops:
            if not isinstance(auth, dict) or auth.get("class") != "auth":
                errors.append(f"{label}: auth operation must use class 'auth': {auth!r}")

    fully_trusted = policy.get("fully_trusted_servers", [])
    for server in ("serena", "codegraph", "context7", "brave-search"):
        if server not in fully_trusted:
            errors.append(f"{label}: fully_trusted_servers missing {server!r}")

    trust = policy.get("fully_trusted_server_rationale")
    if not isinstance(trust, dict) or not trust:
        errors.append(f"{label}: fully_trusted_server_rationale must document server-level trust")
    else:
        for server in fully_trusted if isinstance(fully_trusted, list) else []:
            if server not in trust:
                errors.append(f"{label}: fully_trusted_server_rationale missing {server!r}")

    return servers


def validate_contract_generated(policy: dict, servers: dict[str, dict[str, str]], errors: list[str]) -> None:
    safety_path = ROOT / "references" / "contract" / "safety-tools.md"
    safety = safety_path.read_text()
    label = rel(safety_path)

    for marker in [
        "Managed MCP Operation Classification",
        "references/contract/mcp_operations.yaml",
        "<!-- generated:mcp-operations:start -->",
        "<!-- generated:mcp-operations:end -->",
        "Runtime enforcement notes",
        "server-level trust",
    ]:
        if marker not in safety:
            errors.append(f"{label}: missing marker {marker!r}")

    # Closed-world: every classified tool must appear in the rendered contract table.
    start = "<!-- generated:mcp-operations:start -->"
    end = "<!-- generated:mcp-operations:end -->"
    try:
        block = safety.split(start, 1)[1].split(end, 1)[0]
    except IndexError:
        errors.append(f"{label}: generated MCP operations block missing")
        return

    for server_name, tools in servers.items():
        for tool in tools:
            token = f"`{tool}`"
            if token not in block:
                errors.append(f"{label}: generated table missing classified tool {tool!r}")

    for class_name in policy.get("classes", {}):
        if f"`{class_name}`" not in block:
            errors.append(f"{label}: generated table missing class {class_name!r}")


def reject_unknown(label: str, surface: str, observed: set[str], known: set[str], errors: list[str]) -> None:
    for tool in sorted(observed - known):
        # Ignore explicit wildcards; those are checked separately.
        if tool.endswith("*"):
            continue
        errors.append(
            f"{label}: {surface} includes unclassified managed tool {tool!r}; "
            "add it to references/contract/mcp_operations.yaml"
        )


def validate_pi(servers: dict[str, dict[str, str]], errors: list[str]) -> None:
    path = ROOT / "runtimes" / "pi" / "extensions" / "b-agentic-permissions.ts"
    text = path.read_text()
    label = rel(path)
    trusted_firecrawl = parse_set_literal(text, "FIRECRAWL_TRUSTED_TOOLS")
    trusted_playwright = parse_set_literal(text, "PLAYWRIGHT_TRUSTED_TOOLS")
    firecrawl = servers["firecrawl"]
    playwright = servers["playwright"]

    if not trusted_firecrawl:
        errors.append(f"{label}: FIRECRAWL_TRUSTED_TOOLS missing or unparsable")
    if not trusted_playwright:
        errors.append(f"{label}: PLAYWRIGHT_TRUSTED_TOOLS missing or unparsable")

    reject_unknown(label, "FIRECRAWL_TRUSTED_TOOLS", trusted_firecrawl, set(firecrawl), errors)
    reject_unknown(label, "PLAYWRIGHT_TRUSTED_TOOLS", trusted_playwright, set(playwright), errors)

    for tool, classification in firecrawl.items():
        if classification == READ_ONLY:
            if tool not in trusted_firecrawl:
                errors.append(f"{label}: read-only Firecrawl tool {tool!r} must be trusted")
        elif classification in GATED_CLASSES and tool in trusted_firecrawl:
            errors.append(f"{label}: gated Firecrawl tool {tool!r} must not be trusted")

    for tool, classification in playwright.items():
        if classification == READ_ONLY:
            if tool not in trusted_playwright:
                errors.append(f"{label}: read-only Playwright tool {tool!r} must be trusted")
        elif classification in GATED_CLASSES and tool in trusted_playwright:
            errors.append(f"{label}: gated Playwright tool {tool!r} must not be trusted")


def main() -> int:
    errors: list[str] = []
    if not POLICY_PATH.exists():
        print(f"{rel(POLICY_PATH)}: missing canonical MCP operations policy", file=sys.stderr)
        return 1

    policy = load_policy()
    servers = validate_policy_shape(policy, errors)
    if "firecrawl" in servers and "playwright" in servers:
        validate_contract_generated(policy, servers, errors)
        validate_pi(servers, errors)

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1

    firecrawl_count = len(servers.get("firecrawl", {}))
    playwright_count = len(servers.get("playwright", {}))
    print(
        "MCP operation policy regression passed "
        f"({firecrawl_count} Firecrawl tools, {playwright_count} Playwright tools; "
        f"enforced per-tool: {', '.join(ENFORCED_PER_TOOL_RUNTIMES)}; "
        "closed-world adapter checks enabled)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
