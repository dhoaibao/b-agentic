#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="${B_AGENTIC_RUNTIME:-pi}"
HOME_DIR="$HOME"
PRODUCTION=0
ACTIVE=0

usage() {
  printf 'usage: %s [--runtime=<name>] [--home=<path>] [--production] [--active]\n' "${BASH_SOURCE[0]}" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --runtime=*)
      RUNTIME="${1#--runtime=}"
      ;;
    --home=*)
      HOME_DIR="${1#--home=}"
      ;;
    --production)
      PRODUCTION=1
      ;;
    --active)
      ACTIVE=1
      ;;
    *)
      usage
      exit 2
      ;;
  esac
  shift
done

printf 'Runtime acceptance: %s\n' "$RUNTIME"
printf 'Home: %s\n' "$HOME_DIR"
if [ "$PRODUCTION" -eq 1 ]; then
  printf 'Mode: production readiness\n'
fi
printf '\nSession tool readiness:\n'
session_tools_rc=0
python3 "$ROOT_DIR/tooling/validate/session_readiness.py" || session_tools_rc=$?
printf '\nSkill discovery doctor:\n'
skill_rc=0
python3 "$ROOT_DIR/tooling/validate/skill_doctor.py" --runtime="$RUNTIME" --home "$HOME_DIR" || skill_rc=$?
printf '\nMCP readiness doctor:\n'
mcp_rc=0
if [ "$PRODUCTION" -eq 1 ]; then
  python3 "$ROOT_DIR/tooling/validate/mcp_doctor.py" --runtime="$RUNTIME" --home "$HOME_DIR" || mcp_rc=$?
else
  python3 "$ROOT_DIR/tooling/validate/mcp_doctor.py" --runtime="$RUNTIME" --home "$HOME_DIR" --allow-degraded || mcp_rc=$?
fi

active_rc=0
if [ "$ACTIVE" -eq 1 ]; then
  printf '\nSimulated protocol probes (not live runtime proof):\n'
  printf 'These exercise CLI command construction and harness signals with the real or PATH-provided CLIs.\n'
  printf 'They do not prove a fresh interactive session loaded the kernel or presented UI approval prompts.\n'
  python3 "$ROOT_DIR/tooling/validate/runtime_acceptance.py" --runtime="$RUNTIME" --home "$HOME_DIR" || active_rc=$?
fi

cat <<'EOF'

Evidence classes:
- static: generated/config validation and doctor install/config checks
- simulated: --active protocol/adapter probes (command construction + harness signals)
- live: fresh interactive session observed by an operator

Live fresh-session gates (required for production-ready release claims):
- Kernel/memory file is loaded by a newly started runtime session.
- One installed b-* skill can be invoked and follows its skill prompt.
- For configured MCPs, record the doctor state plus representative live calls: local code intelligence (Serena/CodeGraph, including required onboarding/indexing), external research (Context7/Brave/Firecrawl with authorized credentials), and browser ownership (Playwright where configured).
- Mark unavailable credentials, network access, server startup, Serena onboarding, and CodeGraph indexing as live blockers; configured or launcher-ready is not live-call proof.
- Approval gates prompt or deny commits, pushes, dependency writes, and destructive commands.
- Browser/MCP/API checks state missing keys, packages, auth, or remote-service gaps instead of claiming success.

Verdict rule: automated doctor output and simulated --active probes are not live runtime proof.
Record a live operator attestation with scripts/record-release-evidence.sh after an authorized fresh-session pass.
Verify attestations and static gates with scripts/verify-release-evidence.sh before production-ready claims.
EOF

if [ "$RUNTIME" = "pi" ]; then
  cat <<'EOF'

Pi-specific live checks (print-mode simulated probes cannot exercise UI confirm):
- Confirm pi-mcp-adapter@2.11.0 is installed (or doctor reports missing adapter, not ready MCP).
- Invoke a configured MCP tool through the adapter proxy (or directTools if enabled).
- Allow one approval-gated command (e.g. dependency install) and observe a confirmation prompt.
- Deny one approval-gated command and confirm no side effect.
- Attempt a denied family (e.g. git reset --hard) and confirm an explicit block reason.
EOF
fi

overall_rc=0
if [ "$session_tools_rc" -ne 0 ]; then
  printf '\nRuntime readiness blocked: install the required session shell tools before retrying.\n' >&2
  overall_rc="$session_tools_rc"
fi
if [ "$skill_rc" -ne 0 ]; then
  printf '\nRuntime readiness blocked by skill discovery doctor output above.\n' >&2
  overall_rc="$skill_rc"
fi
if [ "$PRODUCTION" -eq 1 ] && [ "$mcp_rc" -ne 0 ]; then
  printf '\nProduction readiness blocked by MCP doctor output above.\n' >&2
fi
if [ "$overall_rc" -eq 0 ] && [ "$mcp_rc" -ne 0 ]; then
  overall_rc="$mcp_rc"
fi
if [ "$ACTIVE" -eq 1 ] && [ "$active_rc" -ne 0 ]; then
  printf '\nSimulated protocol probes failed or were blocked; inspect the output above.\n' >&2
  if [ "$overall_rc" -eq 0 ]; then
    overall_rc="$active_rc"
  fi
fi
exit "$overall_rc"
