#!/usr/bin/env python3
"""JSON cleanup helpers for removing managed config entries from merged files.

Used by both the interactive installer (common.sh) and the manifest-only
uninstaller (manifest_uninstall.py) so they apply the same merge-inversion
logic and normalize upgraded MCP launchers consistently.
"""

import json
from pathlib import Path

from jsonc import loads as load_jsonc

MISSING = object()


def cleanup(current_value, incoming_value, original_value):
    """Recursively remove values introduced by `incoming` from `current`.

    Values that existed in `original` are preserved in their original form.
    Values that were added by b-agentic are removed. Mixed containers are
    cleaned recursively and pruned when empty.
    """
    if isinstance(current_value, dict) and isinstance(incoming_value, dict):
        original_dict = original_value if isinstance(original_value, dict) else {}
        result = dict(current_value)
        for key, incoming_child in incoming_value.items():
            if key not in result:
                continue
            original_child = original_dict.get(key, MISSING)
            current_child = result[key]
            if original_child is MISSING:
                if current_child == incoming_child:
                    result.pop(key)
                elif isinstance(current_child, (dict, list)) and isinstance(incoming_child, type(current_child)):
                    empty_original = {} if isinstance(current_child, dict) else []
                    cleaned = cleanup(current_child, incoming_child, empty_original)
                    if cleaned in ({}, []):
                        result.pop(key)
                    else:
                        result[key] = cleaned
            else:
                result[key] = cleanup(current_child, incoming_child, original_child)
        return result

    if isinstance(current_value, list) and isinstance(incoming_value, list):
        original_list = original_value if isinstance(original_value, list) else []
        result = list(current_value)
        for item in incoming_value:
            if item not in original_list and item in result:
                result.remove(item)
        return result

    return current_value


def _merged_sequence(existing_items, incoming_items):
    merged = list(existing_items)
    for item in incoming_items:
        if item not in merged:
            merged.append(item)
    return merged


def _normalize_managed_launcher(normalized, incoming_server, old_command, old_args=None):
    incoming_command = incoming_server.get("command")
    if isinstance(incoming_command, str) and isinstance(old_command, str):
        legacy_args = [old_args]
        if isinstance(old_args, list):
            legacy_args.append(_merged_sequence(old_args, incoming_server.get("args", [])))
        if normalized.get("command") == old_command and normalized.get("args") in legacy_args:
            normalized["command"] = incoming_command
            normalized["args"] = list(incoming_server.get("args", []))
        return

    if isinstance(incoming_command, list) and isinstance(old_command, list):
        legacy_commands = [list(old_command), _merged_sequence(old_command, incoming_command)]
        if normalized.get("command") in legacy_commands:
            normalized["command"] = list(incoming_command)


