#!/usr/bin/env bash
# Record a machine-readable operator attestation of a live fresh-session pass.
# This does not verify gates, tags, static validation, or production readiness.
# Use scripts/verify-release-evidence.sh to check attestations plus static gates.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME=""
HOME_DIR="$HOME"
OPERATOR="${USER:-unknown}"
OUTPUT=""
declare -A GATE_STATUS=()
declare -A GATE_NOTES=()

usage() {
  cat <<'EOF' >&2
usage: record-release-evidence.sh --runtime=<name> [--home=<path>] [--operator=<id>] [--output=<path>] \
  --kernel=<pass|fail|skipped> --skill=<pass|fail|skipped> --mcp=<pass|fail|skipped> \
  --approval-gate=<pass|fail|skipped> --deny-gate=<pass|fail|skipped> \
  [--note-kernel=...] [--note-skill=...] [--note-mcp=...] [--note-approval-gate=...] [--note-deny-gate=...]

Records an operator attestation of live fresh-session outcomes only.
It does not run static validation, verify tags, or prove the gates occurred.
Simulated --active probes are not live proof. Use scripts/verify-release-evidence.sh
to validate attestation files together with static release checks.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --runtime=*) RUNTIME="${1#--runtime=}" ;;
    --home=*) HOME_DIR="${1#--home=}" ;;
    --operator=*) OPERATOR="${1#--operator=}" ;;
    --output=*) OUTPUT="${1#--output=}" ;;
    --kernel=*) GATE_STATUS[kernel]="${1#--kernel=}" ;;
    --skill=*) GATE_STATUS[skill]="${1#--skill=}" ;;
    --mcp=*) GATE_STATUS[mcp]="${1#--mcp=}" ;;
    --approval-gate=*) GATE_STATUS[approval_gate]="${1#--approval-gate=}" ;;
    --deny-gate=*) GATE_STATUS[deny_gate]="${1#--deny-gate=}" ;;
    --note-kernel=*) GATE_NOTES[kernel]="${1#--note-kernel=}" ;;
    --note-skill=*) GATE_NOTES[skill]="${1#--note-skill=}" ;;
    --note-mcp=*) GATE_NOTES[mcp]="${1#--note-mcp=}" ;;
    --note-approval-gate=*) GATE_NOTES[approval_gate]="${1#--note-approval-gate=}" ;;
    --note-deny-gate=*) GATE_NOTES[deny_gate]="${1#--note-deny-gate=}" ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
  shift
done

if [ -z "$RUNTIME" ]; then
  usage
  exit 2
fi

for gate in kernel skill mcp approval_gate deny_gate; do
  status="${GATE_STATUS[$gate]:-}"
  case "$status" in
    pass|fail|skipped) ;;
    *)
      printf 'missing or invalid --%s=<pass|fail|skipped>\n' "${gate//_/-}" >&2
      exit 2
      ;;
  esac
done

if [ -z "$OUTPUT" ]; then
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  OUTPUT="$ROOT_DIR/release-evidence/${RUNTIME}-${stamp}.json"
fi

mkdir -p "$(dirname "$OUTPUT")"

python3 - "$ROOT_DIR" "$RUNTIME" "$HOME_DIR" "$OPERATOR" "$OUTPUT" \
  "${GATE_STATUS[kernel]}" "${GATE_NOTES[kernel]:-}" \
  "${GATE_STATUS[skill]}" "${GATE_NOTES[skill]:-}" \
  "${GATE_STATUS[mcp]}" "${GATE_NOTES[mcp]:-}" \
  "${GATE_STATUS[approval_gate]}" "${GATE_NOTES[approval_gate]:-}" \
  "${GATE_STATUS[deny_gate]}" "${GATE_NOTES[deny_gate]:-}" <<'PY'
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

(
    root,
    runtime,
    home,
    operator,
    output,
    kernel_status,
    kernel_note,
    skill_status,
    skill_note,
    mcp_status,
    mcp_note,
    approval_status,
    approval_note,
    deny_status,
    deny_note,
) = sys.argv[1:]

