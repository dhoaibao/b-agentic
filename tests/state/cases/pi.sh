# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034,SC2088,SC2030,SC2031 # Variables are shared with state-probe.sh and the other files it sources; the quoted tilde is the literal text the CLI prints.
# The helpers on Pi: the helper folder override is the one signal, and Pi narrows what Claude Code accepts.
# --- worker steps, the Codex gate and worktrees on Pi ----------------------------------------------------
pi_dir='~/.pi/agent/b-agentic/bin'
# pi_ok, pi_refused, pi_invalid: the same helpers with the Pi override set for that one call.
pi_ok() { B_AGENTIC_HELPER_DIR="$pi_dir" ok "$@"; }
pi_refused() { B_AGENTIC_HELPER_DIR="$pi_dir" refused "$@"; }
pi_invalid() { B_AGENTIC_HELPER_DIR="$pi_dir" invalid "$@"; }
wt_tmp="$work/wt"
mkdir -p "$wt_tmp"
wt_tmp=$(cd "$wt_tmp" && pwd -P)
export TMPDIR="$wt_tmp"
pi_plan() {
  jq -n '{steps: [{id: "S-1", action: "a", paths: ["src/a.txt"], done_when: "d", depends_on: []},
    {id: "S-2", action: "b", paths: ["src/b.txt"], done_when: "d", depends_on: ["S-1"]},
    {id: "S-3", action: "c", paths: ["src/c.txt"], done_when: "d", depends_on: ["S-1"]}],
    checks: ["make test"], invariants: [], stop_conditions: [],
    worker_steps: ["S-2", "S-3"], parallel_steps: ["S-2", "S-3"]}'
}
repoPI="$work/repoPI"
make_repo "$repoPI"
ok "$repoPI" s1 init pi-workers
spec_json 1 'src/**' | br "$repoPI" s1 write spec >/dev/null || fail "write spec (repoPI)"
pi_plan | br "$repoPI" s1 write plan >/dev/null || fail "write plan (repoPI)"
ok "$repoPI" s1 approve --commit yes --branch-target current
ok "$repoPI" s1 advance implement
mkdir -p "$repoPI/src"
printf 'a\n' >"$repoPI/src/a.txt"
ok "$repoPI" s1 record step S-1
# Claude Code: the batch and the worker hand-over stay exactly as they were.
ok "$repoPI" s1 check
jq -e '.next | any(startswith("these worker steps may run at the same time, each in its own worktree: S-2, S-3;"))' <<<"$out" >/dev/null \
  || fail "Claude Code keeps its worktree batch line: $out"
# Pi: the main session applies every worker step and records it --by main; no batch, worktree, or b-worker line.
pi_ok "$repoPI" s1 check
[ "$(jq -r '.next[] | select(startswith("apply S-2"))' <<<"$out")" = "apply S-2 inside the approved scope, then ~/.pi/agent/b-agentic/bin/b-state record step S-2 --by main" ] \
  || fail "Pi applies a worker step itself and records it --by main: $out"
[ "$(jq -r '.next[] | select(startswith("apply S-3"))' <<<"$out")" = "apply S-3 inside the approved scope, then ~/.pi/agent/b-agentic/bin/b-state record step S-3 --by main" ] \
  || fail "Pi applies the second worker step itself too: $out"
jq -e '.next | all((contains("b-worker") or contains("worktree") or contains("codex") or contains("~/.claude")) | not)' <<<"$out" >/dev/null \
  || fail "no Pi next line names a worker, worktree, Codex, or the Claude folder: $out"
