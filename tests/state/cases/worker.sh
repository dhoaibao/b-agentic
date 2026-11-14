# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034 # Variables are shared with state-probe.sh and the other files it sources.
# Worker steps recorded with who applied them (ADR-015).
# --- a plan step handed to a worker is recorded with who applied it (ADR-015) -----------------
worker_plan() { steps_plan | jq '.worker_steps = ["S-2", "S-3"]'; }
snap() { jq -S . "$(sfile "$1")"; }
repoWK="$work/repoWK"
make_repo "$repoWK"
ok "$repoWK" s1 init workers
spec_json 1 'src/**' | br "$repoWK" s1 write spec >/dev/null || fail "write spec (repoWK)"
worker_plan | br "$repoWK" s1 write plan >/dev/null || fail "write plan (repoWK)"
ok "$repoWK" s1 approve --commit yes --branch-target current --codex reviewer
ok "$repoWK" s1 advance implement
ok "$repoWK" s1 check
[ "$(jq -r '.next[1]' <<<"$out")" = "apply S-1 inside the approved scope, then b-state.mjs record step S-1" ] \
  || fail "a step that is not a worker step keeps its next line: $out"
for id in S-2 S-3; do
  [ "$(jq -r --arg id "$id" '.next[] | select(startswith("hand " + $id))' <<<"$out")" = "hand $id to one b-worker with b_run.py handoff implement --step $id and wait for its report (or apply it yourself), then b-state.mjs record step $id --by worker (--by main when the main session applied it)" ] \
    || fail "a worker step is handed over by its next line: $out"
done
# Every guard comes before any write: nothing changes, and nothing counts as a refused step.
mkdir -p "$repoWK/src"
printf 'a\n' >"$repoWK/src/a.txt"
before=$(snap "$repoWK")
invalid "$repoWK" s1 record step S-2
grep -Fq 'worker step' "$work/err" || fail "a worker step without --by must say so: $(cat "$work/err")"
invalid "$repoWK" s1 record step S-2 --by robot
invalid "$repoWK" s1 record step S-1 --by robot
refused "$repoWK" s1 record step S-1 --by worker
grep -Fq 'worker_steps' "$work/err" || fail "--by on a step the plan does not list must name worker_steps: $(cat "$work/err")"
refused "$repoWK" s1 record step S-1 --by main
[ "$before" = "$(snap "$repoWK")" ] || fail "a refused or invalid --by must not change the state"
ok "$repoWK" s1 record step S-1
[ "$(jq -c '.history[-1].detail | has("by")' "$(sfile "$repoWK")")" = false ] || fail "a step that is not a worker step records no --by"
# A worker step: recorded with who applied it, once.
printf 'b\n' >"$repoWK/src/b.txt"
ok "$repoWK" s1 record step S-2 --by worker
[ "$(jq -c '.history[-1].detail | [.step, .by, .paths, .outside, (.tree | length)]' "$(sfile "$repoWK")")" = '["S-2","worker",1,0,40]' ] \
  || fail "a worker step records who applied it, with the gate's measurements: $(jq -c '.history[-1]' "$(sfile "$repoWK")")"
before=$(snap "$repoWK")
refused "$repoWK" s1 record step S-2 --by worker
grep -Fq 'already recorded' "$work/err" || fail "a worker step is recorded once: $(cat "$work/err")"
refused "$repoWK" s1 record step S-2 --by main
[ "$before" = "$(snap "$repoWK")" ] || fail "re-recording a worker step must not change the state"
# The step's packet carries the state revision, so the main session sees any write after handing it over.
packet_rev() { (cd "$1" && python3 -I -B "$run_cli" handoff implement --step S-3 --owner s1 | grep '^State revision: '); }
rev_before=$(packet_rev "$repoWK")
printf 'c\n' >"$repoWK/src/c.txt"
printf 'x\n' >"$repoWK/README.md"
refused "$repoWK" s1 record step S-3 --by worker
[ "$(jq -c '[.recorded, .attempts, .phase]' <<<"$out")" = '[false,1,"implement"]' ] || fail "a worker step outside the scope is refused by the gate: $out"
[ "$(jq -c '.history[-1].detail | [.step, .by, (.reason | startswith("outside the approved scope"))]' "$(sfile "$repoWK")")" = '["S-3","worker",true]' ] \
  || fail "a refused worker step keeps who applied it: $(jq -c '.history[-1]' "$(sfile "$repoWK")")"
[ "$rev_before" != "$(packet_rev "$repoWK")" ] || fail "a state write must change the revision the step packet carries"
rm "$repoWK/README.md"
ok "$repoWK" s1 record step S-3 --by main
[ "$(jq -c '.history[-1].detail | [.step, .by]' "$(sfile "$repoWK")")" = '["S-3","main"]' ] || fail "a worker step the main session applied is recorded --by main"
[ "$(jq -c '[.history[] | select(.op == "record step") | .detail | has("by")] | [index(true), index(false)]' "$(sfile "$repoWK")")" = '[1,0]' ] \
  || fail "only the steps handed to a worker carry --by"
