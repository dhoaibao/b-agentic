#!/usr/bin/env python3
"""Opt-in live MCP startup and tool-inventory probe using the MCP protocol."""

from __future__ import annotations

import argparse
import io
import json
import os
import select
import subprocess
import sys
import time
import urllib.error
import urllib.request
from unittest import mock
from typing import Any


PROTOCOL_VERSION = "2025-11-25"
CLIENT_INFO = {"name": "b-agentic-mcp-doctor", "version": "1"}


class ProbeError(RuntimeError):
    """A sanitized MCP probe failure."""


def initialize_request(request_id: int) -> dict[str, Any]:
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "initialize",
        "params": {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": CLIENT_INFO,
        },
    }


def initialized_notification() -> dict[str, Any]:
    return {"jsonrpc": "2.0", "method": "notifications/initialized"}


def tools_request(request_id: int, cursor: str | None = None) -> dict[str, Any]:
    params = {"cursor": cursor} if cursor else {}
    return {"jsonrpc": "2.0", "id": request_id, "method": "tools/list", "params": params}


def response_result(message: dict[str, Any], request_id: int) -> dict[str, Any]:
    if message.get("id") != request_id:
        raise ProbeError(f"unexpected response id while waiting for {request_id}")
    if "error" in message:
        error = message.get("error")
        code = error.get("code") if isinstance(error, dict) else "unknown"
        raise ProbeError(f"server returned JSON-RPC error {code}")
    result = message.get("result")
    if not isinstance(result, dict):
        raise ProbeError("server response has no object result")
    return result


def collect_tool_inventory(request: Any) -> dict[str, dict[str, Any]]:
    inventory: dict[str, dict[str, Any]] = {}
    cursor: str | None = None
    request_id = 2
    while True:
        result = request(tools_request(request_id, cursor), request_id)
        tools = result.get("tools")
        if not isinstance(tools, list):
            raise ProbeError("tools/list response has no tools array")
        for tool in tools:
            if isinstance(tool, dict) and isinstance(tool.get("name"), str):
                inventory[tool["name"]] = tool
        next_cursor = result.get("nextCursor")
        if not isinstance(next_cursor, str) or not next_cursor:
            return inventory
        cursor = next_cursor
        request_id += 1


def resolve_env_mapping(values: object) -> dict[str, str]:
    if not isinstance(values, dict):
        return {}
    resolved: dict[str, str] = {}
    for key, value in values.items():
        if not isinstance(key, str) or not isinstance(value, str):
            continue
        if value.startswith("${") and value.endswith("}"):
            env_name = value[2:-1]
            env_value = os.environ.get(env_name)
            if env_value is None:
                raise ProbeError(f"required environment variable {env_name} is missing")
            resolved[key] = env_value
        else:
            resolved[key] = value
    return resolved


def probe_stdio(entry: dict[str, Any], timeout: float) -> dict[str, dict[str, Any]]:
    command = entry.get("command")
    args = entry.get("args", [])
    if not isinstance(command, str) or not isinstance(args, list) or not all(isinstance(arg, str) for arg in args):
        raise ProbeError("invalid stdio launcher")
    env = {**os.environ, **resolve_env_mapping(entry.get("env", {}))}
    try:
        process = subprocess.Popen(
            [command, *args],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            env=env,
        )
    except OSError as exc:
        raise ProbeError(f"unable to start {command}: {exc.strerror or exc}") from exc

    def send(message: dict[str, Any]) -> None:
        if process.stdin is None:
            raise ProbeError("server stdin unavailable")
        process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
        process.stdin.flush()

    def receive(request_id: int) -> dict[str, Any]:
        if process.stdout is None:
            raise ProbeError("server stdout unavailable")
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            ready, _, _ = select.select([process.stdout], [], [], max(0.0, deadline - time.monotonic()))
            if not ready:
                break
            line = process.stdout.readline()
            if not line:
                break
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(message, dict) and message.get("id") == request_id:
                return response_result(message, request_id)
        raise ProbeError(f"timed out waiting for JSON-RPC response {request_id}")

    def request(message: dict[str, Any], request_id: int) -> dict[str, Any]:
        send(message)
        return receive(request_id)

    try:
        request(initialize_request(1), 1)
        send(initialized_notification())
        return collect_tool_inventory(request)
    finally:
        if process.stdin:
            process.stdin.close()
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)


