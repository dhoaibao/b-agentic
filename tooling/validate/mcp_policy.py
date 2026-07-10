#!/usr/bin/env python3

"""Table-driven MCP operation policy regression.

Canonical source: references/contract/mcp_operations.yaml.
The contract table in safety-tools.md is generated from that file.
Adapters that support per-tool permissions must:
- auto-allow only classified read-only tools for Firecrawl/Playwright;
- never auto-allow gated classes;
- never include an unclassified Firecrawl/Playwright tool in allow/trust sets.
Runtimes without per-MCP-tool enforcement are reported as capability gaps.
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
PER_TOOL_RUNTIMES = ("claude-code", "pi")
SHELL_ONLY_RUNTIMES = ("codex", "opencode")
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


def claude_entries(settings: dict) -> dict[str, set[str]]:
    permissions = settings.get("permissions", {})
    result: dict[str, set[str]] = {"allow": set(), "ask": set(), "deny": set()}
    for level in result:
        for raw in permissions.get(level, []):
            if not isinstance(raw, str):
                continue
            if raw.startswith("mcp__firecrawl__"):
                result[level].add(raw.removeprefix("mcp__firecrawl__"))
            elif raw.startswith("mcp__playwright__"):
                result[level].add(raw.removeprefix("mcp__playwright__"))
            elif raw in {"mcp__firecrawl__*", "mcp__playwright__*"}:
                result[level].add(raw)
    return result


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
        "capability gap",
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


def validate_claude(servers: dict[str, dict[str, str]], errors: list[str]) -> None:
    path = ROOT / "runtimes" / "claude-code" / "configs" / "settings.template.json"
    settings = load_json(path)
    entries = claude_entries(settings)
    label = rel(path)
    firecrawl = servers["firecrawl"]
    playwright = servers["playwright"]
    known = set(firecrawl) | set(playwright)

    if "mcp__firecrawl__*" in settings.get("permissions", {}).get("allow", []):
        errors.append(f"{label}: Firecrawl server wildcard must not be allowlisted")
    if "mcp__playwright__*" in settings.get("permissions", {}).get("allow", []):
        errors.append(f"{label}: Playwright server wildcard must not be allowlisted")

    reject_unknown(label, "allow list", entries["allow"], known, errors)
    reject_unknown(label, "ask list", entries["ask"], known, errors)

    for tool, classification in firecrawl.items():
        if classification == READ_ONLY:
            if tool not in entries["allow"]:
                errors.append(f"{label}: read-only Firecrawl tool {tool!r} must be allowlisted")
            if tool in entries["ask"]:
                errors.append(f"{label}: read-only Firecrawl tool {tool!r} must not be ask-gated")
        elif classification in GATED_CLASSES:
            if tool in entries["allow"]:
                errors.append(f"{label}: gated Firecrawl tool {tool!r} must not be allowlisted")
            if tool not in entries["ask"]:
                errors.append(f"{label}: gated Firecrawl tool {tool!r} must be ask-listed")

    for tool, classification in playwright.items():
        if classification == READ_ONLY:
            if tool not in entries["allow"]:
                errors.append(f"{label}: read-only Playwright tool {tool!r} must be allowlisted")
        elif classification in GATED_CLASSES:
            if tool in entries["allow"]:
                errors.append(f"{label}: gated Playwright tool {tool!r} must not be allowlisted")
            if tool not in entries["ask"]:
                errors.append(f"{label}: gated Playwright tool {tool!r} must be ask-listed")


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


def validate_shell_only_gaps(errors: list[str]) -> None:
    for runtime in SHELL_ONLY_RUNTIMES:
        readme = ROOT / "runtimes" / runtime / "configs" / "README.md"
        text = readme.read_text() if readme.exists() else ""
        if "per-MCP-tool" not in text and "per-MCP tool" not in text:
            errors.append(
                f"{rel(readme)}: must document missing per-MCP-tool permission enforcement"
            )


def main() -> int:
    errors: list[str] = []
    if not POLICY_PATH.exists():
        print(f"{rel(POLICY_PATH)}: missing canonical MCP operations policy", file=sys.stderr)
        return 1

    policy = load_policy()
    servers = validate_policy_shape(policy, errors)
    if "firecrawl" in servers and "playwright" in servers:
        validate_contract_generated(policy, servers, errors)
        validate_claude(servers, errors)
        validate_pi(servers, errors)
    validate_shell_only_gaps(errors)

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1

    firecrawl_count = len(servers.get("firecrawl", {}))
    playwright_count = len(servers.get("playwright", {}))
    print(
        "MCP operation policy regression passed "
        f"({firecrawl_count} Firecrawl tools, {playwright_count} Playwright tools; "
        f"per-tool: {', '.join(PER_TOOL_RUNTIMES)}; shell-only gap: {', '.join(SHELL_ONLY_RUNTIMES)}; "
        "closed-world adapter checks enabled)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