# Every Pi refusal comes before any write.
before=$(snap "$repoPI")
pi_refused "$repoPI" s1 record step S-2 --by worker
grep -Fq 'Pi has no worker' "$work/err" || fail "--by worker is refused on Pi with the reason: $(cat "$work/err")"
pi_invalid "$repoPI" s1 record step S-2
grep -Fq -- '--by main' "$work/err" || fail "a worker step without --by points to --by main on Pi: $(cat "$work/err")"
pi_refused "$repoPI" s1 worktree add S-2
grep -Fq 'Pi has no worker' "$work/err" || fail "worktree add is refused on Pi with the reason: $(cat "$work/err")"
pi_refused "$repoPI" s1 worktree collect S-2
grep -Fq 'Pi has no worker' "$work/err" || fail "worktree collect is refused on Pi with the reason: $(cat "$work/err")"
[ "$before" = "$(snap "$repoPI")" ] || fail "a Pi refusal must not change the state"
# Claude Code still takes --by worker on the same step; Pi takes --by main.
printf 'b\n' >"$repoPI/src/b.txt"
pi_ok "$repoPI" s1 record step S-2 --by main
[ "$(jq -c '.history[-1].detail | [.step, .by]' "$(sfile "$repoPI")")" = '["S-2","main"]' ] || fail "Pi records a worker step --by main"
pi_refused "$repoPI" s1 record step S-2 --by main
grep -Fq 'recorded once' "$work/err" || fail "a worker step is recorded once on Pi too: $(cat "$work/err")"
! grep -Fq 'report' "$work/err" || fail "the already-recorded text drops the worker report on Pi: $(cat "$work/err")"
# Open worker worktrees: a Claude Code run made one, and Pi refuses to resume it without writing or locking.
ok "$repoPI" s1 worktree add S-3
lock_before=$(cat "$(dirname "$(sfile "$repoPI")")/lock")
before=$(snap "$repoPI")
pi_refused "$repoPI" s1 check
grep -Fq 'open worker worktrees (S-3)' "$work/err" || fail "Pi refuses to resume a run with an open worker worktree: $(cat "$work/err")"
grep -Fq 'Claude Code' "$work/err" || fail "the Pi resume refusal says to continue in Claude Code: $(cat "$work/err")"
[ "$before" = "$(snap "$repoPI")" ] && [ "$lock_before" = "$(cat "$(dirname "$(sfile "$repoPI")")/lock")" ] || fail "the Pi resume refusal must write no state and take no lock"
ok "$repoPI" s1 check
jq -e '.next | any(contains("worktrees exist for S-3"))' <<<"$out" >/dev/null || fail "Claude Code still resumes the run and names the open worktree: $out"
# A failed worktree listing refuses too: it must never read as "no open worktrees", whoever holds the lock.
fakegit="$work/fakegit"
mkdir -p "$fakegit"
real_git=$(command -v git)
# shellcheck disable=SC2016 # The $1, $2 and "$@" belong to the generated script, not to this shell.
printf '#!/bin/sh\nif [ "$1" = worktree ] && [ "$2" = list ]; then exit 1; fi\nexec "%s" "$@"\n' "$real_git" >"$fakegit/git"
chmod +x "$fakegit/git"
before=$(snap "$repoPI")
lock_before=$(cat "$(dirname "$(sfile "$repoPI")")/lock")
PATH="$fakegit:$PATH" pi_refused "$repoPI" s2 check --takeover
grep -Fq 'git worktree list failed' "$work/err" || fail "a failed listing must refuse the Pi resume: $(cat "$work/err")"
[ "$before" = "$(snap "$repoPI")" ] && [ "$lock_before" = "$(cat "$(dirname "$(sfile "$repoPI")")/lock")" ] || fail "a refused takeover must not take the lock or write"
# Pi neither takes the lock nor records a step while a worker worktree is open: that would strand the worker's changes.
before=$(snap "$repoPI")
lock_before=$(cat "$(dirname "$(sfile "$repoPI")")/lock")
pi_refused "$repoPI" s2 lock --takeover
grep -Fq 'open worker worktrees (S-3)' "$work/err" || fail "an explicit Pi lock takeover must refuse over an open worktree: $(cat "$work/err")"
printf 'c\n' >"$repoPI/src/c.txt"
pi_refused "$repoPI" s1 record step S-3 --by main
grep -Fq 'open worker worktrees (S-3)' "$work/err" || fail "Pi must not record a step while a worker worktree is open: $(cat "$work/err")"
[ "$before" = "$(snap "$repoPI")" ] && [ "$lock_before" = "$(cat "$(dirname "$(sfile "$repoPI")")/lock")" ] || fail "a refused Pi lock or record must not write or move the lock"
# Claude Code records the step; Pi's verify refusal then sends the caller to Claude Code, not to a force-discard.
ok "$repoPI" s1 record step S-3 --by main
before=$(snap "$repoPI")
PATH="$fakegit:$PATH" pi_refused "$repoPI" s1 advance verify
grep -Fq 'git worktree list failed' "$work/err" || fail "a failed listing must refuse the Pi verify transition: $(cat "$work/err")"
[ "$before" = "$(snap "$repoPI")" ] || fail "a refused Pi verify transition must not change the state"
pi_refused "$repoPI" s1 advance verify
grep -Fq 'continue the run in Claude Code to inspect and collect' "$work/err" || fail "the Pi verify refusal points to Claude Code: $(cat "$work/err")"
grep -Fq 'force-discards' "$work/err" || fail "the Pi verify refusal warns that remove discards uncollected changes: $(cat "$work/err")"
# remove still works on Pi: it clears what a Claude Code run left.
pi_ok "$repoPI" s1 worktree remove S-3
pi_ok "$repoPI" s1 check

