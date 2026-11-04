#!/usr/bin/env bash
# Exercise the Claude Code hooks with scripted hook
# JSON and throwaway git repositories. Needs only node, git, and jq: no
# credentials, network, or Claude Code.
# shellcheck disable=SC2016 # Single-quoted shell commands with literal $ are the inputs under test.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
pathguard="$root/claude/hooks/b-path-guard.mjs"
verifygate="$root/claude/hooks/b-verify-gate.mjs"
clickupguard="$root/claude/hooks/b-clickup-guard.mjs"
work=$(mktemp -d)
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_CEILING_DIRECTORIES="$work"
export B_AGENTIC_GATE_DIR="$work/gate"

fail() { echo "hooks probe failed: $*" >&2; exit 1; }

# run <script> <json> [args...]: capture exit code in $rc and stderr in $err.
rc=0
err=""
run() {
  local script=$1 input=$2
  shift 2
  rc=0
  err=$(printf '%s' "$input" | node "$script" "$@" 2>&1 >/dev/null) || rc=$?
}
expect() { [ "$rc" = "$1" ] || fail "$2 (exit $rc, expected $1: $err)"; }

# --- path guard ----------------------------------------------------------------
pg() { jq -cn --arg tool "$1" --arg key "$2" --arg path "$3" '{tool_name: $tool, tool_input: {($key): $path}}'; }
run "$pathguard" "$(pg Read file_path /repo/.env)"; expect 2 "Read .env must be blocked"
grep -Fq 'likely-secret path' <<<"$err" || fail "path guard gave no reason"
run "$pathguard" "$(pg Edit file_path /repo/config/.env.production)"; expect 2 "Edit .env.production must be blocked"
run "$pathguard" "$(pg Write file_path /repo/keys/server.pem)"; expect 2 "Write .pem must be blocked"
run "$pathguard" "$(pg Read file_path /repo/aws-credentials.json)"; expect 2 "credentials file must be blocked"
run "$pathguard" "$(pg Read file_path /repo/secrets.yaml)"; expect 2 "secrets file must be blocked"
run "$pathguard" "$(pg Grep path /repo/.env)"; expect 2 "Grep on .env must be blocked"
run "$pathguard" "$(pg NotebookEdit notebook_path /repo/secrets.ipynb)"; expect 2 "notebook secrets must be blocked"
run "$pathguard" "$(pg Grep glob '**/.env.production')"; expect 2 "a Grep glob naming .env.production must be blocked"
run "$pathguard" "$(pg Glob pattern '**/*.pem')"; expect 2 "a Glob pattern naming pem files must be blocked"
run "$pathguard" "$(pg Grep pattern 'process.env.NODE_ENV')"; expect 0 "a Grep content regex must not be treated as a path"
run "$pathguard" "$(pg Grep pattern 'foo.pem')"; expect 0 "a Grep regex mentioning .pem must pass"
run "$pathguard" "$(pg Grep glob '**/*.ts')"; expect 0 "an ordinary glob must pass"
run "$pathguard" "$(pg Grep glob '**/.env.example')"; expect 0 "a glob naming .env.example must pass"
run "$pathguard" "$(pg Read file_path /repo/.env.example)"; expect 0 ".env.example is explicitly allowed"
run "$pathguard" "$(pg Read file_path /repo/src/app.ts)"; expect 0 "ordinary path must pass"
run "$pathguard" '{"tool_name":"Bash","tool_input":{"command":"ls"}}'; expect 0 "tool without a path must pass"
run "$pathguard" 'not json'; expect 0 "malformed input must fail open"
run "$pathguard" ''; expect 0 "empty input must fail open"
echo "hooks probe passed: path-guard"

