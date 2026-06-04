#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"

python3 - <<'PY'
import json
from pathlib import Path

root = Path.cwd()
errors = []

registry = json.loads((root / "runtimes" / "registry.yaml").read_text())
runtime = next((item for item in registry["runtimes"] if item.get("name") == "kimi-code-cli"), None)
if runtime is None:
    errors.append("runtimes/registry.yaml: missing kimi-code-cli")
else:
    expected = {
        "memory_file": "b-agentic-kernel.md",
        "memory_install_path": "~/.kimi-code/b-agentic-kernel.md",
        "metadata_root": "~/.kimi-code/b-agentic",
        "skills_install_root": "~/.kimi-code/skills",
        "config_schema_family": "kimi-code-toml-json",
    }
    for key, value in expected.items():
        if runtime.get(key) != value:
            errors.append(f"runtimes/registry.yaml: kimi-code-cli {key} should be {value!r}")
    if runtime.get("command_wrappers", {}).get("supported") is not False:
        errors.append("runtimes/registry.yaml: Kimi command wrappers should be unsupported")

kernel = root / "runtimes" / "kimi-code-cli" / "kernel.md"
if not kernel.exists():
    errors.append("runtimes/kimi-code-cli/kernel.md: missing")
else:
    text = kernel.read_text()
    for marker in ["Kimi Code CLI", "b-agentic-kernel.md", "Runtime Kernel", "output.md", "decisions.md"]:
        if marker not in text:
            errors.append(f"runtimes/kimi-code-cli/kernel.md: missing marker {marker!r}")

mcp = root / "runtimes" / "kimi-code-cli" / "configs" / "mcp.user.template.json"
try:
    data = json.loads(mcp.read_text())
except Exception as exc:
    errors.append(f"runtimes/kimi-code-cli/configs/mcp.user.template.json: invalid JSON: {exc}")
else:
    servers = data.get("mcpServers", {})
    for server in ["serena", "context7", "brave-search", "firecrawl", "playwright"]:
        if server not in servers:
            errors.append(f"runtimes/kimi-code-cli/configs/mcp.user.template.json: missing {server}")
    if servers.get("serena", {}).get("args") != ["start-mcp-server", "--context", "ide", "--project-from-cwd"]:
        errors.append("runtimes/kimi-code-cli/configs/mcp.user.template.json: unexpected Serena args")

install = (root / "runtimes" / "kimi-code-cli" / "scripts" / "install.sh").read_text()
for marker in [
    "B_AGENTIC_KIMI_CODE_HOME",
    "UserPromptSubmit",
    "inject-kernel.py",
    "mcpServers",
    "remove_kimi_config_block",
]:
    if marker not in install:
        errors.append(f"runtimes/kimi-code-cli/scripts/install.sh: missing marker {marker!r}")

hook = root / "runtimes" / "kimi-code-cli" / "hooks" / "inject-kernel.py"
hook_text = hook.read_text()
if "session_id" not in hook_text:
    errors.append("runtimes/kimi-code-cli/hooks/inject-kernel.py: missing session_id handling")
if "kernel injection failed open" not in hook_text:
    errors.append("runtimes/kimi-code-cli/hooks/inject-kernel.py: missing fail-open diagnostic")

readme = (root / "runtimes" / "kimi-code-cli" / "configs" / "README.md").read_text()
for marker in ["~/.kimi-code/config.toml", "~/.kimi-code/mcp.json", "UserPromptSubmit", "fail-open"]:
    if marker not in readme:
        errors.append(f"runtimes/kimi-code-cli/configs/README.md: missing marker {marker!r}")

if errors:
    for error in errors:
        print(error)
    raise SystemExit(1)

print("Kimi Code CLI runtime validation passed.")
PY
