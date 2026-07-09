#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tooling" / "install"))
from jsonc import loads as load_jsonc
SUPPORTED_SERVERS = ("serena", "codegraph", "context7", "brave-search", "firecrawl", "playwright")
DEFAULT_PACKAGES = {
    "brave-search": "@brave/brave-search-mcp-server@2.0.85",
    "firecrawl": "firecrawl-mcp@3.22.1",
    "playwright": "@playwright/mcp@0.0.77",
}
PRODUCTION_MODE = False
PACKAGE_OVERRIDE_ENVS = {
    "brave-search": "B_AGENTIC_BRAVE_MCP_PACKAGE",
    "firecrawl": "B_AGENTIC_FIRECRAWL_MCP_PACKAGE",
    "playwright": "B_AGENTIC_PLAYWRIGHT_MCP_PACKAGE",
}
CONTEXT7_URL = "https://mcp.context7.com/mcp"


@dataclass
class NormalizedServer:
    """Launcher shape normalized across the three runtime config schemas."""

    command: str | None
    args: list[str] | None
    env: dict | None
    headers: dict | None


class RuntimeStyle:
    CLAUDE = "claude"
    OPENCODE = "opencode"
    CODEX = "codex"
    ANTIGRAVITY = "antigravity"
    CURSOR = "cursor"


def load_json(path: Path) -> dict:
    return load_jsonc(path.read_text())


def load_toml(path: Path) -> dict:
    try:
        import tomllib
    except ModuleNotFoundError as exc:  # pragma: no cover - depends on runtime python
        raise SystemExit("Codex MCP doctor requires Python 3.11+ (stdlib tomllib).") from exc
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
    env_name = PACKAGE_OVERRIDE_ENVS.get(server)
    if env_name:
        return os.environ.get(env_name, DEFAULT_PACKAGES[server])
    return DEFAULT_PACKAGES[server]


def npm_package_name_is_valid(name: str) -> bool:
    if not name or len(name) > 214 or name.lower() != name:
        return False

    if name.startswith("@"):
        parts = name[1:].split("/")
        if len(parts) != 2:
            return False
    elif "/" in name:
        return False
    else:
        parts = [name]

    for part in parts:
        if not part or part in {".", ".."} or part.startswith((".", "_")):
            return False
        if re.fullmatch(r"[a-z0-9-][a-z0-9._-]*", part) is None:
            return False
        if not any(character.isalnum() for character in part):
            return False
    return True


def exact_semver_is_valid(version: str) -> bool:
    match = re.fullmatch(
        r"(?:0|[1-9][0-9]*)\."
        r"(?:0|[1-9][0-9]*)\."
        r"(?:0|[1-9][0-9]*)"
        r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
        r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?",
        version,
    )
    if match is None:
        return False

    prerelease = match.group(1)
    if prerelease is None:
        return True
    return all(
        not (identifier.isdigit() and len(identifier) > 1 and identifier.startswith("0"))
        for identifier in prerelease.split(".")
    )


def package_is_exactly_pinned(package: str) -> bool:
    name, separator, version = package.rpartition("@")
    return bool(separator) and npm_package_name_is_valid(name) and exact_semver_is_valid(version)


def pinned_package_status(server: str, package: object) -> str | None:
    if not isinstance(package, str) or not package:
        return None
    expected = package_name(server)
    env_name = PACKAGE_OVERRIDE_ENVS[server]
    if not package_is_exactly_pinned(package):
        return f"package {package!r} is mutable; set {env_name}=<pinned package> for production"
    if package == expected:
        return None
    if os.environ.get(env_name):
        return f"configured package {package!r} does not match {env_name}={expected!r}; rerun the installer"
    return f"configured package {package!r}; set {env_name}={package} for launcher validation"


def ready_status(base: str, note: str | None) -> str:
    if note and PRODUCTION_MODE:
        return f"blocked: {note}"
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


def normalize_server(entry: dict, style: str) -> NormalizedServer:
    """Return a common launcher view for Claude/Codex (string command) and OpenCode (list command)."""
    command = entry.get("command")
    args = entry.get("args")
    env = entry.get("env")
    headers = entry.get("headers")

    if style == RuntimeStyle.OPENCODE:
        if isinstance(command, list) and command:
            args = command[1:]
            command = command[0]
        env = entry.get("environment")
    elif style == RuntimeStyle.CODEX:
        headers = entry.get("http_headers")

    return NormalizedServer(
        command if isinstance(command, str) else None,
        args if isinstance(args, list) else None,
        env if isinstance(env, dict) else None,
        headers if isinstance(headers, dict) else None,
    )


def join_issues(issues: list[str]) -> str:
    return "; ".join(issues)


def _check_serena(server: NormalizedServer, context: str) -> str:
    if server.command != "serena" or not serena_args_match(server.args, context):
        return "blocked: invalid serena launcher"
    return "ready: serena command found" if command_ready("serena") else "blocked: install serena"


def _check_codegraph(server: NormalizedServer) -> str:
    if server.command != "codegraph" or not list_matches(server.args, ["serve", "--mcp"]):
        return "blocked: invalid codegraph launcher"
    return "ready: codegraph command found" if command_ready("codegraph") else "blocked: install codegraph"