ok "$repoWK" s1 advance verify
# A worker step needs the step base the gate checks it against; without one the main session applies it.
repoWB="$work/repoWB"
make_repo "$repoWB"
ok "$repoWB" s1 init nobase
spec_json 1 'src/**' | br "$repoWB" s1 write spec >/dev/null || fail "write spec (repoWB)"
steps_plan | jq '.worker_steps = ["S-1"]' | br "$repoWB" s1 write plan >/dev/null || fail "write plan (repoWB)"
ok "$repoWB" s1 approve --commit yes --branch-target current --codex reviewer
ok "$repoWB" s1 advance implement
jq '.step_base = null' "$(sfile "$repoWB")" >"$tmp" && cp "$tmp" "$(sfile "$repoWB")"
mkdir -p "$repoWB/src"
printf 'a\n' >"$repoWB/src/a.txt"
before=$(snap "$repoWB")
refused "$repoWB" s1 record step S-1 --by worker
grep -Fq 'step base' "$work/err" || fail "a worker step without a step base must say why: $(cat "$work/err")"
[ "$before" = "$(snap "$repoWB")" ] || fail "that refusal must not change the state"
ok "$repoWB" s1 record step S-1 --by main
[ "$(jq -c '.history[-1].detail | keys' "$(sfile "$repoWB")")" = '["by","fingerprint","step"]' ] || fail "an unchecked step still records who applied it"
# State written while a worker step runs stops the run, and the stop keeps who applied the step.
repoWS="$work/repoWS"
make_repo "$repoWS"
ok "$repoWS" s1 init statewrite
spec_json 1 'src/**' | br "$repoWS" s1 write spec >/dev/null || fail "write spec (repoWS)"
steps_plan | jq '.worker_steps = ["S-1"]' | br "$repoWS" s1 write plan >/dev/null || fail "write plan (repoWS)"
ok "$repoWS" s1 approve --commit yes --branch-target current --codex reviewer
ok "$repoWS" s1 advance implement
mkdir -p "$repoWS/src"
printf 'a\n' >"$repoWS/src/a.txt"
jq '.rev += 1' "$(sfile "$repoWS")" >"$tmp" && cp "$tmp" "$(sfile "$repoWS")"
refused "$repoWS" s1 record step S-1 --by worker
[ "$(jq -c '[.recorded, .phase, .blocked.reason]' <<<"$out")" = '[false,"blocked","run state was written outside the step"]' ] || fail "state written during a worker step must block the run: $out"
[ "$(jq -c '.history[-1].detail | [.step, .by, .reason]' "$(sfile "$repoWS")")" = '["S-1","worker","run state was written outside the step"]' ] \
  || fail "the block must keep who applied the step: $(jq -c '.history[-1]' "$(sfile "$repoWS")")"
# A quick run has no approval round to accept worker steps: refused by name.
repoWQ="$work/repoWQ"
make_repo "$repoWQ"
ok "$repoWQ" s1 init quickworker
quick_spec a.txt | br "$repoWQ" s1 write spec >/dev/null || fail "write quick spec (repoWQ)"
plan_json | jq '.worker_steps = ["S-1"]' | br "$repoWQ" s1 write plan >/dev/null || fail "write plan (repoWQ)"
before=$(snap "$repoWQ")
refused "$repoWQ" s1 "${quick_approve[@]}"
grep -Fq 'worker steps' "$work/err" || fail "a quick run with worker steps must be refused by name: $(cat "$work/err")"
[ "$before" = "$(snap "$repoWQ")" ] || fail "that refusal must not change the state"
# A plan without worker_steps keeps every next line and history entry as it was.
repoWN="$work/repoWN"
make_repo "$repoWN"
ok "$repoWN" s1 init noworker
spec_json 1 'src/**' | br "$repoWN" s1 write spec >/dev/null || fail "write spec (repoWN)"
steps_plan | br "$repoWN" s1 write plan >/dev/null || fail "write plan (repoWN)"
ok "$repoWN" s1 approve --commit yes --branch-target current --codex reviewer
ok "$repoWN" s1 advance implement
ok "$repoWN" s1 check
[ "$(jq -c '.next | map(select(startswith("apply ")))' <<<"$out")" = '["apply S-1 inside the approved scope, then b-state.mjs record step S-1","apply S-2 inside the approved scope, then b-state.mjs record step S-2","apply S-3 inside the approved scope, then b-state.mjs record step S-3"]' ] \
  || fail "a plan without worker_steps keeps its next lines: $out"
grep -Fq 'b-worker' <<<"$out" && fail "a plan without worker_steps never mentions the worker: $out"
grep -Fq 'worktree' <<<"$out" && fail "a plan without parallel_steps never mentions a worktree: $out"
mkdir -p "$repoWN/src"
printf 'a\n' >"$repoWN/src/a.txt"
ok "$repoWN" s1 record step S-1
refused "$repoWN" s1 record step S-1 --by main
[ "$(jq -c '.history[-1].detail | keys' "$(sfile "$repoWN")")" = '["fingerprint","outside","paths","step","tree"]' ] || fail "a step of a plan without worker_steps keeps its history keys"

