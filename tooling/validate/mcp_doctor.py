#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SUPPORTED_SERVERS = ("serena", "codegraph", "context7", "brave-search", "firecrawl", "playwright")
DEFAULT_PACKAGES = {
    "brave-search": "@brave/brave-search-mcp-server",
    "firecrawl": "firecrawl-mcp",
    "playwright": "@playwright/mcp@latest",
}


def load_json(path: Path) -> dict:
    return json.loads(path.read_text())


def load_toml(path: Path) -> dict:
    try:
        import tomllib
    except ModuleNotFoundError as exc:  # pragma: no cover - depends on runtime python
        raise SystemExit("Codex CLI MCP doctor requires Python 3.11+ (stdlib tomllib).") from exc
    return tomllib.loads(path.read_text())


def runtime_records() -> dict[str, dict]:
    registry = load_json(ROOT / "runtimes" / "registry.yaml")
    records = {}
    for runtime in registry.get("runtimes", []):
        if isinstance(runtime, dict) and isinstance(runtime.get("name"), str):
            records[runtime["name"]] = runtime
    return records


def env_var_present(name: str) -> bool:
    return bool(os.environ.get(name))


def command_ready(command: str) -> bool:
    return shutil.which(command) is not None


def list_matches(value: object, expected: list[str]) -> bool:
    return isinstance(value, list) and value == expected


def serena_args_match(value: object, context: str) -> bool:
    if not isinstance(value, list):
        return False
    expected = ["start-mcp-server", "--context", context, "--project-from-cwd"]
    return value == expected or value == expected + ["--open-web-dashboard", "false"]


def package_name(server: str) -> str:
    env_name = {
        "brave-search": "B_AGENTIC_BRAVE_MCP_PACKAGE",
        "firecrawl": "B_AGENTIC_FIRECRAWL_MCP_PACKAGE",
        "playwright": "B_AGENTIC_PLAYWRIGHT_MCP_PACKAGE",
    }.get(server)
    if env_name:
        return os.environ.get(env_name, DEFAULT_PACKAGES[server])
    return DEFAULT_PACKAGES[server]


def pinned_package_status(server: str, package: object) -> str | None:
    if not isinstance(package, str) or not package:
        return None
    expected = package_name(server)
    if package == expected:
        return None
    env_name = {
        "brave-search": "B_AGENTIC_BRAVE_MCP_PACKAGE",
        "firecrawl": "B_AGENTIC_FIRECRAWL_MCP_PACKAGE",
        "playwright": "B_AGENTIC_PLAYWRIGHT_MCP_PACKAGE",
    }[server]
    if os.environ.get(env_name):
        return None
    return f"configured package {package!r}; set {env_name}={package} for strict launcher validation"


def ready_status(base: str, note: str | None) -> str:
    return f"ready: {base}; {note}" if note else f"ready: {base}"


def args_shape_matches(server: str, args: object) -> bool:
    if not isinstance(args, list):
        return False
    if server == "brave-search":
        return len(args) == 4 and args[0] == "dlx" and args[2:] == ["--transport", "stdio"]
    if server == "firecrawl":
        return len(args) == 2 and args[0] == "dlx"
    if server == "playwright":
        return len(args) == 3 and args[0] == "dlx" and args[2] == "--isolated"
    return False


def command_shape_matches(server: str, command: object) -> bool:
    if not isinstance(command, list) or len(command) < 3 or command[0] != "pnpm":
        return False
    return args_shape_matches(server, command[1:])


def join_issues(issues: list[str]) -> str:
    return "; ".join(issues)


