#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="${B_AGENTIC_RUNTIME:-claude-code}"
HOME_DIR="$HOME"
PRODUCTION=0

usage() {
  printf 'usage: %s [--runtime=<name>] [--home=<path>] [--production]\n' "${BASH_SOURCE[0]}" >&2
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
python3 "$ROOT_DIR/tooling/validate/skill_doctor.py" --runtime="$RUNTIME" --home "$HOME_DIR"
printf '\nMCP readiness doctor:\n'
mcp_rc=0
if [ "$PRODUCTION" -eq 1 ]; then
  python3 "$ROOT_DIR/tooling/validate/mcp_doctor.py" --runtime="$RUNTIME" --home "$HOME_DIR" --production || mcp_rc=$?
else
  python3 "$ROOT_DIR/tooling/validate/mcp_doctor.py" --runtime="$RUNTIME" --home "$HOME_DIR" || mcp_rc=$?
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

if [ "$PRODUCTION" -eq 1 ] && [ "$mcp_rc" -ne 0 ]; then
  printf '\nProduction readiness blocked by MCP doctor output above.\n' >&2
fi
exit "$mcp_rc"
