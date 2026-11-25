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

# The probes run with bun; the fake Codex plugin's own script needs node.
for tool in bun node; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'error: %s is required to run the validation suite\n' "$tool" >&2; exit 1; }
done

python3 "$ROOT_DIR/tooling/generate/registry_sync.py" --self-test --check
python3 "$ROOT_DIR/tooling/validate/capabilities.py" --self-test
python3 "$ROOT_DIR/tooling/validate/decision_design.py" --self-test
python3 "$ROOT_DIR/tooling/validate/decision_design.py"
python3 "$ROOT_DIR/tooling/validate/shared.py"
python3 "$ROOT_DIR/tooling/validate/behavior.py"
python3 "$ROOT_DIR/tooling/validate/runtime_parity.py"
python3 "$ROOT_DIR/tooling/validate/mcp_policy.py"
python3 "$ROOT_DIR/tooling/validate/mcp_probe.py" --self-test
python3 "$ROOT_DIR/tooling/validate/session_readiness.py" --self-test
python3 "$ROOT_DIR/tooling/validate/browser_evidence.py" --self-test
python3 "$ROOT_DIR/tooling/validate/review_eval.py" --self-test
python3 "$ROOT_DIR/tooling/validate/review_eval.py"

# The probes below share nothing (each makes its own work folder and repositories), so they
# run at the same time. Each one's output is kept in a log and printed in the order started;
# a failed probe's log goes to stderr and the run fails after every probe has finished.
probe_dir=$(mktemp -d)
probe_names=()
probe_pids=()
probe_done=()
probe_timer_pid=""
probe_timeout=${B_AGENTIC_PROBE_TIMEOUT:-600}

stop_timer() {
  if [ -n "$probe_timer_pid" ]; then
    if command -v pkill >/dev/null 2>&1; then
      pkill -TERM -P "$probe_timer_pid" 2>/dev/null || true
    fi
    kill "$probe_timer_pid" 2>/dev/null || true
    wait "$probe_timer_pid" 2>/dev/null || true
    probe_timer_pid=""
  fi
}

cleanup_probes() {
  stop_timer
  rm -rf "$probe_dir"
}

abort_probes() {
  local reason=$1 index pid
  trap - USR1 INT TERM
  stop_timer
  for index in "${!probe_names[@]}"; do
    [ "${probe_done[$index]:-0}" -eq 0 ] || continue
    pid=${probe_pids[$index]}
    if command -v pkill >/dev/null 2>&1; then
      pkill -TERM -P "$pid" 2>/dev/null || true
    fi
    kill -TERM "$pid" 2>/dev/null || true
    sleep 0.2
    if command -v pkill >/dev/null 2>&1; then
      pkill -KILL -P "$pid" 2>/dev/null || true
    fi
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    printf -- '--- probe unfinished (%s): %s\n' "$reason" "${probe_names[$index]}" >&2
    cat "$probe_dir/${probe_names[$index]}.log" >&2 || true
    probe_done[index]=1
  done
}

trap cleanup_probes EXIT
trap 'abort_probes "interrupted (SIGINT)"; exit 130' INT
trap 'abort_probes "terminated (SIGTERM)"; exit 143' TERM
trap 'abort_probes "timed out after ${probe_timeout}s"; exit 124' USR1

# The state probe is the longest and CPU-bound (about 40 s alone), and hooks-cli mostly waits on real
# timeouts, so both run at normal priority and the other probes yield to them.
start_probe() { # NAME COMMAND...
  local name=$1
  shift
  if [ "$name" = state ] || [ "$name" = hooks-cli ] || ! command -v nice >/dev/null 2>&1; then
    "$@" >"$probe_dir/$name.log" 2>&1 &
  else
    nice -n 10 "$@" >"$probe_dir/$name.log" 2>&1 &
  fi
  probe_pids+=($!)
  probe_names+=("$name")
  probe_done+=(0)
}
finish_probes() {
  local failed=() index
  if [ "$probe_timeout" -gt 0 ] 2>/dev/null; then
    (
      exec >/dev/null 2>&1
      sleep "$probe_timeout"
      kill -USR1 "$$" 2>/dev/null || true
    ) &
    probe_timer_pid=$!
  fi
  for index in "${!probe_names[@]}"; do
    if wait "${probe_pids[$index]}"; then
      cat "$probe_dir/${probe_names[$index]}.log"
    else
      failed+=("${probe_names[$index]}")
      printf -- '--- probe failed: %s\n' "${probe_names[$index]}" >&2
      cat "$probe_dir/${probe_names[$index]}.log" >&2
    fi
    probe_done[index]=1
  done
  stop_timer
  probe_names=()
  probe_pids=()
  probe_done=()
  if [ "${#failed[@]}" -gt 0 ]; then
    printf 'validation failed: %s\n' "${failed[*]}" >&2
    exit 1
  fi
}

# Claude Code runs everything below with bun (ADR-018). The hooks probe is two processes: the hook
# sections, and the slow verdict mapper and review wrapper on their own.
start_probe hooks env HOOKS_PROBE_PART=hooks bash "$ROOT_DIR/tests/hooks/hooks-probe.sh"
start_probe hooks-cli env HOOKS_PROBE_PART=cli bash "$ROOT_DIR/tests/hooks/hooks-probe.sh"
start_probe snapshot bash "$ROOT_DIR/tests/snapshot/cli-probe.sh"
start_probe statusline bash "$ROOT_DIR/tests/statusline/statusline-probe.sh"
start_probe state bash "$ROOT_DIR/tests/state/state-probe.sh"
start_probe pi-guard-cases node "$ROOT_DIR/tests/pi/guard-cases.mjs"
start_probe pi-guard bash "$ROOT_DIR/tests/pi/guard-probe.sh"
start_probe artifacts bash "$ROOT_DIR/tests/artifacts/artifact-probe.sh"

if [ "$run_release" -eq 1 ]; then
  start_probe claude-install bash "$ROOT_DIR/tests/install/claude-install-probe.sh"
  start_probe pi-install bash "$ROOT_DIR/tests/install/pi-install-probe.sh"
  start_probe all-install bash "$ROOT_DIR/tests/install/all-install-probe.sh"
  if command -v rtk >/dev/null 2>&1; then
    start_probe session-readiness python3 "$ROOT_DIR/tooling/validate/session_readiness.py"
  else
    printf '%s\n' 'RTK policy compatibility skipped: rtk is not installed.'
  fi
fi
finish_probes