# --- clickup guard -------------------------------------------------------------
# It answers on stdout (an "ask" decision) and always exits 0, so capture stdout here.
cg() { jq -cn --arg tool "$1" --arg key "$2" --arg text "$3" '{tool_name: $tool, tool_input: {list_id: "1", name: "t", ($key): $text}}'; }
cg_out() {
  rc=0
  out=$(printf '%s' "$1" | node "$clickupguard" 2>/dev/null) || rc=$?
  expect 0 "clickup guard must always exit 0"
}
cg_asks() {
  cg_out "$(cg mcp__clickup__createTask "$2" "$1")"
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")" = ask ] || fail "clickup guard must ask for: $1"
}
cg_passes() {
  cg_out "$(cg "${3:-mcp__clickup__createTask}" "${2:-description}" "$1")"
  [ -z "$out" ] || fail "clickup guard must stay silent for: $1"
}
cg_asks '![shot](/home/u/screenshot.png)' description
cg_asks 'see ![](/etc/hosts) here' description
cg_asks '![x](data:image/png;base64,AAAA)' description
cg_asks '![x](https://example.com/a.png "title")' description
cg_asks '![x](<https://example.com/a b.png>)' append_description
cg_asks '![x][r]

[r]: /home/u/secret.png' description
cg_asks '![x][missing]' description
cg_asks '<img src="/home/u/a.png" alt="x">' description
cg_asks '![x](https://evil.example/.clickup-attachments.com/a.png)' description
cg_asks '![x](http://t1.clickup-attachments.com/a.png)' description
cg_asks '![ok](https://t1.clickup-attachments.com/a.png) ![bad](/home/u/a.png)' description
cg_out "$(cg mcp__clickup__updateTask description '![x](/home/u/a.png)')"
[ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out")" = PreToolUse ] || fail "clickup guard output must name PreToolUse"
grep -Fq '/home/u/a.png' <<<"$out" || fail "clickup guard must name the image it asks about"
cg_passes '![ok](https://t1.clickup-attachments.com/a.png)'
cg_passes '![ok](https://a.b.clickup-attachments.com/x/y.png?z=1)'
cg_passes 'Plain text with [a link](https://example.com) and no image.'
cg_passes 'Use the Windows! [Settings] menu (see docs).'
cg_passes '' description
cg_passes '![x](/home/u/a.png)' title
cg_out '{"tool_name":"mcp__clickup__createTask","tool_input":{"description":42}}'
[ -z "$out" ] || fail "clickup guard must ignore a non-string description"
cg_out 'not json'
[ -z "$out" ] || fail "clickup guard must fail open on malformed input"
cg_out ''
[ -z "$out" ] || fail "clickup guard must fail open on empty input"
echo "hooks probe passed: clickup-guard"

