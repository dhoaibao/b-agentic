# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034 # Variables are shared with state-probe.sh and the other files it sources.
# Plan checks, checks run together, and one command at a time per run.
# --- every approved plan check must pass before review, a low-risk exception, or QA ---
repoH="$work/repoH"
make_repo "$repoH"
ok "$repoH" s1 init allchecks
spec_json 1 | br "$repoH" s1 write spec >/dev/null || fail "write spec (repoH)"
plan_json | jq '.checks += ["make lint"]' | br "$repoH" s1 write plan >/dev/null || fail "write plan (repoH)"
ok "$repoH" s1 approve --commit yes --branch-target current --codex reviewer
ok "$repoH" s1 advance implement
printf 'h\n' >"$repoH/a.txt"
apply_steps "$repoH"
ok "$repoH" s1 advance verify
ok "$repoH" s1 record check --cmd "make test" --exit 0
before=$(jq -S . "$(sfile "$repoH")")
refused "$repoH" s1 advance review --trigger "workflow policy"
grep -Fq 'make lint' "$work/err" || fail "the missing plan check must be named: $(cat "$work/err")"
refused "$repoH" s1 record review --low-risk "docs-only"
[ "$before" = "$(jq -S . "$(sfile "$repoH")")" ] || fail "a refused step must not change the state"
ok "$repoH" s1 check
[ "$(jq -r '.next | length' <<<"$out")" = 1 ] || fail "verify must owe only the missing check: $out"
[ "$(jq -r '.next[0]' <<<"$out")" = "run \`make lint\`, then b-state.mjs record check --cmd 'make lint' --exit <its exit code>" ] \
  || fail "verify must name the missing check command, as it always did: $out"
ok "$repoH" s1 record check --cmd "make lint" --exit 1
refused "$repoH" s1 advance review --trigger "workflow policy"   # recorded, but not passing
ok "$repoH" s1 record check --cmd "make lint" --exit 0
ok "$repoH" s1 check
grep -Fq 'classify risk' <<<"$(jq -r '.next[0]' <<<"$out")" || fail "verify with every check passing must owe the risk decision: $out"
ok "$repoH" s1 record review --low-risk "docs-only"
ok "$repoH" s1 check
[ "$(jq -c .next <<<"$out")" = '["b-state.mjs advance qa"]' ] || fail "a recorded low-risk exception must owe advance qa: $out"
# QA re-checks the plan checks: a state edited to drop one cannot move on.
jq '.candidate.checks |= map(select(.cmd != "make lint"))' "$(sfile "$repoH")" >"$tmp" && cp "$tmp" "$(sfile "$repoH")"
refused "$repoH" s1 advance qa
grep -Fq 'make lint' "$work/err" || fail "advance qa must name the missing plan check: $(cat "$work/err")"
# A run already past verify with a plan check missing (recorded before this rule, or edited)
# goes back to verify on check, and is told which check it owes; its review obligation stays.
ok "$repoH" s1 record check --cmd "make lint" --exit 0
ok "$repoH" s1 advance review --trigger "workflow policy"
jq '.candidate.checks |= map(select(.cmd != "make lint"))' "$(sfile "$repoH")" >"$tmp" && cp "$tmp" "$(sfile "$repoH")"
ok "$repoH" s1 check
[ "$(phase "$repoH")" = verify ] || fail "a run past verify with a plan check missing must return to verify: $(phase "$repoH")"
[ "$(jq -r '.history[-1] | .op + " " + .detail.reason' "$(sfile "$repoH")")" = "check plan checks incomplete: evidence void" ] \
  || fail "the return to verify must be recorded with its reason"
grep -Fq "record check --cmd 'make test'" <<<"$(jq -r '.next | join("\n")' <<<"$out")" || fail "the voided checks must be owed again: $out"
ok "$repoH" s1 record check --cmd "make test" --exit 0
ok "$repoH" s1 record check --cmd "make lint" --exit 0
ok "$repoH" s1 check
[ "$(jq -c .next <<<"$out")" = "[\"b-state.mjs advance review --trigger 'workflow policy'\"]" ] || fail "the review obligation must survive the return to verify: $out"
refused "$repoH" s1 record review --low-risk "docs-only"