def parse_http_message(response: Any, request_id: int) -> dict[str, Any]:
    content_type = response.headers.get("Content-Type", "")
    if "text/event-stream" not in content_type:
        try:
            message = json.loads(response.read())
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise ProbeError("invalid JSON response from HTTP server") from exc
        if not isinstance(message, dict):
            raise ProbeError("HTTP server returned a non-object response")
        return response_result(message, request_id)

    while True:
        line = response.readline()
        if not line:
            break
        if line.startswith(b"data:"):
            try:
                message = json.loads(line[5:].strip())
            except (json.JSONDecodeError, UnicodeDecodeError):
                continue
            if isinstance(message, dict) and message.get("id") == request_id:
                return response_result(message, request_id)
    raise ProbeError(f"HTTP event stream ended before response {request_id}")


def probe_http(entry: dict[str, Any], timeout: float) -> dict[str, dict[str, Any]]:
    url = entry.get("url")
    if not isinstance(url, str):
        raise ProbeError("invalid HTTP endpoint")
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        **resolve_env_mapping(entry.get("headers", {})),
    }
    session_id: str | None = None
    negotiated_version: str | None = None

    def protocol_headers() -> dict[str, str]:
        request_headers = dict(headers)
        if session_id:
            request_headers["MCP-Session-Id"] = session_id
        if negotiated_version:
            request_headers["MCP-Protocol-Version"] = negotiated_version
        return request_headers

    def post(message: dict[str, Any], request_id: int | None) -> dict[str, Any]:
        nonlocal session_id
        request = urllib.request.Request(
            url,
            data=json.dumps(message, separators=(",", ":")).encode(),
            headers=protocol_headers(),
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                received_session = response.headers.get("MCP-Session-Id")
                if received_session:
                    session_id = received_session
                if request_id is None or response.status == 202:
                    return {}
                return parse_http_message(response, request_id)
        except urllib.error.HTTPError as exc:
            raise ProbeError(f"HTTP server returned status {exc.code}") from exc
        except urllib.error.URLError as exc:
            raise ProbeError(f"HTTP connection failed: {exc.reason}") from exc

    def terminate_session() -> None:
        if not session_id:
            return
        request = urllib.request.Request(url, headers=protocol_headers(), method="DELETE")
        try:
            with urllib.request.urlopen(request, timeout=timeout):
                return
        except urllib.error.HTTPError as exc:
            if exc.code == 405:  # Servers may disallow client-initiated termination.
                return
            raise ProbeError(f"HTTP session termination returned status {exc.code}") from exc
        except urllib.error.URLError as exc:
            raise ProbeError(f"HTTP session termination failed: {exc.reason}") from exc

    primary_failure: BaseException | None = None
    try:
        initialization = post(initialize_request(1), 1)
        version = initialization.get("protocolVersion")
        if not isinstance(version, str) or not version:
            raise ProbeError("initialize response has no negotiated protocolVersion")
        negotiated_version = version
        post(initialized_notification(), None)
        return collect_tool_inventory(lambda message, request_id: post(message, request_id))
    except BaseException as exc:
        primary_failure = exc
        raise
    finally:
        try:
            terminate_session()
        except Exception as cleanup_error:
            if primary_failure is None:
                if isinstance(cleanup_error, ProbeError):
                    raise
                raise ProbeError(f"HTTP session termination failed ({type(cleanup_error).__name__})") from cleanup_error


def probe_server(entry: dict[str, Any], timeout: float) -> dict[str, dict[str, Any]]:
    try:
        if isinstance(entry.get("url"), str):
            return probe_http(entry, timeout)
        return probe_stdio(entry, timeout)
    except ProbeError:
        raise
    except Exception as exc:
        transport = "HTTP" if isinstance(entry.get("url"), str) else "stdio"
        raise ProbeError(f"{transport} transport failed ({type(exc).__name__})") from exc


def policy_upstream_name(server: str, policy_tool: str) -> str:
    prefix = server.replace("-", "_") + "_"
    if server in {"codegraph", "context7", "brave-search", "mobbin", "shadcn"} and policy_tool.startswith(prefix):
        return policy_tool[len(prefix) :]
    return policy_tool


def policy_upstream_names(server: str, policy_tools: dict[str, str]) -> set[str]:
    return {policy_upstream_name(server, tool) for tool in policy_tools}


def policy_class_for_upstream(server: str, upstream_tool: str, policy_tools: dict[str, str]) -> str | None:
    for policy_tool, operation_class in policy_tools.items():
        if policy_upstream_name(server, policy_tool) == upstream_tool:
            return operation_class
    return None


def schema_arguments(tool: object) -> list[str]:
    if not isinstance(tool, dict):
        return []
    schema = tool.get("inputSchema")
    properties = schema.get("properties") if isinstance(schema, dict) else None
    return sorted(name for name in properties if isinstance(name, str)) if isinstance(properties, dict) else []


def conservative_tool_suggestion(server: str, tool: str) -> tuple[str | None, str, str]:
    if server == "firecrawl" and tool == "firecrawl_developer_search":
        return (
            "read-only",
            "matches the known Firecrawl developer-search operation used for bounded programming and API research",
            "high",
        )
    return (
        None,
        "manual classification required; no conservative known-safe operation pattern matched",
        "manual",
    )


def conditional_schema_records(
    server: str,
    discovered: dict[str, dict[str, Any]],
    conditional_arguments: dict[str, dict[str, Any]],
) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for key, record in conditional_arguments.items():
        policy_server, _, policy_tool = key.partition(":")
        if policy_server != server or not isinstance(record, dict):
            continue
        upstream_name = policy_upstream_name(server, policy_tool)
        tool = discovered.get(upstream_name)
        if not isinstance(tool, dict):
            continue
        schema = tool.get("inputSchema")
        properties = schema.get("properties") if isinstance(schema, dict) else None
        if not isinstance(properties, dict):
            records.append({"tool": upstream_name, "arguments": [], "reason": "missing-input-properties"})
            continue
        known = set(record.get("known", []))
        added = sorted(set(properties) - known)
        if added:
            records.append({"tool": upstream_name, "arguments": added, "reason": "new-arguments"})
    return records


def conservative_argument_suggestion(
    server: str,
    tool: str,
    arguments: list[str],
) -> tuple[str | None, str, str]:
    if server == "firecrawl" and tool == "firecrawl_search" and set(arguments) == {"highlights"}:
        return (
            "conditional-read",
            "matches the known Firecrawl search highlights option and does not broaden the bounded query surface",
            "high",
        )
    return (
        None,
        "manual classification required; unknown arguments must be reviewed before changing conditional-read policy",
        "manual",
    )


def build_drift_records(
    server: str,
    discovered: dict[str, dict[str, Any]],
    policy_tools: dict[str, str],
    conditional_arguments: dict[str, dict[str, Any]],
) -> list[dict[str, Any]]:
    new_tools, absent_tools = compare_inventory(server, discovered, policy_tools)
    records: list[dict[str, Any]] = []
    for tool in new_tools:
        proposed_class, reason, confidence = conservative_tool_suggestion(server, tool)
        records.append(
            {
                "server": server,
                "tool": tool,
                "operation": "new",
                "arguments": schema_arguments(discovered.get(tool)),
                "proposed_class": proposed_class,
                "reason": reason,
                "confidence": confidence,
                "policy_change_applied": False,
            }
        )
    for tool in absent_tools:
        records.append(
            {
                "server": server,
                "tool": tool,
                "operation": "absent",
                "arguments": [],
                "proposed_class": policy_class_for_upstream(server, tool, policy_tools),
                "reason": "configured operation was not discovered during the live schema probe",
                "confidence": "high",
                "policy_change_applied": False,
            }
        )
    for schema_record in conditional_schema_records(server, discovered, conditional_arguments):
        arguments = schema_record["arguments"]
        operation = "new-arguments" if schema_record["reason"] == "new-arguments" else "schema-unknown"
        if operation == "new-arguments":
            proposed_class, reason, confidence = conservative_argument_suggestion(
                server,
                schema_record["tool"],
                arguments,
            )
        else:
            proposed_class = None
            reason = "manual classification required; the live schema does not expose comparable input properties"
            confidence = "manual"
        records.append(
            {
                "server": server,
                "tool": schema_record["tool"],
                "operation": operation,
                "arguments": arguments,
                "proposed_class": proposed_class,
                "reason": reason,
                "confidence": confidence,
                "policy_change_applied": False,
            }
        )
    return records


def format_drift_record(record: dict[str, Any]) -> str:
    proposed = record.get("proposed_class") or "manual classification required"
    arguments = record.get("arguments") or []
    argument_text = f" arguments={arguments}" if arguments else ""
    return (
        f"policy-suggestion {record.get('server')}:{record.get('tool')} "
        f"operation={record.get('operation')} proposed-class={proposed} "
        f"confidence={record.get('confidence')} reason={record.get('reason')}{argument_text} "
        "policy-change-applied=no"
    )


def build_suggestion_report(
    records: list[dict[str, Any]],
    probed_servers: list[str],
    failures: list[dict[str, str]],
) -> dict[str, Any]:
    status = "complete" if not failures else "partial" if probed_servers else "blocked"
    return {
        "schema_version": 1,
        "status": status,
        "policy_change_applied": False,
        "probed_servers": probed_servers,
        "failed_servers": failures,
        "records": records,
    }


def compare_inventory(server: str, discovered: object, policy_tools: dict[str, str]) -> tuple[list[str], list[str]]:
    discovered_names = set(discovered) if isinstance(discovered, (dict, set)) else set()
    expected = policy_upstream_names(server, policy_tools)
    return sorted(discovered_names - expected), sorted(expected - discovered_names)


def compare_conditional_schemas(
    server: str,
    discovered: dict[str, dict[str, Any]],
    conditional_arguments: dict[str, dict[str, Any]],
) -> list[str]:
    drift: list[str] = []
    for record in conditional_schema_records(server, discovered, conditional_arguments):
        if record["reason"] == "missing-input-properties":
            drift.append(f"{record['tool']}:missing-input-properties")
        elif record["reason"] == "new-arguments":
            drift.append(f"{record['tool']}:new-arguments={record['arguments']}")
    return drift


def self_test() -> int:
    policy = {
        "codegraph_codegraph_explore": "read-only",
        "codegraph_codegraph_index": "local-mutation",
    }
    new_tools, absent_tools = compare_inventory("codegraph", {"codegraph_explore", "new_tool"}, policy)
    if new_tools != ["new_tool"] or absent_tools != ["codegraph_index"]:
        print("MCP inventory comparison fixture failed")
        return 1
    conditional_drift = compare_conditional_schemas(
        "playwright",
        {
            "browser_tabs": {
                "name": "browser_tabs",
                "inputSchema": {"properties": {"action": {}, "index": {}, "url": {}, "newMode": {}}},
            }
        },
        {"playwright:browser_tabs": {"known": ["action", "index", "url"]}},
    )
    if conditional_drift != ["browser_tabs:new-arguments=['newMode']"]:
        print("MCP conditional-schema comparison fixture failed")
        return 1
    suggestion_records = build_drift_records(
        "firecrawl",
        {
            "firecrawl_search": {
                "inputSchema": {"properties": {"query": {}, "highlights": {}}},
            },
            "firecrawl_developer_search": {
                "inputSchema": {"properties": {"query": {}, "k": {}, "skills": {}}},
            },
            "firecrawl_custom_action": {
                "inputSchema": {"properties": {"target": {}}},
            },
        },
        {
            "firecrawl_search": "conditional-read",
            "firecrawl_agent": "external-mutation",
        },
        {"firecrawl:firecrawl_search": {"known": ["query"]}},
    )
    if len(suggestion_records) != 4:
        print("MCP policy suggestion fixture record count failed")
        return 1
    developer_record = next(record for record in suggestion_records if record["tool"] == "firecrawl_developer_search")
    ambiguous_record = next(record for record in suggestion_records if record["tool"] == "firecrawl_custom_action")
    absent_record = next(record for record in suggestion_records if record["tool"] == "firecrawl_agent")
    arguments_record = next(record for record in suggestion_records if record["operation"] == "new-arguments")
    if (
        developer_record["proposed_class"] != "read-only"
        or developer_record["confidence"] != "high"
        or ambiguous_record["proposed_class"] is not None
        or ambiguous_record["confidence"] != "manual"
        or absent_record["operation"] != "absent"
        or arguments_record["arguments"] != ["highlights"]
        or any(record["policy_change_applied"] for record in suggestion_records)
    ):
        print("MCP policy suggestion fixture classification failed")
        return 1
    unsafe_argument_records = build_drift_records(
        "firecrawl",
        {
            "firecrawl_search": {
                "inputSchema": {"properties": {"query": {}, "unsafeMode": {}}},
            },
        },
        {"firecrawl_search": "conditional-read"},
        {"firecrawl:firecrawl_search": {"known": ["query"]}},
    )
    unsafe_argument_record = unsafe_argument_records[0]
    if (
        unsafe_argument_record["proposed_class"] is not None
        or unsafe_argument_record["confidence"] != "manual"
        or "manual classification required" not in unsafe_argument_record["reason"]
    ):
        print("MCP policy suggestion safety fixture failed")
        return 1
    partial_report = build_suggestion_report(
        suggestion_records[:1],
        ["firecrawl"],
        [{"server": "playwright", "reason": "probe timed out"}],
    )
    if (
        partial_report["status"] != "partial"
        or partial_report["probed_servers"] != ["firecrawl"]
        or partial_report["failed_servers"][0]["server"] != "playwright"
        or partial_report["policy_change_applied"]
    ):
        print("MCP policy suggestion completeness fixture failed")
        return 1
    encoded = json.dumps(initialize_request(1))
    if '"method": "initialize"' not in encoded or tools_request(2)["method"] != "tools/list":
        print("MCP protocol request fixture failed")
        return 1
    fake_server = r"""
import json, sys
for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    if method == "initialize":
        result = {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "1"}}
    elif method == "tools/list":
        cursor = message.get("params", {}).get("cursor")
        result = {"tools": [{"name": "second_tool"}]} if cursor else {"tools": [{"name": "first_tool"}], "nextCursor": "page-2"}
    else:
        continue
    print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}), flush=True)
"""
    discovered = probe_stdio({"command": sys.executable, "args": ["-c", fake_server], "env": {}}, 5)
    if set(discovered) != {"first_tool", "second_tool"}:
        print("MCP stdio handshake/pagination fixture failed")
        return 1

    class FakeResponse:
        def __init__(
            self, result: dict[str, Any] | None, request_id: int | None, status: int = 200, session: str | None = None
        ):
            payload = {"jsonrpc": "2.0", "id": request_id, "result": result} if request_id is not None else {}
            self.status = status
            self.headers = {"Content-Type": "application/json"}
            if session:
                self.headers["MCP-Session-Id"] = session
            self._stream = io.BytesIO(json.dumps(payload).encode())

        def __enter__(self) -> "FakeResponse":
            return self

        def __exit__(self, *_args: object) -> None:
            return None

        def read(self) -> bytes:
            return self._stream.read()

        def readline(self) -> bytes:
            return self._stream.readline()

    requests: list[urllib.request.Request] = []

    def fake_urlopen(request: urllib.request.Request, timeout: float) -> FakeResponse:
        requests.append(request)
        if request.get_method() == "DELETE":
            return FakeResponse(None, None)
        message = json.loads(request.data or b"{}")
        if message.get("method") == "initialize":
            result = {
                "protocolVersion": "2025-06-18",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "fake-http", "version": "1"},
            }
            return FakeResponse(result, message["id"], session="test-session")
        if message.get("method") == "tools/list":
            return FakeResponse({"tools": [{"name": "http_tool"}]}, message["id"])
        return FakeResponse(None, None, status=202)

    with mock.patch.object(urllib.request, "urlopen", fake_urlopen):
        http_tools = probe_http({"url": "https://example.invalid/mcp"}, 5)
    request_headers = [{key.lower(): value for key, value in request.header_items()} for request in requests]
    if set(http_tools) != {"http_tool"} or requests[-1].get_method() != "DELETE":
        print("MCP HTTP inventory/session-termination fixture failed")
        return 1
    if any(headers.get("mcp-protocol-version") != "2025-06-18" for headers in request_headers[1:]):
        print("MCP HTTP negotiated-version header fixture failed")
        return 1
    if any(headers.get("mcp-session-id") != "test-session" for headers in request_headers[1:]):
        print("MCP HTTP session header fixture failed")
        return 1
    with mock.patch.object(sys.modules[__name__], "probe_http", side_effect=BrokenPipeError("fixture")):
        try:
            probe_server({"url": "https://example.invalid/mcp"}, 5)
        except ProbeError as exc:
            if "HTTP transport failed (BrokenPipeError)" not in str(exc):
                print("MCP transport-error sanitization fixture failed")
                return 1
        else:
            print("MCP transport-error sanitization fixture failed")
            return 1
    print("MCP live-probe self-test passed.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    parser.error("use --self-test; live probing is exposed through mcp_doctor.py --probe-schemas")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
