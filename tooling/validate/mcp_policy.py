#!/usr/bin/env python3

"""Table-driven MCP operation policy regression.

Canonical source: references/contract/mcp_operations.yaml.
The contract table in safety-tools.md is generated from that file.

Two coverage classes are checked:
- Enforced per-tool runtimes (Claude Code, Pi): adapter policy is treated as the
  runtime-enforced operation boundary.
- Template-policy runtimes (Codex, OpenCode): managed templates encode the same
  closed-world tool classes, but public support tiers remain guidance/shell-only
  until live runtime enforcement is proven.

In both cases adapters must:
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
ENFORCED_PER_TOOL_RUNTIMES = ("claude-code", "pi")
# Template encoding only (support_tier=guidance-shell-only until live proof).
TEMPLATE_POLICY_RUNTIMES = ("codex", "opencode")
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


def validate_codex(servers: dict[str, dict[str, str]], errors: list[str]) -> None:
    try:
        import tomllib
    except ModuleNotFoundError:
        errors.append("Codex MCP policy validation requires Python 3.11+ tomllib")
        return

    path = ROOT / "runtimes" / "codex" / "configs" / "mcp.user.template.toml"
    label = rel(path)
    data = tomllib.loads(path.read_text())
    mcp_servers = data.get("mcp_servers", {})
    if not isinstance(mcp_servers, dict):
        errors.append(f"{label}: missing mcp_servers table")
        return

    for server_name, classified in servers.items():
        server = mcp_servers.get(server_name)
        if not isinstance(server, dict):
            errors.append(f"{label}: missing MCP server {server_name!r}")
            continue
        enabled = server.get("enabled_tools")
        if not isinstance(enabled, list) or not all(isinstance(item, str) for item in enabled):
            errors.append(f"{label}: {server_name}.enabled_tools must list classified tools")
            continue
        enabled_set = set(enabled)
        known = set(classified)
        if enabled_set != known:
            missing = sorted(known - enabled_set)
            extra = sorted(enabled_set - known)
            if missing:
                errors.append(f"{label}: {server_name}.enabled_tools missing {missing}")
            if extra:
                errors.append(
                    f"{label}: {server_name}.enabled_tools includes unclassified tools {extra}"
                )
        if server.get("default_tools_approval_mode") != "prompt":
            errors.append(
                f"{label}: {server_name}.default_tools_approval_mode must be 'prompt' "
                "so gated tools require approval"
            )
        tool_policy = server.get("tools")
        if not isinstance(tool_policy, dict):
            errors.append(f"{label}: {server_name}.tools must define read-only auto-approve entries")
            continue
        for tool, classification in classified.items():
            entry = tool_policy.get(tool)
            if classification == READ_ONLY:
                if not isinstance(entry, dict) or entry.get("approval_mode") != "approve":
                    errors.append(
                        f"{label}: read-only {server_name}.{tool} must set approval_mode=approve"
                    )
            elif classification in GATED_CLASSES and isinstance(entry, dict):
                if entry.get("approval_mode") in {"approve", "auto"}:
                    errors.append(
                        f"{label}: gated {server_name}.{tool} must not auto-approve"
                    )


def validate_opencode(servers: dict[str, dict[str, str]], errors: list[str]) -> None:
    path = ROOT / "runtimes" / "opencode" / "configs" / "mcp.user.template.json"
    label = rel(path)
    data = load_json(path)
    permission = data.get("permission")
    if not isinstance(permission, dict):
        errors.append(f"{label}: missing permission object")
        return

    # OpenCode tool keys are sanitize(server) + "_" + sanitize(tool).
    for server_name, classified in servers.items():
        for tool, classification in classified.items():
            key = f"{server_name}_{tool}"
            action = permission.get(key)
            if classification == READ_ONLY:
                if action != "allow":
                    errors.append(f"{label}: read-only MCP tool {key!r} must be allow")
            elif classification in GATED_CLASSES:
                if action != "ask":
                    errors.append(f"{label}: gated MCP tool {key!r} must be ask")
                if action == "allow":
                    errors.append(f"{label}: gated MCP tool {key!r} must not be allow")

    # Fully trusted managed servers may use server wildcards.
    for server in ("serena", "codegraph", "context7", "brave-search"):
        if permission.get(f"{server}_*") != "allow":
            errors.append(f"{label}: fully trusted server wildcard {server}_* must be allow")

    # Closed-world for firecrawl/playwright permission keys: only classified tools.
    observed = {
        key
        for key, value in permission.items()
        if isinstance(key, str)
        and (key.startswith("firecrawl_") or key.startswith("playwright_"))
        and not key.endswith("_*")
    }
    known = {
        f"{server}_{tool}"
        for server, tools in servers.items()
        for tool in tools
    }
    reject_unknown(label, "permission MCP tool keys", observed, known, errors)


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
        validate_codex(servers, errors)
        validate_opencode(servers, errors)

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
        f"template policy: {', '.join(TEMPLATE_POLICY_RUNTIMES)}; "
        "closed-world adapter checks enabled)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
