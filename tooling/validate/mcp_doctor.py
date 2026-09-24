#!/usr/bin/env python3
"""Report Pi MCP configuration and local prerequisites without connecting to servers."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

from session_readiness import check_session_tools

SERVERS = ("codegraph", "context7", "brave_search", "firecrawl", "playwright", "mobbin", "shadcn")
CREDENTIALS = {"context7": "CONTEXT7_API_KEY", "brave_search": "BRAVE_API_KEY", "firecrawl": "FIRECRAWL_API_KEY"}


def configured_path(home: str | None, config: str | None) -> Path:
    if config:
        return Path(config).expanduser()
    if home:
        return Path(home).expanduser() / ".pi" / "agent" / "mcp.json"
    explicit = os.environ.get("B_AGENTIC_PI_DIR") or os.environ.get("PI_CODING_AGENT_DIR")
    return (Path(explicit).expanduser() if explicit else Path.home() / ".pi" / "agent") / "mcp.json"


def status(server: str, entry: object) -> str:
    if not isinstance(entry, dict):
        return "missing: config entry not installed"
    if entry.get("disabled") is True:
        return "blocked: server disabled in config"
    credential = CREDENTIALS.get(server)
    if credential and credential not in os.environ:
        return f"blocked: {credential} environment variable not present"
    if isinstance(entry.get("url"), str):
        return "configured: remote endpoint present; not connected"
    binary = entry.get("command")
    if not isinstance(binary, str) or not binary:
        return "blocked: local MCP launcher is invalid"
    if shutil.which(binary) is None:
        return f"blocked: local launcher unavailable: {binary}"
    return "configured: local launcher present; not started"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", help="Inspect this home's default Pi agent directory.")
    parser.add_argument("--config", help="Inspect this explicit Pi MCP config file.")
    parser.add_argument("--session-tools", action="store_true")
    parser.add_argument("--allow-degraded", action="store_true")
    args = parser.parse_args()
    if args.session_tools:
        ready, detail = check_session_tools()
        print(f"session-tools: {detail}")
        return 0 if ready else 1

    config_path = configured_path(args.home, args.config)
    if not config_path.exists():
        print(f"runtime: Pi\nconfig: {config_path}\nstatus: missing Pi MCP config")
        return 0 if args.allow_degraded else 1
    try:
        config = json.loads(config_path.read_text())
        servers = config.get("mcpServers")
        if not isinstance(servers, dict):
            raise ValueError("mcpServers must be an object")
    except (OSError, ValueError, AttributeError) as exc:
        print(f"runtime: Pi\nconfig: {config_path}\nstatus: invalid config: {exc}", file=sys.stderr)
        return 1

    print(f"runtime: Pi\nconfig: {config_path}\nstartup-check: not attempted; no MCP or browser connections")
    blocked = shutil.which("pi") is None
    print("pi: " + ("configured: CLI found" if not blocked else "blocked: Pi CLI not found"))
    for server in SERVERS:
        detail = status(server, servers.get(server))
        print(f"{server}: {detail}")
        blocked = blocked or detail.startswith(("blocked:", "missing:"))
    return 0 if args.allow_degraded or not blocked else 1


if __name__ == "__main__":
    raise SystemExit(main())
