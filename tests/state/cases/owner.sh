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
(cd "$repoP" && env -u CLAUDE_CODE_SESSION_ID -u ANTIGRAVITY_CONVERSATION_ID "${js[@]}" "$cli" lock >/dev/null 2>"$work/err") || rc=$?
[ "$rc" -eq 2 ] || fail "a missing owner must be invalid input: rc=$rc"

# --- the Antigravity conversation id is the fallback owner (ADR-025) ---------
repoA="$work/repoA"
make_repo "$repoA"
ok "$repoA" s1 init agy-owner
(cd "$repoA" && env -u CLAUDE_CODE_SESSION_ID ANTIGRAVITY_CONVERSATION_ID=agy-conv-1 "${js[@]}" "$cli" lock --takeover >/dev/null 2>"$work/err") \
  || fail "lock --takeover with ANTIGRAVITY_CONVERSATION_ID: $(cat "$work/err")"
[ "$(jq -r .owner "$(dirname "$(sfile "$repoA")")/lock")" = "agy-conv-1" ] || fail "the lock owner must be the ANTIGRAVITY_CONVERSATION_ID value when no Claude session id is set"
(cd "$repoA" && env CLAUDE_CODE_SESSION_ID=claude-session-2 ANTIGRAVITY_CONVERSATION_ID=agy-conv-1 "${js[@]}" "$cli" lock --takeover >/dev/null 2>"$work/err") \
  || fail "lock --takeover with both variables: $(cat "$work/err")"
[ "$(jq -r .owner "$(dirname "$(sfile "$repoA")")/lock")" = "claude-session-2" ] || fail "CLAUDE_CODE_SESSION_ID must win when both variables are set"

# --- no command outside a git worktree ---------------------------------------
mkdir -p "$work/plain"
refused "$work/plain" s1 show

