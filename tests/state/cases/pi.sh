# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034,SC2088,SC2030,SC2031 # Variables are shared with state-probe.sh and the other files it sources; the quoted tilde is the literal text the CLI prints.
# The helpers on Pi: the helper folder override is the one signal; Pi supports b-worker and parallel worktrees, while keeping the reviewer-only gate.
# --- worker steps, worktrees, and the reviewer gate on Pi ---------------------------------------------
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
    {id: "S-3", action: "c", paths: ["src/c.txt"], done_when: "d", depends_on: ["S-1"]},
    {id: "S-4", action: "d", paths: ["src/d.txt"], done_when: "d", depends_on: ["S-1"]}],
    checks: ["make test"], invariants: [], stop_conditions: [],
    worker_steps: ["S-2", "S-3", "S-4"], parallel_steps: ["S-2", "S-3", "S-4"]}'
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

# Claude Code keeps its own batch dispatch wording; Pi names one parallel-workflow subagent call and ~/.pi/agent/b-agentic/bin.
ok "$repoPI" s1 check
jq -e '.next | any(contains("all calls in one message, then end the turn"))' <<<"$out" >/dev/null \
  || fail "Claude Code keeps its batch message wording: $out"

pi_ok "$repoPI" s1 check
batch_line=$(jq -r '.next[] | select(startswith("these worker steps may run at the same time, each in its own worktree: S-2, S-3;"))' <<<"$out")
[ -n "$batch_line" ] || fail "Pi lists the parallel batch for S-2, S-3: $out"
grep -Fq 'one subagent call with workflow parallel and one {agent: "b-worker", task, cwd} entry per step' <<<"$batch_line" \
  || fail "Pi batch line names one parallel workflow subagent call: $batch_line"
grep -Fq '~/.pi/agent/b-agentic/bin/b-state worktree add S-n' <<<"$batch_line" \
  || fail "Pi batch line uses ~/.pi/agent/b-agentic/bin: $batch_line"
jq -e '.next | any(startswith("hand S-4 to one b-worker with ~/.pi/agent/b-agentic/bin/b-run handoff implement --step S-4"))' <<<"$out" >/dev/null \
  || fail "Pi keeps single-worker handoff for non-batched S-4: $out"
jq -e '.next | all((contains("all calls in one message") or contains("codex") or contains("~/.claude")) | not)' <<<"$out" >/dev/null \
  || fail "no Pi next line names Claude batch wording, Codex, or ~/.claude: $out"

# Worktree lifecycle and --by worker on Pi.
pi_ok "$repoPI" s1 worktree add S-2
wt2=$(jq -r '.dir' <<<"$out")
pi_ok "$repoPI" s1 worktree add S-3
wt3=$(jq -r '.dir' <<<"$out")
pi_ok "$repoPI" s1 check
jq -e '.next | any(startswith("worktrees exist for S-2, S-3:"))' <<<"$out" >/dev/null \
  || fail "Pi check lists open worktrees: $out"

printf 'b\n' >"$wt2/src/b.txt"
pi_ok "$repoPI" s1 worktree collect S-2
apply2=$(jq -r '.apply' <<<"$out")
(cd "$repoPI" && sh -c "$apply2")
pi_invalid "$repoPI" s1 record step S-2
grep -Fq -- '--by worker' "$work/err" || fail "Pi worker step without --by names --by worker: $(cat "$work/err")"
pi_ok "$repoPI" s1 record step S-2 --by worker
[ "$(jq -c '.history[-1].detail | [.step, .by, .worktree]' "$(sfile "$repoPI")")" = '["S-2","worker",true]' ] \
  || fail "Pi records parallel worker step with by worker and worktree true"
pi_refused "$repoPI" s1 record step S-2 --by worker
grep -Fq 'recorded once' "$work/err" || fail "a worker step is recorded once on Pi too: $(cat "$work/err")"
pi_ok "$repoPI" s1 worktree remove S-2

# An open worktree still blocks advance verify and unblock verify on Pi, and failed git listing refuses fail-closed.
fakegit="$work/fakegit"
mkdir -p "$fakegit"
real_git=$(command -v git)
# shellcheck disable=SC2016 # The $1, $2 and "$@" belong to the generated script, not to this shell.
printf '#!/bin/sh\nif [ "$1" = worktree ] && [ "$2" = list ]; then exit 1; fi\nexec "%s" "$@"\n' "$real_git" >"$fakegit/git"
chmod +x "$fakegit/git"

