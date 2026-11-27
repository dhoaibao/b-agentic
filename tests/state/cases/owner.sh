# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034 # Variables are shared with state-probe.sh and the other files it sources.
# shellcheck disable=SC2088,SC2016 # The helper folder is the literal text ~/... that the helpers print, never expanded.
# The lock owner variables, the printed helper folder, and the command outside a git worktree.
# --- the lock owner comes from the Claude Code session variable ----
repoP="$work/repoP"
make_repo "$repoP"
ok "$repoP" s1 init pi-owner
lock_owner() { jq -r .owner "$(dirname "$(sfile "$repoP")")/lock"; }
(cd "$repoP" && env CLAUDE_CODE_SESSION_ID=claude-session-1 "${js[@]}" "$cli" lock --takeover >/dev/null 2>"$work/err") \
  || fail "lock --takeover with CLAUDE_CODE_SESSION_ID: $(cat "$work/err")"
[ "$(lock_owner)" = "claude-session-1" ] || fail "the lock owner must be the CLAUDE_CODE_SESSION_ID value"
rc=0
(cd "$repoP" && env -u CLAUDE_CODE_SESSION_ID -u PI_SESSION_ID "${js[@]}" "$cli" lock >/dev/null 2>"$work/err") || rc=$?
[ "$rc" -eq 2 ] || fail "a missing owner must be invalid input: rc=$rc"
grep -Fq 'or set CLAUDE_CODE_SESSION_ID' "$work/err" || fail "the Claude Code message must name its session variable: $(cat "$work/err")"
! grep -Fq 'PI_SESSION_ID' "$work/err" || fail "the Claude Code message must not mention the Pi variable: $(cat "$work/err")"

# --- the Pi session variable is the fallback, and the order is --owner, Claude Code, Pi ---
(cd "$repoP" && env -u CLAUDE_CODE_SESSION_ID PI_SESSION_ID=pi-session-1 "${js[@]}" "$cli" lock --takeover >/dev/null 2>"$work/err") \
  || fail "lock --takeover with PI_SESSION_ID: $(cat "$work/err")"
[ "$(lock_owner)" = "pi-session-1" ] || fail "the lock owner must be the PI_SESSION_ID value when no Claude Code variable is set"
(cd "$repoP" && env CLAUDE_CODE_SESSION_ID=claude-session-2 PI_SESSION_ID=pi-session-1 "${js[@]}" "$cli" lock --takeover >/dev/null 2>"$work/err") \
  || fail "lock --takeover with both variables: $(cat "$work/err")"
[ "$(lock_owner)" = "claude-session-2" ] || fail "CLAUDE_CODE_SESSION_ID must win over PI_SESSION_ID"
(cd "$repoP" && env CLAUDE_CODE_SESSION_ID=claude-session-2 PI_SESSION_ID=pi-session-1 "${js[@]}" "$cli" lock --takeover --owner explicit-3 >/dev/null 2>"$work/err") \
  || fail "lock --takeover with --owner: $(cat "$work/err")"
[ "$(lock_owner)" = "explicit-3" ] || fail "--owner must win over both session variables"

# An empty Claude Code variable counts as unset in both helpers, so the Pi variable still decides.
(cd "$repoP" && env CLAUDE_CODE_SESSION_ID= PI_SESSION_ID=pi-session-4 "${js[@]}" "$cli" lock --takeover >/dev/null 2>"$work/err") \
  || fail "lock --takeover with an empty CLAUDE_CODE_SESSION_ID: $(cat "$work/err")"
[ "$(lock_owner)" = "pi-session-4" ] || fail "an empty CLAUDE_CODE_SESSION_ID must fall through to PI_SESSION_ID in b-state"
py_owner() { env "$@" python3 -I -B -c "import sys; sys.path.insert(0, '$root/claude/bin'); import b_run_lib as b_run;print(b_run.default_owner({}))"; }
[ "$(py_owner CLAUDE_CODE_SESSION_ID= PI_SESSION_ID=pi-session-4)" = "pi-session-4" ] || fail "b_run must also take PI_SESSION_ID when the Claude Code variable is empty"
[ "$(py_owner CLAUDE_CODE_SESSION_ID=claude-session-2 PI_SESSION_ID=pi-session-4)" = "claude-session-2" ] || fail "b_run must keep CLAUDE_CODE_SESSION_ID first"
rc=0
env CLAUDE_CODE_SESSION_ID=claude-session-2 PI_SESSION_ID=pi-session-4 python3 -I -B -c "import sys; sys.path.insert(0, '$root/claude/bin'); import b_run_lib as b_run;b_run.default_owner({'owner': ''})" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "b_run must refuse an explicit empty --owner like b-state, not take the session identity"
[ "$(env CLAUDE_CODE_SESSION_ID=claude-session-2 python3 -I -B -c "import sys; sys.path.insert(0, '$root/claude/bin'); import b_run_lib as b_run;print(b_run.default_owner({'owner': 'explicit-6'}))")" = "explicit-6" ] || fail "b_run must keep an explicit --owner first"
rc=0
(cd "$repoP" && env CLAUDE_CODE_SESSION_ID= PI_SESSION_ID= "${js[@]}" "$cli" lock >/dev/null 2>"$work/err") || rc=$?
[ "$rc" -eq 2 ] || fail "two empty owner variables must be invalid input: rc=$rc"
rc=0
(cd "$repoP" && env CLAUDE_CODE_SESSION_ID=claude-session-5 PI_SESSION_ID=pi-session-5 "${js[@]}" "$cli" lock --takeover --owner "" >/dev/null 2>"$work/err") || rc=$?
[ "$rc" -eq 2 ] || fail "an explicit empty --owner must stay invalid input, not take the session identity: rc=$rc"
[ "$(lock_owner)" = "pi-session-4" ] || fail "a refused empty --owner must leave the lock unchanged"