def _check_playwright(server: NormalizedServer) -> str:
    package_ref = server.args[1] if isinstance(server.args, list) and len(server.args) > 1 else None
    pinned_status = pinned_package_status("playwright", package_ref)
    expected_args = ["dlx", package_name("playwright"), "--isolated"]
    if (
        server.command != "pnpm"
        or (pinned_status and not args_shape_matches("playwright", server.args))
        or (not pinned_status and not list_matches(server.args, expected_args))
    ):
        return "blocked: invalid playwright launcher"
    return ready_status("pnpm available", pinned_status) if command_ready("pnpm") else "blocked: install pnpm"


def _check_brave_or_firecrawl(
    server: NormalizedServer,
    server_name: str,
    env_key: str,
    env_value: str | None,
) -> str:
    """Check a brave-search or firecrawl launcher.

    `env_value` must be the effective resolved value: a literal configured key,
    a resolved environment-variable value, or None if no key is available.
    """
    issues: list[str] = []
    package_ref = server.args[1] if isinstance(server.args, list) and len(server.args) > 1 else None
    pinned_status = pinned_package_status(server_name, package_ref)
    expected_args = (
        ["dlx", package_name("brave-search"), "--transport", "stdio"]
        if server_name == "brave-search"
        else ["dlx", package_name("firecrawl")]
    )
    if (
        server.command != "pnpm"
        or (pinned_status and not args_shape_matches(server_name, server.args))
        or (not pinned_status and not list_matches(server.args, expected_args))
    ):
        issues.append(f"invalid {server_name} launcher")
    if not command_ready("pnpm"):
        issues.append("install pnpm")
    if not env_value:
        issues.append(f"set {env_key}")
    if issues:
        return f"blocked: {join_issues(issues)}"
    return ready_status(f"pnpm and {env_key} available", pinned_status)


def claude_server_status(server: str, config: dict) -> str:
    servers = config.get("mcpServers", {})
    entry = servers.get(server)
    if not isinstance(entry, dict):
        return "missing: config entry not installed"

    normalized = normalize_server(entry, RuntimeStyle.CLAUDE)

    if server == "serena":
        return _check_serena(normalized, "claude-code")
    if server == "context7":
        if entry.get("type") != "http" or entry.get("url") != CONTEXT7_URL:
            return "blocked: invalid context7 config"
        return "ready: CONTEXT7_API_KEY available" if env_var_present("CONTEXT7_API_KEY") else "blocked: missing CONTEXT7_API_KEY"
    if server == "codegraph":
        return _check_codegraph(normalized)
    if server == "playwright":
        return _check_playwright(normalized)

    env_key = "BRAVE_API_KEY" if server == "brave-search" else "FIRECRAWL_API_KEY"
    env_value = os.environ.get(env_key) if env_var_present(env_key) else None
    return _check_brave_or_firecrawl(normalized, server, env_key, env_value)


def antigravity_server_status(server: str, config: dict) -> str:
    servers = config.get("mcpServers", {})
    entry = servers.get(server)
    if not isinstance(entry, dict):
        return "missing: config entry not installed"

    normalized = normalize_server(entry, RuntimeStyle.ANTIGRAVITY)

    if server == "serena":
        return _check_serena(normalized, "antigravity")
    if server == "context7":
        if entry.get("type") != "remote" or entry.get("serverUrl") != CONTEXT7_URL:
            return "blocked: invalid context7 config"
        return "ready: CONTEXT7_API_KEY available" if env_var_present("CONTEXT7_API_KEY") else "blocked: missing CONTEXT7_API_KEY"
    if server == "codegraph":
        return _check_codegraph(normalized)
    if server == "playwright":
        return _check_playwright(normalized)

    env_key = "BRAVE_API_KEY" if server == "brave-search" else "FIRECRAWL_API_KEY"
    env_value = os.environ.get(env_key) if env_var_present(env_key) else None
    return _check_brave_or_firecrawl(normalized, server, env_key, env_value)


def cursor_server_status(server: str, config: dict) -> str:
    servers = config.get("mcpServers", {})
    entry = servers.get(server)
    if not isinstance(entry, dict):
        return "missing: config entry not installed"

    normalized = normalize_server(entry, RuntimeStyle.CURSOR)

    if server == "serena":
        return _check_serena(normalized, "ide")
    if server == "context7":
        if entry.get("type") != "http" or entry.get("url") != CONTEXT7_URL:
            return "blocked: invalid context7 config"
        return "ready: CONTEXT7_API_KEY available" if env_var_present("CONTEXT7_API_KEY") else "blocked: missing CONTEXT7_API_KEY"
    if server == "codegraph":
        return _check_codegraph(normalized)
    if server == "playwright":
        return _check_playwright(normalized)

    env_key = "BRAVE_API_KEY" if server == "brave-search" else "FIRECRAWL_API_KEY"
    env_value = os.environ.get(env_key) if env_var_present(env_key) else None
    return _check_brave_or_firecrawl(normalized, server, env_key, env_value)


