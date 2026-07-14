#!/usr/bin/env python3

from __future__ import annotations

import argparse
import importlib.util
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
try:
    from tooling.validate.session_readiness import check_session_tools
except ModuleNotFoundError:
    from session_readiness import check_session_tools


def load_jsonc(text: str) -> object:
    module_path = ROOT / "tooling" / "install" / "jsonc.py"
    spec = importlib.util.spec_from_file_location("b_agentic_jsonc", module_path)
    if spec is None or spec.loader is None:
        raise OSError(f"cannot load JSONC parser: {module_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.loads(text)


SUPPORTED_SERVERS = ("serena", "codegraph", "context7", "brave-search", "firecrawl", "playwright")
CONTEXT7_URL = "https://mcp.context7.com/mcp"


@dataclass
class NormalizedServer:
    command: str | None
    args: list[str] | None


def command_ready(command: str) -> bool:
    return shutil.which(command) is not None


def normalize_server(entry: dict) -> NormalizedServer:
    command = entry.get("command")
    args = entry.get("args")
    return NormalizedServer(command if isinstance(command, str) else None, args if isinstance(args, list) else None)


def pi_mcp_adapter_ready(home: Path) -> tuple[bool, str]:
    if not command_ready("pi"):
        return False, "missing: pi CLI not installed"
    env = {**os.environ, "HOME": str(home), "PI_CODING_AGENT_DIR": str(home / ".pi" / "agent")}
    completed = subprocess.run(["pi", "list"], capture_output=True, text=True, env=env)
    if "pi-mcp-adapter" in f"{completed.stdout}\n{completed.stderr}":
        return True, "ready: pi-mcp-adapter installed"
    return False, "missing: pi-mcp-adapter not installed; run pi install npm:pi-mcp-adapter"


def validate_config(config: object) -> dict:
    if not isinstance(config, dict):
        raise ValueError("config root must be an object")
    if not isinstance(config.get("mcpServers", {}), dict):
        raise ValueError("mcpServers must be an object")
    return config


def pi_server_status(server: str, config: dict) -> str:
    entry = config.get("mcpServers", {}).get(server)
    if not isinstance(entry, dict):
        return "missing: config entry not installed"
    normalized = normalize_server(entry)
    if server == "serena":
        valid = normalized.command == "serena" and normalized.args[:3] == ["start-mcp-server", "--context", "ide"] if normalized.args else False
        return "ready: serena command found" if valid and command_ready("serena") else "blocked: invalid or unavailable serena launcher"
    if server == "codegraph":
        valid = normalized.command == "codegraph" and normalized.args == ["serve", "--mcp"]
        return "ready: codegraph command found" if valid and command_ready("codegraph") else "blocked: invalid or unavailable codegraph launcher"
    if server == "context7":
        return "ready: CONTEXT7_API_KEY available" if entry.get("url") == CONTEXT7_URL and os.environ.get("CONTEXT7_API_KEY") else "blocked: invalid context7 config or missing CONTEXT7_API_KEY"
    expected = {
        "brave-search": ["dlx", "@brave/brave-search-mcp-server", "--transport", "stdio"],
        "firecrawl": ["dlx", "firecrawl-mcp"],
        "playwright": ["dlx", "@playwright/mcp", "--isolated"],
    }[server]
    if normalized.command != "pnpm" or normalized.args != expected:
        return f"blocked: invalid {server} launcher"
    if not command_ready("pnpm"):
        return "blocked: install pnpm"
    if server == "brave-search" and not os.environ.get("BRAVE_API_KEY"):
        return "blocked: set BRAVE_API_KEY"
    if server == "firecrawl" and not os.environ.get("FIRECRAWL_API_KEY"):
        return "blocked: set FIRECRAWL_API_KEY"
    return "ready: launcher and local prerequisites available"


def main() -> int:
    parser = argparse.ArgumentParser(description="Check installed b-agentic Pi MCP configuration and local prerequisites.")
    parser.add_argument("--home", default=str(Path.home()), help="Home directory to inspect. Defaults to current HOME.")
    parser.add_argument("--session-tools", action="store_true", help="Check active-session RTK and required shell tools only.")
    parser.add_argument("--allow-degraded", action="store_true", help="Exit zero even for missing or blocked MCP readiness.")
    args = parser.parse_args()
    if args.session_tools:
        ready, detail = check_session_tools()
        print(f"session-tools: {detail}")
        return 0 if ready else 1

    home = Path(args.home).expanduser()
    config_path = home / ".pi" / "agent" / "mcp.json"
    if not config_path.exists():
        print(f"agent: Pi\nconfig: {config_path}\nstatus: missing Pi config")
        return 0 if args.allow_degraded else 1
    try:
        config = validate_config(load_jsonc(config_path.read_text()))
    except (OSError, ValueError) as exc:
        print(f"agent: Pi\nconfig: {config_path}\nstatus: invalid config: {exc}", file=sys.stderr)
        return 1

    adapter_ready, adapter_status = pi_mcp_adapter_ready(home)
    print(f"agent: Pi\nconfig: {config_path}\nstartup-check: not attempted; validates local launchers, keys, and config shape only")
    print(f"mcp-adapter: {adapter_status}")
    blocked = not adapter_ready
    for server in SUPPORTED_SERVERS:
        status = pi_server_status(server, config)
        print(f"{server}: {status}")
        blocked = blocked or status.startswith(("blocked:", "missing:"))
    return 0 if args.allow_degraded or not blocked else 1


if __name__ == "__main__":
    raise SystemExit(main())