# --- a worktree under a folder whose name holds a newline still stops the Pi resume (the listing is NUL-delimited) ---
repoPN="$work/repoPN"
make_repo "$repoPN"
ok "$repoPN" s1 init pi-newline
spec_json 1 'src/**' | br "$repoPN" s1 write spec >/dev/null || fail "write spec (repoPN)"
pi_plan | br "$repoPN" s1 write plan >/dev/null || fail "write plan (repoPN)"
ok "$repoPN" s1 approve --commit yes --branch-target current
ok "$repoPN" s1 advance implement
mkdir -p "$repoPN/src"
printf 'a\n' >"$repoPN/src/a.txt"
ok "$repoPN" s1 record step S-1
nl_tmp="$work/nl"$'\n'"tmp"
mkdir -p "$nl_tmp"
TMPDIR="$nl_tmp" ok "$repoPN" s1 worktree add S-2
pi_refused "$repoPN" s1 check
grep -Fq 'open worker worktrees (S-2)' "$work/err" || fail "a worktree under a path with a newline must still stop the Pi resume: $(cat "$work/err")"
# A different lock owner gets the Claude Code message, not a takeover hint, and nothing moves.
before=$(snap "$repoPN")
lock_before=$(cat "$(dirname "$(sfile "$repoPN")")/lock")
pi_refused "$repoPN" s2 check
grep -Fq 'continue the run in Claude Code' "$work/err" || fail "a different owner must be told to continue in Claude Code: $(cat "$work/err")"
[ "$before" = "$(snap "$repoPN")" ] && [ "$lock_before" = "$(cat "$(dirname "$(sfile "$repoPN")")/lock")" ] || fail "a refused different-owner check must not write or move the lock"
printf 'b\n' >"$repoPN/src/b.txt"
ok "$repoPN" s1 record step S-2 --by main
printf 'c\n' >"$repoPN/src/c.txt"
ok "$repoPN" s1 record step S-3 --by main
before=$(snap "$repoPN")
pi_refused "$repoPN" s1 advance verify
grep -Fq 'worktrees of this run remain: S-2' "$work/err" || fail "a newline path must still stop the Pi verify transition: $(cat "$work/err")"
[ "$before" = "$(snap "$repoPN")" ] || fail "a refused Pi verify transition must not change the state"
# A blocked run with an open worker worktree is not unblocked from Pi, whoever holds the lock.
ok "$repoPN" s1 advance blocked --reason "probe" --needs "probe"
before=$(snap "$repoPN")
lock_before=$(cat "$(dirname "$(sfile "$repoPN")")/lock")
pi_refused "$repoPN" s1 unblock verify --reason "probe"
grep -Fq 'open worker worktrees (S-2)' "$work/err" || fail "Pi must not unblock a run over an open worktree: $(cat "$work/err")"
[ "$before" = "$(snap "$repoPN")" ] && [ "$lock_before" = "$(cat "$(dirname "$(sfile "$repoPN")")/lock")" ] || fail "a refused Pi unblock must not write or move the lock"