def json_mcp_server_status(server: str, config: dict) -> str:
    servers = config.get("mcp", {})
    entry = servers.get(server)
    if not isinstance(entry, dict):
        return "missing: config entry not installed"

    normalized = normalize_server(entry, RuntimeStyle.OPENCODE)

    if server == "serena":
        return _check_serena(normalized, "ide")
    if server == "context7":
        if entry.get("type") != "remote" or entry.get("url") != CONTEXT7_URL:
            return "blocked: invalid context7 config"
        return "ready: CONTEXT7_API_KEY available" if env_var_present("CONTEXT7_API_KEY") else "blocked: missing CONTEXT7_API_KEY"
    if server == "codegraph":
        return _check_codegraph(normalized)
    if server == "playwright":
        return _check_playwright(normalized)

    env_key = "BRAVE_API_KEY" if server == "brave-search" else "FIRECRAWL_API_KEY"
    env_value = os.environ.get(env_key) if env_var_present(env_key) else None
    return _check_brave_or_firecrawl(normalized, server, env_key, env_value)




def _codex_env_value(entry: dict, env_key: str) -> str | None:
    """Return the effective API key value for a Codex brave/firecrawl server.

    A literal key name (e.g. "BRAVE_API_KEY") in the env table is treated as an
    env-variable binding. Empty, missing, or non-dict env sections fall back to
    the environment variable of the same name when present.
    """
    env_section = entry.get("env", {})
    if isinstance(env_section, dict):
        env_value = env_section.get(env_key)
        if isinstance(env_value, str) and env_value:
            if env_value == env_key:
                return os.environ.get(env_key) if env_var_present(env_key) else None
            return env_value
    return os.environ.get(env_key) if env_var_present(env_key) else None


def codex_server_status(server: str, config: dict) -> str:
    servers = config.get("mcp_servers", {})
    entry = servers.get(server)
    if not isinstance(entry, dict):
        return "missing: config entry not installed"

    normalized = normalize_server(entry, RuntimeStyle.CODEX)

    if server == "serena":
        return _check_serena(normalized, "codex")
    if server == "context7":
        if entry.get("url") != CONTEXT7_URL:
            return "blocked: invalid context7 config"
        # Codex uses literal key names (e.g. "CONTEXT7_API_KEY") in http_headers as env bindings.
        headers = entry.get("http_headers", {})
        if isinstance(headers, dict):
            context7_value = headers.get("CONTEXT7_API_KEY")
            if isinstance(context7_value, str) and context7_value:
                if context7_value == "CONTEXT7_API_KEY":
                    return (
                        "ready: CONTEXT7_API_KEY env binding configured in Codex config"
                        if env_var_present("CONTEXT7_API_KEY")
                        else "blocked: missing CONTEXT7_API_KEY; env binding configured in Codex config"
                    )
                return "ready: CONTEXT7_API_KEY configured in Codex config"
        return "ready: CONTEXT7_API_KEY available" if env_var_present("CONTEXT7_API_KEY") else "blocked: missing CONTEXT7_API_KEY"
    if server == "codegraph":
        return _check_codegraph(normalized)
    if server == "playwright":
        return _check_playwright(normalized)

    env_key = "BRAVE_API_KEY" if server == "brave-search" else "FIRECRAWL_API_KEY"
    env_value = _codex_env_value(entry, env_key)
    return _check_brave_or_firecrawl(normalized, server, env_key, env_value)


def resolve_config_path(runtime: dict, home: Path) -> Path:
    config_path = runtime.get("config_install_path")
    if not isinstance(config_path, str):
        raise ValueError("runtime has no config_install_path")
    if config_path.startswith("~/"):
        return home / config_path[2:]
    return Path(config_path).expanduser()


def main() -> int:
    global PRODUCTION_MODE

    parser = argparse.ArgumentParser(description="Check installed b-agentic MCP readiness for a runtime.")
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--home", default=str(Path.home()), help="Home directory to inspect. Defaults to current HOME.")
    parser.add_argument(
        "--production",
        action="store_true",
        help="Deprecated (strict check is now the default).",
    )
    parser.add_argument(
        "--allow-degraded",
        action="store_true",
        help="Exit zero even for missing/blocked MCP readiness and mutable packages.",
    )
    args = parser.parse_args()
    PRODUCTION_MODE = not args.allow_degraded

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
    elif schema_family == "antigravity-json":
        config = load_json(config_path)
        status_fn = antigravity_server_status
    elif schema_family == "cursor-json":
        config = load_json(config_path)
        status_fn = cursor_server_status
    else:
        config = load_json(config_path)
        status_fn = json_mcp_server_status

    print(f"runtime: {args.runtime}")
    print(f"config: {config_path}")
    print("startup-check: not attempted; validates local launchers, keys, and config shape only")
    blocked = False
    for server in SUPPORTED_SERVERS:
        status = status_fn(server, config)
        print(f"{server}: {status}")
        blocked = blocked or status.startswith(("blocked:", "missing:"))
    if PRODUCTION_MODE and blocked:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