# --- checks a plan lists to run together count only for the candidate they started on ------
par_plan() { plan_json | jq '.checks += ["make lint", "make docs"] | .parallel_checks = ["make lint", "make test"]'; }
started() { jq -r '.next[0]' <<<"$out" | grep -o -- '--from [0-9a-f]\{64\}' | cut -d' ' -f2; }
repoK="$work/repoK"
make_repo "$repoK"
printf 'artifact.out\n' >"$repoK/.gitignore"
git -C "$repoK" add .gitignore
git -C "$repoK" commit -qm "ignore artifact"
ok "$repoK" s1 init together
spec_json 1 | br "$repoK" s1 write spec >/dev/null || fail "write spec (repoK)"
par_plan | br "$repoK" s1 write plan >/dev/null || fail "write plan (repoK)"
ok "$repoK" s1 approve --commit yes --branch-target current --codex reviewer
ok "$repoK" s1 advance implement
printf 'p\n' >"$repoK/a.txt"
printf 'built\n' >"$repoK/artifact.out"
apply_steps "$repoK"
ok "$repoK" s1 advance verify
ok "$repoK" s1 check
[ "$(jq -r '.next | length' <<<"$out")" = 2 ] || fail "the listed checks share one line: $out"
grep -Fq "these checks may run at the same time: \`make test\`, \`make lint\`; then for each b-state.mjs record check" <<<"$(jq -r '.next[0]' <<<"$out")" \
  || fail "the listed checks must be named together, in plan order: $out"
[ "$(jq -r '.next[1]' <<<"$out")" = "run \`make docs\`, then b-state.mjs record check --cmd 'make docs' --exit <its exit code>" ] \
  || fail "a check that is not listed keeps its line: $out"
[ -n "$(started)" ] || fail "the line must carry the fingerprint the checks start on: $out"
# The included artifact is named on the check that runs alone; it is part of the candidate from then on.
ok "$repoK" s1 record check --cmd "make docs" --exit 0 --include-ignored artifact.out
ok "$repoK" s1 check
from=$(started)
[ "$from" = "$(jq -r .candidate.fingerprint "$(sfile "$repoK")")" ] || fail "--from must be the current candidate fingerprint: $out"
before=$(jq -S . "$(sfile "$repoK")")
refused "$repoK" s1 record check --cmd "make test" --exit 0
grep -Fq -- '--from' "$work/err" || fail "a listed check without --from must be told to pass it: $(cat "$work/err")"
invalid "$repoK" s1 record check --cmd "make test" --exit 0 --from nope
invalid "$repoK" s1 record check --cmd "make test" --exit 0 --from "$from" --include-ignored other.out
grep -Fq 'include-ignored' "$work/err" || fail "a changed included set must be named: $(cat "$work/err")"
[ "$before" = "$(jq -S . "$(sfile "$repoK")")" ] || fail "a refused or invalid record must not change the state"
ok "$repoK" s1 record check --cmd "make test" --exit 0 --from "$from" --include-ignored artifact.out
[ "$(jq -c '[.candidate.checks[] | select(.cmd == "make test") | .exit]' "$(sfile "$repoK")")" = '[0]' ] || fail "a check that ran on the current candidate is recorded"
ok "$repoK" s1 check
grep -Fq "may run at the same time: \`make lint\`; then" <<<"$(jq -r '.next[0]' <<<"$out")" || fail "only the listed check still owed is named: $out"
[ "$(jq -r '.next | length' <<<"$out")" = 1 ] || fail "recorded checks are not owed again: $out"
# The candidate moves while a listed check runs: its result belongs to no candidate.
printf 'p2\n' >"$repoK/a.txt"
ok "$repoK" s1 record check --cmd "make lint" --exit 0 --from "$from"
[ "$(jq -c '[.recorded, .attempts, .phase]' <<<"$out")" = '[false,1,"verify"]' ] || fail "a check of a moved candidate must not be recorded: $out"
[ "$(jq -c '[(.candidate.checks | length), .candidate.fingerprint != $f, .attempts.verify]' --arg f "$from" "$(sfile "$repoK")")" = '[0,true,1]' ] \
  || fail "a moved candidate has no results and costs one verify attempt"
