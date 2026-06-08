"""Smoke tests for the MCP JSON-RPC protocol layer of b-agentic-state-server."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
SERVER = REPO_ROOT / "tooling" / "mcp" / "b-agentic-state-server" / "server.py"


def _start_server():
    return subprocess.Popen(
        [sys.executable, str(SERVER)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    )


def _rpc(proc, method, params=None, req_id=1):
    msg = {"jsonrpc": "2.0", "id": req_id, "method": method}
    if params is not None:
        msg["params"] = params
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()
    return json.loads(proc.stdout.readline())


def test_initialize_returns_protocol_version():
    proc = _start_server()
    try:
        resp = _rpc(proc, "initialize")
        assert resp["result"]["protocolVersion"] == "2024-11-05"
        assert "tools" in resp["result"]["capabilities"]
        assert resp["result"]["serverInfo"]["name"] == "b-agentic-state-server"
    finally:
        proc.kill()
        proc.wait()


def test_tools_list_returns_validate_action():
    proc = _start_server()
    try:
        _rpc(proc, "initialize")
        # send notification (no id, no response expected)
        proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        proc.stdin.flush()
        resp = _rpc(proc, "tools/list", req_id=2)
        tools = resp["result"]["tools"]
        assert len(tools) == 1
        assert tools[0]["name"] == "validate_action"
        assert "inputSchema" in tools[0]
    finally:
        proc.kill()
        proc.wait()


def test_validate_action_read_tool_returns_allow(tmp_path):
    proc = _start_server()
    try:
        _rpc(proc, "initialize")
        resp = _rpc(proc, "tools/call", {
            "name": "validate_action",
            "arguments": {
                "root": str(tmp_path),
                "payload": {"tool": "read"},
                "runtime": "claude-code",
            },
        }, req_id=2)
        content = json.loads(resp["result"]["content"][0]["text"])
        assert content["verdict"] == "allow"
        assert content["allowed"] is True
        assert "reason" in content
    finally:
        proc.kill()
        proc.wait()


def test_unknown_tool_name_returns_error():
    proc = _start_server()
    try:
        _rpc(proc, "initialize")
        resp = _rpc(proc, "tools/call", {
            "name": "nonexistent_tool",
            "arguments": {},
        }, req_id=2)
        assert "error" in resp
        assert resp["error"]["code"] == -32602
    finally:
        proc.kill()
        proc.wait()


def test_missing_runtime_returns_error(tmp_path):
    proc = _start_server()
    try:
        _rpc(proc, "initialize")
        resp = _rpc(proc, "tools/call", {
            "name": "validate_action",
            "arguments": {
                "root": str(tmp_path),
                "payload": {"tool": "write"},
            },
        }, req_id=2)
        assert "error" in resp
        assert "runtime" in resp["error"]["message"]
    finally:
        proc.kill()
        proc.wait()
