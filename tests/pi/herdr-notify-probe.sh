#!/usr/bin/env bash
# Exercise pi/extensions/b-herdr-notify.ts offline against a scripted local model.
# The extension only acts inside Herdr in the root TUI session, so the probe checks
# what needs no terminal or Herdr:
#   1. unit and wiring cases (tests/pi/herdr-notify-cases.ts): the Herdr gate, the
#      balanced blocked aggregate, toast throttle and privacy, the Pi wiring, a missing
#      `herdr` binary, and the exact argv sent to a fake `herdr`;
#   2. with no Herdr environment, and with Herdr variables set in a non-TUI run, the
#      extension loads without error and leaves the prompt and reply unchanged, and the
#      Herdr binary is never called.
# The toast, the sound, and the pane state need a real Herdr and are not covered.
# Needs only the installed Pi CLI and jq: no npm packages, credentials, or network.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export PI_CODING_AGENT_DIR="$work/home" PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0
mkdir -p "$work/home" "$work/cwd" "$work/spy-bin"

ext="$root/pi/extensions/b-herdr-notify.ts"

# A `herdr` that records any call: no run below may reach it.
cat >"$work/spy-bin/herdr" <<EOF
#!/bin/sh
echo called >> "$work/spy-called"
EOF
chmod +x "$work/spy-bin/herdr"

# `-ne` drops user and built-in extensions; only the `-e` files load. Developers run
# this inside Herdr, so the Herdr variables are removed unless a run sets them.
run_pi() {
  local name=$1 prompt=$2
  shift 2
  ( cd "$work/cwd" && env -u HERDR_ENV -u HERDR_SOCKET_PATH -u HERDR_PANE_ID -u PI_HERDR_NOTIFY \
      "$@" pi -ne -e "$root/tests/pi/gate-stub-provider.ts" -e "$ext" \
      -e "$root/tests/pi/herdr-notify-cases.ts" --model gate-stub/gate-1 \
      --mode json --no-session "$prompt" >"$work/$name.jsonl" 2>"$work/$name.err" )
  if grep -Eiq 'failed to load|extension.*error' "$work/$name.err" "$work/$name.jsonl"; then
    echo "herdr-notify probe failed: $name reported an extension error" >&2
    cat "$work/$name.err" >&2
    exit 1
  fi
}

user_texts() {
  jq -r 'select(.type == "message_end" and .message.role == "user") | .message.content[]? | .text? // empty' "$work/$1.jsonl"
}

replies() {
  jq -c 'select(.type == "message_end" and .message.role == "assistant" and any(.message.content[]?; .text? == "gate-probe-done"))' \
    "$work/$1.jsonl" | wc -l | tr -d ' '
}

# 1. Unit and wiring cases run at session start, even in a non-TUI session.
run_pi cases 'gate-none herdr' env PROBE_OUT="$work/cases.json" PROBE_WORK="$work/files"
if [ ! -s "$work/cases.json" ]; then
  echo 'herdr-notify probe failed: cases did not run' >&2
  exit 1
fi
# The cases file records its own size; require a minimum so a partial run cannot pass.
min_cases=58
count=$(jq -r '._count // 0' "$work/cases.json")
if [ "$count" -lt "$min_cases" ]; then
  echo "herdr-notify probe failed: only $count cases ran, expected at least $min_cases" >&2
  exit 1
fi
failed=$(jq -r 'del(._count) | to_entries[] | select(.value != "ok") | "\(.key): \(.value | tojson)"' "$work/cases.json")
if [ -n "$failed" ]; then
  printf 'herdr-notify probe failed:\n%s\n' "$failed" >&2
  exit 1
fi
echo "herdr-notify cases passed: $count"

# 2a. Outside Herdr: the reply arrives once and the prompt is unchanged.
if [ "$(replies cases)" != 1 ] || [ "$(user_texts cases)" != 'gate-none herdr' ]; then
  echo 'herdr-notify probe failed: a run outside Herdr changed the prompt or reply' >&2
  exit 1
fi

# 2b. Herdr variables set but a non-TUI run: still inert, and the binary is never called.
run_pi inert 'gate-none herdr inert' env PATH="$work/spy-bin:$PATH" HERDR_ENV=1 \
  HERDR_SOCKET_PATH="$work/none.sock" HERDR_PANE_ID=p_probe
if [ "$(replies inert)" != 1 ] || [ "$(user_texts inert)" != 'gate-none herdr inert' ]; then
  echo 'herdr-notify probe failed: a non-TUI run inside Herdr changed the prompt or reply' >&2
  exit 1
fi
if [ -e "$work/spy-called" ]; then
  echo 'herdr-notify probe failed: the herdr binary was called in a non-TUI run' >&2
  exit 1
fi
echo 'herdr-notify probe passed'
