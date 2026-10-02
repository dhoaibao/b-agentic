#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

run_release=0
while [ $# -gt 0 ]; do
  case "$1" in
    --release) run_release=1 ;;
    *) printf 'usage: %s [--release]\n' "${BASH_SOURCE[0]}" >&2; exit 2 ;;
  esac
  shift
done

python3 "$ROOT_DIR/tooling/generate/registry_sync.py" --self-test --check
python3 "$ROOT_DIR/tooling/validate/capabilities.py" --self-test
python3 "$ROOT_DIR/tooling/validate/shared.py"
python3 "$ROOT_DIR/tooling/validate/behavior.py"
python3 "$ROOT_DIR/tooling/validate/mcp_policy.py"
python3 "$ROOT_DIR/tooling/validate/mcp_probe.py" --self-test
python3 "$ROOT_DIR/tooling/validate/session_readiness.py" --self-test
python3 "$ROOT_DIR/tooling/validate/browser_evidence.py" --self-test
bash "$ROOT_DIR/pi/scripts/validate.sh"
bash "$ROOT_DIR/tests/install/prune-retired.sh"
bash "$ROOT_DIR/tests/install/mcp-search-migration.sh"

if [ "$run_release" -eq 1 ]; then
  if command -v rtk >/dev/null 2>&1; then
    python3 "$ROOT_DIR/tooling/validate/session_readiness.py"
  else
    printf '%s\n' 'RTK policy compatibility skipped: rtk is not installed.'
  fi
  # B_AGENTIC_REQUIRE_PI_PROBES=1 (set in CI) turns a missing Pi CLI or probe
  # profile into a failure instead of a skip.
  require_pi="${B_AGENTIC_REQUIRE_PI_PROBES:-0}"
  if command -v pi >/dev/null 2>&1; then
    bash "$ROOT_DIR/tests/pi/verify-gate-probe.sh"
    bash "$ROOT_DIR/tests/pi/snapshot-probe.sh"
    bash "$ROOT_DIR/tests/pi/input-image-preview-probe.sh"
    probe_profile="${PI_PROBE_DIR:-$ROOT_DIR/node_modules/.pi-migration-probe}"
    if [ -f "$probe_profile/.pi/settings.json" ]; then
      bash "$ROOT_DIR/tests/pi/permission-probe.sh"
    elif [ "$require_pi" = 1 ]; then
      bash "$ROOT_DIR/tests/pi/permission-probe.sh" --setup
    else
      printf '%s\n' 'Permission probe skipped: run tests/pi/permission-probe.sh --setup once.'
    fi
  elif [ "$require_pi" = 1 ]; then
    printf '%s\n' 'Pi integration probes required but pi is not installed.' >&2
    exit 1
  else
    printf '%s\n' 'Pi integration probes skipped: pi is not installed.'
  fi
fi
