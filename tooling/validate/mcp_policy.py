#!/usr/bin/env python3

"""Table-driven MCP operation policy regression.

Canonical source: references/mcp_operations.yaml.
The kernel's managed-operation table is generated from that file.

Operation-enforced runtimes treat adapter policy as the runtime-enforced
operation boundary. Adapters must:
- auto-allow only classified read-only tools for Firecrawl/Playwright;
- never auto-allow gated classes;
- never include an unclassified Firecrawl/Playwright tool in allow/trust sets.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
POLICY_PATH = ROOT / "references" / "mcp_operations.yaml"

GATED_CLASSES = {"local-upload", "external-mutation", "monitor-lifecycle", "local-mutation", "auth"}
READ_ONLY = "read-only"
RUNTIME_REGISTRY_PATH = ROOT / "runtimes" / "registry.yaml"
MANAGED_SERVERS = ("serena", "codegraph", "context7", "brave-search", "firecrawl", "playwright")


def rel(path: Path) -> str:
    try:
        return path.relative_to(ROOT).as_posix()
    except ValueError:
        return str(path)


def load_json(path: Path) -> dict:
    return json.loads(path.read_text())


def load_policy() -> dict:
    return load_json(POLICY_PATH)


def tools_by_server(policy: dict) -> dict[str, dict[str, str]]:
    servers = policy.get("servers", {})
    result: dict[str, dict[str, str]] = {}
    for server_name, server in servers.items():
        if not isinstance(server, dict):
            continue
        tools = server.get("tools", {})
        if not isinstance(tools, dict):
            continue
        result[server_name] = {
            str(tool): str(classification)
            for tool, classification in tools.items()
        }
    return result


def validate_policy_shape(policy: dict, errors: list[str]) -> dict[str, dict[str, str]]:
    label = rel(POLICY_PATH)
    classes = policy.get("classes")
    if not isinstance(classes, dict) or not classes:
        errors.append(f"{label}: missing classes map")
        classes = {}
    for required in [READ_ONLY, *sorted(GATED_CLASSES)]:
        if required not in classes:
            errors.append(f"{label}: missing class {required!r}")

    servers = tools_by_server(policy)
    if set(servers) != set(MANAGED_SERVERS):
        errors.append(
            f"{label}: expected servers {sorted(MANAGED_SERVERS)}, found {sorted(servers)}"
        )

    for server_name, tools in servers.items():
        if not tools:
            errors.append(f"{label}: server {server_name!r} has no tools")
        for tool, classification in tools.items():
            if classification not in classes:
                errors.append(
                    f"{label}: tool {server_name}:{tool} has unknown class {classification!r}"
                )

    auth_ops = policy.get("auth_operations", [])
    if not isinstance(auth_ops, list) or not auth_ops:
        errors.append(f"{label}: auth_operations must be a non-empty list")
    else:
        for auth in auth_ops:
            if not isinstance(auth, dict) or auth.get("class") != "auth":
                errors.append(f"{label}: auth operation must use class 'auth': {auth!r}")

    return servers


def validate_kernel_generated(policy: dict, errors: list[str]) -> None:
    kernel_path = ROOT / "references" / "kernel.template.md"
    kernel = kernel_path.read_text()
    label = rel(kernel_path)

    for marker in [
        "Managed MCP operations",
        "references/mcp_operations.yaml",
        "<!-- generated:mcp-operations:start -->",
        "<!-- generated:mcp-operations:end -->",
        "server wildcards and unclassified managed tools are approval-required",
    ]:
        if marker not in kernel:
            errors.append(f"{label}: missing marker {marker!r}")

    start = "<!-- generated:mcp-operations:start -->"
    end = "<!-- generated:mcp-operations:end -->"
    try:
        block = kernel.split(start, 1)[1].split(end, 1)[0]
    except IndexError:
        errors.append(f"{label}: generated MCP operations block missing")
        return

    for class_name in policy.get("classes", {}):
        if f"`{class_name}`" not in block:
            errors.append(f"{label}: generated table missing class {class_name!r}")


def operation_enforced_runtimes() -> tuple[str, ...]:
    registry = load_json(RUNTIME_REGISTRY_PATH)
    return tuple(
        runtime["name"]
        for runtime in registry.get("runtimes", [])
        if isinstance(runtime, dict)
        and isinstance(runtime.get("name"), str)
        and runtime.get("support_tier") == "operation-enforced"
    )


def validate_runtime_adapter(runtime_name: str, errors: list[str]) -> None:
    validator = ROOT / "runtimes" / runtime_name / "scripts" / "validate_mcp_policy.py"
    if not validator.is_file():
        errors.append(
            f"runtimes/{runtime_name}: operation-enforced runtime requires "
            "scripts/validate_mcp_policy.py"
        )
        return
    result = subprocess.run(
        [sys.executable, str(validator), "--policy", str(POLICY_PATH)],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        errors.append(f"runtimes/{runtime_name}: MCP operation-policy adapter validation failed: {detail}")


def main() -> int:
    errors: list[str] = []
    if not POLICY_PATH.exists():
        print(f"{rel(POLICY_PATH)}: missing canonical MCP operations policy", file=sys.stderr)
        return 1

    policy = load_policy()
    servers = validate_policy_shape(policy, errors)
    if "firecrawl" in servers and "playwright" in servers:
        validate_kernel_generated(policy, errors)
        enforced_runtimes = operation_enforced_runtimes()
        for runtime_name in enforced_runtimes:
            validate_runtime_adapter(runtime_name, errors)
    else:
        enforced_runtimes = ()

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1

    firecrawl_count = len(servers.get("firecrawl", {}))
    playwright_count = len(servers.get("playwright", {}))
    print(
        "MCP operation policy regression passed "
        f"({firecrawl_count} Firecrawl tools, {playwright_count} Playwright tools; "
        f"enforced per-tool: {', '.join(enforced_runtimes) or 'none'}; "
        "closed-world adapter checks enabled)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
