#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="${B_AGENTIC_RUNTIME:-codex-cli}"
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
  printf '\nActive runtime probes:\n'
  python3 "$ROOT_DIR/tooling/validate/runtime_acceptance.py" --runtime="$RUNTIME" --home "$HOME_DIR" || active_rc=$?
fi

cat <<'EOF'

Fresh-session gates to verify manually in the selected runtime:
- Kernel/memory file is loaded by a newly started runtime session.
- One installed b-* skill can be invoked and follows its skill prompt.
- Configured MCP servers start or report actionable local blockers.
- Approval gates prompt or deny commits, pushes, dependency writes, and destructive commands.
- Browser/MCP/API checks state missing keys, packages, auth, or remote-service gaps instead of claiming success.

Verdict rule: automated doctor output is install/config evidence only. Mark release acceptance complete only after the fresh-session gates above are observed.
EOF

overall_rc=0
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
  printf '\nActive runtime probes failed or were blocked; inspect the output above.\n' >&2
  if [ "$overall_rc" -eq 0 ]; then
    overall_rc="$active_rc"
  fi
fi
exit "$overall_rc"
