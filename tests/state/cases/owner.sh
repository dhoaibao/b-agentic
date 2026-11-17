# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034 # Variables are shared with state-probe.sh and the other files it sources.
# The lock owner variables and the command outside a git worktree.
# --- the lock owner comes from the Claude Code session variable ----
repoP="$work/repoP"
make_repo "$repoP"
ok "$repoP" s1 init pi-owner
(cd "$repoP" && env CLAUDE_CODE_SESSION_ID=claude-session-1 "${js[@]}" "$cli" lock --takeover >/dev/null 2>"$work/err") \
  || fail "lock --takeover with CLAUDE_CODE_SESSION_ID: $(cat "$work/err")"
[ "$(jq -r .owner "$(dirname "$(sfile "$repoP")")/lock")" = "claude-session-1" ] || fail "the lock owner must be the CLAUDE_CODE_SESSION_ID value"
rc=0
(cd "$repoP" && env -u CLAUDE_CODE_SESSION_ID "${js[@]}" "$cli" lock >/dev/null 2>"$work/err") || rc=$?
[ "$rc" -eq 2 ] || fail "a missing owner must be invalid input: rc=$rc"

# --- no command outside a git worktree ---------------------------------------
mkdir -p "$work/plain"
refused "$work/plain" s1 show