def claude_server_status(server: str, config: dict) -> str:
    servers = config.get("mcpServers", {})
    entry = servers.get(server)
    if not isinstance(entry, dict):
        return "missing: config entry not installed"

    if server == "serena":
        if entry.get("command") != "serena" or not serena_args_match(entry.get("args"), "claude-code"):
            return "blocked: invalid serena launcher"
        return "ready: serena command found" if command_ready("serena") else "blocked: install serena"
    if server == "context7":
        if entry.get("type") != "http" or entry.get("url") != "https://mcp.context7.com/mcp":
            return "blocked: invalid context7 config"
        return "ready: CONTEXT7_API_KEY available" if env_var_present("CONTEXT7_API_KEY") else "blocked: missing CONTEXT7_API_KEY"
    if server == "codegraph":
        if entry.get("command") != "codegraph" or not list_matches(entry.get("args"), ["serve", "--mcp"]):
            return "blocked: invalid codegraph launcher"
        return "ready: codegraph command found" if command_ready("codegraph") else "blocked: install codegraph"
    if server == "playwright":
        args = entry.get("args")
        pinned_status = pinned_package_status("playwright", args[1] if isinstance(args, list) and len(args) > 1 else None)
        if entry.get("command") != "pnpm" or (pinned_status and not args_shape_matches("playwright", args)) or (not pinned_status and not list_matches(args, ["dlx", package_name("playwright"), "--isolated"])):
            return "blocked: invalid playwright launcher"
        return ready_status("pnpm available", pinned_status) if command_ready("pnpm") else "blocked: install pnpm"

    issues: list[str] = []
    args = entry.get("args")
    pinned_status = pinned_package_status(server, args[1] if isinstance(args, list) and len(args) > 1 else None)
    expected_args = ["dlx", package_name("brave-search"), "--transport", "stdio"] if server == "brave-search" else ["dlx", package_name("firecrawl")]
    if entry.get("command") != "pnpm" or (pinned_status and not args_shape_matches(server, args)) or (not pinned_status and not list_matches(args, expected_args)):
        issues.append(f"invalid {server} launcher")
    if not command_ready("pnpm"):
        issues.append("install pnpm")
    env_key = "BRAVE_API_KEY" if server == "brave-search" else "FIRECRAWL_API_KEY"
    if not env_var_present(env_key):
        issues.append(f"set {env_key}")
    if issues:
        return f"blocked: {join_issues(issues)}"
    return ready_status(f"pnpm and {env_key} available", pinned_status)


def json_mcp_server_status(server: str, config: dict) -> str:
    servers = config.get("mcp", {})
    entry = servers.get(server)
    if not isinstance(entry, dict):
        return "missing: config entry not installed"

    if server == "serena":
        command = entry.get("command")
        if not isinstance(command, list) or not serena_args_match(command[1:], "ide") or command[0] != "serena":
            return "blocked: invalid serena launcher"
        if command_ready("serena"):
            return "ready: serena command found"
        return "blocked: install serena"
    if server == "context7":
        if entry.get("type") != "remote" or entry.get("url") != "https://mcp.context7.com/mcp":
            return "blocked: invalid context7 config"
        return "ready: CONTEXT7_API_KEY available" if env_var_present("CONTEXT7_API_KEY") else "blocked: missing CONTEXT7_API_KEY"
    if server == "codegraph":
        command = entry.get("command")
        if not list_matches(command, ["codegraph", "serve", "--mcp"]):
            return "blocked: invalid codegraph launcher"
        return "ready: codegraph command found" if command_ready("codegraph") else "blocked: install codegraph"
    if server == "playwright":
        command = entry.get("command")
        pinned_status = pinned_package_status("playwright", command[2] if isinstance(command, list) and len(command) > 2 else None)
        if (pinned_status and not command_shape_matches("playwright", command)) or (not pinned_status and not list_matches(command, ["pnpm", "dlx", package_name("playwright"), "--isolated"])):
            return "blocked: invalid playwright launcher"
        return ready_status("pnpm available", pinned_status) if command_ready("pnpm") else "blocked: install pnpm"

    issues: list[str] = []
    command = entry.get("command")
    pinned_status = pinned_package_status(server, command[2] if isinstance(command, list) and len(command) > 2 else None)
    expected_command = ["pnpm", "dlx", package_name("brave-search"), "--transport", "stdio"] if server == "brave-search" else ["pnpm", "dlx", package_name("firecrawl")]
    if (pinned_status and not command_shape_matches(server, command)) or (not pinned_status and not list_matches(command, expected_command)):
        issues.append(f"invalid {server} launcher")
    if not command_ready("pnpm"):
        issues.append("install pnpm")
    env_key = "BRAVE_API_KEY" if server == "brave-search" else "FIRECRAWL_API_KEY"
    if not env_var_present(env_key):
        issues.append(f"set {env_key}")
    if issues:
        return f"blocked: {join_issues(issues)}"
    return ready_status(f"pnpm and {env_key} available", pinned_status)