# --- the review gate on Pi --------------------------------------------------------------------------------------
repoPR="$work/repoPR"
make_repo "$repoPR"
ok "$repoPR" s1 init pi-review
write_artifacts "$repoPR" 1
ok "$repoPR" s1 approve --commit yes --branch-target current
ok "$repoPR" s1 advance implement
printf 'feature\n' >"$repoPR/f.txt"
apply_steps "$repoPR"
ok "$repoPR" s1 advance verify
ok "$repoPR" s1 record check --cmd "make test" --exit 0
ok "$repoPR" s1 advance review --trigger "workflow policy"
ok "$repoPR" s1 check
claude_gate_line=$(jq -r '.next[] | select(contains("record review"))' <<<"$out")
[ "$claude_gate_line" = '~/.claude/b-agentic/bin/b-state record review --verdict "<verdict>" --gate codex|reviewer [--gate-reason R]' ] || fail "Claude Code keeps its review line: $claude_gate_line"
pi_ok "$repoPR" s1 check
[ "$(jq -r '.next[] | select(contains("record review"))' <<<"$out")" = '~/.pi/agent/b-agentic/bin/b-state record review --verdict "<verdict>" --gate reviewer --gate-reason R' ] \
  || fail "Pi names only the reviewer gate: $out"
before=$(snap "$repoPR")
pi_invalid "$repoPR" s1 record review --verdict "READY FOR PR" --gate codex
grep -Fq 'Pi has no Codex gate' "$work/err" || fail "--gate codex is invalid on Pi with the reason: $(cat "$work/err")"
pi_invalid "$repoPR" s1 record review --verdict "READY FOR PR" --gate reviewer
grep -Fq 'why the reviewer gate ran' "$work/err" || fail "a reviewer gate needs its reason on Pi: $(cat "$work/err")"
[ "$before" = "$(snap "$repoPR")" ] || fail "a Pi gate refusal must not change the state"
pi_ok "$repoPR" s1 record review --verdict "READY FOR PR" --gate reviewer --gate-reason "Pi runtime: reviewer gate only"
[ "$(jq -r '.review.gate' "$(sfile "$repoPR")")" = reviewer ] || fail "Pi records the reviewer gate"

# --- the usage text names what Pi can run ------------------------------------------------------------------------------------
claude_usage=$("${js[@]}" "$cli" help)
pi_usage=$(B_AGENTIC_HELPER_DIR="$pi_dir" "${js[@]}" "$cli" help)
grep -Fq 'record step S-n [--by worker|main]' <<<"$claude_usage" || fail "Claude Code usage keeps --by worker|main"
grep -Fq 'worktree add|collect|remove S-n' <<<"$claude_usage" || fail "Claude Code usage keeps the worktree commands"
! grep -Eq 'worker\|main|add\|collect|codex\|reviewer|Codex was not used' <<<"$pi_usage" || fail "Pi usage names no worker, collect, or Codex option: $pi_usage"
grep -Fq -- '--gate reviewer --gate-reason R' <<<"$pi_usage" || fail "Pi usage names the reviewer gate"
grep -Fq 'worktree remove S-n' <<<"$pi_usage" || fail "Pi usage names worktree remove"
grep -Fq -- '--by main' <<<"$pi_usage" || fail "Pi usage names --by main"
