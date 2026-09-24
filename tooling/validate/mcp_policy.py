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
    from tooling.generate.registry_sync import load_policy, native_tool_name, render_permissions

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
            if permission.get(native_tool_name(server, tool)) != expected:
                errors.append(f"{server}:{tool} differs from canonical policy")
    if native_tool_name("codegraph", "codegraph_explore") != "codegraph_explore":
        errors.append("adapter-prefixed CodeGraph tool must not be double-prefixed")
    if permission.get("codegraph_explore") != "allow":
        errors.append("CodeGraph explore must be allowed under its actual Pi tool name")
    if permission.get("firecrawl_search") != "allow":
        errors.append("adapter-prefixed Firecrawl search must be allowed")
    if "codegraph_codegraph_explore" in permission or "firecrawl_firecrawl_search" in permission:
        errors.append("doubled adapter tool names must not appear in permission policy")
    for agent in ("b-planner", "b-researcher", "b-debugger", "b-reviewer"):
        profile = (ROOT / "pi" / "agents" / f"{agent}.md").read_text()
        if "bash, codegraph_explore," not in profile or "codegraph_codegraph_explore" in profile:
            errors.append(f"{agent} must expose the actual CodeGraph direct tool")
        if "\npermission:\n" in profile:
            errors.append(f"{agent} must inherit global permission policy")
    research_profile = (ROOT / "pi" / "agents" / "b-researcher.md").read_text()
    research_tools = research_profile.split("tools: ", 1)[1].split("\n", 1)[0].split(", ")
    required_research_tools = {"firecrawl_search", "firecrawl_scrape", "firecrawl_map", "firecrawl_extract"}
    if not required_research_tools.issubset(research_tools):
        errors.append("b-researcher must expose the Firecrawl search and bounded extraction tools")
    for name in ("b-planner", "b-debugger", "b-reviewer"):
        profile = (ROOT / "pi" / "agents" / f"{name}.md").read_text()
        profile_tools = profile.split("tools: ", 1)[1].split("\n", 1)[0].split(", ")
        if required_research_tools.intersection(profile_tools):
            errors.append(f"{name} must not inherit researcher-only Firecrawl tools")
    for name in ("firecrawl_crawl", "playwright_browser_click"):
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
    for name in ("ctx_search", "ctx_expand", "ctx_memory", "ctx_note", "ctx_reduce", "todowrite"):
        if permission.get(name) != "allow":
            errors.append(f"Magic Context tool must not prompt: {name}")
    if permission.get("*") != "ask" or "ctx_*" in permission:
        errors.append("unknown extension tools must still ask")
    if permission.get("path", {}).get("*.env") != "deny":
        errors.append("protected paths must be denied")
    if permission.get("external_directory_write") != "deny":
        errors.append("outside-repository writes must be denied")
    if permission.get("external_directory") != "ask":
        errors.append("outside-repository reads must still ask")
    for command in (
        "sudo *",
        "sudo*",
        "doas *",
        "docker system prune*",
        "docker system prun*",
        "rm -rf *",
        "bash",
        "sh",
        "bash -s*",
        "sh -s*",
    ):
        if permission.get("bash", {}).get(command) != "deny":
            errors.append(f"dangerous command must be denied: {command}")
    if rendered.get("permissionReviewLog") is not False or rendered.get("yoloMode") is not False:
        errors.append("permission review logging and yolo mode must be disabled")
    mcp = json.loads((ROOT / "pi" / "configs" / "mcp.base.json").read_text())
    if set(mcp.get("mcpServers", {})) != EXPECTED_SERVERS:
        errors.append("Pi MCP adapter must configure all seven servers")
    settings = mcp.get("settings", {})
    if settings.get("directTools") is not True or settings.get("scriptMode") is not False:
        errors.append("direct tools must be enabled and MCP script mode disabled")
    eager_count = 0
    for server, record in servers.items():
        configured = mcp.get("mcpServers", {}).get(server, {}).get("directTools")
        allowed = {
            tool
            for tool, classification in record.get("tools", {}).items()
            if policy["classes"][classification]["native_permission"] == "allow"
        }
        if not isinstance(configured, list) or any(not isinstance(tool, str) for tool in configured):
            errors.append(f"{server} must list allowed direct tools")
            continue
        if len(configured) != len(set(configured)) or set(configured) != allowed:
            errors.append(f"{server} direct tools differ from allowed MCP operations")
        eager_count += len(configured)
    if eager_count >= 75:
        errors.append("configured direct tools meet the adapter's 75-tool advisory threshold")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Pi MCP operation policy regression passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