[ "$(jq -c '.history[-1] | [.op, .detail.cmd, .detail.reason, .detail.exit]' "$(sfile "$repoK")")" = '["record check","make lint","the candidate changed while the check ran",null]' ] \
  || fail "the lost check must be recorded with its reason and no result"
refused "$repoK" s1 advance review --trigger "workflow policy"
# --from is optional for a check that is not listed, with the same meaning.
ok "$repoK" s1 record check --cmd "make docs" --exit 0 --from "$from"
[ "$(jq -c '[.recorded, .attempts]' <<<"$out")" = '[false,2]' ] || fail "an unlisted check with a stale --from is not recorded either: $out"
ok "$repoK" s1 record check --cmd "make lint" --exit 0 --from "$from"
[ "$(jq -c '[.recorded, .phase]' <<<"$out")" = '[false,"blocked"]' ] || fail "the third lost check must block the run: $out"
[ "$(jq -c '[(.candidate.checks | length), .blocked.reason]' "$(sfile "$repoK")")" = '[0,"3 failed verify attempts"]' ] \
  || fail "the block must name the verify limit and leave no result"
# A quick run has no approval round, so nobody would have accepted the list.
repoKQ="$work/repoKQ"
make_repo "$repoKQ"
ok "$repoKQ" s1 init quicktogether
CONSENT_COMMIT=no spec_json 1 a.txt | jq '.size = "quick"' | br "$repoKQ" s1 write spec >/dev/null || fail "write quick spec (repoKQ)"
par_plan | br "$repoKQ" s1 write plan >/dev/null || fail "write plan (repoKQ)"
refused "$repoKQ" s1 approve --commit no --branch-target current --codex reviewer --size quick
grep -Fq 'parallel checks' "$work/err" || fail "a quick run with parallel checks must be refused by name: $(cat "$work/err")"

# --- one command at a time per run; a dead holder is never recovered automatically
repo13="$work/repo13"
make_repo "$repo13"
ok "$repo13" s1 init mutex
d13=$(dirname "$(sfile "$repo13")")
printf '{"pid":%s,"token":"live"}\n' "$$" >"$d13/mutex"       # this shell is alive
refused "$repo13" s1 lock --takeover
grep -Fq 'another b-state command' "$work/err" || fail "a live holder must be named: $(cat "$work/err")"
printf '{"pid":2147483646,"token":"dead"}\n' >"$d13/mutex"    # a holder that is gone
refused "$repo13" s1 lock --takeover
grep -Fq 'delete' "$work/err" || fail "a dead holder must say how to clear it by hand: $(cat "$work/err")"
refused "$repo13" s1 clear-mutex                  # no recovery command exists: the dead holder still refuses
rm -f "$d13/mutex"
ok "$repo13" s1 lock --takeover
[ ! -e "$d13/mutex" ] || fail "the mutex must be released"
# Concurrent commands: exactly one wins the mutex, the other is refused, nothing is left behind.
repo13b="$work/repo13b"
make_repo "$repo13b"
ok "$repo13b" s1 init race
( cd "$repo13b" && for _ in 1 2 3 4 5 6; do node "$cli" lock --owner s1 >/dev/null 2>&1 & done; wait ) || true
[ ! -e "$(dirname "$(sfile "$repo13b")")/mutex" ] || fail "no mutex may remain after concurrent commands"
ok "$repo13b" s1 show

