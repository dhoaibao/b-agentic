# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034 # Variables are shared with state-probe.sh and the other files it sources.
# The run time budget (ADR-039): a run past its mark stops for the user, and continues with its evidence.
# --- helpers: counted time is edited in the state, never waited for -----------------------
edit() { # REPO JQ-FILTER [jq args...]
  local repo=$1 filter=$2
  shift 2
  jq "$@" "$filter" "$(sfile "$repo")" >"$tmp" && cp "$tmp" "$(sfile "$repo")"
}
# ago REPO SECONDS: the last write happened that long ago.
# shellcheck disable=SC2016 # $s is a jq variable.
ago() { edit "$1" '.updated_at = ((now - $s) | floor | todate)' --argjson s "$2"; }
# expire REPO: the counted time is at the mark.
expire() { edit "$1" '.budget.phase_s.approved = .budget.stop_at_s'; }
get() { jq -c "$2" "$(sfile "$1")"; } # REPO JQ-FILTER
counted() { get "$1" '[.budget.phase_s[]] | add // 0'; }
time_stopped() { # LABEL: the last command's own result is kept and the run is time-stopped
  [ "$rc" -eq 3 ] || fail "$1 must stop on the time budget: rc=$rc $out $(cat "$work/err")"
  jq -e '.ok == false and .phase == "blocked" and .blocked.reason == "run time budget reached" and .time_stop.counted_s >= 2700' <<<"$out" >/dev/null \
    || fail "$1 must report the time stop: $out"
}
no_stop() { # LABEL
  [ "$rc" -eq 0 ] || fail "$1 must not stop the run: rc=$rc $out $(cat "$work/err")"
}
started() { # REPO: an approved run in implement with its one step applied
  make_repo "$1"
  ok "$1" s1 init budget
  write_artifacts "$1" 1
  ok "$1" s1 approve --commit yes --branch-target current
  ok "$1" s1 advance implement
  printf 'changed\n' >"$1/a.txt"
}
to_verify() { started "$1"; apply_steps "$1"; ok "$1" s1 advance verify; }
unchanged() { # REPO ARGS...: refused with exit 3, and nothing is written
  local repo=$1 before
  shift
  before=$(snap "$repo")
  refused "$repo" s1 "$@"
  [ "$before" = "$(snap "$repo")" ] || fail "a refused command must not change the state ($*)"
}

# --- what is counted: from approval, never clarify or blocked time ------------------------
repoB="$work/repoB"
make_repo "$repoB"
ok "$repoB" s1 init counting
write_artifacts "$repoB" 1
[ "$(get "$repoB" .budget)" = null ] || fail "no budget before approval"
ago "$repoB" 10800
ok "$repoB" s1 approve --commit yes --branch-target current
[ "$(get "$repoB" .budget)" = '{"phase_s":{},"stop_at_s":2700}' ] || fail "approval starts the budget and clarify is not counted: $(get "$repoB" .budget)"
ok "$repoB" s1 advance implement
printf 'changed\n' >"$repoB/a.txt"
ago "$repoB" 100
ok "$repoB" s1 record step S-1
jq -e '.budget.phase_s.implement >= 100 and .budget.phase_s.implement < 160' "$(sfile "$repoB")" >/dev/null \
  || fail "time between writes counts for the phase the run was in: $(get "$repoB" .budget)"
ok "$repoB" s1 advance blocked --reason "probe" --needs "nothing"
before_total=$(counted "$repoB")
ago "$repoB" 10800
ok "$repoB" s1 unblock verify --reason "probe"
[ "$(counted "$repoB")" = "$before_total" ] || fail "blocked time is not counted: $(get "$repoB" .budget)"
[ "$(get "$repoB" .budget.stop_at_s)" = 2700 ] || fail "an unblock before the mark keeps the mark"

# --- the stop: the call's own result is recorded, then the run is blocked with a report -----
repoBs="$work/repoBs"
to_verify "$repoBs"
unchanged "$repoBs" advance blocked --reason "run time budget reached" --needs "x"
expire "$repoBs"
unchanged "$repoBs" advance commit                     # a refused command never stops the run
st "$repoBs" s1 record check --cmd "make test" --exit 0
time_stopped "record check"
[ "$(get "$repoBs" '[.phase, .blocked.from, .candidate.checks]')" = '["blocked","verify",[{"cmd":"make test","exit":0}]]' ] \
  || fail "the check stays recorded and the run is blocked from verify: $(get "$repoBs" .)"
[ "$(get "$repoBs" '.history[-1] | [.op, .to, .detail.reason]')" = '["advance","blocked","run time budget reached"]' ] \
  || fail "the stop adds one history entry: $(get "$repoBs" '.history[-1]')"
jq -e '.time_stop.review_rounds == 0 and .time_stop.open_blockers == [] and (.time_stop.phase_s | has("approved"))' <<<"$out" >/dev/null \
  || fail "the report names phase seconds, review rounds and open blockers: $out"
st "$repoBs" s1 check
[ "$rc" -eq 3 ] || fail "a time-stopped run stays blocked: $out"
jq -e '(.next | any(startswith("report to the user: ") and contains("without clarify and blocked time"))) and (.next | any(contains("b-state unblock continue --reason R (back to verify")))' <<<"$out" >/dev/null \
  || fail "check must give the report and the way on: $out"

