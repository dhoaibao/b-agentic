#!/usr/bin/env bash
# Exercise pi/extensions/b-input-image-preview/index.ts offline against a scripted local
# model. The extension is interactive-only and display-only, so the probe checks what
# needs no terminal:
#   1. unit cases (tests/pi/input-image-preview-cases.ts): path extraction, clipboard
#      labels, the recent-preview list behind /b-image, popup-slot ownership, the
#      bounded file read, and FIFO rejection where mkfifo exists;
#   2. in a non-TUI run it loads without error, registers no "/b-image" command (a
#      "/b-image 1" prompt reaches the model), and leaves a prompt unchanged.
# Rendering, the popup, and mouse handling need a real terminal and are not covered.
# Without `pi` the probe prints a skip line and exits 0; PI_PROBE_REQUIRE=1 turns a
# skip into a failure. Needs only Pi and jq: no npm packages, credentials, or network.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fail() { echo "input-image-preview probe failed: $*" >&2; exit 1; }
skip() {
  if [ "${PI_PROBE_REQUIRE:-}" = 1 ]; then fail "skipped but required: $*"; fi
  echo "input-image-preview probe skipped: $*"
}

if ! command -v pi >/dev/null 2>&1; then
  skip "pi is not installed"
  exit 0
fi
command -v jq >/dev/null 2>&1 || fail "this probe needs jq on PATH"

work=$(mktemp -d)
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT
mkdir -p "$work/h/.pi/agent" "$work/cwd"
export HOME="$work/h" PI_CODING_AGENT_DIR="$work/h/.pi/agent" PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0

ext="$root/pi/extensions/b-input-image-preview/index.ts"

# stock macOS has no GNU timeout; spawn the child in its own process group so a timeout kills descendants too
bounded() { # bounded <seconds> <command...>
  if command -v timeout >/dev/null 2>&1; then timeout -k 2 "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout -k 2 "$@"
  else perl -e '
    my $secs = shift;
    my $pid = fork();
    die "fork: $!\n" unless defined $pid;
    if ($pid == 0) {
      setpgrp(0, 0);
      exec @ARGV or die "exec: $!\n";
    }
    local $SIG{ALRM} = sub {
      kill "TERM", -$pid;
      select(undef, undef, undef, 0.2);
      kill "KILL", -$pid;
      waitpid($pid, 0);
      exit 124;
    };
    alarm $secs;
    waitpid($pid, 0);
    alarm 0;
    exit(($? & 127) ? 128 + ($? & 127) : ($? >> 8));
  ' "$@"
  fi
}

# `-ne` drops user and built-in extensions; only the `-e` files load.
# stdin comes from /dev/null: `pi` waits for EOF on an open non-terminal stdin.
run_pi() {
  local name=$1 prompt=$2
  shift 2
  ( cd "$work/cwd" && bounded 60 "$@" pi -ne -e "$root/tests/pi/stub-provider.ts" -e "$ext" \
      -e "$root/tests/pi/input-image-preview-cases.ts" --model probe/probe-1 \
      --mode json --no-session "$prompt" >"$work/$name.jsonl" 2>"$work/$name.err" </dev/null ) \
    || fail "$name: pi exited non-zero: $(head -c 400 "$work/$name.err")"
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
  fail "cases did not run"
fi
# The cases file records its own size; require a minimum so a partial run cannot pass.
min_cases=37
count=$(jq -r '._count // 0' "$work/cases.json")
if [ "$count" -lt "$min_cases" ]; then
  fail "only $count cases ran, expected at least $min_cases"
fi
failed=$(jq -r 'del(._count) | to_entries[] | select(.value != "ok") | "\(.key): \(.value | tojson)"' "$work/cases.json")
if [ -n "$failed" ]; then
  printf 'input-image-preview probe failed:\n%s\n' "$failed" >&2
  exit 1
fi
echo "input-image-preview cases passed: $count"

# 2. Non-TUI: the model reply arrives once, and the prompt text is unchanged.
replies=$(jq -c 'select(.type == "message_end" and .message.role == "assistant" and any(.message.content[]?; .text? == "probe-reply-0"))' \
  "$work/cases.jsonl" | wc -l | tr -d ' ')
if [ "$replies" != 1 ]; then
  fail "replies=$replies, expected 1"
fi
if [ "$(user_texts cases)" != 'gate-none [Image 1]' ]; then
  fail "prompt text was altered"
fi

# 3. A "/b-image" prompt is not claimed outside the TUI: it must reach the model as text.
run_pi slash '/b-image 1'
if [ "$(user_texts slash)" != '/b-image 1' ]; then
  fail "/b-image was consumed outside the TUI"
fi

# 4. R7-2: normal startup discovery in an installed sandbox home loads the preview without `-e`.
disc_home="$work/disc_home"
mkdir -p "$disc_home"
env -u PI_CODING_AGENT_DIR HOME="$disc_home" python3 "$root/tooling/install/pi_install.py" -y >"$work/disc_install.log" 2>&1 \
  || { cat "$work/disc_install.log" >&2; fail "pi_install failed for startup discovery"; }
rm -f "$disc_home/.pi/agent/mcp.json"
jq 'del(.packages)' "$disc_home/.pi/agent/settings.json" >"$work/disc_settings.json" \
  && mv "$work/disc_settings.json" "$disc_home/.pi/agent/settings.json"
( cd "$work/cwd" && bounded 60 env HOME="$disc_home" PI_CODING_AGENT_DIR="$disc_home/.pi/agent" pi \
    -e "$root/tests/pi/stub-provider.ts" --model probe/probe-1 --mode json --no-session '/b-image 1' \
    >"$work/disc.jsonl" 2>"$work/disc.err" </dev/null ) \
  || fail "startup discovery run exited non-zero: $(head -c 400 "$work/disc.err")"
if grep -Eiq 'failed to load|extension.*error' "$work/disc.err" || jq -e 'select(.type == "extension_error")' "$work/disc.jsonl" >/dev/null; then
  fail "startup discovery reported an extension error: $(cat "$work/disc.err")"
fi
if [ "$(user_texts disc)" != '/b-image 1' ]; then
  fail "startup discovery altered /b-image 1 in json mode"
fi
echo 'input-image-preview probe passed'
