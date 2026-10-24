#!/usr/bin/env python3
"""Report Claude Code or OpenCode MCP configuration and local prerequisites without connecting to servers."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

from session_readiness import check_session_tools

SERVERS = (
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
)
OPTIONAL_SERVERS = {"clickup", "datagrip"}
CREDENTIALS = {
    "context7": ("CONTEXT7_API_KEY",),
    "brave_search": ("BRAVE_API_KEY",),
    "firecrawl": ("FIRECRAWL_API_KEY",),
    "clickup": ("CLICKUP_API_KEY", "CLICKUP_TEAM_ID"),
}


def configured_path(home: str | None, config: str | None) -> Path:
    """User-scope MCP servers live in .claude.json (inside CLAUDE_CONFIG_DIR when it is set)."""
    if config:
        return Path(config).expanduser()
    explicit = os.environ.get("B_AGENTIC_CLAUDE_DIR") or os.environ.get("CLAUDE_CONFIG_DIR")
    if explicit:
        return Path(explicit).expanduser() / ".claude.json"
    return (Path(home).expanduser() if home else Path.home()) / ".claude.json"


def opencode_path(home: str | None, config: str | None) -> Path:
    """OpenCode's global config; only the default ~/.config/opencode is a supported install location."""
    if config:
        return Path(config).expanduser()
    explicit = os.environ.get("B_AGENTIC_OPENCODE_DIR")
    if explicit:
        return Path(explicit).expanduser() / "opencode.json"
    return (Path(home).expanduser() if home else Path.home()) / ".config" / "opencode" / "opencode.json"


def status(server: str, entry: object) -> str:
    if not isinstance(entry, dict):
        return "not installed: optional" if server in OPTIONAL_SERVERS else "missing: config entry not installed"
    if entry.get("disabled") is True:
        return "blocked: server disabled in config"
    missing = [name for name in CREDENTIALS.get(server, ()) if name not in os.environ]
    if missing:
        variables = ", ".join(missing)
        suffix = "environment variable" if len(missing) == 1 else "environment variables"
        return f"blocked: {variables} {suffix} not present"
    if isinstance(entry.get("url"), str):
        return "configured: remote endpoint present; not connected"
    binary = entry.get("command")
    if isinstance(binary, list) and binary and isinstance(binary[0], str):
        binary = binary[0]  # OpenCode writes the launcher as an argv array
    if not isinstance(binary, str) or not binary:
        return "blocked: local MCP launcher is invalid"
    if shutil.which(binary) is None:
        return f"blocked: local launcher unavailable: {binary}"
    return "configured: local launcher present; not started"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", choices=("claude", "opencode"), default="claude")
    parser.add_argument("--home", help="Inspect this home's default MCP configuration for the runtime.")
    parser.add_argument("--config", help="Inspect this explicit MCP config file.")
    parser.add_argument("--session-tools", action="store_true")
    parser.add_argument("--allow-degraded", action="store_true")
    args = parser.parse_args()
    if args.session_tools:
        ready, detail = check_session_tools()
        print(f"session-tools: {detail}")
        return 0 if ready else 1

    opencode = args.runtime == "opencode"
    label = "OpenCode" if opencode else "Claude Code"
    config_path = opencode_path(args.home, args.config) if opencode else configured_path(args.home, args.config)
    if not config_path.exists():
        print(f"runtime: {label}\nconfig: {config_path}\nstatus: missing {label} MCP config")
        return 0 if args.allow_degraded else 1
    try:
        config = json.loads(config_path.read_text())
        servers = config.get("mcp", {}).get("servers") if opencode else config.get("mcpServers")
        if not isinstance(servers, dict):
            raise ValueError("mcp.servers must be an object" if opencode else "mcpServers must be an object")
    except (OSError, ValueError, AttributeError) as exc:
        print(f"runtime: {label}\nconfig: {config_path}\nstatus: invalid config: {exc}", file=sys.stderr)
        return 1

    print(f"runtime: {label}\nconfig: {config_path}\nstartup-check: not attempted; no MCP or browser connections")
    cli = "opencode" if opencode else "claude"
    blocked = shutil.which(cli) is None
    print(f"{cli}: " + ("configured: CLI found" if not blocked else f"blocked: {label} CLI not found"))
    for server in SERVERS:
        detail = status(server, servers.get(server))
        print(f"{server}: {detail}")
        blocked = blocked or detail.startswith(("blocked:", "missing:"))
    return 0 if args.allow_degraded or not blocked else 1


if __name__ == "__main__":
    raise SystemExit(main())
