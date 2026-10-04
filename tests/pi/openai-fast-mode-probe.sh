#!/usr/bin/env bash
# Exercise pi/extensions/b-openai-fast-mode.ts offline against a scripted local model.
# A test-only extension (tests/pi/openai-fast-mode-cases.ts) runs unit and wiring cases
# at session start: config parsing, model/API eligibility, payload injection, the /openai-fastmode
# command, and persistence in an isolated agent directory. A second run with
# PI_OPENAI_FAST_MODE=off confirms the extension is inert and the reply is unchanged.
# Real OpenAI requests and gateway behavior are not covered.
# Needs only the installed Pi CLI and jq: no npm packages, credentials, or network.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export PI_CODING_AGENT_DIR="$work/home" PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0
mkdir -p "$work/home" "$work/cwd"

ext="$root/pi/extensions/b-openai-fast-mode.ts"

# `-ne` drops user and built-in extensions; only the `-e` files load.
run_pi() {
  local name=$1 prompt=$2
  shift 2
  ( cd "$work/cwd" && env -u PI_OPENAI_FAST_MODE "$@" \
      pi -ne -e "$root/tests/pi/gate-stub-provider.ts" -e "$ext" \
      -e "$root/tests/pi/openai-fast-mode-cases.ts" --model gate-stub/gate-1 \
      --mode json --no-session "$prompt" >"$work/$name.jsonl" 2>"$work/$name.err" )
  if grep -Eiq 'failed to load|extension.*error' "$work/$name.err" "$work/$name.jsonl"; then
    echo "openai-fast-mode probe failed: $name reported an extension error" >&2
    cat "$work/$name.err" >&2
    exit 1
  fi
}

replies() {
  jq -c 'select(.type == "message_end" and .message.role == "assistant" and any(.message.content[]?; .text? == "gate-probe-done"))' \
    "$work/$1.jsonl" | wc -l | tr -d ' '
}

# 1. Unit and wiring cases run at session start, even in a non-TUI session.
run_pi cases 'gate-none fast' env PROBE_OUT="$work/cases.json" PROBE_WORK="$work/files"
if [ ! -s "$work/cases.json" ]; then
  echo 'openai-fast-mode probe failed: cases did not run' >&2
  exit 1
fi
# The cases file records its own size; require a minimum so a partial run cannot pass.
min_cases=70
count=$(jq -r '._count // 0' "$work/cases.json")
if [ "$count" -lt "$min_cases" ]; then
  echo "openai-fast-mode probe failed: only $count cases ran, expected at least $min_cases" >&2
  exit 1
fi
failed=$(jq -r 'del(._count) | to_entries[] | select(.value != "ok") | "\(.key): \(.value | tojson)"' "$work/cases.json")
if [ -n "$failed" ]; then
  printf 'openai-fast-mode probe failed:\n%s\n' "$failed" >&2
  exit 1
fi
echo "openai-fast-mode cases passed: $count"

# 2. The reply arrives once with the extension loaded.
if [ "$(replies cases)" != 1 ]; then
  echo 'openai-fast-mode probe failed: a run with the extension changed the reply' >&2
  exit 1
fi

# 3. PI_OPENAI_FAST_MODE=off loads cleanly and the reply is unchanged.
run_pi off 'gate-none fast off' env PI_OPENAI_FAST_MODE=off
if [ "$(replies off)" != 1 ]; then
  echo 'openai-fast-mode probe failed: the disabled extension changed the reply' >&2
  exit 1
fi
echo 'openai-fast-mode probe passed'
