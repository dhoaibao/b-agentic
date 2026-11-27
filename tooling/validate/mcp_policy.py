#!/usr/bin/env python3
"""Regression checks for the rendered Claude Code settings and MCP policy."""

from __future__ import annotations

import functools
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
    "notion",
    "excalidraw",
    "drawio",
    "shadcn",
    "datagrip",
    "tablepro",
}
IDE_MANAGED_SERVERS = {"datagrip"}
TABLEPRO_URL = "http://127.0.0.1:23508/mcp"
TABLEPRO_AUTHORIZATION = "Bearer ${TABLEPRO_MCP_TOKEN}"
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
AGENTS = ("b-planner", "b-researcher", "b-debugger", "b-auditor", "b-reviewer")
WORKER_BASE_TOOLS = ("Read", "Grep", "Glob", "Edit", "Write", "Bash")
WORKER_FORBIDDEN_TOOLS = {"NotebookEdit", "Agent", "Task", "Skill", "AskUserQuestion"}
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

# Destructive spellings the option-placement and combined-flag deny rules must catch, and their
# safe neighbours that must stay allowed. Each runs plain and under `rtk`.
DESTRUCTIVE_DECISIONS = {
    "git clean -f": "deny",
    "git clean -fd": "deny",
    "git clean -xdf": "deny",
    "git clean -d -f": "deny",
    "git clean -n -d --force": "deny",
    "git reset --hard HEAD~1": "deny",
    "git reset -q --hard": "deny",
    "git reset HEAD~1 --hard": "deny",
    "git branch -D old": "deny",
    "git branch --delete --force old": "deny",
    "git branch -d -f old": "deny",
    "git branch -f -d old": "deny",
    "rm -rf build": "deny",
    "rm -fr build": "deny",
    "rm -Rf build": "deny",
    "rm -r -f build": "deny",
    "rm -f -r build": "deny",
    "rm -v -rf build": "deny",
    "rm --recursive --force build": "deny",
    "rm build -r -f": "deny",
    "git clean -n": "allow",
    "git clean -nd": "allow",
    "git clean --dry-run": "allow",
    "git reset --soft HEAD~1": "allow",
    "git reset HEAD file.txt": "allow",
    "git branch -d merged": "allow",
    "git branch -f topic HEAD~1": "allow",
    "rm -r build": "allow",
    "rm -f notes-r.txt": "allow",
    "rm -r notes-f.txt": "allow",
}


def bash_patterns(rules: set[str]) -> list[str]:
    return [rule[5:-1] for rule in rules if rule.startswith("Bash(") and rule.endswith(")")]


@functools.lru_cache(maxsize=None)
def glob_regex(pattern: str) -> re.Pattern[str]:
    # Cached without a bound: `re`'s own cache holds 512 patterns, far fewer than the rules checked per command.
    return re.compile("^" + ".*".join(re.escape(part) for part in pattern.split("*")) + "$")


def glob_matches(pattern: str, command: str) -> bool:
    """Approximate Claude Code's Bash glob: `*` spans any characters; a trailing ` *` also matches the bare command."""
    return bool(glob_regex(pattern).match(command)) or (pattern.endswith(" *") and command == pattern[:-2])


def push_decision_errors(allow: set[str], ask: set[str], deny: set[str]) -> list[str]:
    """Check concrete push, PR, and destructive commands against the rendered rules in deny, ask, allow order."""
    errors: list[str] = []
    deny_patterns, ask_patterns = bash_patterns(deny), bash_patterns(ask)
    for command, expected in {**PUSH_DECISIONS, **DESTRUCTIVE_DECISIONS}.items():
        for prefix in ("", "rtk "):
            full = prefix + command
            if any(glob_matches(pattern, full) for pattern in deny_patterns):
                actual = "deny"
            elif any(glob_matches(pattern, full) for pattern in ask_patterns):
                actual = "ask"
            else:
                actual = "allow" if "Bash" in allow else "unmatched"
            if actual != expected:
                errors.append(f"shell policy: {full!r} resolves to {actual}, expected {expected}")
    return errors