# --- B_AGENTIC_HELPER_DIR: the folder the printed text names -------------------
pi_dir='~/.pi/agent/b-agentic/bin'
rc=0
(cd "$repoP" && env -u CLAUDE_CODE_SESSION_ID -u PI_SESSION_ID B_AGENTIC_HELPER_DIR="$pi_dir" "${js[@]}" "$cli" lock >/dev/null 2>"$work/err") || rc=$?
[ "$rc" -eq 2 ] || fail "a missing owner under the override must be invalid input: rc=$rc"
grep -Fq 'or set PI_SESSION_ID' "$work/err" || fail "the override message must name the Pi session variable: $(cat "$work/err")"
! grep -Fq 'CLAUDE_CODE_SESSION_ID' "$work/err" || fail "the override message must not name the Claude Code variable: $(cat "$work/err")"
first_line=$(env B_AGENTIC_HELPER_DIR="$pi_dir" "${js[@]}" "$cli" help | head -1)
[ "$first_line" = "Usage: $pi_dir/b-state <command> [args] [--run ID] [--owner NAME]" ] || fail "usage must name the override folder: $first_line"
first_line=$(env -u B_AGENTIC_HELPER_DIR "${js[@]}" "$cli" help | head -1)
[ "$first_line" = "Usage: ~/.claude/b-agentic/bin/b-state <command> [args] [--run ID] [--owner NAME]" ] || fail "usage must keep the Claude Code folder: $first_line"
first_line=$(env B_AGENTIC_HELPER_DIR='x; rm -rf y' "${js[@]}" "$cli" help | head -1)
[ "$first_line" = "Usage: ~/.claude/b-agentic/bin/b-state <command> [args] [--run ID] [--owner NAME]" ] || fail "an unsafe override must be ignored: $first_line"

# --- the JS and Python helpers agree on every override value ----------------------
for value in '~/.pi/agent/b-agentic/bin' '~/.pi/agent/b-agentic/bin//' '/opt/b-agentic/bin' 'x; rm -rf y' '$HOME/x' 'a b' '/' '' 'bin' './bin' '../bin' '~' '~x/bin' '/x y'; do
  from_js=$(B_AGENTIC_HELPER_DIR="$value" "${js[@]}" -e "import { helperDir } from '$root/claude/bin/b-state-core.mjs'; console.log(helperDir());")
  from_py=$(B_AGENTIC_HELPER_DIR="$value" python3 -I -B -c "import sys; sys.path.insert(0, '$root/claude/bin'); import b_run_lib as b_run;print(b_run.helper_dir())")
  [ "$from_js" = "$from_py" ] || fail "helperDir and helper_dir disagree for '$value': '$from_js' vs '$from_py'"
  pi_js=$(B_AGENTIC_HELPER_DIR="$value" "${js[@]}" -e "import { onPi } from '$root/claude/bin/b-state-core.mjs'; console.log(onPi());")
  pi_py=$(B_AGENTIC_HELPER_DIR="$value" python3 -I -B -c "import sys; sys.path.insert(0, '$root/claude/bin'); import b_run_lib as b_run;print(str(b_run.on_pi()).lower())")
  [ "$pi_js" = "$pi_py" ] || fail "onPi and on_pi disagree for '$value': '$pi_js' vs '$pi_py'"
done
[ "$(env -u B_AGENTIC_HELPER_DIR "${js[@]}" -e "import { onPi } from '$root/claude/bin/b-state-core.mjs'; console.log(onPi());")" = false ] || fail "onPi must be false without the override"
[ "$(B_AGENTIC_HELPER_DIR="$pi_dir" "${js[@]}" -e "import { onPi } from '$root/claude/bin/b-state-core.mjs'; console.log(onPi());")" = true ] || fail "onPi must be true under the Pi override"
from_js=$(env -u B_AGENTIC_HELPER_DIR "${js[@]}" -e "import { helperDir } from '$root/claude/bin/b-state-core.mjs'; console.log(helperDir());")
from_py=$(env -u B_AGENTIC_HELPER_DIR python3 -I -B -c "import sys; sys.path.insert(0, '$root/claude/bin'); import b_run_lib as b_run;print(b_run.helper_dir())")
[ "$from_js" = "~/.claude/b-agentic/bin" ] && [ "$from_py" = "$from_js" ] || fail "an unset override must give the Claude Code folder in both: '$from_js' vs '$from_py'"

# --- no command outside a git worktree ---------------------------------------
mkdir -p "$work/plain"
refused "$work/plain" s1 show
