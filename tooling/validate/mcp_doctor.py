#!/usr/bin/env python3
"""Report Claude Code MCP configuration and local prerequisites without connecting to servers."""

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
    "notion",
    "excalidraw",
    "drawio",
    "shadcn",
    "datagrip",
)


def optional_servers() -> set[str]:
    """Servers a user may leave uninstalled: DataGrip (user-managed) and every optional component's."""
    names = {"datagrip"}
    try:
        registry = json.loads((Path(__file__).resolve().parents[2] / "skills" / "registry.yaml").read_text())
    except (OSError, json.JSONDecodeError):
        return names
    for component in registry.get("optional_components", {}).values():
        names.update(name for name in component.get("mcp_servers", []) if isinstance(name, str))
    return names


def deselected_servers(home: str | None) -> set[str] | None:
    """Servers of components the install manifest records as not selected; None when no choice is recorded."""
    explicit = os.environ.get("B_AGENTIC_CLAUDE_DIR") or os.environ.get("CLAUDE_CONFIG_DIR")
    base = Path(explicit).expanduser() if explicit else (Path(home).expanduser() if home else Path.home()) / ".claude"
    try:
        recorded = json.loads((base / "b-agentic" / "install.json").read_text()).get("optional_components")
        registry = json.loads((Path(__file__).resolve().parents[2] / "skills" / "registry.yaml").read_text())
    except (OSError, json.JSONDecodeError, AttributeError):
        return None
    if not isinstance(recorded, dict):
        return None
    return {
        name
        for key, component in registry.get("optional_components", {}).items()
        if not recorded.get(key)
        for name in component.get("mcp_servers", [])
        if isinstance(name, str)
    }


CREDENTIALS = {
    "context7": ("CONTEXT7_API_KEY",),
    "brave_search": ("BRAVE_API_KEY",),
    "firecrawl": ("FIRECRAWL_API_KEY",),
}


def configured_path(home: str | None, config: str | None) -> Path:
    """User-scope MCP servers live in .claude.json (inside CLAUDE_CONFIG_DIR when it is set)."""
    if config:
        return Path(config).expanduser()
    explicit = os.environ.get("B_AGENTIC_CLAUDE_DIR") or os.environ.get("CLAUDE_CONFIG_DIR")
    if explicit:
        return Path(explicit).expanduser() / ".claude.json"
    return (Path(home).expanduser() if home else Path.home()) / ".claude.json"


def status(server: str, entry: object, optional: set[str]) -> str:
    if not isinstance(entry, dict):
        return "not installed: optional" if server in optional else "missing: config entry not installed"
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
    if not isinstance(binary, str) or not binary:
        return "blocked: local MCP launcher is invalid"
    if shutil.which(binary) is None:
        return f"blocked: local launcher unavailable: {binary}"
    return "configured: local launcher present; not started"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", help="Inspect this home's default MCP configuration.")
    parser.add_argument("--config", help="Inspect this explicit MCP config file.")
    parser.add_argument("--session-tools", action="store_true")
    parser.add_argument("--allow-degraded", action="store_true")
    args = parser.parse_args()
    if args.session_tools:
        ready, detail = check_session_tools()
        print(f"session-tools: {detail}")
        return 0 if ready else 1

    label = "Claude Code"
    config_path = configured_path(args.home, args.config)
    if not config_path.exists():
        print(f"runtime: {label}\nconfig: {config_path}\nstatus: missing {label} MCP config")
        return 0 if args.allow_degraded else 1
    try:
        config = json.loads(config_path.read_text())
        servers = config.get("mcpServers")
        if not isinstance(servers, dict):
            raise ValueError("mcpServers must be an object")
    except (OSError, ValueError, AttributeError) as exc:
        print(f"runtime: {label}\nconfig: {config_path}\nstatus: invalid config: {exc}", file=sys.stderr)
        return 1

    print(f"runtime: {label}\nconfig: {config_path}\nstartup-check: not attempted; no MCP or browser connections")
    blocked = shutil.which("claude") is None
    print("claude: " + ("configured: CLI found" if not blocked else f"blocked: {label} CLI not found"))
    deselected = deselected_servers(args.home)
    optional = {"datagrip"} | (optional_servers() if deselected is None else deselected)
    for server in SERVERS:
        detail = status(server, servers.get(server), optional)
        print(f"{server}: {detail}")
        blocked = blocked or detail.startswith(("blocked:", "missing:"))
    return 0 if args.allow_degraded or not blocked else 1


if __name__ == "__main__":
    raise SystemExit(main())