def agent_tools(agent: str) -> list[str]:
    profile = (ROOT / "claude" / "agents" / f"{agent}.md").read_text()
    line = next(item for item in profile.splitlines() if item.startswith("tools: "))
    return [tool.strip() for tool in line.removeprefix("tools: ").split(",") if tool.strip()]


def pi_push_errors(bash: dict[str, str]) -> list[str]:
    """Concrete push, PR and destructive commands resolved like Pi does: the last matching rule wins."""
    errors: list[str] = []
    for command, expected in {**PUSH_DECISIONS, **DESTRUCTIVE_DECISIONS}.items():
        for prefix in ("", "rtk "):
            full = prefix + command
            actual = None
            for pattern, verdict in bash.items():
                if glob_matches(pattern, full):
                    actual = verdict
            if actual != expected:
                errors.append(f"pi shell policy: {full!r} resolves to {actual}, expected {expected}")
    return errors


def pi_permission_errors(permission: dict, policy: dict, agent_tools: dict[str, list[str]]) -> list[str]:
    """The Pi permission config must carry exactly the policy's MCP verdicts and the shell rules."""
    from tooling.generate.registry_sync import PATH_RULES, RUNTIMES, shell_pattern_rules

    errors: list[str] = []
    mcp = permission.get("mcp", {})
    if mcp.get("*") != "ask":
        errors.append("pi permission: the mcp default must be ask")
    expected: dict[str, str] = {}
    for server, record in policy["servers"].items():
        for tool, classification in record["tools"].items():
            name = RUNTIMES["pi"]["mcp_tool_format"].format(server=server, tool=tool.replace("-", "_"))
            # Pi rewrites dots to underscores and shortens ids over 64 characters; the renderer only maps dashes, so a
            # name that Pi would rewrite must fail here until the renderer learns that rule.
            if re.search(r"[^A-Za-z0-9_-]", tool) or len(name) > 64:
                errors.append(
                    f"pi permission: {server}:{tool} has a character or length Pi rewrites; extend the renderer first"
                )
            if name in expected:
                errors.append(f"pi permission: {name} collides with another MCP tool after dash replacement")
            expected[name] = policy["classes"][classification]["native_permission"]
    for name, verdict in expected.items():
        if mcp.get(name) != verdict:
            errors.append(f"pi permission: {name} is {mcp.get(name)!r}, policy says {verdict}")
    for name in sorted(set(mcp) - set(expected) - {"*"}):
        errors.append(f"pi permission: {name} is not an MCP tool of the policy")
    ask, deny = shell_pattern_rules()
    # Pi uses the last matching rule, so order is part of the policy: the catch-all first, then the asks, then the denies.
    denied = set(deny)
    wanted_bash = {
        "*": "allow",
        **{pattern: "ask" for pattern in ask if pattern not in denied},
        **{pattern: "deny" for pattern in deny},
    }
    if list(permission.get("bash", {}).items()) != list(wanted_bash.items()):
        errors.append(
            "pi permission: the bash rules differ from the shell policy in content or order (catch-all first)"
        )
    if next(iter(mcp), None) != "*":
        errors.append("pi permission: the mcp catch-all must come first")
    if list(permission.get("path", {}).items()) != list(PATH_RULES.items()):
        errors.append("pi permission: the path rules differ from the shared protected path rules in content or order")
    errors.extend(pi_push_errors(permission.get("bash", {})))
    for tool in RUNTIMES["pi"]["allowed_tools"]:
        if permission.get(tool) != "allow":
            errors.append(f"pi permission: {tool} must be allowed")
    for agent, tools in agent_tools.items():
        for tool in tools:
            # Pi agent files name an MCP tool mcp:<server>/<tool>; the permission id is mcp__<server>__<tool_with_underscores>.
            if tool.startswith("mcp:"):
                server, _, name = tool.removeprefix("mcp:").partition("/")
                permission_id = RUNTIMES["pi"]["mcp_tool_format"].format(server=server, tool=name.replace("-", "_"))
                if mcp.get(permission_id) != "allow":
                    errors.append(f"pi agent {agent}: {tool} must be an allowed read tool ({permission_id})")
    return errors