def codex_server_status(server: str, config: dict) -> str:
    servers = config.get("mcp_servers", {})
    entry = servers.get(server)
    if not isinstance(entry, dict):
        return "missing: config entry not installed"

    if server == "serena":
        command = entry.get("command")
        if command != "serena" or not serena_args_match(entry.get("args"), "codex"):
            return "blocked: invalid serena launcher"
        return "ready: serena command found" if command_ready("serena") else "blocked: install serena"
    if server == "context7":
        if entry.get("url") != "https://mcp.context7.com/mcp":
            return "blocked: invalid context7 config"
        headers = entry.get("http_headers", {})
        if isinstance(headers, dict) and isinstance(headers.get("CONTEXT7_API_KEY"), str) and headers.get("CONTEXT7_API_KEY"):
            return "ready: CONTEXT7_API_KEY configured in Codex config"
        env_headers = entry.get("env_http_headers", {})
        if isinstance(env_headers, dict) and env_headers.get("CONTEXT7_API_KEY") == "CONTEXT7_API_KEY":
            return "ready: CONTEXT7_API_KEY env binding configured in Codex config" if env_var_present("CONTEXT7_API_KEY") else "blocked: missing CONTEXT7_API_KEY; env binding configured in Codex config"
        return "ready: CONTEXT7_API_KEY available" if env_var_present("CONTEXT7_API_KEY") else "blocked: missing CONTEXT7_API_KEY"
    if server == "codegraph":
        if entry.get("command") != "codegraph" or not list_matches(entry.get("args"), ["serve", "--mcp"]):
            return "blocked: invalid codegraph launcher"
        return "ready: codegraph command found" if command_ready("codegraph") else "blocked: install codegraph"
    if server == "playwright":
        args = entry.get("args")
        pinned_status = pinned_package_status("playwright", args[1] if isinstance(args, list) and len(args) > 1 else None)
        if entry.get("command") != "pnpm" or (pinned_status and not args_shape_matches("playwright", args)) or (not pinned_status and not list_matches(args, ["dlx", package_name("playwright"), "--isolated"])):
            return "blocked: invalid playwright launcher"
        return ready_status("pnpm available", pinned_status) if command_ready("pnpm") else "blocked: install pnpm"

    issues: list[str] = []
    args = entry.get("args")
    pinned_status = pinned_package_status(server, args[1] if isinstance(args, list) and len(args) > 1 else None)
    expected_args = ["dlx", package_name("brave-search"), "--transport", "stdio"] if server == "brave-search" else ["dlx", package_name("firecrawl")]
    if entry.get("command") != "pnpm" or (pinned_status and not args_shape_matches(server, args)) or (not pinned_status and not list_matches(args, expected_args)):
        issues.append(f"invalid {server} launcher")
    if not command_ready("pnpm"):
        issues.append("install pnpm")
    env_key = "BRAVE_API_KEY" if server == "brave-search" else "FIRECRAWL_API_KEY"
    env_section = entry.get("env", {})
    if not (isinstance(env_section, dict) and isinstance(env_section.get(env_key), str) and env_section.get(env_key)):
        if not env_var_present(env_key):
            issues.append(f"set {env_key}")
    if issues:
        return f"blocked: {join_issues(issues)}"
    return ready_status(f"pnpm and {env_key} available", pinned_status)


def resolve_config_path(runtime: dict, home: Path) -> Path:
    schema_family = runtime.get("config_schema_family")
    if schema_family == "claude-user-config":
        return home / ".claude.json"
    if schema_family == "codex-toml":
        return home / ".codex" / "config.toml"
    if schema_family == "opencode-json":
        return home / ".config" / "opencode" / "opencode.json"
    raise ValueError(f"unsupported config schema family: {schema_family!r}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Check installed b-agentic MCP readiness for a runtime.")
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--home", default=str(Path.home()), help="Home directory to inspect. Defaults to current HOME.")
    args = parser.parse_args()

    runtimes = runtime_records()
    runtime = runtimes.get(args.runtime)
    if runtime is None:
        print(f"unsupported runtime: {args.runtime}", file=sys.stderr)
        return 2

    home = Path(args.home).expanduser()
    config_path = resolve_config_path(runtime, home)
    if not config_path.exists():
        print(f"runtime: {args.runtime}")
        print(f"config: {config_path}")
        print("status: missing runtime config")
        return 1

    schema_family = runtime.get("config_schema_family")
    if schema_family == "claude-user-config":
        config = load_json(config_path)
        status_fn = claude_server_status
    elif schema_family == "codex-toml":
        config = load_toml(config_path)
        status_fn = codex_server_status
    else:
        config = load_json(config_path)
        status_fn = json_mcp_server_status

    print(f"runtime: {args.runtime}")
    print(f"config: {config_path}")
    print("startup-check: not attempted; validates local launchers, keys, and config shape only")
    for server in SUPPORTED_SERVERS:
        print(f"{server}: {status_fn(server, config)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
