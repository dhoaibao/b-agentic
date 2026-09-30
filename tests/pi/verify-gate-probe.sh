#!/usr/bin/env bash
# Exercise pi/extensions/b-verify-gate.ts against a scripted local model. Needs
# only the installed Pi CLI: no npm packages, credentials, or network.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export PI_CODING_AGENT_DIR="$work/home" PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0
mkdir -p "$work/home" "$work/cwd"

# `-ne` drops user and built-in extensions; only the two `-e` files load.
run_case() {
  local name=$1 expected=$2 want_replies=${3:-$((1 + $2))} replies reminded=0
  ( cd "$work/cwd" && pi -ne -e "$root/tests/pi/gate-stub-provider.ts" \
      -e "$root/pi/extensions/b-verify-gate.ts" --model gate-stub/gate-1 \
      --mode json --no-session "$name" >"$work/$name.jsonl" )
  grep -Fq 'b-agentic verify gate' "$work/$name.jsonl" && reminded=1
  replies=$(jq -c 'select(.type == "message_end" and .message.role == "assistant" and any(.message.content[]?; .text? == "gate-probe-done"))' \
    "$work/$name.jsonl" | wc -l | tr -d ' ')
  if [ "$reminded" != "$expected" ]; then
    echo "verify-gate probe failed: $name (reminder=$reminded, expected $expected)" >&2
    exit 1
  fi
  # One reminder buys exactly one extra model turn, never more.
  if [ "$replies" != "$want_replies" ]; then
    echo "verify-gate probe failed: $name (replies=$replies, expected $want_replies)" >&2
    exit 1
  fi
  if [ "$name" = gate-loop ] && [ "$(jq -c 'select(.type == "tool_execution_end" and .toolName == "write")' "$work/$name.jsonl" | wc -l | tr -d ' ')" != 2 ]; then
    echo "verify-gate probe failed: $name (continuation did not edit again)" >&2
    exit 1
  fi
  echo "verify-gate probe passed: $name"
}

run_case gate-edit 1
run_case gate-edit-check 0
run_case gate-check-edit 1
run_case gate-prose 0
run_case gate-none 0
# Editing again during the continuation earns no second reminder.
run_case gate-loop 1 2