def pi_yolo_errors(config: dict) -> list[str]:
    return [] if config.get("yoloMode") is False else ["pi permission: the emitted yoloMode must be false"]


def pi_mcp_errors(artifact: str) -> list[str]:
    """The installer consumes the rendered config/mcp.json: it must hold every shipped server, direct."""
    servers = json.loads((ROOT / "claude" / "configs" / "mcp.base.json").read_text())["mcpServers"]
    try:
        pi_mcp = json.loads(artifact)["mcpServers"]
    except (ValueError, KeyError, TypeError):
        return ["pi mcp: config/mcp.json is not a JSON object with mcpServers"]
    errors = []
    if set(pi_mcp) != set(servers):
        errors.append("pi mcp: the server set of config/mcp.json differs from claude/configs/mcp.base.json")
    for name, entry in pi_mcp.items():
        if name in servers and entry != {**servers[name], "exposure": "direct"}:
            errors.append(f"pi mcp: {name} must be the shipped definition with exposure direct")
    return errors


def pi_errors(policy: dict) -> list[str]:
    from tooling.generate.registry_sync import (
        load_agents,
        load_skills,
        render_pi_outputs,
        render_pi_permission,
    )

    outputs, _ = render_pi_outputs(load_skills(), load_agents(), policy)
    permission = json.loads(outputs["config/permission.json"])["permission"]
    if json.loads(outputs["config/permission.json"]) != render_pi_permission(policy):
        return ["pi permission: the rendered config differs from render_pi_permission"]
    agent_tools: dict[str, list[str]] = {}
    for path, text in outputs.items():
        if path.startswith("agents/"):
            line = next((item for item in text.splitlines() if item.startswith("tools: ")), "tools: ")
            agent_tools[path] = [tool.strip() for tool in line.removeprefix("tools: ").split(",") if tool.strip()]
    errors = pi_permission_errors(permission, policy, agent_tools)
    # Pi must never ship with its yolo mode on, whatever the renderer says: check the emitted file itself.
    emitted = json.loads(outputs["config/permission.json"])
    errors.extend(pi_yolo_errors(emitted))
    if not pi_yolo_errors({**emitted, "yoloMode": True}):
        errors.append("pi permission regression: an enabled yoloMode was not detected")
    errors.extend(pi_mcp_errors(outputs["config/mcp.json"]))
    mcp_artifact = json.loads(outputs["config/mcp.json"])
    del mcp_artifact["mcpServers"][next(iter(mcp_artifact["mcpServers"]))]
    if not pi_mcp_errors(json.dumps(mcp_artifact)):
        errors.append("pi mcp regression: a server removed from the emitted config/mcp.json was not detected")
    # A drifted verdict, a missing shell deny, and a stray tool must each be caught.
    drifted = json.loads(json.dumps(permission))
    name = next(key for key, value in drifted["mcp"].items() if key != "*" and value == "allow")
    drifted["mcp"][name] = "deny"
    dropped = json.loads(json.dumps(permission))
    del dropped["bash"]["sudo"]
    stray = json.loads(json.dumps(permission))
    stray["mcp"]["mcp__nowhere__tool"] = "allow"
    ask_after_deny = json.loads(json.dumps(permission))
    ask_after_deny["bash"]["git push *"] = ask_after_deny["bash"].pop("git push *")
    mcp_default = json.loads(json.dumps(permission))
    mcp_default["mcp"]["*"] = "allow"
    mcp_second = json.loads(json.dumps(permission))
    mcp_second["mcp"]["*"] = mcp_second["mcp"].pop("*")
    path_moved = json.loads(json.dumps(permission))
    path_moved["path"]["*"] = path_moved["path"].pop("*")
    agent_drift = json.loads(json.dumps(permission))
    agent_drift["mcp"]["mcp__codegraph__codegraph_explore"] = "ask"
    long_policy = json.loads(json.dumps(policy))
    long_policy["servers"][next(iter(long_policy["servers"]))]["tools"]["x" * 70] = "read-only"
    dotted_policy = json.loads(json.dumps(policy))
    first_server = next(iter(dotted_policy["servers"]))
    dotted_policy["servers"][first_server]["tools"]["probe.tool"] = "read-only"
    moved = json.loads(json.dumps(permission))
    moved["bash"]["*"] = moved["bash"].pop("*")  # the catch-all allow after every managed ask and deny
    for label, bad_policy in (("a dotted tool name", dotted_policy), ("a tool id over 64 characters", long_policy)):
        if not any("rewrites" in error for error in pi_permission_errors(permission, bad_policy, agent_tools)):
            errors.append(f"pi permission regression: {label} was not detected")
    for label, candidate in (
        ("a drifted MCP verdict", drifted),
        ("a dropped shell deny", dropped),
        ("a stray MCP tool", stray),
        ("a catch-all allow moved after the managed denies", moved),
        ("a bash ask placed after its deny (a bare git push)", ask_after_deny),
        ("an mcp default that is not ask", mcp_default),
        ("an mcp catch-all that is not first", mcp_second),
        ("a path catch-all that is not first", path_moved),
        ("an agent MCP tool that is not allowed", agent_drift),
    ):
        if not pi_permission_errors(candidate, policy, agent_tools):
            errors.append(f"pi permission regression: {label} was not detected")
    return errors


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
        "mcp__firecrawl__alexandria_library_search",
    ):
        if name not in allow:
            errors.append(f"read tool must be allowed: {name}")
    if any("codegraph_codegraph" in name or "firecrawl_firecrawl_firecrawl" in name for name in allow | ask):
        errors.append("doubled tool names must not appear in permission rules")
    for name in (
        "mcp__firecrawl__firecrawl_crawl",
        "mcp__firecrawl__alexandria_library_read",
        "mcp__firecrawl__people_company_search",
        "mcp__firecrawl__people_company_enrich",
        "mcp__notion__notion-create-meeting-note",
        "mcp__notion__notion-update-sidebar-tabs",
        "mcp__notion__notion-complete-mcp-setup",
        "mcp__notion__notion-convert-to-meetings-database",
        "mcp__notion__notion-link-meeting-note-to-calendar-event",
        "mcp__notion__notion-update-page-favorites",
        "mcp__playwright__browser_file_upload",
        "mcp__playwright__browser_drop",
        "mcp__playwright__browser_run_code_unsafe",
        "mcp__notion__notion-create-pages",
        "mcp__notion__notion-update-page",
        "mcp__notion__notion-create-file-upload",
        "mcp__notion__notion-spawn-session",
        "mcp__notion__notion-delete-pages",
        "mcp__notion__notion-calendar-create-events",
        "mcp__drawio__open_drawio_xml",
        "mcp__drawio__open_drawio_csv",
        "mcp__drawio__open_drawio_mermaid",
        "mcp__excalidraw__create_view",
    ):
        if name not in ask:
            errors.append(f"{name} must ask before mutation")
    for name in (
        "mcp__notion__notion-calendar-list-events",
        "mcp__notion__notion-calendar-list-calendars",
        "mcp__notion__notion-calendar-list-coworkers-events",
        "mcp__notion__notion-calendar-list-calendar-resources",
        "mcp__notion__notion-calendar-list-contacts",
    ):
        if name in allow:
            errors.append(f"{name} is private-read and must not be auto-allowed")
        if name not in ask:
            errors.append(f"{name} is private-read and must ask")
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
    for name in ("connect", "browse_table", "count_rows", "export_data", "execute_query"):
        if f"mcp__tablepro__{name}" in allow or f"mcp__tablepro__{name}" not in ask:
            errors.append(f"mcp__tablepro__{name} opens a connection, returns database rows, or runs SQL and must ask")
    metadata = ("list_connections", "list_databases", "list_schemas", "list_tables", "describe_table", "get_table_ddl")
    tablepro = servers.get("tablepro", {}).get("tools", {})
    if {tool for tool, classification in tablepro.items() if classification == "conditional-read"} != set(metadata):
        errors.append("exactly the TablePro metadata tools must be classed conditional-read")
    if any(classification == "read-only" for classification in tablepro.values()):
        errors.append("no TablePro tool may be classed read-only: that class feeds the specialist profiles")
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
            errors.append(f"{name} reads arbitrary .drawio/.xml paths and must not be auto-allowed")
        if name not in ask:
            errors.append(f"{name} is private-read and must ask")
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
        "Bash(git clean * -f*)",
        "Bash(git reset * --hard)",
        "Bash(git branch --delete --force*)",
        "Bash(rtk rm -r -f*)",
        "Bash(rm --recursive --force*)",
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
    # firecrawl_scrape is auto-allowed, and its alexandria argument runs the billed lookups the policy asks
    # for; a rule cannot match an argument, so the guard hook is the only thing that restores the prompt.
    if "mcp__firecrawl__firecrawl_scrape" in allow:
        scrape_guards = [
            hook
            for entry in hooks["PreToolUse"]
            if entry["matcher"] == "mcp__firecrawl__firecrawl_scrape"
            for hook in entry["hooks"]
        ]
        if len(scrape_guards) != 1 or not scrape_guards[0]["command"].endswith('/b-alexandria-guard.mjs"'):
            errors.append("the auto-allowed firecrawl_scrape needs exactly one b-alexandria-guard PreToolUse hook")
        elif scrape_guards[0].get("onFailure") != "block":
            errors.append("the b-alexandria-guard hook must fail closed with onFailure block")
    for entry in hooks["PreToolUse"]:
        for hook in entry["hooks"]:
            if entry["matcher"] == "Bash":
                # The Codex guard is a tripwire on every Bash call (the wrapper is the boundary), so it must
                # fail open: a broken guard that blocked Bash would also block the repair or reinstall.
                if "onFailure" in hook:
                    errors.append(
                        "the Bash Codex tripwire must fail open (no onFailure), or a broken guard blocks its own repair"
                    )
            elif hook.get("onFailure") != "block":
                errors.append("PreToolUse guards must fail closed with onFailure block (Claude Code 2.1.295 or later)")
    for event in ("PostToolUse", "Stop", "SessionStart"):
        for entry in hooks[event]:
            for hook in entry["hooks"]:
                if "onFailure" in hook:
                    errors.append(f"onFailure is reserved for the PreToolUse guards, not {event} hooks")
    shipped = {path.name for path in (ROOT / "claude" / "hooks").glob("*.mjs")}
    for entries in hooks.values():
        for entry in entries:
            for hook in entry["hooks"]:
                script = hook["command"].rsplit("/", 1)[-1].rstrip('"')
                if script not in shipped:
                    errors.append(f"hook runs a script that claude/hooks does not ship: {script}")
    for entries in hooks.values():
        for entry in entries:
            for hook in entry["hooks"]:
                if hook.get("type") != "command" or not hook["command"].startswith(
                    'bun --no-env-file --config=/dev/null "$HOME/.claude/b-agentic/hooks/'
                ):
                    errors.append(f"hook must run a managed script with hardened bun: {hook}")

    research_tools = {
        "mcp__firecrawl__firecrawl_search",
        "mcp__firecrawl__firecrawl_scrape",
        "mcp__firecrawl__firecrawl_map",
    }
    classified = {
        mcp_tool_name(server, tool): classification
        for server, record in servers.items()
        for tool, classification in record.get("tools", {}).items()
    }
    for agent in AGENTS:
        tools = agent_tools(agent)
        if "mcp__codegraph__codegraph_explore" not in tools:
            errors.append(f"{agent} must expose the CodeGraph explore tool")
        for tool in tools:
            if tool.startswith("mcp__") and classified.get(tool) not in {"read-only", "conditional-read"}:
                errors.append(f"{agent} lists {tool}, which the MCP policy does not class as read-only")
        if any(tool.startswith("mcp__notion__") for tool in tools):
            errors.append(f"{agent} must not receive private Notion workspace tools")
        if any(tool.startswith("mcp__datagrip__") for tool in tools):
            errors.append(f"{agent} must not receive private DataGrip database tools")
        if any(tool.startswith("mcp__tablepro__") for tool in tools):
            errors.append(f"{agent} must not receive private TablePro database tools")
        if any(tool in ask or tool in deny for tool in tools if tool.startswith("mcp__")):
            errors.append(f"{agent} must not list a tool that asks or is denied")
        if agent == "b-researcher":
            if not research_tools.issubset(tools):
                errors.append("b-researcher must expose the Firecrawl search and bounded extraction tools")
        elif research_tools.intersection(tools):
            errors.append(f"{agent} must not inherit researcher-only Firecrawl tools")

    # The writer child (ADR-015) is Claude Code only and the one profile with Edit and Write: its
    # reads are the specialists' reads, and it gets no prompt, delegation, or mutating MCP class.
    worker = agent_tools("b-worker")
    if worker[: len(WORKER_BASE_TOOLS)] != list(WORKER_BASE_TOOLS):
        errors.append(f"b-worker must start with exactly {', '.join(WORKER_BASE_TOOLS)}")
    worker_mcp = [tool for tool in worker if tool.startswith("mcp__")]
    if worker_mcp != [tool for tool in agent_tools("b-planner") if tool.startswith("mcp__")]:
        errors.append("b-worker MCP tools must be exactly b-planner's MCP tools")
    if any(classified.get(tool) != "read-only" for tool in worker_mcp):
        errors.append("b-worker MCP tools must all be classed read-only")
    if "mcp__codegraph__codegraph_explore" not in worker:
        errors.append("b-worker must expose the CodeGraph explore tool")
    if WORKER_FORBIDDEN_TOOLS & set(worker):
        errors.append("b-worker must not receive a notebook, prompt, skill, or delegation tool")
    if any(tool.startswith(("mcp__notion__", "mcp__datagrip__", "mcp__tablepro__")) for tool in worker):
        errors.append("b-worker must not receive private Notion, DataGrip, or TablePro tools")
    if any(tool in ask or tool in deny for tool in worker_mcp):
        errors.append("b-worker must not list a tool that asks or is denied")
    if research_tools.intersection(worker):
        errors.append("b-worker must not inherit researcher-only Firecrawl tools")

    mcp = json.loads((ROOT / "claude" / "configs" / "mcp.base.json").read_text())
    if set(mcp.get("mcpServers", {})) != EXPECTED_SERVERS - IDE_MANAGED_SERVERS:
        errors.append("Claude Code base MCP config must configure all required servers only")
    for server, entry in mcp.get("mcpServers", {}).items():
        kind = entry.get("type")
        if kind == "http":
            # TablePro serves its MCP endpoint from the local application, over loopback only.
            local = server == "tablepro" and entry.get("url") == TABLEPRO_URL
            if not local and not str(entry.get("url", "")).startswith("https://"):
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
        if server == "tablepro" and (
            entry.get("url") != TABLEPRO_URL or entry.get("headers") != {"Authorization": TABLEPRO_AUTHORIZATION}
        ):
            errors.append("tablepro must use its loopback URL and only the TABLEPRO_MCP_TOKEN environment reference")
        retired = {"directTools", "lifecycle", "description"} & set(entry)
        if retired:
            errors.append(f"{server} carries retired adapter fields: {sorted(retired)}")
    errors.extend(pi_errors(policy))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Claude Code and Pi MCP operation policy regression passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
