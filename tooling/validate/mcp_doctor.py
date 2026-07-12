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
try:
    from tooling.validate.session_readiness import check_session_tools
except ModuleNotFoundError:  # Direct execution: tooling/validate is on sys.path.
    from session_readiness import check_session_tools

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
    """Launcher shape normalized across the runtime config schemas."""

    command: str | None
    args: list[str] | None
    env: dict | None
    headers: dict | None


class RuntimeStyle:
    PI = "pi"


def load_json(path: Path) -> dict:
    return load_jsonc(path.read_text())


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
    """Return a common launcher view across runtime config schemas."""
    command = entry.get("command")
    args = entry.get("args")
    env = entry.get("env")
    headers = entry.get("headers")

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


def pi_mcp_adapter_ready(home: Path) -> tuple[bool, str]:
    """Return whether the pinned pi-mcp-adapter package appears installed for home."""
    if shutil.which("pi") is None:
        return False, "missing: pi CLI not installed"
    import os
    import subprocess

    # Bind Pi to the target home so sandbox / --home checks do not pick up a
    # global adapter install under a different HOME.
    env = dict(os.environ)
    env["HOME"] = str(home)
    env["PI_CODING_AGENT_DIR"] = str(home / ".pi" / "agent")

    completed = subprocess.run(
        ["pi", "list"],
        capture_output=True,
        text=True,
        env=env,
    )
    listing = f"{completed.stdout}\n{completed.stderr}"
    if "pi-mcp-adapter@2.11.0" in listing or re.search(r"pi-mcp-adapter.*2\.11\.0", listing):
        return True, "ready: pi-mcp-adapter@2.11.0 installed"
    return False, "missing: pi-mcp-adapter@2.11.0 not installed; run pi install npm:pi-mcp-adapter@2.11.0"


def pi_server_status(server: str, config: dict) -> str:
    servers = config.get("mcpServers", {})
    entry = servers.get(server)
    if not isinstance(entry, dict):
        return "missing: config entry not installed"

    normalized = normalize_server(entry, RuntimeStyle.PI)

    if server == "serena":
        return _check_serena(normalized, "ide")
    if server == "context7":
        if entry.get("url") != CONTEXT7_URL:
            return "blocked: invalid context7 config"
        return "ready: CONTEXT7_API_KEY available" if env_var_present("CONTEXT7_API_KEY") else "blocked: missing CONTEXT7_API_KEY"
    if server == "codegraph":
        return _check_codegraph(normalized)
    if server == "playwright":
        return _check_playwright(normalized)

    env_key = "BRAVE_API_KEY" if server == "brave-search" else "FIRECRAWL_API_KEY"
    env_value = os.environ.get(env_key) if env_var_present(env_key) else None
    return _check_brave_or_firecrawl(normalized, server, env_key, env_value)


def readiness_ladder(server: str, status: str) -> str:
    """Describe evidence levels without promoting local checks to live proof."""
    configured = not status.startswith("missing:")
    launcher = "ready" if status.startswith("ready:") else "blocked"
    if not configured:
        auth = "not assessed (server is not configured)"
    elif server in {"context7", "brave-search", "firecrawl"}:
        auth = "local key/config check passed" if launcher == "ready" else "not established"
    else:
        auth = "not required by configured launcher"
    initialized = "not observed (run runtime-specific onboarding/indexing where applicable)"
    live = "not proven (requires an operator-observed representative tool call)"
    return (
        f"configured: {'yes' if configured else 'no'}; launcher-ready: {launcher}; authenticated: {auth}; "
        f"initialized/indexed: {initialized}; live-call-proven: {live}"
    )


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
    parser.add_argument("--runtime", help="Runtime whose installed MCP configuration to inspect.")
    parser.add_argument("--home", default=str(Path.home()), help="Home directory to inspect. Defaults to current HOME.")
    parser.add_argument(
        "--session-tools",
        action="store_true",
        help="Check active-session RTK and required shell tools only; does not inspect runtime config.",
    )
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

    if args.session_tools:
        ready, detail = check_session_tools()
        print(f"session-tools: {detail}")
        return 0 if ready else 1
    if not args.runtime:
        parser.error("--runtime is required unless --session-tools is used")

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
    if schema_family == "pi-json":
        config = load_json(config_path)
        status_fn = pi_server_status
    else:
        print(f"unsupported runtime config schema: {schema_family}", file=sys.stderr)
        return 2

    print(f"runtime: {args.runtime}")
    print(f"config: {config_path}")
    print("startup-check: not attempted; validates local launchers, keys, and config shape only")
    blocked = False
    if schema_family == "pi-json":
        adapter_ready, adapter_status = pi_mcp_adapter_ready(home)
        print(f"mcp-adapter: {adapter_status}")
        blocked = blocked or not adapter_ready
    for server in SUPPORTED_SERVERS:
        status = status_fn(server, config)
        print(f"{server}: {status}")
        print(f"{server} readiness: {readiness_ladder(server, status)}")
        blocked = blocked or status.startswith(("blocked:", "missing:"))
    if PRODUCTION_MODE and blocked:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
