#!/usr/bin/env python3
"""Minimal MCP stdio server exposing validate_action from tooling.state.validator."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

# Ensure the repo root is on sys.path so `tooling.*` imports resolve when the
# server is run directly (e.g. `python3 tooling/mcp/.../server.py`).
_REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

TOOL_NAME = "validate_action"
TOOL_DESCRIPTION = (
    "Validate a runtime action against b-agentic state and intent. "
    "Returns a Decision with verdict (allow/block/advisory), reason, risk class, and capability."
)
TOOL_SCHEMA = {
    "type": "object",
    "properties": {
        "root": {
            "type": "string",
            "description": "Repo root path to resolve .b-agentic/state.json from. Defaults to '.'.",
        },
        "payload": {
            "type": "object",
            "description": "Runtime action payload (tool name, command, files, etc.).",
        },
        "runtime": {
            "type": "string",
            "description": "Runtime identifier (e.g. 'claude-code').",
        },
        "strict": {
            "type": "boolean",
            "description": "Enable strict blocking mode. Defaults to false.",
        },
        "transcript": {
            "type": "string",
            "description": "Recent transcript text to extract machine-readable intent from.",
        },
    },
    "required": ["payload", "runtime"],
}


def _respond(request_id: Any, result: Any) -> None:
    msg = json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result})
    sys.stdout.write(msg + "\n")
    sys.stdout.flush()


def _error(request_id: Any, code: int, message: str) -> None:
    msg = json.dumps({"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}})
    sys.stdout.write(msg + "\n")
    sys.stdout.flush()


def _handle_initialize(request_id: Any) -> None:
    _respond(request_id, {
        "protocolVersion": "2024-11-05",
        "capabilities": {"tools": {}},
        "serverInfo": {"name": "b-agentic-state-server", "version": "1.0.0"},
    })


def _handle_tools_list(request_id: Any) -> None:
    _respond(request_id, {
        "tools": [{
            "name": TOOL_NAME,
            "description": TOOL_DESCRIPTION,
            "inputSchema": TOOL_SCHEMA,
        }]
    })


def _handle_tools_call(request_id: Any, params: dict[str, Any]) -> None:
    if params.get("name") != TOOL_NAME:
        _error(request_id, -32602, f"unknown tool: {params.get('name')!r}")
        return

    args = params.get("arguments") or params.get("input") or {}
    root = Path(args.get("root", ".")).resolve()
    payload = args.get("payload", {})
    runtime = args.get("runtime", "")
    strict = args.get("strict", False)
    transcript = args.get("transcript")

    if not runtime:
        _error(request_id, -32602, "runtime is required")
        return

    try:
        from tooling.state.validator import validate_action
        decision = validate_action(root, payload, runtime=runtime, strict=strict, transcript=transcript)
        _respond(request_id, {
            "content": [{
                "type": "text",
                "text": json.dumps({
                    "verdict": decision.verdict,
                    "reason": decision.reason,
                    "risk": decision.risk,
                    "capability": decision.capability,
                    "allowed": decision.allowed,
                }),
            }]
        })
    except Exception as exc:
        _error(request_id, -32603, f"validate_action failed: {exc}")


def _serve() -> None:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError as exc:
            sys.stderr.write(f"JSON parse error: {exc}\n")
            continue

        request_id = msg.get("id")
        method = msg.get("method", "")

        if method == "initialize":
            _handle_initialize(request_id)
        elif method == "notifications/initialized":
            pass
        elif method == "tools/list":
            _handle_tools_list(request_id)
        elif method == "tools/call":
            _handle_tools_call(request_id, msg.get("params", {}))
        elif request_id is not None:
            _error(request_id, -32601, f"method not found: {method!r}")


def main() -> int:
    parser = argparse.ArgumentParser(description="b-agentic MCP state validation server (stdio transport).")
    parser.parse_args()
    _serve()
    return 0


if __name__ == "__main__":
    sys.exit(main())
