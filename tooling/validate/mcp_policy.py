#!/usr/bin/env python3
"""Regression checks for native OpenCode v2 MCP policy rendering."""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
POLICY_PATH = ROOT / "references" / "mcp_operations.yaml"
EXPECTED_SERVERS = {"codegraph", "context7", "brave_search", "firecrawl", "playwright", "mobbin", "shadcn"}
EXPECTED_CLASSES = {
    "read-only",
    "conditional-read",
    "conditional-local",
    "local-upload",
    "external-mutation",
    "monitor-lifecycle",
    "local-mutation",
    "auth",
}


def matching_indices(rules: list[dict], action: str, resource: str = "*") -> list[int]:
    return [
        index for index, rule in enumerate(rules) if rule.get("action") == action and rule.get("resource") == resource
    ]


def effect(rules: list[dict], action: str, resource: str = "*") -> str | None:
    matches = matching_indices(rules, action, resource)
    return rules[matches[-1]].get("effect") if matches else None


def main() -> int:
    from tooling.generate.registry_sync import load_policy, render_opencode_template

    errors: list[str] = []
    try:
        policy = load_policy()
    except ValueError as exc:
        print(exc, file=sys.stderr)
        return 1
    classes = policy.get("classes")
    if not isinstance(classes, dict) or set(classes) != EXPECTED_CLASSES:
        errors.append(f"references/mcp_operations.yaml: expected classes {sorted(EXPECTED_CLASSES)}")
    servers = policy.get("servers")
    if not isinstance(servers, dict) or set(servers) != EXPECTED_SERVERS:
        errors.append(f"references/mcp_operations.yaml: expected servers {sorted(EXPECTED_SERVERS)}")
    else:
        for server, record in servers.items():
            tools = record.get("tools") if isinstance(record, dict) else None
            if not isinstance(tools, dict) or not tools:
                errors.append(f"references/mcp_operations.yaml: {server} has no tools")
                continue
            for tool, classification in tools.items():
                if classification not in EXPECTED_CLASSES:
                    errors.append(
                        f"references/mcp_operations.yaml: {server}:{tool} has unknown class {classification!r}"
                    )
    expected = render_opencode_template(policy)
    template = ROOT / "opencode" / "configs" / "opencode.user.template.json"
    if not template.exists() or template.read_text() != expected:
        errors.append("opencode/configs/opencode.user.template.json: rendered policy is out of date")
    else:
        rendered = json.loads(template.read_text())
        rules = rendered.get("permissions", [])
        if not isinstance(rules, list):
            errors.append("generated native permissions must be an ordered list")
        else:
            if effect(rules, "firecrawl_crawl") != "ask" or effect(rules, "playwright_browser_click") != "ask":
                errors.append("generated native permissions must ask for mutating MCP tools")
            if effect(rules, "context7_resolve_library_id") != "allow":
                errors.append("generated native permissions must allow read-only MCP tools")
            secret_paths = (
                "*.env",
                "**/.env",
                "*.env.*",
                "**/*.env.*",
                ".env.*",
                "**/.env.*",
                "*.pem",
                "**/*.pem",
                "*credentials.*",
                "**/*credentials.*",
                "*secrets.*",
                "**/*secrets.*",
            )
            if any(effect(rules, "read", path) != "deny" for path in secret_paths):
                errors.append("generated native read permissions must deny root and nested secret paths")
            if any(effect(rules, "edit", path) != "deny" for path in secret_paths):
                errors.append("generated native edit permissions must deny root and nested secret paths")
            for action in ("read", "edit"):
                example_paths = ("*.env.example", "**/*.env.example", ".env.example", "**/.env.example")
                if any(effect(rules, action, path) != "allow" for path in example_paths):
                    errors.append(f"generated native {action} permissions must keep env examples allowed")
            if effect(rules, "shell", "curl * | bash*") != "ask":
                errors.append("generated native shell permissions must ask before curl pipes into bash")
            for server in EXPECTED_SERVERS:
                wildcard = matching_indices(rules, f"{server}_*")
                allowed = matching_indices(rules, "context7_resolve_library_id") if server == "context7" else []
                if effect(rules, f"{server}_*") != "ask":
                    errors.append(f"generated native permissions must ask for unknown {server} tools")
                if server == "context7" and (not wildcard or not allowed or wildcard[-1] >= allowed[-1]):
                    errors.append("generated native permissions must order MCP wildcard asks before specific allows")
        mcp_servers = rendered.get("mcp", {}).get("servers", {})
        if set(mcp_servers) != EXPECTED_SERVERS:
            errors.append("generated native MCP server set must match policy")
        elif any(entry.get("codemode") is not False for entry in mcp_servers.values()):
            errors.append("managed MCP servers must disable Code Mode for direct tool permissions")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Native OpenCode v2 MCP operation policy regression passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