def managed_mcp_server(current_server, incoming_server, server_name):
    """Return True if current_server matches the managed template for server_name."""
    if not isinstance(current_server, dict) or not isinstance(incoming_server, dict):
        return False
    normalized = json.loads(json.dumps(current_server))

    def remove_managed_key(section_name, key_name):
        section = normalized.get(section_name)
        if isinstance(section, dict) and key_name in section:
            section.pop(key_name, None)
            if not section:
                normalized.pop(section_name, None)

    if server_name == "context7":
        headers = normalized.get("headers")
        incoming_headers = incoming_server.get("headers", {})
        if isinstance(headers, dict) and isinstance(incoming_headers, dict) and "CONTEXT7_API_KEY" in headers:
            headers["CONTEXT7_API_KEY"] = incoming_headers.get("CONTEXT7_API_KEY")
    elif server_name == "brave-search":
        env_key = "environment" if "environment" in incoming_server else "env"
        env = normalized.get(env_key)
        incoming_env = incoming_server.get(env_key, {})
        if isinstance(env, dict) and isinstance(incoming_env, dict) and "BRAVE_API_KEY" in env:
            env["BRAVE_API_KEY"] = incoming_env.get("BRAVE_API_KEY")
        if env_key == "env":
            _normalize_managed_launcher(
                normalized,
                incoming_server,
                "npx",
                ["-y", "@brave/brave-search-mcp-server", "--transport", "stdio"],
            )
            _normalize_managed_launcher(
                normalized,
                incoming_server,
                "bunx",
                ["@brave/brave-search-mcp-server", "--transport", "stdio"],
            )
        else:
            _normalize_managed_launcher(
                normalized,
                incoming_server,
                ["npx", "-y", "@brave/brave-search-mcp-server", "--transport", "stdio"],
            )
            _normalize_managed_launcher(
                normalized,
                incoming_server,
                ["bunx", "@brave/brave-search-mcp-server", "--transport", "stdio"],
            )
    elif server_name == "firecrawl":
        env_key = "environment" if "environment" in incoming_server else "env"
        env = normalized.get(env_key)
        incoming_env = incoming_server.get(env_key, {})
        if isinstance(env, dict) and isinstance(incoming_env, dict) and "FIRECRAWL_API_KEY" in env:
            env["FIRECRAWL_API_KEY"] = incoming_env.get("FIRECRAWL_API_KEY")
        if env_key == "env":
            _normalize_managed_launcher(normalized, incoming_server, "npx", ["-y", "firecrawl-mcp"])
            _normalize_managed_launcher(normalized, incoming_server, "bunx", ["firecrawl-mcp"])
        else:
            _normalize_managed_launcher(normalized, incoming_server, ["npx", "-y", "firecrawl-mcp"])
            _normalize_managed_launcher(normalized, incoming_server, ["bunx", "firecrawl-mcp"])
    elif server_name == "playwright":
        if isinstance(incoming_server.get("command"), str):
            _normalize_managed_launcher(normalized, incoming_server, "npx", ["-y", "@playwright/mcp@latest", "--isolated"])
            _normalize_managed_launcher(normalized, incoming_server, "bunx", ["@playwright/mcp@latest", "--isolated"])
        else:
            _normalize_managed_launcher(
                normalized,
                incoming_server,
                ["npx", "-y", "@playwright/mcp@latest", "--isolated"],
            )
            _normalize_managed_launcher(
                normalized,
                incoming_server,
                ["bunx", "@playwright/mcp@latest", "--isolated"],
            )
    return normalized == incoming_server


def remove_managed_json_config(current_path: Path, template_path: Path, original_path: Path | None, label: str):
    """Return `current` with all managed entries from `template` removed.

    If `original_path` is provided, entries that existed before installation are
    preserved. When `original_path` is None, the file did not exist before
    installation, so any matching template entry is removed entirely.
    """
    current = load_jsonc(current_path.read_text())
    incoming = json.loads(template_path.read_text())
    original = {} if original_path is None else load_jsonc(original_path.read_text())

    if not isinstance(current, dict) or not isinstance(incoming, dict) or not isinstance(original, dict):
        raise ValueError(f"{label} cleanup requires JSON object inputs")

    cleaned = cleanup(current, incoming, original)
    mcp_labels = {
        ".claude.json": "mcpServers",
        "opencode.json": "mcp",
        "mcp_config.json": "mcpServers",
        "mcp.json": "mcpServers",
    }
    mcp_key = mcp_labels.get(label)
    if mcp_key is not None:
        cleaned_servers = cleaned.get(mcp_key)
        incoming_servers = incoming.get(mcp_key, {})
        original_servers = original.get(mcp_key, {})
        if isinstance(cleaned_servers, dict) and isinstance(incoming_servers, dict):
            for server_name in incoming_servers:
                cleaned_server = cleaned_servers.get(server_name)
                if not isinstance(original_servers, dict) or server_name not in original_servers:
                    if cleaned_server in (None, {}, []):
                        cleaned_servers.pop(server_name, None)
                    continue
                if managed_mcp_server(cleaned_server, incoming_servers.get(server_name), server_name):
                    cleaned_servers.pop(server_name, None)
            if not cleaned_servers:
                cleaned.pop(mcp_key, None)
    return cleaned