root_path = Path(root)
home_path = Path(home).expanduser()
registry = json.loads((root_path / "runtimes" / "registry.yaml").read_text())
runtime_names = {item.get("name") for item in registry.get("runtimes", []) if isinstance(item, dict)}
if runtime not in runtime_names:
    raise SystemExit(f"unsupported runtime: {runtime}")

pyproject = (root_path / "pyproject.toml").read_text()
version_match = re.search(r'^version\s*=\s*"([^"]+)"', pyproject, re.MULTILINE)
package_version = version_match.group(1) if version_match else "unknown"

git_rev = subprocess.run(
    ["git", "-C", str(root_path), "rev-parse", "HEAD"],
    capture_output=True,
    text=True,
    check=False,
).stdout.strip()
# Unresolved revisions are recorded but not release-eligible; verification rejects them.
release_eligible = bool(git_rev)
if not git_rev:
    git_rev = "unknown"

cli_lookup = {
    "claude-code": "claude",
    "codex": "codex",
    "pi": "pi",
}
cli_name = cli_lookup.get(runtime, runtime)
cli_path = shutil.which(cli_name)
cli_version = "missing"
if cli_path:
    completed = subprocess.run([cli_path, "--version"], capture_output=True, text=True, check=False)
    cli_version = (completed.stdout or completed.stderr or "unknown").strip().splitlines()[0][:200]

registry_runtime = next(
    (item for item in registry.get("runtimes", []) if isinstance(item, dict) and item.get("name") == runtime),
    {},
)
support_tier = registry_runtime.get("support_tier") if isinstance(registry_runtime, dict) else None
mcp_enforcement = registry_runtime.get("mcp_enforcement") if isinstance(registry_runtime, dict) else None

pins = {
    "brave": os.environ.get("B_AGENTIC_BRAVE_MCP_PACKAGE", "@brave/brave-search-mcp-server@2.0.85"),
    "firecrawl": os.environ.get("B_AGENTIC_FIRECRAWL_MCP_PACKAGE", "firecrawl-mcp@3.22.1"),
    "playwright": os.environ.get("B_AGENTIC_PLAYWRIGHT_MCP_PACKAGE", "@playwright/mcp@0.0.77"),
    "pi_mcp_adapter": "pi-mcp-adapter@2.11.0",
    "rtk_ref": os.environ.get("B_AGENTIC_RTK_REF", "v0.43.0"),
}

gates = [
    {"name": "kernel", "status": kernel_status, "note": kernel_note},
    {"name": "skill", "status": skill_status, "note": skill_note},
    {"name": "mcp", "status": mcp_status, "note": mcp_note},
    {"name": "approval-gate", "status": approval_status, "note": approval_note},
    {"name": "deny-gate", "status": deny_status, "note": deny_note},
]

all_pass = all(item["status"] == "pass" for item in gates)
notes = [
    "Operator attestation only. This file does not prove the gates occurred.",
    "Static validation, tags, and production readiness require scripts/verify-release-evidence.sh.",
    "Simulated --active probes are a separate evidence class and are not live proof.",
]
if not release_eligible:
    notes.append(
        "package.git_rev could not be resolved; release_eligible=false and "
        "scripts/verify-release-evidence.sh will reject this attestation."
    )
if cli_version in {"missing", "unknown"}:
    notes.append(
        "runtime.cli_version is unresolved; scripts/verify-release-evidence.sh will reject this attestation."
    )
    release_eligible = False
payload = {
    "schema_version": 1,
    "record_type": "operator-attestation",
    "evidence_class": "live",
    "recorded_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "operator": operator,
    "package": {
        "name": "b-agentic",
        "version": package_version,
        "git_rev": git_rev,
    },
    "runtime": {
        "name": runtime,
        "cli": cli_name,
        "cli_path": cli_path,
        "cli_version": cli_version,
        "home": str(home_path),
        "support_tier": support_tier,
        "mcp_enforcement": mcp_enforcement,
    },
    "mcp_package_pins": pins,
    "gates": gates,
    "operator_attested_all_gates_pass": all_pass,
    "release_eligible": release_eligible,
    "notes": notes,
}

output_path = Path(output)
output_path.parent.mkdir(parents=True, exist_ok=True)
output_path.write_text(json.dumps(payload, indent=2) + "\n")
print(output_path)
if not all_pass or not release_eligible:
    raise SystemExit(1)
PY