# --- continue: back to the same phase with everything kept ---------------------------------
kept='{candidate, review, qa, ac, steps, commits, prior_commits, attempts}'
at_stop=$(get "$repoBs" "$kept")
ago "$repoBs" 10800
total=$(counted "$repoBs")
ok "$repoBs" s1 unblock continue --reason "more time"
[ "$(get "$repoBs" "$kept")" = "$at_stop" ] || fail "continue must keep the evidence and the counters: $(get "$repoBs" "$kept")"
[ "$(get "$repoBs" '[.phase, .blocked.reason]')" = '["verify",""]' ] || fail "continue returns to the stopped phase"
[ "$(get "$repoBs" .budget.stop_at_s)" = "$((total + 2700))" ] || fail "the next stop is a full window later: $(get "$repoBs" .budget)"
ok "$repoBs" s1 check
ok "$repoBs" s1 advance review --trigger "approval policy"
expire "$repoBs"
st "$repoBs" s1 check
no_stop "check in review without a verdict"
[ "$(phase "$repoBs")" = review ] || fail "a pending review is not stopped"
jq -n '{items: [{id: "R1-1", source: "review", summary: "unchecked path", disposition: "open", kind: "blocker", blocker_class: "unexpected path", escaped_from: "implement"}]}' \
  | br "$repoBs" s1 write followups >/dev/null || fail "write followups (budget)"
st "$repoBs" s1 record review --verdict "NEEDS FIXES" --gate codex
time_stopped "record review"
jq -e '.time_stop.review_rounds == 1 and .time_stop.open_blockers == ["R1-1"]' <<<"$out" >/dev/null || fail "the report must name the open blocker: $out"
ok "$repoBs" s1 unblock continue --reason "more time"
[ "$(get "$repoBs" '[.phase, .review.verdict, .review.round, .attempts.review_needs_fixes]')" = '["review","NEEDS FIXES",1,1]' ] \
  || fail "continue keeps the verdict and the NEEDS FIXES count: $(get "$repoBs" .)"
ok "$repoBs" s1 advance fix

# --- continue leaves only a time stop -------------------------------------------------------
ok "$repoBs" s1 advance blocked --reason "3 consecutive NEEDS FIXES rounds" --needs "user decision"
unchanged "$repoBs" unblock continue --reason "no"
ok "$repoBs" s1 unblock fix --reason "probe"
expire "$repoBs"
st "$repoBs" s1 advance verify
time_stopped "advance verify"
ok "$repoBs" s1 advance blocked --reason "another reason" --needs "user decision"
unchanged "$repoBs" unblock continue --reason "no"    # a later block replaces the time stop

repoBp="$work/repoBp"
to_verify "$repoBp"
expire "$repoBp"
st "$repoBp" s1 check
time_stopped "check"
spec_file=$(dirname "$(sfile "$repoBp")")/spec.md
cp "$spec_file" "$tmp2"
printf 'edited\n' >>"$spec_file"
unchanged "$repoBp" unblock continue --reason "no"    # the spec changed after approval
cp "$tmp2" "$spec_file"

# --- a check that finds a problem on a time-stopped run keeps the time stop ------------------
still_stopped() { # LABEL PROBLEM: the check reports the problem and writes nothing
  [ "$rc" -eq 3 ] || fail "$1: the run stays blocked: rc=$rc $out"
  jq -e --arg p "$2" '.problems == [$p] and .blocked.reason == "run time budget reached"' <<<"$out" >/dev/null \
    || fail "$1 must be reported without replacing the time stop: $out"
  [ "$stopped_state" = "$(snap "$repoBp")" ] || fail "$1 must not write the state"
}
stopped_state=$(snap "$repoBp")
mkdir -p "$work/shim-python"
printf '#!/bin/sh\nexit 1\n' >"$work/shim-python/python3"
chmod +x "$work/shim-python/python3"
PATH="$work/shim-python:$PATH" st "$repoBp" s1 check
still_stopped "one failed artifact validation" "run artifacts changed outside b_run.py"
printf 'edited\n' >>"$spec_file"
st "$repoBp" s1 check
still_stopped "an edited spec" "spec.md or plan.md changed after approval"
unchanged "$repoBp" unblock continue --reason "no"
cp "$tmp2" "$spec_file"
home_of_run=$(git -C "$repoBp" rev-parse --abbrev-ref HEAD)
git -C "$repoBp" checkout -q -b elsewhere
st "$repoBp" s1 check
still_stopped "another branch" "repository root or branch differs from the run"
jq -e '.next | any(contains("open blockers: none"))' <<<"$out" >/dev/null || fail "the report must still read the blockers: $out"
unchanged "$repoBp" unblock continue --reason "no"    # continuing there would carry the evidence along
grep -Fq 'repository root or branch differs' "$work/err" || fail "continue must name the other branch: $(cat "$work/err")"
git -C "$repoBp" checkout -q "$home_of_run"
git -C "$repoBp" commit -q --allow-empty -m "outside the run"
unchanged "$repoBp" unblock continue --reason "no"    # HEAD moved outside the recorded commits
grep -Fq 'HEAD moved outside the recorded commits' "$work/err" || fail "continue must name the moved HEAD: $(cat "$work/err")"
git -C "$repoBp" reset -q --soft HEAD~1
ok "$repoBp" s1 unblock continue --reason "more time"
[ "$(phase "$repoBp")" = verify ] || fail "continue must still work after the failed checks"
expire "$repoBp"
st "$repoBp" s1 check
time_stopped "check after the recovered run"