# --- verify gate ---------------------------------------------------------------
vg() {
  jq -cn --arg event "$1" --arg session "$2" --arg tool "${3:-}" --arg path "${4:-}" --argjson active "${5:-false}" --arg command "${6:-}" \
    '{hook_event_name: $event, session_id: $session, tool_name: $tool, tool_input: ({file_path: $path} + (if $command == "" then {} else {command: $command} end)), stop_hook_active: $active}'
}
# edit then stop: one reminder, then the continuation finishes.
run "$verifygate" "$(vg PostToolUse s1 Edit /repo/src/a.ts)"; expect 0 "PostToolUse never blocks"
run "$verifygate" "$(vg Stop s1)"; expect 2 "edit without a later shell command must remind once"
grep -Fq 'b-agentic verify gate' <<<"$err" || fail "reminder text missing"
run "$verifygate" "$(vg Stop s1 '' '' true)"; expect 0 "the continuation must be allowed to stop"
# a shell command after the edit counts as a check.
run "$verifygate" "$(vg PostToolUse s2 Write /repo/src/a.ts)"; expect 0 "write"
run "$verifygate" "$(vg PostToolUse s2 Bash)"; expect 0 "bash"
run "$verifygate" "$(vg Stop s2)"; expect 0 "edit then check must not remind"
# an edit after the check re-arms the reminder.
run "$verifygate" "$(vg PostToolUse s3 Bash)"; expect 0 "bash"
run "$verifygate" "$(vg PostToolUse s3 Edit /repo/src/a.ts)"; expect 0 "edit"
run "$verifygate" "$(vg Stop s3)"; expect 2 "edit after the check must remind"
# prose-only edits carry nothing to verify.
run "$verifygate" "$(vg PostToolUse s4 Edit /repo/README.md)"; expect 0 "prose edit"
run "$verifygate" "$(vg Stop s4)"; expect 0 "prose edit must not remind"
# nothing edited, nothing to remind.
run "$verifygate" "$(vg Stop s5)"; expect 0 "no edits must not remind"
# read-only searches and listings are not check attempts; anything else still is.
run "$verifygate" "$(vg PostToolUse s20 Edit /repo/src/a.ts)"; expect 0 "edit"
run "$verifygate" "$(vg PostToolUse s20 Bash '' false "rtk rg -n 'a|b' src | head -5")"; expect 0 "search"
run "$verifygate" "$(vg PostToolUse s20 Bash '' false 'git status --short && ls src')"; expect 0 "listing"
run "$verifygate" "$(vg Stop s20)"; expect 2 "searches after an edit must not clear the reminder"
run "$verifygate" "$(vg PostToolUse s21 Edit /repo/src/a.ts)"; expect 0 "edit"
run "$verifygate" "$(vg PostToolUse s21 Bash '' false 'rg -n x src && npm test')"; expect 0 "search plus test"
run "$verifygate" "$(vg Stop s21)"; expect 0 "a compound command that runs a check must clear the reminder"
run "$verifygate" "$(vg PostToolUse s22 Edit /repo/src/a.ts)"; expect 0 "edit"
run "$verifygate" "$(vg PostToolUse s22 Bash '' false 'find . -name x -exec node {} ;')"; expect 0 "find exec"
run "$verifygate" "$(vg Stop s22)"; expect 0 "find -exec must count as a check attempt"
run "$verifygate" "$(vg PostToolUse s23 Edit /repo/src/a.ts)"; expect 0 "edit"
run "$verifygate" "$(vg PostToolUse s23 Bash '' false 'cat src/a.ts > /tmp/x')"; expect 0 "redirect"
run "$verifygate" "$(vg Stop s23)"; expect 0 "a redirecting command must count as a check attempt"
# classifier regressions: quoted or escaped arguments are data, executing options are not.
gate_case() { # session, exit code at Stop (2 = still dirty), command, description
  run "$verifygate" "$(vg PostToolUse "$1" Edit /repo/src/a.ts)"; expect 0 "edit"
  run "$verifygate" "$(vg PostToolUse "$1" Bash '' false "$3")"; expect 0 "shell"
  run "$verifygate" "$(vg Stop "$1")"; expect "$2" "$4"
}
gate_case s24 2 'rg foo\|bar src' "an escaped pipe is an argument, not a pipeline"
gate_case s25 2 $'rg -F \'$(name)\' src' "a single-quoted substitution is data"
gate_case s26 2 'git -C . status --short' "git -C with a read subcommand is inspection"
gate_case s27 0 'fdfind . -x npm test' "fd -x executes a command"
gate_case s28 0 "find . '-exec' node {} +" "a quoted -exec still executes"
gate_case s29 0 'rg foo > /dev/null' "a redirect to /dev/null is still a redirect"
gate_case s30 0 'rg --pre ./filter foo src' "rg --pre executes a command"
gate_case s31 0 'git -c core.pager=./x log' "git -c can run a command"
gate_case s32 0 'FOO=1 rg foo src' "an environment assignment prefix is not interpreted"
gate_case s33 0 'tree -o /tmp/listing.txt .' "tree can write a file, so it is not inspection"
gate_case s34 0 'file -C -m custom.magic' "file -C compiles a magic file, so it is not inspection"
gate_case s35 0 'find . -maxdepth 0 "$ACTION" echo {} +' "a double-quoted expansion is ambiguous"
gate_case s36 0 $'find . "-ex\\\nec" echo {} +' "a backslash-newline inside double quotes is removed"
gate_case s37 2 'rg "a|b" "src dir"' "a double-quoted pattern and path are data"
gate_case s38 0 'find . -maxdepth 0 -exe{c..c} echo {} +' "brace expansion can build -exec"
gate_case s39 0 'git diff --out{put,put}=/tmp/result' "brace expansion can build --output"
gate_case s40 0 'find . -exe? echo {} +' "a glob in an option word is ambiguous"
gate_case s41 2 'echo {} src' "a literal {} is data"
gate_case s42 0 'find . ?exec echo {} +' "a leading ? could expand to -exec"
gate_case s43 0 'find . [a-]exec echo {} +' "a leading bracket class could expand to -exec"
gate_case s44 0 'rg foo *' "a bare * could expand to an option file name for rg"
gate_case s45 2 'ls *.mjs && cat src/*.md' "leading globs are fine for tools without executing options"
gate_case s46 2 'rg foo src/*.mjs' "a fixed-prefix glob is fine"
# a subagent's shell command (it carries agent_id) is not the main session's check.
sub=$(vg PostToolUse s47 Bash '' false 'npm test' | jq -c '. + {agent_id: "a1", agent_type: "b-debugger"}')
run "$verifygate" "$(vg PostToolUse s47 Edit /repo/src/a.ts)"; expect 0 "edit"
run "$verifygate" "$sub"; expect 0 "subagent shell"
run "$verifygate" "$(vg Stop s47)"; expect 2 "a subagent shell command must not clear the main session's reminder"
# editing again during the continuation earns no second reminder.
run "$verifygate" "$(vg PostToolUse s6 Edit /repo/src/a.ts)"; expect 0 "edit"
run "$verifygate" "$(vg Stop s6)"; expect 2 "first stop reminds"
run "$verifygate" "$(vg PostToolUse s6 Edit /repo/src/b.ts)"; expect 0 "edit during continuation"
run "$verifygate" "$(vg Stop s6 '' '' true)"; expect 0 "no second reminder in the same continuation"
run "$verifygate" "$(vg Stop s6)"; expect 0 "state is cleared after the continuation"
# sessions are independent.
run "$verifygate" "$(vg PostToolUse s7 Edit /repo/src/a.ts)"; expect 0 "edit in s7"
run "$verifygate" "$(vg Stop s8)"; expect 0 "another session is unaffected"
run "$verifygate" 'not json'; expect 0 "malformed input must fail open"
# a symlinked state file must not be followed.
if [ "$(uname -s)" != MINGW ]; then
  victim="$work/victim"; printf keep >"$victim"
  ln -s "$victim" "$work/gate/s9.json"
  run "$verifygate" "$(vg PostToolUse s9 Edit /repo/src/a.ts)"; expect 0 "symlinked state must fail open"
  [ "$(cat "$victim")" = keep ] || fail "verify-gate followed a symlinked state file"
  rm -f "$work/gate/s9.json"
  # a non-regular state file must not block the hook.
  mkfifo "$work/gate/s10.json"
  run "$verifygate" "$(vg Stop s10)"; expect 0 "FIFO state must fail open without blocking"
  rm -f "$work/gate/s10.json"
  # a group/other-accessible state directory disables the gate.
  chmod 755 "$work/gate"
  run "$verifygate" "$(vg PostToolUse s11 Edit /repo/src/a.ts)"; expect 0 "permissive dir"
  run "$verifygate" "$(vg Stop s11)"; expect 0 "permissive state dir must fail open"
  [ ! -e "$work/gate/s11.json" ] || fail "verify-gate wrote into a permissive directory"
  chmod 700 "$work/gate"
  # a rejected (symlinked) state directory must not have files deleted through it.
  mv "$work/gate" "$work/gate.real"
  ln -s "$work/gate.real" "$work/gate"
  printf '{"dirty":false,"reminded":false}' >"$work/gate.real/s12.json"
  run "$verifygate" "$(vg Stop s12)"; expect 0 "symlinked state dir must fail open"
  [ -e "$work/gate.real/s12.json" ] || fail "verify-gate deleted a file through a symlinked state directory"
  rm -f "$work/gate"
  mv "$work/gate.real" "$work/gate"
fi
echo "hooks probe passed: verify-gate"
