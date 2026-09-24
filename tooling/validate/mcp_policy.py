#!/usr/bin/env python3
"""Regression checks for Pi permission-system and MCP adapter policy rendering."""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
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


def main() -> int:
    from tooling.generate.registry_sync import load_policy, render_permissions

    errors: list[str] = []
    policy = load_policy()
    if set(policy.get("classes", {})) != EXPECTED_CLASSES:
        errors.append("MCP policy classes differ from the supported set")
    servers = policy.get("servers", {})
    if set(servers) != EXPECTED_SERVERS:
        errors.append("MCP policy server set differs from the supported set")
    template = ROOT / "pi" / "configs" / "permission.user.template.json"
    rendered = render_permissions(policy)
    if not template.exists() or template.read_text() != json.dumps(rendered, indent=2) + "\n":
        errors.append("Pi permission policy is missing or out of date")
    permission = rendered["permission"]
    for server, record in servers.items():
        if permission.get(f"{server}_*") != "ask":
            errors.append(f"unknown direct tools on {server} must ask")
        for tool, classification in record.get("tools", {}).items():
            expected = policy["classes"][classification]["native_permission"]
            if permission.get(f"{server}_{tool.replace('.', '_')}") != expected:
                errors.append(f"{server}:{tool} differs from canonical policy")
    for name in ("firecrawl_firecrawl_crawl", "playwright_browser_click"):
        if permission.get(name) != "ask":
            errors.append(f"{name} must ask before mutation")
    if permission.get("context7_resolve-library-id") != "allow":
        errors.append("read-only context7 lookup must be allowed")
    if permission.get("mcp", {}).get("*") != "ask":
        errors.append("MCP proxy must ask for unknown operations")
    if set(permission.get("mcp", {})) != {"*", "mcp_status", "mcp_search", "mcp_describe"}:
        errors.append("MCP proxy must not gain tool allows that can cross server boundaries")
    if permission.get("skill") != "allow":
        errors.append("skill invocation must not prompt; tool and path gates remain active")
    if permission.get("path", {}).get("*.env") != "deny":
        errors.append("protected paths must be denied")
    if permission.get("bash", {}).get("curl * | bash*") != "ask":
        errors.append("curl pipes must ask")
    if rendered.get("permissionReviewLog") is not False or rendered.get("yoloMode") is not False:
        errors.append("permission review logging and yolo mode must be disabled")
    mcp = json.loads((ROOT / "pi" / "configs" / "mcp.base.json").read_text())
    if set(mcp.get("mcpServers", {})) != EXPECTED_SERVERS:
        errors.append("Pi MCP adapter must configure all seven servers")
    settings = mcp.get("settings", {})
    if settings.get("directTools") is not True or settings.get("scriptMode") is not False:
        errors.append("direct tools must be enabled and MCP script mode disabled")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Pi MCP operation policy regression passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
