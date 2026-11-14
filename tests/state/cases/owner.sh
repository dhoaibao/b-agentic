# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034 # Variables are shared with state-probe.sh and the other files it sources.
# The lock owner variables and the command outside a git worktree.
# --- the lock owner may come from the Claude Code or the Pi session variable ----------
repoP="$work/repoP"
make_repo "$repoP"
ok "$repoP" s1 init pi-owner
(cd "$repoP" && env -u CLAUDE_CODE_SESSION_ID PI_SESSION_ID=pi-session-1 node "$cli" lock --takeover >/dev/null 2>"$work/err") \
  || fail "PI_SESSION_ID must be accepted as the lock owner: $(cat "$work/err")"
[ "$(jq -r .owner "$(dirname "$(sfile "$repoP")")/lock")" = "pi-session-1" ] || fail "the lock owner must be the PI_SESSION_ID value"
(cd "$repoP" && env CLAUDE_CODE_SESSION_ID=claude-session-1 PI_SESSION_ID=pi-session-2 node "$cli" lock --takeover >/dev/null 2>"$work/err") \
  || fail "lock --takeover with both variables set: $(cat "$work/err")"
[ "$(jq -r .owner "$(dirname "$(sfile "$repoP")")/lock")" = "claude-session-1" ] || fail "CLAUDE_CODE_SESSION_ID must win over PI_SESSION_ID"
rc=0
(cd "$repoP" && env -u CLAUDE_CODE_SESSION_ID -u PI_SESSION_ID node "$cli" lock >/dev/null 2>"$work/err") || rc=$?
[ "$rc" -eq 2 ] || fail "a missing owner must be invalid input: rc=$rc"

# --- no command outside a git worktree ---------------------------------------
mkdir -p "$work/plain"
refused "$work/plain" s1 show

