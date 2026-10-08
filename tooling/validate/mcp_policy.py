#!/usr/bin/env python3
"""Regression checks for the rendered Claude Code settings and MCP policy."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
EXPECTED_SERVERS = {
    "codegraph",
    "context7",
    "brave_search",
    "firecrawl",
    "playwright",
    "mobbin",
    "notion",
    "excalidraw",
    "drawio",
    "shadcn",
    "clickup",
    "datagrip",
}
OPTIONAL_SERVERS = {"clickup"}
IDE_MANAGED_SERVERS = {"datagrip"}
EXPECTED_CLASSES = {
    "read-only",
    "conditional-read",
    "trusted-mutation",
    "local-upload",
    "private-read",
    "external-mutation",
    "monitor-lifecycle",
    "local-mutation",
    "auth",
}
AGENTS = ("b-planner", "b-researcher", "b-debugger", "b-auditor")
ENV_REFERENCE = re.compile(r"^\$\{[A-Z][A-Z0-9_]*\}$")


PUSH_DECISIONS = {
    "git push -u origin feat/docs-index": "ask",
    "git push -u origin refs/heads/feat/x:refs/heads/feat/x": "ask",
    "git push origin refs/heads/feat/mainline:refs/heads/feat/mainline": "ask",
    "gh pr create -R owner/repo --draft --base main --head feat/x --title t --body-file -": "ask",
    "git push origin feature-f": "ask",
    "git push origin feature-d": "ask",
    "git push origin refs/heads/main-fix": "ask",
    "git push origin feat/mainline": "ask",
    "git push -u origin master-plan": "ask",
    "git push origin feat/c++": "ask",
    "git -C . push origin feat/x": "ask",
    "git --no-pager push origin feat/x": "ask",
    "git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push -u origin refs/heads/feat/x:refs/heads/feat/x": "ask",
    "git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push origin refs/heads/feat/mainline:refs/heads/feat/mainline": "ask",
    "git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push origin refs/heads/feat/main:refs/heads/feat/main": "ask",
    "gh pr create --draft --base main --head feat/x": "ask",
    "gh auth switch --hostname github.com --user octocat": "ask",
    "gh --repo owner/repo auth switch --user octocat": "ask",
    "gh auth status --hostname github.com": "allow",
    "gh auth status": "allow",
    "gh api repos/o/r": "allow",
    "gh api repos/o/r/issues --jq .[].title": "allow",
    "gh pr view 12": "allow",
    "gh pr list -R o/r --head feat/x --state open --json url,baseRefName --limit 1": "allow",
    "gh repo view o/r --json viewerPermission -q .viewerPermission": "allow",
    "gh issue list": "allow",
    "gh search repos x": "allow",
    "gh api repos/o/r/issues -f title=x": "ask",
    "gh api -X POST repos/o/r/issues -f title=PATCH": "ask",
    "gh api --method GET repos/o/r/contents/DELETE.md": "ask",
    "gh api repos/o/r/contents/DELETE.md": "allow",
    "gh api repos/o/r/contents/PUT.md": "allow",
    "gh api repos/o/r -f note=PUT": "ask",
    "gh api graphql -f query=q": "ask",
    "gh api -X POST repos/o/r/issues": "ask",
    "gh api repos/o/r/issues --input body.json": "ask",
    "gh release create v1": "ask",
    "gh -R o/r release upload v1 a.zip": "ask",
    "gh variable set X --body 1": "ask",
    "gh repo fork o/r": "ask",
    "gh gist create a.txt": "ask",
    "gh issue close 1": "ask",
    "gh pr close 1": "ask",
    "gh pr edit 1 --base dev": "ask",
    "gh workflow run ci.yml": "ask",
    "gh run delete 1": "ask",
    "gh cache delete 1": "ask",
    "gh label delete bug": "ask",
    "gh codespace delete -c x": "ask",
    "gh -R owner/repo pr create --draft": "ask",
    "git push": "deny",
    "git push origin": "deny",
    "git push --force origin feat/x": "deny",
    "git push origin feat/x --force-with-lease": "deny",
    "git push -f origin feat/x": "deny",
    "git push origin feat/x -f": "deny",
    "git push origin --delete feat/x": "deny",
    "git push -d origin feat/x": "deny",
    "git push origin +feat/x": "deny",
    "git push --mirror origin": "deny",
    "git push origin --all": "deny",
    "git push --all origin": "deny",
    "git push origin --branches": "deny",
    "git push --branches origin": "deny",
    "git push origin --prune": "deny",
    "git push origin main": "deny",
    "git push -u origin master": "deny",
    "git push origin main feat/x": "deny",
    "git push origin HEAD:master feat/x": "deny",
    "git push origin HEAD:refs/heads/main": "deny",
    "git push origin feat/x:main": "deny",
    "git -c credential.helper= push --force origin refs/heads/feat/x:refs/heads/feat/x": "deny",
    "git -c credential.helper= push origin refs/heads/feat/x:refs/heads/feat/x -f": "deny",
    "git -c credential.helper= push origin refs/heads/main:refs/heads/main": "deny",
    "git -c credential.helper= push origin +refs/heads/feat/x:refs/heads/feat/x": "deny",
    "git -c credential.helper= push -u origin +feat/x": "deny",
    "git -c credential.helper= push +feat/x": "deny",
    "git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push origin +refs/heads/feat/x:refs/heads/feat/x": "deny",
    "git -c credential.helper= push --force-with-lease origin refs/heads/feat/x:refs/heads/feat/x": "deny",
    "gh api -X=DELETE repos/o/r": "deny",
    "gh api --method delete repos/o/r": "deny",
    "gh api repos/o/r/issues -X PATCH -f state=closed": "deny",
    "git -c credential.helper= push -u origin refs/heads/feat/x:refs/heads/master": "deny",
    "gh pr merge 12": "deny",
    "gh -R a/b pr merge 12": "deny",
    "gh repo delete a/b --yes": "deny",
    "gh auth login": "deny",
    "gh auth login --hostname github.com": "deny",
    "gh auth logout --user octocat": "deny",
    "gh auth token": "deny",
    "gh auth token --hostname github.com": "deny",
    "gh auth refresh --scopes repo": "deny",
    "gh --hostname github.com auth token": "deny",
    "gh auth status --show-token": "deny",
    "gh auth status --hostname github.com --show-token": "deny",
    "gh auth status -t": "deny",
    "gh api -X DELETE repos/o/r": "deny",
    "gh api repos/o/r --method DELETE": "deny",
    "gh api repos/o/r --method=DELETE": "deny",
    "gh api repos/o/r -XPUT": "deny",
    "gh api repos/o/r -X patch -f name=x": "deny",
    "gh -R o/r api -X PATCH repos/o/r": "deny",
    "gh repo archive o/r --yes": "deny",
    "gh repo rename new-name": "deny",
    "gh repo edit o/r --visibility public": "deny",
    "gh repo deploy-key add k.pub": "deny",
    "gh release delete v1": "deny",
    "gh -R o/r release delete-asset v1 a.zip": "deny",
    "gh extension install o/x": "deny",
    "gh alias set --shell x 'rm -rf .'": "deny",
    "gh secret set X": "deny",
    "gh secret delete X": "deny",
    "gh ssh-key add k.pub": "deny",
    "gh gpg-key delete 1": "deny",
}


def bash_patterns(rules: set[str]) -> list[str]:
    return [rule[5:-1] for rule in rules if rule.startswith("Bash(") and rule.endswith(")")]


def glob_matches(pattern: str, command: str) -> bool:
    """Approximate Claude Code's Bash glob: `*` spans any characters; a trailing ` *` also matches the bare command."""
    regex = "^" + ".*".join(re.escape(part) for part in pattern.split("*")) + "$"
    return bool(re.match(regex, command)) or (pattern.endswith(" *") and command == pattern[:-2])


