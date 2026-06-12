#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path


SUPPORTED_RUNTIMES = {"claude-code", "codex-cli", "opencode", "kilo-code"}
SUPPORTED_SERVERS = ("serena", "context7", "brave-search", "firecrawl", "playwright")


def load_json(path: Path) -> dict:
    return json.loads(path.read_text())


def load_toml(path: Path) -> dict:
    try:
        import tomllib
    except ModuleNotFoundError as exc:  # pragma: no cover - depends on runtime python
        raise SystemExit("Codex CLI MCP doctor requires Python 3.11+ (stdlib tomllib).") from exc
    return tomllib.loads(path.read_text())


def env_var_present(name: str) -> bool:
    return bool(os.environ.get(name))


def command_ready(command: str) -> bool:
    return shutil.which(command) is not None


def join_issues(issues: list[str]) -> str:
    return "; ".join(issues)


def claude_server_status(server: str, config: dict) -> str:
    servers = config.get("mcpServers", {})
    entry = servers.get(server)
    if not isinstance(entry, dict):
        return "missing: config entry not installed"

    if server == "serena":
        return "ready: serena command found" if command_ready("serena") else "blocked: install serena"
    if server == "context7":
        return "ready: CONTEXT7_API_KEY available" if env_var_present("CONTEXT7_API_KEY") else "blocked: missing CONTEXT7_API_KEY"
    if server == "playwright":
        return "ready: pnpm available" if command_ready("pnpm") else "blocked: install pnpm"

    issues: list[str] = []
    if not command_ready("pnpm"):
        issues.append("install pnpm")
    env_key = "BRAVE_API_KEY" if server == "brave-search" else "FIRECRAWL_API_KEY"
    if not env_var_present(env_key):
        issues.append(f"set {env_key}")
    if issues:
        return f"blocked: {join_issues(issues)}"
    return f"ready: pnpm and {env_key} available"


def json_mcp_server_status(server: str, config: dict) -> str:
    servers = config.get("mcp", {})
    entry = servers.get(server)
    if not isinstance(entry, dict):
        return "missing: config entry not installed"

    if server == "serena":
        command = entry.get("command")
        if isinstance(command, list) and command and command[0] == "serena" and command_ready("serena"):
            return "ready: serena command found"
        return "blocked: install serena"
    if server == "context7":
        return "ready: CONTEXT7_API_KEY available" if env_var_present("CONTEXT7_API_KEY") else "blocked: missing CONTEXT7_API_KEY"
    if server == "playwright":
        return "ready: pnpm available" if command_ready("pnpm") else "blocked: install pnpm"

    issues: list[str] = []
    if not command_ready("pnpm"):
        issues.append("install pnpm")
    env_key = "BRAVE_API_KEY" if server == "brave-search" else "FIRECRAWL_API_KEY"
    if not env_var_present(env_key):
        issues.append(f"set {env_key}")
    if issues:
        return f"blocked: {join_issues(issues)}"
    return f"ready: pnpm and {env_key} available"


def codex_server_status(server: str, config: dict) -> str:
    servers = config.get("mcp_servers", {})
    entry = servers.get(server)
    if not isinstance(entry, dict):
        return "missing: config entry not installed"

    if server == "serena":
        command = entry.get("command")
        return "ready: serena command found" if command == "serena" and command_ready("serena") else "blocked: install serena"
    if server == "context7":
        headers = entry.get("http_headers", {})
        if isinstance(headers, dict) and isinstance(headers.get("CONTEXT7_API_KEY"), str) and headers.get("CONTEXT7_API_KEY"):
            return "ready: CONTEXT7_API_KEY configured in Codex config"
        return "ready: CONTEXT7_API_KEY available" if env_var_present("CONTEXT7_API_KEY") else "blocked: missing CONTEXT7_API_KEY"
    if server == "playwright":
        return "ready: pnpm available" if command_ready("pnpm") else "blocked: install pnpm"

    issues: list[str] = []
    if not command_ready("pnpm"):
        issues.append("install pnpm")
    env_key = "BRAVE_API_KEY" if server == "brave-search" else "FIRECRAWL_API_KEY"
    env_section = entry.get("env", {})
    if not (isinstance(env_section, dict) and isinstance(env_section.get(env_key), str) and env_section.get(env_key)):
        if not env_var_present(env_key):
            issues.append(f"set {env_key}")
    if issues:
        return f"blocked: {join_issues(issues)}"
    return f"ready: pnpm and {env_key} available"


def resolve_config_path(runtime: str, home: Path) -> Path:
    if runtime == "claude-code":
        return home / ".claude.json"
    if runtime == "codex-cli":
        return home / ".codex" / "config.toml"
    if runtime == "opencode":
        return home / ".config" / "opencode" / "opencode.json"
    if runtime == "kilo-code":
        return home / ".config" / "kilo" / "kilo.jsonc"
    raise ValueError(runtime)


def main() -> int:
    parser = argparse.ArgumentParser(description="Check installed b-agentic MCP readiness for a runtime.")
    parser.add_argument("--runtime", required=True, choices=sorted(SUPPORTED_RUNTIMES))
    parser.add_argument("--home", default=str(Path.home()), help="Home directory to inspect. Defaults to current HOME.")
    args = parser.parse_args()

    home = Path(args.home).expanduser()
    config_path = resolve_config_path(args.runtime, home)
    if not config_path.exists():
        print(f"runtime: {args.runtime}")
        print(f"config: {config_path}")
        print("status: missing runtime config")
        return 1

    if args.runtime == "claude-code":
        config = load_json(config_path)
        status_fn = claude_server_status
    elif args.runtime == "codex-cli":
        config = load_toml(config_path)
        status_fn = codex_server_status
    else:
        config = load_json(config_path)
        status_fn = json_mcp_server_status

    print(f"runtime: {args.runtime}")
    print(f"config: {config_path}")
    for server in SUPPORTED_SERVERS:
        print(f"{server}: {status_fn(server, config)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
