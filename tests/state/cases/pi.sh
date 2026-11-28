# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034,SC2088,SC2030,SC2031 # Variables are shared with state-probe.sh and the other files it sources; the quoted tilde is the literal text the CLI prints.
# The helpers on Pi: the helper folder override is the one signal; Pi supports single b-worker steps, while keeping the reviewer-only gate.
# --- worker steps and the reviewer gate on Pi ---------------------------------------------
pi_dir='~/.pi/agent/b-agentic/bin'
# pi_ok, pi_refused, pi_invalid: the same helpers with the Pi override set for that one call.
pi_ok() { B_AGENTIC_HELPER_DIR="$pi_dir" ok "$@"; }
pi_refused() { B_AGENTIC_HELPER_DIR="$pi_dir" refused "$@"; }
pi_invalid() { B_AGENTIC_HELPER_DIR="$pi_dir" invalid "$@"; }
pi_plan() {
  jq -n '{steps: [{id: "S-1", action: "a", paths: ["src/a.txt"], done_when: "d", depends_on: []},
    {id: "S-2", action: "b", paths: ["src/b.txt"], done_when: "d", depends_on: ["S-1"]},
    {id: "S-3", action: "c", paths: ["src/c.txt"], done_when: "d", depends_on: ["S-1"]},
    {id: "S-4", action: "d", paths: ["src/d.txt"], done_when: "d", depends_on: ["S-1"]}],
    checks: ["make test"], invariants: [], stop_conditions: [],
    worker_steps: ["S-2", "S-3", "S-4"]}'
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

# The runtime recorded at init follows the helper folder override.
repoPIrt="$work/repoPIrt"
make_repo "$repoPIrt"
pi_ok "$repoPIrt" s1 init pi-runtime
[ "$(jq -r .runtime "$(sfile "$repoPIrt")")" = pi ] || fail "init under the Pi override must record runtime pi"

# Pi hands each ready worker step to one worker, naming ~/.pi/agent/b-agentic/bin.
pi_ok "$repoPI" s1 check
for step in S-2 S-3 S-4; do
  jq -e --arg line "hand $step to one b-worker with ~/.pi/agent/b-agentic/bin/b-run handoff implement --step $step" \
    '.next | any(startswith($line))' <<<"$out" >/dev/null || fail "Pi keeps the single-worker handoff for $step: $out"
done
jq -e '.next | all((contains("at the same time") or contains("worktree") or contains("codex") or contains("~/.claude")) | not)' <<<"$out" >/dev/null \
  || fail "no Pi next line names a batch, a worktree, Codex, or ~/.claude: $out"

# --by worker on Pi: required, recorded once, and the history carries no worktree key.
printf 'b\n' >"$repoPI/src/b.txt"
pi_invalid "$repoPI" s1 record step S-2
grep -Fq -- '--by worker' "$work/err" || fail "Pi worker step without --by names --by worker: $(cat "$work/err")"
pi_ok "$repoPI" s1 record step S-2 --by worker
[ "$(jq -c '.history[-1].detail | [.step, .by, has("worktree")]' "$(sfile "$repoPI")")" = '["S-2","worker",false]' ] \
  || fail "Pi records a worker step with by worker and no worktree key"
pi_refused "$repoPI" s1 record step S-2 --by worker
grep -Fq 'recorded once' "$work/err" || fail "a worker step is recorded once on Pi too: $(cat "$work/err")"
printf 'c\n' >"$repoPI/src/c.txt"
pi_ok "$repoPI" s1 record step S-3 --by worker
printf 'd\n' >"$repoPI/src/d.txt"
pi_ok "$repoPI" s1 record step S-4 --by main
pi_ok "$repoPI" s1 advance verify
pi_ok "$repoPI" s1 advance blocked --reason "probe" --needs "probe"
pi_ok "$repoPI" s1 unblock verify --reason "probe"

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
grep -Fq 'record step S-n [--by worker|main]' <<<"$pi_usage" || fail "Pi usage keeps --by worker|main"
! grep -Fq 'worktree add' <<<"$claude_usage$pi_usage" || fail "no usage lists a worktree command"
! grep -Eq 'codex\|reviewer|Codex was not used' <<<"$pi_usage" || fail "Pi usage names no Codex option: $pi_usage"
grep -Fq -- '--gate reviewer --gate-reason R' <<<"$pi_usage" || fail "Pi usage names the reviewer gate"