def push_decision_errors(allow: set[str], ask: set[str], deny: set[str]) -> list[str]:
    """Check concrete push and PR commands against the rendered rules in deny, ask, allow order."""
    errors: list[str] = []
    deny_patterns, ask_patterns = bash_patterns(deny), bash_patterns(ask)
    for command, expected in PUSH_DECISIONS.items():
        for prefix in ("", "rtk "):
            full = prefix + command
            if any(glob_matches(pattern, full) for pattern in deny_patterns):
                actual = "deny"
            elif any(glob_matches(pattern, full) for pattern in ask_patterns):
                actual = "ask"
            else:
                actual = "allow" if "Bash" in allow else "unmatched"
            if actual != expected:
                errors.append(f"push policy: {full!r} resolves to {actual}, expected {expected}")
    return errors


def agent_tools(agent: str) -> list[str]:
    profile = (ROOT / "claude" / "agents" / f"{agent}.md").read_text()
    line = next(item for item in profile.splitlines() if item.startswith("tools: "))
    return [tool.strip() for tool in line.removeprefix("tools: ").split(",") if tool.strip()]


def main() -> int:
    from tooling.generate.registry_sync import (
        SETTINGS_TEMPLATE_PATH,
        load_policy,
        mcp_tool_name,
        render_settings,
    )

    errors: list[str] = []
    policy = load_policy()
    if set(policy.get("classes", {})) != EXPECTED_CLASSES:
        errors.append("MCP policy classes differ from the supported set")
    servers = policy.get("servers", {})
    if set(servers) != EXPECTED_SERVERS:
        errors.append("MCP policy server set differs from the supported set")
    rendered = render_settings(policy)
    if (
        not SETTINGS_TEMPLATE_PATH.exists()
        or SETTINGS_TEMPLATE_PATH.read_text() != json.dumps(rendered, indent=2) + "\n"
    ):
        errors.append("Claude Code settings template is missing or out of date")
    permissions = rendered["permissions"]
    allow, ask, deny = set(permissions["allow"]), set(permissions["ask"]), set(permissions["deny"])
    for server, record in servers.items():
        for tool, classification in record.get("tools", {}).items():
            name = mcp_tool_name(server, tool)
            expected = policy["classes"][classification]["native_permission"]
            actual = "allow" if name in allow else "ask" if name in ask else "deny" if name in deny else None
            if actual != expected:
                errors.append(f"{server}:{tool} differs from canonical policy")
    for name in (
        "mcp__codegraph__codegraph_explore",
        "mcp__firecrawl__firecrawl_search",
        "mcp__context7__resolve-library-id",
        "mcp__notion__notion-search",
        "mcp__drawio__search_shapes",
    ):
        if name not in allow:
            errors.append(f"read tool must be allowed: {name}")
    if any("codegraph_codegraph" in name or "firecrawl_firecrawl_firecrawl" in name for name in allow | ask):
        errors.append("doubled tool names must not appear in permission rules")
    for name in (
        "mcp__firecrawl__firecrawl_crawl",
        "mcp__playwright__browser_click",
        "mcp__playwright__browser_navigate",
        "mcp__notion__notion-create-pages",
        "mcp__notion__notion-update-page",
        "mcp__notion__notion-create-file-upload",
        "mcp__notion__notion-spawn-session",
        "mcp__drawio__open_drawio_xml",
        "mcp__drawio__open_drawio_csv",
        "mcp__drawio__open_drawio_mermaid",
        "mcp__excalidraw__create_view",
    ):
        if name not in ask:
            errors.append(f"{name} must ask before mutation")
    for name in ("mcp__clickup__createTask", "mcp__clickup__updateTask"):
        if name not in allow:
            errors.append(f"{name} is a trusted mutation and must be allowed")
    for name in (
        "mcp__datagrip__preview_table_data",
        "mcp__datagrip__fetch_query_result",
        "mcp__datagrip__list_recent_sql_queries",
        "mcp__datagrip__execute_sql_query",
        "mcp__datagrip__cancel_sql_query",
        "mcp__datagrip__create_database_connection",
        "mcp__datagrip__edit_database_connection",
    ):
        if name not in ask:
            errors.append(f"{name} returns database rows or changes database state and must ask")
    if "mcp__datagrip__execute_tool" in allow or "mcp__datagrip__execute_tool" in ask:
        errors.append("mcp__datagrip__execute_tool is unclassified and must keep the runtime approval prompt")
    for pattern in (
        "Bash(git push *)",
        "Bash(rtk git push *)",
        "Bash(gh pr create)",
        "Bash(gh pr create *)",
        "Bash(rtk gh pr create *)",
        "Bash(gh auth switch *)",
        "Bash(rtk gh auth switch *)",
    ):
        if pattern not in ask:
            errors.append(f"push, PR creation, and account switching must ask before running: {pattern}")
        if pattern in deny:
            errors.append(f"push and PR creation must not be blanket-denied: {pattern}")
    errors.extend(push_decision_errors(allow, ask, deny))
    for name in ("mcp__drawio__get_page", "mcp__drawio__list_pages"):
        if name in allow:
            errors.append(f"{name} is unclassified and must keep the runtime approval prompt")
    for tool in ("Read", "Glob", "Grep", "Edit", "Write", "Bash"):
        if tool not in allow:
            errors.append(f"repository-local tool must not prompt: {tool}")
    for pattern in (
        "Bash(git push)",
        "Bash(rtk git push)",
        "Bash(gh pr merge *)",
        "Bash(gh repo delete *)",
        "Bash(gh auth login *)",
        "Bash(gh auth logout *)",
        "Bash(gh auth token *)",
        "Bash(gh auth refresh *)",
        "Bash(git pull *)",
        "Bash(git reset --hard *)",
        "Bash(git clean -f *)",
        "Bash(git branch -D *)",
        "Bash(rm -rf *)",
        "Bash(sudo *)",
        "Bash(doas *)",
        "Bash(docker system prune *)",
        "Bash(bash)",
        "Bash(sh)",
        "Bash(bash -s *)",
        "Bash(sh -s *)",
    ):
        if pattern not in deny:
            errors.append(f"dangerous command must be denied: {pattern}")
    for tool in ("Read", "Edit"):
        for glob in ("**/.env", "**/.env.local", "**/*.pem", "**/*credentials.*", "**/*secrets.*"):
            if f"{tool}({glob})" not in deny:
                errors.append(f"protected path must be denied: {tool}({glob})")
    if "Read(**/.env.example)" in deny or any(".env.example" in rule for rule in deny):
        errors.append(".env.example must stay readable; the path guard hook owns exact path rules")
    if any(rule.startswith("Bash(") and rule.endswith(":*)") for rule in allow | ask | deny):
        errors.append("Bash rules must use the space-star form, not the legacy :* prefix form")
    if any("(" in rule and rule.startswith("mcp__") for rule in allow | ask | deny):
        errors.append("MCP rules must not carry argument patterns")
    hooks = rendered["hooks"]
    commands = [hook["command"] for entries in hooks.values() for entry in entries for hook in entry["hooks"]]
    if len(commands) != len(set(commands)) and not (
        hooks["PostToolUse"][0]["hooks"][0]["command"] == hooks["Stop"][0]["hooks"][0]["command"]
    ):
        errors.append("hook commands must be unique per script, except the verify gate shared by PostToolUse and Stop")
    if hooks["PreToolUse"][0]["matcher"] != "Read|Edit|Write|NotebookEdit|Grep|Glob":
        errors.append("path guard must cover every file tool")
    if hooks["PreToolUse"][1]["matcher"] != "Bash":
        errors.append("Codex guard must watch Bash")
    for entries in hooks.values():
        for entry in entries:
            for hook in entry["hooks"]:
                if hook.get("type") != "command" or not hook["command"].startswith(
                    'node "$HOME/.claude/b-agentic/hooks/'
                ):
                    errors.append(f"hook must run a managed script with node: {hook}")

    research_tools = {
        "mcp__firecrawl__firecrawl_search",
        "mcp__firecrawl__firecrawl_scrape",
        "mcp__firecrawl__firecrawl_map",
    }
    for agent in AGENTS:
        tools = agent_tools(agent)
        if "mcp__codegraph__codegraph_explore" not in tools:
            errors.append(f"{agent} must expose the CodeGraph explore tool")
        if any(tool.startswith("mcp__notion__") for tool in tools):
            errors.append(f"{agent} must not receive private Notion workspace tools")
        if any(tool.startswith("mcp__datagrip__") for tool in tools):
            errors.append(f"{agent} must not receive private DataGrip database tools")
        if any(tool in ask or tool in deny for tool in tools if tool.startswith("mcp__")):
            errors.append(f"{agent} must not list a tool that asks or is denied")
        if agent == "b-researcher":
            if not research_tools.issubset(tools):
                errors.append("b-researcher must expose the Firecrawl search and bounded extraction tools")
        elif research_tools.intersection(tools):
            errors.append(f"{agent} must not inherit researcher-only Firecrawl tools")

    mcp = json.loads((ROOT / "claude" / "configs" / "mcp.base.json").read_text())
    optional_mcp = json.loads((ROOT / "claude" / "configs" / "mcp.clickup.json").read_text())
    if set(mcp.get("mcpServers", {})) != EXPECTED_SERVERS - OPTIONAL_SERVERS - IDE_MANAGED_SERVERS:
        errors.append("Claude Code base MCP config must configure all required servers only")
    if set(optional_mcp.get("mcpServers", {})) != OPTIONAL_SERVERS:
        errors.append("Claude Code optional MCP config must configure each optional server exactly once")
    for server, entry in {**mcp.get("mcpServers", {}), **optional_mcp.get("mcpServers", {})}.items():
        kind = entry.get("type")
        if kind == "http":
            if not str(entry.get("url", "")).startswith("https://"):
                errors.append(f"{server} must use an https URL")
        elif kind == "stdio":
            if not isinstance(entry.get("command"), str) or not isinstance(entry.get("args"), list):
                errors.append(f"{server} stdio entry needs a command and args")
        else:
            errors.append(f"{server} must declare type http or stdio")
        for field in ("env", "headers"):
            for key, value in entry.get(field, {}).items():
                if key.endswith(("_KEY", "_TOKEN", "_ID")) and not ENV_REFERENCE.fullmatch(str(value)):
                    errors.append(f"{server}.{field}.{key} must reference an environment variable, not store a value")
        retired = {"directTools", "lifecycle", "description"} & set(entry)
        if retired:
            errors.append(f"{server} carries retired adapter fields: {sorted(retired)}")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Claude Code MCP operation policy regression passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
