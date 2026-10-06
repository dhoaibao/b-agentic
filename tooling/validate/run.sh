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
bash "$ROOT_DIR/tests/install/stage-failure.sh"

if [ "$run_release" -eq 1 ]; then
  # Installer sandbox tests run many full installs, so they gate release and CI
  # rather than every edit. Each suite owns a private mktemp sandbox and HOME, so
  # they run in parallel; output is buffered and shown only for a failed suite.
  install_log_dir="$(mktemp -d "${TMPDIR:-/tmp}/b-agentic-install-tests.XXXXXX")"
  trap 'rm -rf "$install_log_dir"' EXIT
  install_suites=(prune-retired mcp-search-migration runtime-tools)
  install_pids=()
  for suite in "${install_suites[@]}"; do
    bash "$ROOT_DIR/tests/install/$suite.sh" >"$install_log_dir/$suite.log" 2>&1 &
    install_pids+=("$!")
  done
  install_failed=0
  for index in "${!install_suites[@]}"; do
    if wait "${install_pids[$index]}"; then
      tail -n 1 "$install_log_dir/${install_suites[$index]}.log"
    else
      install_failed=1
      printf 'Installer suite failed: %s\n' "${install_suites[$index]}" >&2
      cat "$install_log_dir/${install_suites[$index]}.log" >&2
    fi
  done
  [ "$install_failed" -eq 0 ] || exit 1
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
    bash "$ROOT_DIR/tests/pi/herdr-notify-probe.sh"
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