# --- any other unblock past the mark also opens a new window, and counting adds up ----------
total=$(counted "$repoBp")
ok "$repoBp" s1 unblock verify --reason "probe"
[ "$(get "$repoBp" .budget.stop_at_s)" = "$((total + 2700))" ] || fail "an unblock past the mark opens a window: $(get "$repoBp" .budget)"
ok "$repoBp" s1 check
ok "$repoBp" s1 advance blocked --reason "new plan" --needs "approval"
ok "$repoBp" s1 unblock clarify --reason "new plan"
git -C "$repoBp" checkout -q -- a.txt
ok "$repoBp" s1 approve --commit yes --branch-target current
[ "$(counted "$repoBp")" -ge "$total" ] || fail "a re-approval keeps the counted time: $(get "$repoBp" .budget)"

# --- time with no write is counted live, on a check that changes nothing --------------------
repoBl="$work/repoBl"
started "$repoBl"
ago "$repoBl" 2800
st "$repoBl" s1 check
time_stopped "a check after a long silence"
jq -e '.budget.phase_s.implement >= 2800' "$(sfile "$repoBl")" >/dev/null || fail "the silent time is stored: $(get "$repoBl" .budget)"
# The stop is the only write since the step base, so the step is still recorded after continue.
ok "$repoBl" s1 unblock continue --reason "more time"
ok "$repoBl" s1 record step S-1

repoBw="$work/repoBw"
started "$repoBw"
expire "$repoBw"
st "$repoBw" s1 record step S-1
time_stopped "record step"
ok "$repoBw" s1 unblock continue --reason "more time"
ok "$repoBw" s1 advance verify

# A base that was already stale before the stop stays stale.
repoBx="$work/repoBx"
started "$repoBx"
edit "$repoBx" '.step_base.rev -= 1'
expire "$repoBx"
st "$repoBx" s1 check
time_stopped "check with a stale base"
ok "$repoBx" s1 unblock continue --reason "more time"
st "$repoBx" s1 record step S-1
jq -e '.recorded == false and .blocked.reason == "run state was written outside the step"' <<<"$out" >/dev/null \
  || fail "continue must not adopt a write outside the step: $out"

# --- a candidate that changed while stopped goes back to verify -----------------------------
repoBc="$work/repoBc"
to_verify "$repoBc"
ok "$repoBc" s1 record check --cmd "make test" --exit 0
expire "$repoBc"
st "$repoBc" s1 advance review --trigger "approval policy"
time_stopped "advance review"
printf 'edited while stopped\n' >"$repoBc/a.txt"
ok "$repoBc" s1 unblock continue --reason "more time"
[ "$(phase "$repoBc")" = review ] || fail "continue returns to review"
ok "$repoBc" s1 check
[ "$(get "$repoBc" '[.phase, .candidate.checks]')" = '["verify",[]]' ] || fail "the changed candidate must be verified again: $(get "$repoBc" .)"

# --- no stop once commits begin, or on the way to done --------------------------------------
repoBm="$work/repoBm"
to_commit "$repoBm" current
expire "$repoBm"
st "$repoBm" s1 check
no_stop "check in commit"
git -C "$repoBm" add -A
git -C "$repoBm" commit -qm feature
st "$repoBm" s1 record commit "$(git -C "$repoBm" rev-parse HEAD)"
no_stop "record commit"
st "$repoBm" s1 advance "done"
no_stop "advance done"
st "$repoBm" s1 check
no_stop "check on a finished run"

# A check by a session that does not hold the lock takes it with the stop it made.
repoBk="$work/repoBk"
to_verify "$repoBk"
rm -f "$(dirname "$(sfile "$repoBk")")/lock"
expire "$repoBk"
st "$repoBk" s2 check
time_stopped "check by a new session"
ok "$repoBk" s2 unblock continue --reason "more time"

# --- a run approved before the budget existed is never time-stopped --------------------------
repoBo="$work/repoBo"
to_verify "$repoBo"
edit "$repoBo" 'del(.budget)'
ago "$repoBo" 100000
st "$repoBo" s1 check
no_stop "check without a budget"
st "$repoBo" s1 record check --cmd "make test" --exit 0
no_stop "record without a budget"
[ "$(get "$repoBo" .budget)" = null ] || fail "no budget is backfilled"
for bad in '{phase_s: {}}' '{phase_s: {clarify: 1}, stop_at_s: 1}' '{phase_s: {verify: -1}, stop_at_s: 1}' '[]'; do
  edit "$repoBo" ".budget = $bad"
  invalid "$repoBo" s1 show
done