printf 'c\n' >"$wt3/src/c.txt"
pi_ok "$repoPI" s1 worktree collect S-3
apply3=$(jq -r '.apply' <<<"$out")
(cd "$repoPI" && sh -c "$apply3")
pi_ok "$repoPI" s1 record step S-3 --by worker
printf 'd\n' >"$repoPI/src/d.txt"
pi_ok "$repoPI" s1 record step S-4 --by main
before=$(snap "$repoPI")
PATH="$fakegit:$PATH" pi_refused "$repoPI" s1 advance verify
grep -Fq 'git worktree list failed' "$work/err" || fail "a failed listing must refuse advance verify on Pi: $(cat "$work/err")"
[ "$before" = "$(snap "$repoPI")" ] || fail "a refused advance verify must not write state"
pi_refused "$repoPI" s1 advance verify
grep -Fq 'worktrees of this run remain: S-3' "$work/err" || fail "open worktree blocks verify on Pi: $(cat "$work/err")"
pi_ok "$repoPI" s1 advance blocked --reason "probe" --needs "probe"
before=$(snap "$repoPI")
PATH="$fakegit:$PATH" pi_refused "$repoPI" s1 unblock verify --reason "probe"
grep -Fq 'git worktree list failed' "$work/err" || fail "a failed listing must refuse unblock verify on Pi: $(cat "$work/err")"
pi_refused "$repoPI" s1 unblock verify --reason "probe"
grep -Fq 'worktrees of this run remain: S-3' "$work/err" || fail "unblock verify must refuse while a worktree remains: $(cat "$work/err")"
[ "$before" = "$(snap "$repoPI")" ] || fail "a refused unblock verify must not write state"
pi_ok "$repoPI" s1 worktree remove S-3
pi_ok "$repoPI" s1 unblock verify --reason "probe"

# A worktree under a folder whose name holds a newline is still caught by NUL-delimited runWorktrees.
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
TMPDIR="$nl_tmp" pi_ok "$repoPN" s1 worktree add S-2
printf 'b\n' >"$repoPN/src/b.txt"
pi_ok "$repoPN" s1 record step S-2 --by main
printf 'c\n' >"$repoPN/src/c.txt"
pi_ok "$repoPN" s1 record step S-3 --by main
printf 'd\n' >"$repoPN/src/d.txt"
pi_ok "$repoPN" s1 record step S-4 --by main
before=$(snap "$repoPN")
pi_refused "$repoPN" s1 advance verify
grep -Fq 'worktrees of this run remain: S-2' "$work/err" || fail "a newline path must still stop verify on Pi: $(cat "$work/err")"
[ "$before" = "$(snap "$repoPN")" ] || fail "a refused newline advance verify must not write state"
pi_ok "$repoPN" s1 worktree remove S-2
pi_ok "$repoPN" s1 advance verify

# --- the review gate on Pi ----------------------------------------------------------------------
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

# --- the usage text names what Pi can run -------------------------------------------------------
claude_usage=$("${js[@]}" "$cli" help)
pi_usage=$(B_AGENTIC_HELPER_DIR="$pi_dir" "${js[@]}" "$cli" help)
grep -Fq 'record step S-n [--by worker|main]' <<<"$claude_usage" || fail "Claude Code usage keeps --by worker|main"
grep -Fq 'worktree add|collect|remove S-n' <<<"$claude_usage" || fail "Claude Code usage keeps the worktree commands"
grep -Fq 'record step S-n [--by worker|main]' <<<"$pi_usage" || fail "Pi usage keeps --by worker|main"
grep -Fq 'worktree add|collect|remove S-n' <<<"$pi_usage" || fail "Pi usage keeps worktree add|collect|remove"
! grep -Eq 'codex\|reviewer|Codex was not used' <<<"$pi_usage" || fail "Pi usage names no Codex option: $pi_usage"
grep -Fq -- '--gate reviewer --gate-reason R' <<<"$pi_usage" || fail "Pi usage names the reviewer gate"
