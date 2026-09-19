#!/usr/bin/env python3

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
try:
    from tooling.validate.mcp_probe import (
        ProbeError,
        build_drift_records,
        build_suggestion_report,
        compare_conditional_schemas,
        compare_inventory,
        format_drift_record,
        probe_server,
    )
    from tooling.validate.session_readiness import check_session_tools
except ModuleNotFoundError:
    from mcp_probe import (
        ProbeError,
        build_drift_records,
        build_suggestion_report,
        compare_conditional_schemas,
        compare_inventory,
        format_drift_record,
        probe_server,
    )
    from session_readiness import check_session_tools


def load_jsonc(text: str) -> object:
    module_path = ROOT / "tooling" / "install" / "jsonc.py"
    spec = importlib.util.spec_from_file_location("b_agentic_jsonc", module_path)
    if spec is None or spec.loader is None:
        raise OSError(f"cannot load JSONC parser: {module_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.loads(text)


SUPPORTED_SERVERS = ("codegraph", "context7", "brave-search", "firecrawl", "playwright", "shadcn")
CONTEXT7_URL = "https://mcp.context7.com/mcp"
POLICY_PATH = ROOT / "references" / "mcp_operations.yaml"


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


def configured_secret(entry: dict, section: str, key: str) -> bool:
    values = entry.get(section)
    if not isinstance(values, dict):
        return False
    value = values.get(key)
    return isinstance(value, str) and bool(value) and not value.startswith("$")


def credential_available(entry: dict, section: str, key: str) -> bool:
    return bool(os.environ.get(key)) or configured_secret(entry, section, key)


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


def write_suggestion_report(path: Path, report: dict) -> bool:
    try:
        path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    except OSError as exc:
        print(f"policy-suggestions-json: blocked: {exc}", file=sys.stderr)
        return False
    print(f"policy-suggestions-json: wrote {path}")
    return True


def emit_blocked_suggestions(path: Path | None, server: str, reason: str) -> bool:
    print(f"policy-suggestion-error server={server} reason={reason}")
    print("policy-suggestions: blocked; probed=none policy-change-applied=no")
    if path is None:
        return True
    return write_suggestion_report(
        path,
        build_suggestion_report([], [], [{"server": server, "reason": reason}]),
    )


def pi_server_status(server: str, config: dict) -> str:
    entry = config.get("mcpServers", {}).get(server)
    if not isinstance(entry, dict):
        return "missing: config entry not installed"
    normalized = normalize_server(entry)
    if server == "codegraph":
        valid = normalized.command == "codegraph" and normalized.args == ["serve", "--mcp"]
        return (
            "ready: codegraph command found"
            if valid and command_ready("codegraph")
            else "blocked: invalid or unavailable codegraph launcher"
        )
    if server == "context7":
        return (
            "ready: CONTEXT7_API_KEY available"
            if entry.get("url") == CONTEXT7_URL and credential_available(entry, "headers", "CONTEXT7_API_KEY")
            else "blocked: invalid context7 config or missing CONTEXT7_API_KEY"
        )
    expected = {
        "brave-search": ["@brave/brave-search-mcp-server", "--transport", "stdio"],
        "firecrawl": ["firecrawl-mcp"],
        "playwright": ["@playwright/mcp", "--isolated", "--headless", "--caps=testing"],
        "shadcn": ["shadcn@latest", "mcp"],
    }[server]
    if normalized.command != "bunx" or normalized.args != expected:
        return f"blocked: invalid {server} launcher"
    if not command_ready("bunx"):
        return "blocked: install Bun (bunx)"
    if server == "brave-search" and not credential_available(entry, "env", "BRAVE_API_KEY"):
        return "blocked: set BRAVE_API_KEY"
    if server == "firecrawl" and not credential_available(entry, "env", "FIRECRAWL_API_KEY"):
        return "blocked: set FIRECRAWL_API_KEY"
    return "ready: launcher and local prerequisites available"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check installed b-agentic Pi MCP configuration and local prerequisites."
    )
    parser.add_argument("--home", default=str(Path.home()), help="Home directory to inspect. Defaults to current HOME.")
    parser.add_argument("--session-tools", action="store_true", help="Check active-session RTK support only.")
    parser.add_argument(
        "--allow-degraded", action="store_true", help="Exit zero even for missing or blocked MCP readiness."
    )
    parser.add_argument(
        "--probe-schemas",
        action="store_true",
        help="Explicitly start/connect to configured MCP servers and compare live tool IDs with canonical policy.",
    )
    parser.add_argument("--probe-timeout", type=float, default=20.0, help="Per-response live probe timeout in seconds.")
    parser.add_argument(
        "--suggestions",
        action="store_true",
        help="Emit human-readable review suggestions for explicitly probed schema drift; never changes policy.",
    )
    parser.add_argument(
        "--suggestions-json",
        type=Path,
        help="Write machine-readable review suggestions to this path; implies --suggestions.",
    )
    args = parser.parse_args()
    if args.session_tools:
        ready, detail = check_session_tools()
        print(f"session-tools: {detail}")
        return 0 if ready else 1

    suggestions_requested = args.suggestions or args.suggestions_json is not None
    if suggestions_requested and not args.probe_schemas:
        parser.error("--suggestions and --suggestions-json require --probe-schemas")

    home = Path(args.home).expanduser()
    config_path = home / ".pi" / "agent" / "mcp.json"
    if not config_path.exists():
        print(f"agent: Pi\nconfig: {config_path}\nstatus: missing Pi config")
        report_ok = True
        if suggestions_requested:
            report_ok = emit_blocked_suggestions(
                args.suggestions_json,
                "<config>",
                "missing Pi config",
            )
        return 0 if args.allow_degraded and report_ok else 1
    try:
        config = validate_config(load_jsonc(config_path.read_text()))
    except (OSError, ValueError) as exc:
        print(f"agent: Pi\nconfig: {config_path}\nstatus: invalid config: {exc}", file=sys.stderr)
        if suggestions_requested:
            emit_blocked_suggestions(
                args.suggestions_json,
                "<config>",
                f"invalid config: {exc}",
            )
        return 1

    adapter_ready, adapter_status = pi_mcp_adapter_ready(home)
    print(
        f"agent: Pi\nconfig: {config_path}\nstartup-check: not attempted; validates local launchers, keys, and config shape only"
    )
    print(f"mcp-adapter: {adapter_status}")
    blocked = not adapter_ready
    suggestion_records: list[dict] = []
    suggestion_probed_servers: list[str] = []
    suggestion_failures: list[dict[str, str]] = []
    for server in SUPPORTED_SERVERS:
        status = pi_server_status(server, config)
        print(f"{server}: {status}")
        blocked = blocked or status.startswith(("blocked:", "missing:"))

    if not args.probe_schemas:
        print(
            "schema-probe: not run; live tool inventory is unverified (run --probe-schemas after MCP updates and before release candidates)"
        )

    if args.probe_schemas:
        try:
            policy = json.loads(POLICY_PATH.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            print(f"schema-probe: blocked: invalid canonical policy: {exc}")
            if suggestions_requested:
                suggestion_failures.append({"server": "<policy>", "reason": str(exc)})
            blocked = True
        else:
            print("schema-probe: explicitly requested; starting/connecting to configured servers")
            for server in SUPPORTED_SERVERS:
                entry = config.get("mcpServers", {}).get(server)
                policy_tools = policy.get("servers", {}).get(server, {}).get("tools", {})
                if not isinstance(entry, dict) or not isinstance(policy_tools, dict):
                    print(f"schema-probe {server}: blocked: missing config or policy entry")
                    if suggestions_requested:
                        suggestion_failures.append({"server": server, "reason": "missing config or policy entry"})
                    blocked = True
                    continue
                try:
                    discovered = probe_server(entry, args.probe_timeout)
                    new_tools, absent_tools = compare_inventory(server, discovered, policy_tools)
                    schema_drift = compare_conditional_schemas(
                        server,
                        discovered,
                        policy.get("conditional_arguments", {}),
                    )
                    if suggestions_requested:
                        suggestion_records.extend(
                            build_drift_records(
                                server,
                                discovered,
                                policy_tools,
                                policy.get("conditional_arguments", {}),
                            )
                        )
                except ProbeError as exc:
                    print(f"schema-probe {server}: blocked: {exc}")
                    if suggestions_requested:
                        suggestion_failures.append({"server": server, "reason": str(exc)})
                    blocked = True
                    continue
                if suggestions_requested:
                    suggestion_probed_servers.append(server)
                state = "drift" if new_tools or absent_tools or schema_drift else "match"
                print(
                    f"schema-probe {server}: {state}: discovered={len(discovered)} "
                    f"new-unclassified={new_tools or 'none'} absent-configured={absent_tools or 'none'} "
                    f"conditional-schema-drift={schema_drift or 'none'}"
                )
                blocked = blocked or bool(new_tools or absent_tools or schema_drift)

    if suggestions_requested:
        if suggestion_records:
            for record in suggestion_records:
                print(format_drift_record(record))
        if suggestion_failures:
            for failure in suggestion_failures:
                print(f"policy-suggestion-error server={failure['server']} reason={failure['reason']}")
            print(
                f"policy-suggestions: incomplete; probed={suggestion_probed_servers or 'none'} policy-change-applied=no"
            )
        elif not suggestion_records:
            print("policy-suggestions: no schema drift records; policy-change-applied=no")
        if args.suggestions_json is not None:
            report = build_suggestion_report(
                suggestion_records,
                suggestion_probed_servers,
                suggestion_failures,
            )
            if not write_suggestion_report(args.suggestions_json, report):
                blocked = True

    return 0 if args.allow_degraded or not blocked else 1


if __name__ == "__main__":
    raise SystemExit(main())
