#!/usr/bin/env bash
# Exercise pi/extensions/b-input-image-preview.ts offline against a scripted local
# model. The extension is interactive-only and display-only, so the probe checks what
# needs no terminal:
#   1. unit cases (tests/pi/input-image-preview-cases.ts): path extraction, clipboard
#      labels, the recent-preview list behind /image, popup-slot ownership, and the
#      bounded file read;
#   2. in a non-TUI run it loads without error, registers no "/image" command (a
#      "/image 1" prompt reaches the model), and leaves a prompt unchanged.
# Rendering, the popup, and mouse handling need a real terminal and are not covered.
# Needs only the installed Pi CLI and jq: no npm packages, credentials, or network.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export PI_CODING_AGENT_DIR="$work/home" PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0
mkdir -p "$work/home" "$work/cwd"

ext="$root/pi/extensions/b-input-image-preview.ts"

# `-ne` drops user and built-in extensions; only the `-e` files load.
run_pi() {
  local name=$1 prompt=$2
  shift 2
  ( cd "$work/cwd" && "$@" pi -ne -e "$root/tests/pi/gate-stub-provider.ts" -e "$ext" \
      -e "$root/tests/pi/input-image-preview-cases.ts" --model gate-stub/gate-1 \
      --mode json --no-session "$prompt" >"$work/$name.jsonl" 2>"$work/$name.err" )
  if grep -Eiq 'failed to load|extension.*error' "$work/$name.err" "$work/$name.jsonl"; then
    echo "input-image-preview probe failed: $name reported an extension error" >&2
    cat "$work/$name.err" >&2
    exit 1
  fi
}

user_texts() {
  jq -r 'select(.type == "message_end" and .message.role == "user") | .message.content[]? | .text? // empty' "$work/$1.jsonl"
}

# 1. Unit cases run at session start, even in a non-TUI session.
run_pi cases 'gate-none [Image 1]' env PROBE_OUT="$work/cases.json" PROBE_WORK="$work/files"
if [ ! -s "$work/cases.json" ]; then
  echo 'input-image-preview probe failed: cases did not run' >&2
  exit 1
fi
# The cases file records its own size; require a minimum so a partial run cannot pass.
min_cases=37
count=$(jq -r '._count // 0' "$work/cases.json")
if [ "$count" -lt "$min_cases" ]; then
  echo "input-image-preview probe failed: only $count cases ran, expected at least $min_cases" >&2
  exit 1
fi
failed=$(jq -r 'del(._count) | to_entries[] | select(.value != "ok") | "\(.key): \(.value | tojson)"' "$work/cases.json")
if [ -n "$failed" ]; then
  printf 'input-image-preview probe failed:\n%s\n' "$failed" >&2
  exit 1
fi
echo "input-image-preview cases passed: $count"

# 2. Non-TUI: the model reply arrives once, and the prompt text is unchanged.
replies=$(jq -c 'select(.type == "message_end" and .message.role == "assistant" and any(.message.content[]?; .text? == "gate-probe-done"))' \
  "$work/cases.jsonl" | wc -l | tr -d ' ')
if [ "$replies" != 1 ]; then
  echo "input-image-preview probe failed: replies=$replies, expected 1" >&2
  exit 1
fi
if [ "$(user_texts cases)" != 'gate-none [Image 1]' ]; then
  echo 'input-image-preview probe failed: prompt text was altered' >&2
  exit 1
fi

# 3. A "/image" prompt is not claimed outside the TUI: it must reach the model as text.
run_pi slash '/image 1'
if [ "$(user_texts slash)" != '/image 1' ]; then
  echo 'input-image-preview probe failed: /image was consumed outside the TUI' >&2
  exit 1
fi
echo 'input-image-preview probe passed'
