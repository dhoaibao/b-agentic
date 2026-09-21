#!/usr/bin/env python3
"""Report native OpenCode MCP configuration and local readiness without starting servers."""

from __future__ import annotations

import argparse
import os
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tooling" / "install"))
from jsonc import loads as load_jsonc  # noqa: E402
from session_readiness import check_session_tools  # noqa: E402

SERVERS = ("codegraph", "context7", "brave_search", "firecrawl", "playwright", "mobbin", "shadcn")


def has_credential(entry: dict, section: str, key: str) -> bool:
    value = entry.get(section, {}).get(key) if isinstance(entry.get(section), dict) else None
    return bool(os.environ.get(key)) or (isinstance(value, str) and value and not value.startswith("{env:"))


def status(server: str, entry: object) -> str:
    if not isinstance(entry, dict):
        return "missing: config entry not installed"
    if entry.get("disabled") is True:
        return "blocked: managed MCP server is disabled"
    if entry.get("type") == "remote":
        if server == "context7" and not has_credential(entry, "headers", "CONTEXT7_API_KEY"):
            return "blocked: set CONTEXT7_API_KEY"
        return "ready: native remote MCP configuration present"
    command = entry.get("command")
    if not isinstance(command, list) or not command:
        return "blocked: local MCP command is invalid"
    binary = command[0]
    if shutil.which(binary) is None:
        return f"blocked: local launcher unavailable: {binary}"
    if server == "brave_search" and not has_credential(entry, "environment", "BRAVE_API_KEY"):
        return "blocked: set BRAVE_API_KEY"
    if server == "firecrawl" and not has_credential(entry, "environment", "FIRECRAWL_API_KEY"):
        return "blocked: set FIRECRAWL_API_KEY"
    return "ready: native local MCP configuration and launcher present"


def config_in_directory(directory: Path) -> Path:
    json_path = directory / "opencode.json"
    jsonc_path = directory / "opencode.jsonc"
    return json_path if json_path.exists() or not jsonc_path.exists() else jsonc_path


def configured_path(home: str | None, config: str | None) -> Path:
    if config:
        return Path(config).expanduser()
    if home:
        return config_in_directory(Path(home).expanduser() / ".config" / "opencode")
    explicit_config = os.environ.get("B_AGENTIC_OPENCODE_CONFIG")
    if explicit_config:
        return Path(explicit_config).expanduser()
    config_dir = os.environ.get("B_AGENTIC_OPENCODE_DIR")
    if config_dir:
        return config_in_directory(Path(config_dir).expanduser())
    xdg_config = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config")))
    return config_in_directory(xdg_config / "opencode")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", help="Inspect this home's default OpenCode config path.")
    parser.add_argument("--config", help="Inspect this explicit OpenCode config file.")
    parser.add_argument("--session-tools", action="store_true")
    parser.add_argument("--allow-degraded", action="store_true")
    args = parser.parse_args()
    if args.session_tools:
        ready, detail = check_session_tools()
        print(f"session-tools: {detail}")
        return 0 if ready else 1

    config_path = configured_path(args.home, args.config)
    if not config_path.exists():
        print(f"runtime: OpenCode\nconfig: {config_path}\nstatus: missing OpenCode config")
        return 0 if args.allow_degraded else 1
    try:
        config = load_jsonc(config_path.read_text())
        mcp = config.get("mcp", {}).get("servers", {})
        if not isinstance(mcp, dict):
            raise ValueError("mcp.servers must be an object")
    except (OSError, ValueError) as exc:
        print(f"runtime: OpenCode\nconfig: {config_path}\nstatus: invalid config: {exc}", file=sys.stderr)
        return 1

    print(
        f"runtime: OpenCode\nconfig: {config_path}\nstartup-check: not attempted; this command never starts or authenticates MCP servers"
    )
    blocked = shutil.which("opencode") is None
    print("opencode: " + ("ready: CLI found" if not blocked else "blocked: OpenCode CLI not found"))
    for server in SERVERS:
        value = status(server, mcp.get(server))
        print(f"{server}: {value}")
        blocked = blocked or value.startswith(("blocked:", "missing:"))
    return 0 if args.allow_degraded or not blocked else 1


if __name__ == "__main__":
    raise SystemExit(main())
