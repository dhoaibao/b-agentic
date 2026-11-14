#!/usr/bin/env bash
# Exercise claude/bin/b-state.mjs against throwaway git repositories.
# Needs only node, git, and jq: no network, credentials, or Claude Code.
# Exit contract: 0 done, 3 refused or not ok, 2 invalid input or state.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cli="$root/claude/bin/b-state.mjs"
work=$(mktemp -d)
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_CEILING_DIRECTORIES="$work"

fail() { echo "state probe failed: $*" >&2; exit 1; }

make_repo() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q .
  git -C "$dir" config user.email probe@example.invalid
  git -C "$dir" config user.name probe
  printf 'a\n' >"$dir/a.txt"
  git -C "$dir" add .
  git -C "$dir" commit -qm init
}

# st REPO OWNER ARGS...: run the CLI in REPO as OWNER; prints stdout, sets $rc.
st() {
  local repo=$1 owner=$2
  shift 2
  rc=0; [ -z "${STATE_PROBE_DEBUG:-}" ] || echo "st: $*" >&2
  out=$(cd "$repo" && node "$cli" "$@" --owner "$owner" 2>"$work/err") || rc=$?
}
ok() { st "$@"; [ "$rc" -eq 0 ] || fail "expected success ($*): rc=$rc $(cat "$work/err")"; }
refused() { st "$@"; [ "$rc" -eq 3 ] || fail "expected refusal ($*): rc=$rc $(cat "$work/err")"; }
invalid() { st "$@"; [ "$rc" -eq 2 ] || fail "expected invalid input ($*): rc=$rc $(cat "$work/err")"; }
phase() { jq -r .phase "$1"/.b-agentic/runs/*/state.json; }
sfile() { printf '%s' "$1"/.b-agentic/runs/*/state.json; }

# Artifact helpers: specs, plans and QA files come from claude/bin/b_run.py only.
run_cli="$root/claude/bin/b_run.py"
br() { # REPO OWNER ARGS... (JSON on stdin)
  local repo=$1 owner=$2
  shift 2
  (cd "$repo" && python3 -I -B "$run_cli" "$@" --owner "$owner")
}
# CONSENT_COMMIT, CONSENT_TARGET and CONSENT_CODEX set the spec's consent block; every
# approve call below repeats the same values.
spec_json() { # N [SCOPE]: N automated criteria that run "make test"
  jq -n --argjson n "$1" --arg scope "${2:-**}" --arg commit "${CONSENT_COMMIT:-yes}" \
    --arg target "${CONSENT_TARGET:-current}" --arg codex "${CONSENT_CODEX:-reviewer}" '{request: "probe request", answers: [],
    behavior: {current: [], new: ["x"], examples: [{input: "a", output: "b"}, {input: "c", output: "d"}], non_goals: []},
    criteria: [range(1; $n + 1) | {id: "AC-\(.)", when: "a", then: "b", evidence: "automated", command: "make test"}],
    scope_paths: [$scope], out_of_scope: [],
    consent: {commit: $commit, branch_target: $target, codex: $codex}}'
}
plan_json() { jq -n '{steps: [{id: "S-1", action: "do", paths: ["a.txt"], done_when: "done"}], checks: ["make test"], invariants: [], stop_conditions: []}'; }
write_artifacts() { # REPO N [SCOPE]
  spec_json "$2" "${3:-**}" | br "$1" s1 write spec >/dev/null || fail "write spec ($1)"
  plan_json | br "$1" s1 write plan >/dev/null || fail "write plan ($1)"
}
# apply_steps REPO: record the one step of plan_json; verify is refused until every step is recorded.
apply_steps() { ok "$1" s1 record step S-1; }
write_qa() { # REPO N VERDICT RESULT
  jq -n --argjson n "$2" --arg verdict "$3" --arg result "$4" '{rows: [range(1; $n + 1) | {ac: "AC-\(.)", evidence: "automated", command: "make test", result: $result}],
    regression_scope: "all", not_covered: [], verdict: $verdict}' | br "$1" s1 write qa >/dev/null || fail "write qa ($1)"
}

repo="$work/repo"
make_repo "$repo"

# --- init: layout, self-ignoring folder, no tracked change -------------------
ok "$repo" s1 init demo
[ "$(phase "$repo")" = clarify ] || fail "init phase"
[ "$(cat "$repo/.b-agentic/.gitignore")" = '*' ] || fail ".gitignore must be '*'"
[ -z "$(git -C "$repo" status --porcelain)" ] || fail ".b-agentic must not appear in git status"
invalid "$repo" s1 init Bad_Slug

# --- approve needs valid, recorded artifacts; consent and branch target are validated
refused "$repo" s1 approve --commit yes --branch-target current --codex reviewer
run_dir=$(dirname "$(sfile "$repo")")
printf '# Spec\nhand written, no criteria\n' >"$run_dir/spec.md"
refused "$repo" s1 approve --commit yes --branch-target current --codex reviewer   # unrecorded file
rm -f "$run_dir/spec.md"
ok "$repo" s1 check
grep -Fq 'write spec' <<<"$(jq -r '.next[0]' <<<"$out")" || fail "clarify must owe the spec first: $out"
write_artifacts "$repo" 2
ok "$repo" s1 check
grep -Fq 'approve --commit yes --branch-target current --codex reviewer' <<<"$(jq -r '.next[-1]' <<<"$out")" \
  || fail "clarify must name the approval the spec records: $out"
invalid "$repo" s1 approve --commit yes --branch-target "bad target" --codex reviewer
ok "$repo" s1 approve --commit yes --branch-target current --codex reviewer
[ "$(phase "$repo")" = approved ] || fail "approve phase"
ok "$repo" s1 check
[ "$(jq -c .next <<<"$out")" = '["b-state.mjs advance implement"]' ] || fail "approved must owe advance implement: $out"
[ "$(jq -c '[.history[].op]' "$(sfile "$repo")")" = '["init","approve"]' ] || fail "every write must add one history entry"
[ "$(jq -r '.history[1] | .from + ">" + .to + " " + (.detail.spec | length | tostring)' "$(sfile "$repo")")" = "clarify>approved 64" ] \
  || fail "the approval entry must carry the phases and the spec hash"
[ "$(jq -r '.ac | keys | join(",")' "$(sfile "$repo")")" = "AC-1,AC-2" ] || fail "AC ids"
[ "$(jq -r '.spec.plan_sha256 | length' "$(sfile "$repo")")" = 64 ] || fail "the plan hash must be recorded at approval"

# --- another session cannot write while the lock is held ----------------------
refused "$repo" s2 advance implement
ok "$repo" s2 check --takeover
ok "$repo" s2 lock --takeover
refused "$repo" s1 advance implement
ok "$repo" s1 lock --takeover

# --- AC-1: step guards -------------------------------------------------------
refused "$repo" s1 advance review          # not reachable from approved
ok "$repo" s1 advance implement
printf 'b\n' >"$repo/a.txt"
refused "$repo" s1 advance qa              # not reachable from implement
apply_steps "$repo"
ok "$repo" s1 advance verify
refused "$repo" s1 advance review          # no passing checks yet
ok "$repo" s1 record check --cmd "make test" --exit 0
ok "$repo" s1 advance review --trigger "workflow policy"
ok "$repo" s1 record review --verdict "READY FOR PR" --trigger "workflow policy"
ok "$repo" s1 advance qa
refused "$repo" s1 advance commit          # no QA verdict yet
refused "$repo" s1 record qa --verdict "QA PASS"      # qa.md is not written yet
jq -n '{rows: [{ac: "AC-1", evidence: "automated", command: "make test", result: "pass"},
  {ac: "AC-2", evidence: "automated", command: "make test", result: "waived", waived_by: "user"}],
  regression_scope: "all", not_covered: [], verdict: "QA PASS"}' | br "$repo" s1 write qa >/dev/null || fail "write qa"
refused "$repo" s1 record qa --verdict "QA FAIL"      # differs from qa.md
ok "$repo" s1 record qa --verdict "QA PASS"
refused "$repo" s1 advance commit          # criteria not passed yet
refused "$repo" s1 record ac AC-1 fail     # differs from qa.md
ok "$repo" s1 record ac AC-1 pass
ok "$repo" s1 record ac AC-2 waived
refused "$repo" s1 advance "done"            # commit consent was given: the run ends through commit
grep -Fq 'through commit' "$work/err" || fail "a run with commit consent must not end at QA: $(cat "$work/err")"

# A QA PASS for another candidate does not allow the commit; state is unchanged.
printf 'c\n' >"$repo/a.txt"
before=$(jq -S 'del(.updated_at)' "$(sfile "$repo")")
refused "$repo" s1 advance commit
[ "$before" = "$(jq -S 'del(.updated_at)' "$(sfile "$repo")")" ] || fail "refused advance must not change state"
printf 'b\n' >"$repo/a.txt"

# Without recorded consent the commit is refused even with passing evidence.
repo2="$work/repo2"
make_repo "$repo2"
ok "$repo2" s1 init nocommit
CONSENT_COMMIT=no write_artifacts "$repo2" 1
ok "$repo2" s1 approve --commit no --branch-target current --codex reviewer
ok "$repo2" s1 advance implement
printf 'b\n' >"$repo2/a.txt"
apply_steps "$repo2"
ok "$repo2" s1 advance verify
ok "$repo2" s1 record check --cmd "make test" --exit 0
ok "$repo2" s1 record review --low-risk "docs-only change, no trigger"
ok "$repo2" s1 advance qa
write_qa "$repo2" 1 "QA PASS" pass
ok "$repo2" s1 record qa --verdict "QA PASS"
ok "$repo2" s1 record ac AC-1 pass
refused "$repo2" s1 advance commit
grep -Fq 'consent' "$work/err" || fail "refusal must name the missing consent: $(cat "$work/err")"
# The spec's consent decides: a state.json edited to say yes cannot pass the gate.
tmp2=$(mktemp -p "$work")
jq '.consent.commit = true' "$(sfile "$repo2")" >"$tmp2" && cp "$tmp2" "$(sfile "$repo2")"
refused "$repo2" s1 advance commit
grep -Fq 'approved spec' "$work/err" || fail "the gate must name the approved spec: $(cat "$work/err")"

# --- AC-2: a changed tree voids the evidence on resume ------------------------
printf 'changed while stopped\n' >"$repo/a.txt"
ok "$repo" s1 check
[ "$(jq -r .ok <<<"$out")" = true ] || fail "check ok after void"
[ "$(phase "$repo")" = verify ] || fail "resume must return to verify: $(phase "$repo")"
[ "$(jq -r '.review.verdict + .qa.verdict' "$(sfile "$repo")")" = "" ] || fail "verdicts must be voided"
[ "$(jq -r '.ac["AC-1"].status' "$(sfile "$repo")")" = pending ] || fail "AC status must be reset"
grep -Fq 'void' <<<"$out" || fail "check must say the evidence is void"

# --- spec change after approval blocks the run --------------------------------
printf '\n- AC-3: sneaked in\n' >>"$run_dir/spec.md"
refused "$repo" s1 advance review
refused "$repo" s1 check
[ "$(jq -r .ok <<<"$out")" = false ] || fail "spec change must not be ok"
[ "$(phase "$repo")" = blocked ] || fail "spec change must block"
grep -Fq 'ask the user: spec or plan changed' <<<"$(jq -r '.next[0]' <<<"$out")" || fail "a blocked run must owe the user decision: $out"
[ "$(jq -r '.history[-1] | .op + " " + .to + " " + .detail.reason' "$(sfile "$repo")")" = "check blocked spec or plan changed after approval" ] \
  || fail "a block found by check must be recorded with its reason"
entries=$(jq '.history | length' "$(sfile "$repo")")
refused "$repo" s1 check
[ "$(jq '.history | length' "$(sfile "$repo")")" = "$entries" ] || fail "re-checking a run blocked for the same reason must not add history"
refused "$repo" s1 unblock verify --reason "keep going"   # spec still differs
ok "$repo" s1 unblock clarify --reason "re-approve"
[ "$(phase "$repo")" = clarify ] || fail "unblock to clarify"

# --- bounded rounds: the third failure blocks --------------------------------
repo3="$work/repo3"
make_repo "$repo3"
ok "$repo3" s1 init rounds
CONSENT_CODEX=standing write_artifacts "$repo3" 1
ok "$repo3" s1 approve --commit yes --branch-target current --codex standing
ok "$repo3" s1 advance implement
printf 'x\n' >"$repo3/a.txt"
apply_steps "$repo3"
ok "$repo3" s1 advance verify
ok "$repo3" s1 record check --cmd "make test" --exit 1
ok "$repo3" s1 record check --cmd "make test" --exit 1
[ "$(phase "$repo3")" = verify ] || fail "two failures must not block"
ok "$repo3" s1 record check --cmd "make test" --exit 1
[ "$(phase "$repo3")" = blocked ] || fail "third failure must block"
[ "$(jq -r .attempts.verify "$(sfile "$repo3")")" = 3 ] || fail "attempt counter"
[ "$(jq -c '.history[-1] | [.op, .from, .to, .detail.cmd, .detail.exit, .detail.reason]' "$(sfile "$repo3")")" \
  = '["record check","verify","blocked","make test",1,"3 failed verify attempts"]' ] || fail "the blocking check must be recorded with its reason"
# The unblock reason is kept: it is the only record of what the user decided.
ok "$repo3" s1 unblock verify --reason "user accepted the flaky test"
[ "$(jq -c '.history[-1] | [.op, .from, .to, .detail.reason]' "$(sfile "$repo3")")" \
  = '["unblock","blocked","verify","user accepted the flaky test"]' ] || fail "the unblock reason must be kept in history"

# --- invalid state and unsafe folders fail closed -----------------------------
repo4="$work/repo4"
make_repo "$repo4"
ok "$repo4" s1 init broken
printf '{"schema":1,"phase":"nonsense"}\n' >"$(sfile "$repo4")"
invalid "$repo4" s1 show
printf 'not json\n' >"$(sfile "$repo4")"
invalid "$repo4" s1 show

repo5="$work/repo5"
make_repo "$repo5"
mkdir -p "$work/elsewhere/runs"
ln -s "$work/elsewhere" "$repo5/.b-agentic"
refused "$repo5" s1 init linked

# --- helpers for the sections below ---------------------------------------------
# to_commit REPO TARGET: drive a fresh run to the commit phase on a changed candidate.
to_commit() {
  local repo=$1 target=$2 dir
  make_repo "$repo"
  ok "$repo" s1 init flow
  dir=$(dirname "$(sfile "$repo")")
  CONSENT_TARGET=$target write_artifacts "$repo" 1
  ok "$repo" s1 approve --commit yes --branch-target "$target" --codex reviewer
  ok "$repo" s1 advance implement
  printf 'feature\n' >"$repo/f.txt"
  apply_steps "$repo"
  ok "$repo" s1 advance verify
  ok "$repo" s1 record check --cmd "make test" --exit 0
  ok "$repo" s1 record review --low-risk "docs-only"
  ok "$repo" s1 advance qa
  write_qa "$repo" 1 "QA PASS" pass
  ok "$repo" s1 record qa --verdict "QA PASS"
  ok "$repo" s1 record ac AC-1 pass
  ok "$repo" s1 advance commit
}

# --- a complete run on a new branch reaches done only with the approved commits ---
repo6="$work/repo6"
to_commit "$repo6" new:feat/demo
base=$(git -C "$repo6" rev-parse HEAD)
refused "$repo6" s1 record commit "$base"          # the base is not a run commit
refused "$repo6" s1 advance "done"                   # nothing committed yet
git -C "$repo6" switch -q -c feat/demo
git -C "$repo6" add f.txt
git -C "$repo6" commit -qm "feat: add f"
sha=$(git -C "$repo6" rev-parse HEAD)
ok "$repo6" s1 check                               # the approved new branch is not a branch change
[ "$(jq -r .branch "$(sfile "$repo6")")" = feat/demo ] || fail "state must follow the approved branch"
[ "$(phase "$repo6")" = commit ] || fail "check must keep the commit phase after the commit"
grep -Fq 'record commit' <<<"$(jq -r '.next | join("\n")' <<<"$out")" || fail "an unrecorded commit must be owed: $out"
ok "$repo6" s1 record commit "$sha"
ok "$repo6" s1 check
[ "$(jq -c .next <<<"$out")" = '["b-state.mjs advance done"]' ] || fail "a recorded HEAD commit must owe advance done: $out"
ok "$repo6" s1 advance "done"
[ "$(phase "$repo6")" = "done" ] || fail "done phase"

# A commit of different content does not complete the run.
repo7="$work/repo7"
to_commit "$repo7" current
printf 'changed after QA\n' >"$repo7/f.txt"
git -C "$repo7" add f.txt
git -C "$repo7" commit -qm "feat: other"
ok "$repo7" s1 record commit "$(git -C "$repo7" rev-parse HEAD)"
refused "$repo7" s1 advance "done"
grep -Fq 'approved candidate' "$work/err" || fail "done must name the candidate mismatch: $(cat "$work/err")"

# Commits on the wrong branch are refused.
repo8="$work/repo8"
to_commit "$repo8" new:feat/other
printf 'x\n' >>"$repo8/f.txt"
git -C "$repo8" add f.txt
git -C "$repo8" commit -qm "feat: x"
refused "$repo8" s1 record commit "$(git -C "$repo8" rev-parse HEAD)"

# --- acceptance results from another candidate cannot pass the commit gate --------
repo9="$work/repo9"
to_commit "$repo9-b" current
tmp=$(mktemp -p "$work")
jq '.phase = "qa" | .commit_plan = null | .ac["AC-1"].fingerprint = ("0" * 64)' "$(sfile "$repo9-b")" >"$tmp" && cp "$tmp" "$(sfile "$repo9-b")"
refused "$repo9-b" s1 advance commit
grep -Fq 'current pass' "$work/err" || fail "stale AC must be named: $(cat "$work/err")"
# Entering verify again starts a new evidence round.
repo10="$work/repo10"
to_commit "$repo10" current
ok "$repo10" s1 check
jq '.phase = "qa" | .commit_plan = null' "$(sfile "$repo10")" >"$tmp" && cp "$tmp" "$(sfile "$repo10")"
printf 'more\n' >>"$repo10/f.txt"
ok "$repo10" s1 check
[ "$(phase "$repo10")" = verify ] || fail "a changed candidate in qa must return to verify"
[ "$(jq -r '.ac["AC-1"].status' "$(sfile "$repo10")")" = pending ] || fail "AC results must be reset with the evidence"
# In verify, recorded checks for another candidate are void too.
ok "$repo10" s1 record check --cmd "make test" --exit 0
printf 'again\n' >>"$repo10/f.txt"
ok "$repo10" s1 check
grep -Fq 'void' <<<"$out" || fail "check in verify must report void evidence: $out"
[ "$(jq -r '.candidate.checks | length' "$(sfile "$repo10")")" = 0 ] || fail "stale checks must be cleared in verify"

# --- malformed consent fails closed -------------------------------------------------
repo11="$work/repo11"
to_commit "$repo11" current
jq '.consent.commit = "no"' "$(sfile "$repo11")" >"$tmp" && cp "$tmp" "$(sfile "$repo11")"
invalid "$repo11" s1 show

# --- a successful retry supersedes a failure of the same command --------------------
repo12="$work/repo12"
make_repo "$repo12"
ok "$repo12" s1 init retry
write_artifacts "$repo12" 1
ok "$repo12" s1 approve --commit yes --branch-target current --codex reviewer
ok "$repo12" s1 advance implement
printf 'r\n' >"$repo12/r.txt"
apply_steps "$repo12"
ok "$repo12" s1 advance verify
ok "$repo12" s1 record check --cmd "make test" --exit 1
ok "$repo12" s1 record check --cmd "make test" --exit 0
ok "$repo12" s1 advance review --trigger "workflow policy"
[ "$(jq -r .attempts.verify "$(sfile "$repo12")")" = 0 ] || fail "entering review resets the verify attempts"

# --- history is bounded, shown in part, and limited to the allowed facts --------------
jq '.history = [range(0; 200) | {at: "t", rev: 0, op: "check", from: "verify", to: "verify", detail: {}}]' \
  "$(sfile "$repo12")" >"$tmp" && cp "$tmp" "$(sfile "$repo12")"
ok "$repo12" s1 advance blocked --reason "probe stop" --needs "nothing"
[ "$(jq -c '[(.history | length), .history_dropped, .history[-1].detail.reason]' "$(sfile "$repo12")")" = '[200,1,"probe stop"]' ] \
  || fail "history must stay capped and count what it dropped"
# A block that replaces another keeps its own reason: unblock later clears the state's copy.
ok "$repo12" s1 advance blocked --reason "second stop" --needs "a decision"
[ "$(jq -c '.history[-1] | [.from, .to, .detail.reason, .detail.needs]' "$(sfile "$repo12")")" = '["blocked","blocked","second stop","a decision"]' ] \
  || fail "a replaced block reason must be recorded"
printf '\n- AC-9: sneaked in\n' >>"$(dirname "$(sfile "$repo12")")/spec.md"
refused "$repo12" s1 check
[ "$(jq -c '.history[-1] | [.op, .detail.reason]' "$(sfile "$repo12")")" = '["check","spec or plan changed after approval"]' ] \
  || fail "a block reason replaced by check must be recorded"
[ "$(jq -c '[.history[-3:][].detail.reason]' "$(sfile "$repo12")")" = '["probe stop","second stop","spec or plan changed after approval"]' ] \
  || fail "every block reason must stay in history"
ok "$repo12" s1 show
[ "$(jq -r '(.history | length | tostring) + " " + (.history_shown | length > 0 | tostring)' <<<"$out")" = "20 true" ] || fail "show must print the latest entries only"
ok "$repo12" s1 show --history
[ "$(jq '.history | length' <<<"$out")" = 200 ] || fail "show --history must print every entry"
jq '.history[0].detail.output = "command output does not belong here"' "$(sfile "$repo12")" >"$tmp" && cp "$tmp" "$(sfile "$repo12")"
invalid "$repo12" s1 show

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

# --- the commit plan binds the approved fingerprint to the committed tree -----------
repo14="$work/repo14"
make_repo "$repo14"
printf 'keep.log\n' >"$repo14/.gitignore"
printf 'tracked but ignored\n' >"$repo14/keep.log"
git -C "$repo14" add .gitignore
git -C "$repo14" add -f keep.log
git -C "$repo14" commit -qm "add ignored-but-tracked file"
ok "$repo14" s1 init ignored
write_artifacts "$repo14" 1
ok "$repo14" s1 approve --commit yes --branch-target current --codex reviewer
ok "$repo14" s1 advance implement
printf 'edited\n' >"$repo14/keep.log"
printf 'new\n' >"$repo14/n.txt"
apply_steps "$repo14"
ok "$repo14" s1 advance verify
ok "$repo14" s1 record check --cmd "make test" --exit 0
ok "$repo14" s1 record review --low-risk "docs-only"
ok "$repo14" s1 advance qa
write_qa "$repo14" 1 "QA PASS" pass
ok "$repo14" s1 record qa --verdict "QA PASS"
ok "$repo14" s1 record ac AC-1 pass
index_before=$(git -C "$repo14" ls-files -s | sha256sum)
ok "$repo14" s1 advance commit
[ "$index_before" = "$(git -C "$repo14" ls-files -s | sha256sum)" ] || fail "capturing the plan must not touch the real index"
# A partial commit, then an edit of the remaining tree, must not be resumed under the old approval.
git -C "$repo14" add n.txt
git -C "$repo14" commit -qm "feat: new"
ok "$repo14" s1 record commit "$(git -C "$repo14" rev-parse HEAD)"
printf 'edited again\n' >"$repo14/keep.log"
refused "$repo14" s1 check
[ "$(phase "$repo14")" = blocked ] || fail "an edit after commits began must block, not resume"
# Without that edit the same partial state completes once the rest is committed.
repo15="$work/repo15"
make_repo "$repo15"
printf 'keep.log\n' >"$repo15/.gitignore"
printf 'tracked but ignored\n' >"$repo15/keep.log"
git -C "$repo15" add .gitignore
git -C "$repo15" add -f keep.log
git -C "$repo15" commit -qm "add ignored-but-tracked file"
ok "$repo15" s1 init ignored2
write_artifacts "$repo15" 1
ok "$repo15" s1 approve --commit yes --branch-target current --codex reviewer
ok "$repo15" s1 advance implement
printf 'edited\n' >"$repo15/keep.log"
printf 'new\n' >"$repo15/n.txt"
apply_steps "$repo15"
ok "$repo15" s1 advance verify
ok "$repo15" s1 record check --cmd "make test" --exit 0
ok "$repo15" s1 record review --low-risk "docs-only"
ok "$repo15" s1 advance qa
write_qa "$repo15" 1 "QA PASS" pass
ok "$repo15" s1 record qa --verdict "QA PASS"
ok "$repo15" s1 record ac AC-1 pass
ok "$repo15" s1 advance commit
git -C "$repo15" add n.txt
git -C "$repo15" commit -qm "feat: new"
ok "$repo15" s1 record commit "$(git -C "$repo15" rev-parse HEAD)"
refused "$repo15" s1 advance "done"            # keep.log is still uncommitted
ok "$repo15" s1 check                          # the tree still equals the approved one
git -C "$repo15" add -f keep.log
git -C "$repo15" commit -qm "fix: keep"
ok "$repo15" s1 record commit "$(git -C "$repo15" rev-parse HEAD)"
ok "$repo15" s1 advance "done"
[ "$(phase "$repo15")" = "done" ] || fail "tracked ignored files must complete the run"

# --- unblocking after a partial commit rebases the plan on the current HEAD ---------
repo14c="$work/repo14c"
to_commit "$repo14c" current
printf 'second\n' >"$repo14c/g.txt"
git -C "$repo14c" add f.txt
git -C "$repo14c" commit -qm "feat: f"
ok "$repo14c" s1 record commit "$(git -C "$repo14c" rev-parse HEAD)"
printf 'moved on\n' >>"$repo14c/g.txt"
refused "$repo14c" s1 check                       # the tree changed after commits began
[ "$(phase "$repo14c")" = blocked ] || fail "blocked after the edit"
ok "$repo14c" s1 unblock verify --reason "user accepted the new content"
[ "$(jq -r '.commits | length' "$(sfile "$repo14c")")" = 0 ] || fail "old commits must leave the active list"
[ "$(jq -r '.prior_commits | length' "$(sfile "$repo14c")")" = 1 ] || fail "old commits must be kept as an audit record"
ok "$repo14c" s1 check                            # HEAD is a known prior commit, not a foreign move
ok "$repo14c" s1 record check --cmd "make test" --exit 0
ok "$repo14c" s1 record review --low-risk "docs-only"
ok "$repo14c" s1 advance qa
write_qa "$repo14c" 1 "QA PASS" pass
ok "$repo14c" s1 record qa --verdict "QA PASS"
ok "$repo14c" s1 record ac AC-1 pass
ok "$repo14c" s1 advance commit
git -C "$repo14c" add g.txt
git -C "$repo14c" commit -qm "feat: g"
ok "$repo14c" s1 record commit "$(git -C "$repo14c" rev-parse HEAD)"
ok "$repo14c" s1 advance "done"
[ "$(phase "$repo14c")" = "done" ] || fail "a rebased plan must reach done"

# --- artifacts named with --include-ignored are part of the approved tree ------------
repo16="$work/repo16"
make_repo "$repo16"
printf 'artifact.out\n' >"$repo16/.gitignore"
git -C "$repo16" add .gitignore
git -C "$repo16" commit -qm "ignore artifact"
ok "$repo16" s1 init artifact
write_artifacts "$repo16" 1
ok "$repo16" s1 approve --commit yes --branch-target current --codex reviewer
ok "$repo16" s1 advance implement
printf 'code\n' >"$repo16/c.txt"
printf 'built\n' >"$repo16/artifact.out"
apply_steps "$repo16"
ok "$repo16" s1 advance verify
ok "$repo16" s1 record check --cmd "make test" --exit 0 --include-ignored artifact.out
ok "$repo16" s1 record review --low-risk "docs-only"
ok "$repo16" s1 advance qa
write_qa "$repo16" 1 "QA PASS" pass
ok "$repo16" s1 record qa --verdict "QA PASS"
ok "$repo16" s1 record ac AC-1 pass
ok "$repo16" s1 advance commit
git -C "$repo16" add c.txt
git -C "$repo16" commit -qm "feat: c"
ok "$repo16" s1 record commit "$(git -C "$repo16" rev-parse HEAD)"
printf 'rebuilt\n' >"$repo16/artifact.out"             # the QA'd artifact changes after commits began
refused "$repo16" s1 check
[ "$(phase "$repo16")" = blocked ] || fail "a changed included artifact must block"
repo17="$work/repo17"
make_repo "$repo17"
printf 'artifact.out\n' >"$repo17/.gitignore"
git -C "$repo17" add .gitignore
git -C "$repo17" commit -qm "ignore artifact"
ok "$repo17" s1 init artifact2
write_artifacts "$repo17" 1
ok "$repo17" s1 approve --commit yes --branch-target current --codex reviewer
ok "$repo17" s1 advance implement
printf 'code\n' >"$repo17/c.txt"
printf 'built\n' >"$repo17/artifact.out"
apply_steps "$repo17"
ok "$repo17" s1 advance verify
ok "$repo17" s1 record check --cmd "make test" --exit 0 --include-ignored artifact.out
ok "$repo17" s1 record review --low-risk "docs-only"
ok "$repo17" s1 advance qa
write_qa "$repo17" 1 "QA PASS" pass
ok "$repo17" s1 record qa --verdict "QA PASS"
ok "$repo17" s1 record ac AC-1 pass
ok "$repo17" s1 advance commit
git -C "$repo17" add c.txt
git -C "$repo17" add -f artifact.out
git -C "$repo17" commit -qm "feat: c and artifact"
ok "$repo17" s1 record commit "$(git -C "$repo17" rev-parse HEAD)"
ok "$repo17" s1 advance "done"
[ "$(phase "$repo17")" = "done" ] || fail "committing the approved artifact must complete the run"

# The fingerprint is rechecked after the tree is captured: a change during capture records no plan.
race=$(cd "$repo14" && node --input-type=module -e '
  import { pathToFileURL } from "node:url";
  const { captureCommitPlan } = await import(pathToFileURL(process.argv[1]).href);
  const state = { repo_root: process.cwd(), candidate: { include_ignored: [] } };
  let calls = 0;
  try {
    await captureCommitPlan(process.cwd(), state, "a".repeat(64), "b".repeat(40), {
      tree: async () => "c".repeat(40),
      fingerprintOf: async () => (++calls, "d".repeat(64)),
    });
    console.log("recorded");
  } catch (error) {
    console.log("refused:" + error.message);
  }
' "$cli" 2>&1) || true
grep -Fq 'refused:the working tree changed' <<<"$race" || fail "a change during capture must refuse: $race"

# --- state is coupled to the validated artifacts -----------------------------------
repo18="$work/repo18"
make_repo "$repo18"
ok "$repo18" s1 init coupled
d18=$(dirname "$(sfile "$repo18")")
write_artifacts "$repo18" 1 a.txt
ok "$repo18" s1 approve --commit yes --branch-target current --codex reviewer
ok "$repo18" s1 advance implement
printf 'b\n' >"$repo18/a.txt"
apply_steps "$repo18"
printf 'x\n' >"$repo18/extra.txt"                                # after the step: the gate on the way to QA must still catch it
ok "$repo18" s1 advance verify
refused "$repo18" s1 record check --cmd "npm test" --exit 0     # not an approved plan check
grep -Fq 'approved plan checks' "$work/err" || fail "an unapproved check must be named: $(cat "$work/err")"
ok "$repo18" s1 record check --cmd "make test" --exit 0
ok "$repo18" s1 record review --low-risk "docs-only"
refused "$repo18" s1 advance qa                                  # extra.txt is outside the spec scope
grep -Fq 'outside the approved scope' "$work/err" || fail "scope breach must be named: $(cat "$work/err")"
rm "$repo18/extra.txt"
ok "$repo18" s1 record check --cmd "make test" --exit 0
ok "$repo18" s1 record review --low-risk "docs-only"
ok "$repo18" s1 advance qa
# A hand-edited plan, or a file nobody recorded, stops the run.
printf '\nhand edit\n' >>"$d18/plan.md"
refused "$repo18" s1 record qa --verdict "QA PASS"
refused "$repo18" s1 check
[ "$(phase "$repo18")" = blocked ] || fail "a hand-edited plan must block: $(phase "$repo18")"
repo19="$work/repo19"
make_repo "$repo19"
ok "$repo19" s1 init unknownfile
d19=$(dirname "$(sfile "$repo19")")
write_artifacts "$repo19" 1
ok "$repo19" s1 approve --commit yes --branch-target current --codex reviewer
printf 'x\n' >"$d19/notes.md"
refused "$repo19" s1 advance implement
grep -Fq 'unknown file' "$work/err" || fail "an unknown file must be named: $(cat "$work/err")"
rm "$d19/notes.md"
# qa.md must be rewritten in each QA round: an older file cannot be recorded again.
repo20="$work/repo20"
make_repo "$repo20"
ok "$repo20" s1 init staleqa
write_artifacts "$repo20" 1
ok "$repo20" s1 approve --commit yes --branch-target current --codex reviewer
ok "$repo20" s1 advance implement
printf 'q\n' >"$repo20/a.txt"
apply_steps "$repo20"
ok "$repo20" s1 advance verify
ok "$repo20" s1 record check --cmd "make test" --exit 0
ok "$repo20" s1 record review --low-risk "docs-only"
ok "$repo20" s1 advance qa
write_qa "$repo20" 1 "QA FAIL" fail
ok "$repo20" s1 record qa --verdict "QA FAIL"
ok "$repo20" s1 advance fix
printf 'q2\n' >"$repo20/a.txt"
ok "$repo20" s1 advance verify
ok "$repo20" s1 record check --cmd "make test" --exit 0
ok "$repo20" s1 record review --low-risk "docs-only"
ok "$repo20" s1 advance qa
refused "$repo20" s1 record qa --verdict "QA FAIL"
grep -Fq 'in this QA phase' "$work/err" || fail "a stale qa.md must be named: $(cat "$work/err")"
write_qa "$repo20" 1 "QA PASS" pass
ok "$repo20" s1 record qa --verdict "QA PASS"

# --- the scope is re-checked on every move toward review, QA, and commit -------------------
repo22="$work/repo22"
make_repo "$repo22"
ok "$repo22" s1 init scopeflow
write_artifacts "$repo22" 1 a.txt
ok "$repo22" s1 approve --commit yes --branch-target current --codex reviewer
ok "$repo22" s1 advance implement
printf 'b\n' >"$repo22/a.txt"
apply_steps "$repo22"
ok "$repo22" s1 advance verify
ok "$repo22" s1 record check --cmd "make test" --exit 0
ok "$repo22" s1 advance review --trigger "workflow policy"
printf 'x\n' >"$repo22/extra.txt"                        # an out-of-scope file appears during review
refused "$repo22" s1 record review --verdict "READY FOR PR"
grep -Fq 'current candidate' "$work/err" || fail "a verdict needs fresh checks for the current candidate: $(cat "$work/err")"
rm "$repo22/extra.txt"
ok "$repo22" s1 record review --verdict "READY FOR PR"
printf 'x\n' >"$repo22/extra.txt"
refused "$repo22" s1 advance qa
grep -Fq 'outside the approved scope' "$work/err" || fail "review -> qa must re-check the scope: $(cat "$work/err")"
rm "$repo22/extra.txt"
repo23="$work/repo23"
make_repo "$repo23"
ok "$repo23" s1 init scopecommit
write_artifacts "$repo23" 1 a.txt
ok "$repo23" s1 approve --commit yes --branch-target current --codex reviewer
ok "$repo23" s1 advance implement
printf 'b\n' >"$repo23/a.txt"
apply_steps "$repo23"
ok "$repo23" s1 advance verify
ok "$repo23" s1 record check --cmd "make test" --exit 0
ok "$repo23" s1 record review --low-risk "docs-only"
ok "$repo23" s1 advance qa
printf 'x\n' >"$repo23/extra.txt"                        # an out-of-scope file appears during QA
write_qa "$repo23" 1 "QA PASS" pass
ok "$repo23" s1 record qa --verdict "QA PASS"
ok "$repo23" s1 record ac AC-1 pass
refused "$repo23" s1 advance commit
grep -Fq 'outside the approved scope' "$work/err" || fail "the commit gate must re-check the scope: $(cat "$work/err")"

# --- a run made before ADR-010 loads, blocks, and can be rebuilt ------------------------------
repo21="$work/repo21"
make_repo "$repo21"
ok "$repo21" s1 init legacy
d21=$(dirname "$(sfile "$repo21")")
write_artifacts "$repo21" 1
ok "$repo21" s1 approve --commit yes --branch-target current --codex reviewer
tmp=$(mktemp -p "$work")
jq 'del(.spec.plan_sha256) | del(.qa.artifact_rev) | del(.history) | del(.history_dropped) | del(.steps) | del(.size) | del(.baseline.dirty)' "$(sfile "$repo21")" >"$tmp" && cp "$tmp" "$(sfile "$repo21")"
rm -f "$d21/artifacts.json"
ok "$repo21" s1 show
[ "$(jq -c '[.history, .history_dropped, .steps, .size, .baseline.dirty]' <<<"$out")" = '[[],0,{},"full",{}]' ] \
  || fail "a run made before these fields must load as a full run with empty records"
refused "$repo21" s1 check
[ "$(phase "$repo21")" = blocked ] || fail "a legacy run without recorded artifacts must block: $(phase "$repo21")"
ok "$repo21" s1 unblock clarify --reason "rebuild the artifacts after the upgrade"
write_artifacts "$repo21" 1
ok "$repo21" s1 approve --commit yes --branch-target current --codex reviewer
[ "$(phase "$repo21")" = approved ] || fail "a rebuilt legacy run must approve again"

# --- consent lives in the approved spec; approve repeats it and a clean tree is required ---
repoC="$work/repoC"
make_repo "$repoC"
ok "$repoC" s1 init consent
write_artifacts "$repoC" 1
refused "$repoC" s1 approve --commit no --branch-target current --codex reviewer
grep -Fq 'differ from the consent' "$work/err" || fail "a commit flag mismatch must be named: $(cat "$work/err")"
refused "$repoC" s1 approve --commit yes --branch-target current --codex standing
refused "$repoC" s1 approve --commit yes --branch-target new:feat/x --codex reviewer
[ "$(phase "$repoC")" = clarify ] || fail "a refused approve must leave the phase"
printf 'x\n' >"$repoC/dirty.txt"
refused "$repoC" s1 approve --commit yes --branch-target current --codex reviewer
grep -Fq 'working tree' "$work/err" || fail "a dirty tree must be named: $(cat "$work/err")"
rm "$repoC/dirty.txt"
ok "$repoC" s1 approve --commit yes --branch-target current --codex reviewer
grep -Fq 'Commit: yes' "$(dirname "$(sfile "$repoC")")/spec.md" || fail "spec.md must show the consent"
# A state.json whose consent differs from the approved spec blocks the run.
jq '.consent.codex = "standing"' "$(sfile "$repoC")" >"$tmp2" && cp "$tmp2" "$(sfile "$repoC")"
refused "$repoC" s1 check
grep -Fq 'consent differs' <<<"$out" || fail "consent drift must be named: $out"
[ "$(phase "$repoC")" = blocked ] || fail "consent drift must block"

# The commit boundaries compare the whole consent without an intervening check: an unapproved
# branch target in state.json cannot be used to record commits or finish the run.
repoB="$work/repoB"
to_commit "$repoB" current
jq '.consent.branch_target = "new:fix/unapproved"' "$(sfile "$repoB")" >"$tmp2" && cp "$tmp2" "$(sfile "$repoB")"
git -C "$repoB" checkout -q -b fix/unapproved
git -C "$repoB" add -A
git -C "$repoB" commit -qm "feat: x"
refused "$repoB" s1 record commit "$(git -C "$repoB" rev-parse HEAD)"
grep -Fq 'consent differs' "$work/err" || fail "record commit must name the consent drift: $(cat "$work/err")"
jq '.consent.branch_target = "current"' "$(sfile "$repoB")" >"$tmp2" && cp "$tmp2" "$(sfile "$repoB")"
git -C "$repoB" checkout -q -
git -C "$repoB" branch -q -D fix/unapproved 2>/dev/null || true
repoD="$work/repoD"
to_commit "$repoD" current
jq '.consent.codex = "standing"' "$(sfile "$repoD")" >"$tmp2" && cp "$tmp2" "$(sfile "$repoD")"
jq '.phase = "qa" | .commit_plan = null' "$(sfile "$repoD")" >"$tmp2" && cp "$tmp2" "$(sfile "$repoD")"
refused "$repoD" s1 advance commit
grep -Fq 'consent differs' "$work/err" || fail "advance commit must compare the whole consent: $(cat "$work/err")"

# A refused check must not adopt a branch on the strength of a forged consent, and restoring the
# consent afterwards must not make that branch count as approved.
repoE="$work/repoE"
to_commit "$repoE" current
home_branch=$(git -C "$repoE" rev-parse --abbrev-ref HEAD)
jq '.consent.branch_target = "new:fix/unapproved"' "$(sfile "$repoE")" >"$tmp2" && cp "$tmp2" "$(sfile "$repoE")"
git -C "$repoE" checkout -q -b fix/unapproved
refused "$repoE" s1 check
[ "$(jq -r .branch "$(sfile "$repoE")")" = "$home_branch" ] || fail "a refused check must keep the run's branch: $(jq -r .branch "$(sfile "$repoE")")"
jq '.consent.branch_target = "current"' "$(sfile "$repoE")" >"$tmp2" && cp "$tmp2" "$(sfile "$repoE")"
ok "$repoE" s1 unblock verify --reason "restored"
refused "$repoE" s1 check
[ "$(jq -r .branch "$(sfile "$repoE")")" = "$home_branch" ] || fail "the unauthorized branch must stay rejected"

# The same with spec.md, its artifact record and the state's consent all rewritten consistently:
# the recorded spec hash still refuses the check, and the branch is still not adopted.
repoG="$work/repoG"
to_commit "$repoG" current
home_branch=$(git -C "$repoG" rev-parse --abbrev-ref HEAD)
jq '.phase = "clarify"' "$(sfile "$repoG")" >"$tmp2" && cp "$tmp2" "$(sfile "$repoG")"
CONSENT_TARGET=new:fix/unapproved write_artifacts "$repoG" 1
jq '.phase = "commit" | .consent.branch_target = "new:fix/unapproved"' "$(sfile "$repoG")" >"$tmp2" && cp "$tmp2" "$(sfile "$repoG")"
git -C "$repoG" checkout -q -b fix/unapproved
refused "$repoG" s1 check
[ "$(jq -r .branch "$(sfile "$repoG")")" = "$home_branch" ] || fail "a refused check must not adopt the branch after a consistent spec rewrite"

# --- a review trigger is required, and a triggered run cannot skip its re-review ---
repoF="$work/repoF"
make_repo "$repoF"
ok "$repoF" s1 init rereview
write_artifacts "$repoF" 1
ok "$repoF" s1 approve --commit yes --branch-target current --codex reviewer
ok "$repoF" s1 advance implement
printf 'f1\n' >"$repoF/a.txt"
apply_steps "$repoF"
ok "$repoF" s1 advance verify
ok "$repoF" s1 record check --cmd "make test" --exit 0
invalid "$repoF" s1 advance review                 # no --trigger
ok "$repoF" s1 advance review --trigger "approval policy"
[ "$(jq -r .review.trigger "$(sfile "$repoF")")" = "approval policy" ] || fail "advance review must record the trigger"
# A verdict that depends on findings needs them written first, so a session lost after the
# verdict can still read what the round found.
followups_json() { jq -n --argjson items "$1" '{items: $items}'; }
r1_note='{"id": "R1-1", "source": "review", "summary": "naming", "disposition": "open"}'
r1_blocker='{"id": "R1-2", "source": "review", "summary": "unchecked path", "disposition": "open", "kind": "blocker"}'
ok "$repoF" s1 check
grep -Fq 'R1-<n>' <<<"$(jq -r '.next | join("\n")' <<<"$out")" || fail "review must owe the round's findings: $out"
refused "$repoF" s1 record review --verdict "NEEDS FIXES"
grep -Fq 'R1-<n>, kind blocker' "$work/err" || fail "the missing blocker must be named: $(cat "$work/err")"
followups_json "[$r1_note]" | br "$repoF" s1 write followups >/dev/null || fail "write followups (note)"
refused "$repoF" s1 record review --verdict "NEEDS FIXES"   # a follow-up is not a blocker
followups_json "[$r1_note, $r1_blocker]" | br "$repoF" s1 write followups >/dev/null || fail "write followups (blocker)"
ok "$repoF" s1 record review --verdict "NEEDS FIXES"
[ "$(jq -c '.history[-1] | [.op, .detail.verdict, .detail.round, .detail.trigger]' "$(sfile "$repoF")")" \
  = '["record review","NEEDS FIXES",1,"approval policy"]' ] || fail "the verdict must be recorded with its round and trigger"
ok "$repoF" s1 check
[ "$(jq -c .next <<<"$out")" = '["b-state.mjs advance fix"]' ] || fail "NEEDS FIXES must owe advance fix: $out"
ok "$repoF" s1 advance fix
ok "$repoF" s1 check
[ "$(jq -r '.next[0]' <<<"$out")" = "b_run.py handoff fix" ] || fail "fix must start from its packet: $out"
grep -Fq 'open blockers' <<<"$(jq -r '.next[1]' <<<"$out")" || fail "fix must owe the open blockers: $out"
grep -Fq 'R1-2' <<<"$(jq -r '.next[1]' <<<"$out")" || fail "fix must name the open blocker: $out"
grep -Fq 'R1-1' <<<"$(jq -r '.next[1]' <<<"$out")" && fail "fix must not list a follow-up as a blocker: $out"
# A fix round corrects findings and owes no plan step: the cursor is kept and verify is open.
refused "$repoF" s1 record step S-1
[ "$(jq -c '.steps | keys' "$(sfile "$repoF")")" = '["S-1"]' ] || fail "the step cursor must survive review and fix"
printf 'f2\n' >"$repoF/a.txt"
ok "$repoF" s1 advance verify
ok "$repoF" s1 record check --cmd "make test" --exit 0
ok "$repoF" s1 check
[ "$(jq -c .next <<<"$out")" = "[\"b-state.mjs advance review --trigger 'approval policy'\"]" ] || fail "a triggered run must owe its re-review: $out"
refused "$repoF" s1 record review --low-risk "fixed it"
grep -Fq 'review was already' "$work/err" || fail "the low-risk guard must be named: $(cat "$work/err")"
refused "$repoF" s1 advance qa
ok "$repoF" s1 advance review --trigger "approval policy"
refused "$repoF" s1 record review --verdict "READY WITH FOLLOW-UPS"   # round 2 recorded no finding
grep -Fq 'R2-<n>' "$work/err" || fail "the missing round-2 follow-up must be named: $(cat "$work/err")"
r2_note='{"id": "R2-1", "source": "review", "summary": "docs", "disposition": "open"}'
followups_json "[$r1_note, $r1_blocker, $r2_note]" | br "$repoF" s1 write followups >/dev/null || fail "write followups (round 2)"
ok "$repoF" s1 record review --verdict "READY WITH FOLLOW-UPS"
[ "$(jq -c '[.history[] | select(.op == "record review") | .detail.verdict]' "$(sfile "$repoF")")" \
  = '["NEEDS FIXES","READY WITH FOLLOW-UPS"]' ] || fail "earlier review verdicts must stay in history"
ok "$repoF" s1 advance qa
# A session that has never seen the run can tell what QA still owes.
ok "$repoF" s1 check
grep -Fq 'handoff qa' <<<"$(jq -r '.next[0]' <<<"$out")" || fail "QA without a fresh qa.md must owe it: $out"
write_qa "$repoF" 1 "QA PASS" pass
ok "$repoF" cold check --takeover
[ "$(jq -c .next <<<"$out")" = '["b-state.mjs record ac AC-1 pass","b-state.mjs record qa --verdict \"QA PASS\""]' ] \
  || fail "a cold session must be told the QA records still owed: $out"
ok "$repoF" cold record ac AC-1 pass
ok "$repoF" cold check
[ "$(jq -c .next <<<"$out")" = '["b-state.mjs record qa --verdict \"QA PASS\""]' ] || fail "only the QA verdict is still owed: $out"
ok "$repoF" cold record qa --verdict "QA PASS"
ok "$repoF" cold check
[ "$(jq -c .next <<<"$out")" = '["b-state.mjs advance commit"]' ] || fail "a recorded QA PASS must owe advance commit: $out"
jq -e '[.history[].detail | keys[]] | unique - ["ac","cmd","exit","fingerprint","needs","outside","paths","reason","round","sha","spec","status","step","tree","trigger","verdict"] == []' \
  "$(sfile "$repoF")" >/dev/null || fail "history details must hold only the allowed facts"

# --- the implement step cursor: progress is recorded, not read back from the tree -------
repoS="$work/repoS"
make_repo "$repoS"
ok "$repoS" s1 init cursor
spec_json 1 | br "$repoS" s1 write spec >/dev/null || fail "write spec (repoS)"
plan_json | jq '.steps += [{id: "S-2", action: "second", paths: ["a.txt"], done_when: "done"},
  {id: "S-3", action: "independent", paths: ["a.txt"], done_when: "done", depends_on: []}]' \
  | br "$repoS" s1 write plan >/dev/null || fail "write plan (repoS)"
owed_steps() { jq -c '[.next[] | select(test("record step")) | capture("record step (?<id>S-[0-9]+)").id]' <<<"$out"; }
step_keys() { jq -c '.steps | keys' "$(sfile "$repoS")"; }
ok "$repoS" s1 approve --commit yes --branch-target current --codex reviewer
refused "$repoS" s1 record step S-1                 # steps are recorded in implement only
ok "$repoS" s1 advance implement
ok "$repoS" s1 check
[ "$(jq -r '.next[0]' <<<"$out")" = "b_run.py handoff implement" ] || fail "implement must start from its packet: $out"
[ "$(owed_steps)" = '["S-1","S-2","S-3"]' ] || fail "implement must owe every unrecorded step: $out"
[ "$(jq -r '.next[-1]' <<<"$out")" = "b-state.mjs advance verify" ] || fail "implement must end with advance verify: $out"
printf 's\n' >"$repoS/a.txt"
before=$(jq -S . "$(sfile "$repoS")")
refused "$repoS" s1 advance verify
grep -Fq 'plan steps not recorded: S-1, S-2, S-3' "$work/err" || fail "the unrecorded steps must be named: $(cat "$work/err")"
[ "$before" = "$(jq -S . "$(sfile "$repoS")")" ] || fail "a refused advance verify must not change the state"
invalid "$repoS" s1 record step S-9                 # not a plan step
refused "$repoS" s1 record step S-2                 # waits for the step before it
grep -Fq 'S-1' "$work/err" || fail "the step a step waits for must be named: $(cat "$work/err")"
ok "$repoS" s1 record step S-3                      # depends on none
ok "$repoS" s1 record step S-1
[ "$(jq -c '.history[-1] | [.op, .detail.step, (.detail.fingerprint | length)]' "$(sfile "$repoS")")" = '["record step","S-1",64]' ] \
  || fail "a recorded step must add one history entry with its fingerprint"
[ "$(jq -c '.steps["S-1"] | [.status, (.fingerprint | length)]' "$(sfile "$repoS")")" = '["done",64]' ] || fail "a recorded step must carry its evidence"
refused "$repoS" s1 advance verify
grep -Fq 'plan steps not recorded: S-2' "$work/err" || fail "only the remaining step must be named: $(cat "$work/err")"
ok "$repoS" cold check --takeover                   # a session that never saw the run
[ "$(owed_steps)" = '["S-2"]' ] || fail "a cold session must be told the one step still owed: $out"
ok "$repoS" s1 lock --takeover
ok "$repoS" s1 record step S-2
ok "$repoS" s1 check
[ "$(jq -c .next <<<"$out")" = '["b-state.mjs advance verify"]' ] || fail "with every step recorded only advance verify is owed: $out"
ok "$repoS" s1 advance verify
# The cursor survives a voiding check and a return to verify or fix; implement and clarify redo the plan.
ok "$repoS" s1 record check --cmd "make test" --exit 0
printf 's2\n' >"$repoS/a.txt"
ok "$repoS" s1 check
[ "$(step_keys)" = '["S-1","S-2","S-3"]' ] || fail "voided evidence must keep the step cursor"
ok "$repoS" s1 advance blocked --reason "probe" --needs "nothing"
ok "$repoS" s1 unblock fix --reason "probe"
[ "$(step_keys)" = '["S-1","S-2","S-3"]' ] || fail "unblock fix must keep the step cursor"
ok "$repoS" s1 advance verify                       # a fix round owes no step
ok "$repoS" s1 advance blocked --reason "probe" --needs "nothing"
ok "$repoS" s1 unblock verify --reason "probe"
[ "$(step_keys)" = '["S-1","S-2","S-3"]' ] || fail "unblock verify must keep the step cursor"
ok "$repoS" s1 advance blocked --reason "probe" --needs "nothing"
ok "$repoS" s1 unblock implement --reason "redo the plan"
[ "$(step_keys)" = '[]' ] || fail "unblock implement must reset the step cursor"
refused "$repoS" s1 advance verify
ok "$repoS" s1 record step S-1
ok "$repoS" s1 advance blocked --reason "probe" --needs "nothing"
ok "$repoS" s1 unblock clarify --reason "new plan"
[ "$(step_keys)" = '[]' ] || fail "unblock clarify must reset the step cursor"
# A new approval is a new plan, whatever the state claimed before it.
jq '.steps = {"S-1": {status: "done", fingerprint: ("a" * 64)}}' "$(sfile "$repoS")" >"$tmp" && cp "$tmp" "$(sfile "$repoS")"
git -C "$repoS" checkout -q -- a.txt
ok "$repoS" s1 approve --commit yes --branch-target current --codex reviewer
[ "$(step_keys)" = '[]' ] || fail "approve must reset the step cursor"
jq '.steps = {"S-1": {status: "done", fingerprint: "not a fingerprint"}}' "$(sfile "$repoS")" >"$tmp" && cp "$tmp" "$(sfile "$repoS")"
invalid "$repoS" s1 show

# --- a plan step is checked against the approved scope when it is recorded -------------------
steps_plan() {
  jq -n '{steps: [{id: "S-1", action: "a", paths: ["src/a.txt"], done_when: "d"}, {id: "S-2", action: "b", paths: ["src/b.txt"], done_when: "d"},
    {id: "S-3", action: "c", paths: ["src/c.txt"], done_when: "d"}], checks: ["make test"], invariants: [], stop_conditions: []}'
}
last() { jq -c ".history[-1] | $1" "$(sfile "$repoJ")"; } # JQ-FILTER applied to the latest history entry
repoJ="$work/repoJ"
make_repo "$repoJ"
ok "$repoJ" s1 init stepgate
spec_json 1 'src/**' | br "$repoJ" s1 write spec >/dev/null || fail "write spec (repoJ)"
steps_plan | br "$repoJ" s1 write plan >/dev/null || fail "write plan (repoJ)"
ok "$repoJ" s1 approve --commit yes --branch-target current --codex reviewer
[ "$(jq -c '[.step_base, .attempts.step]' "$(sfile "$repoJ")")" = '[null,0]' ] || fail "a run has no step base before implement"
ok "$repoJ" s1 advance implement
[ "$(jq -c '[.step_base.rev == .rev, (.step_base.tree | length), .step_base.head == .baseline.head]' "$(sfile "$repoJ")")" = '[true,40,true]' ] \
  || fail "entering implement must record where the first step starts"
mkdir -p "$repoJ/src"
printf 'a\n' >"$repoJ/src/a.txt"
printf 't\n' >"$repoJ/src/a_test.txt"
ok "$repoJ" s1 record step S-1
[ "$(jq -c '[.step, .owed]' <<<"$out")" = '["S-1",["S-2","S-3"]]' ] || fail "a recorded step keeps its result: $out"
[ "$(last '[.op, .detail.step, .detail.paths, .detail.outside, (.detail.tree | length)]')" = '["record step","S-1",2,1,40]' ] \
  || fail "a recorded step must carry its tree, its changed paths, and those outside its own paths: $(last .)"
[ "$(jq -c '[.step_base.tree == .history[-1].detail.tree, .step_base.rev == .rev]' "$(sfile "$repoJ")")" = '[true,true]' ] \
  || fail "a recorded step is where the next one starts"
# A path outside the approved scope: nothing is recorded, the refusal is counted, the base stays.
printf 'b\n' >"$repoJ/src/b.txt"
printf 'x\n' >"$repoJ/README.md"
base_tree=$(jq -r .step_base.tree "$(sfile "$repoJ")")
refused "$repoJ" s1 record step S-2
[ "$(jq -c '[.recorded, .attempts, .phase, .reason]' <<<"$out")" = '[false,1,"implement","outside the approved scope: README.md"]' ] \
  || fail "a step that left the scope must be refused with the path named: $out"
[ "$(jq -c '[(.steps | has("S-2")), .attempts.step, .step_base.tree == $t, .step_base.rev == .rev]' --arg t "$base_tree" "$(sfile "$repoJ")")" = '[false,1,true,true]' ] \
  || fail "a refused step is not recorded and keeps its base"
[ "$(jq -c '.history[-1].detail | [.step, .reason, (.tree | length), .tree != $t]' --arg t "$base_tree" "$(sfile "$repoJ")")" = '["S-2","outside the approved scope: README.md",40,true]' ] \
  || fail "the refusal must record its reason and the rejected tree: $(last .)"
# Restoring the path and recording again compares the same step, and resets the count.
rm "$repoJ/README.md"
ok "$repoJ" s1 record step S-2
[ "$(jq -c '[.attempts.step, .history[-1].detail.paths, .history[-1].detail.outside]' "$(sfile "$repoJ")")" = '[0,1,0]' ] \
  || fail "a recorded step resets the refusals and counts only its own changes"
# A likely-secret path: refused by count, with no tree built and no name in the state.
printf 'c\n' >"$repoJ/src/c.txt"
printf 's\n' >"$repoJ/src/db.env"
refused "$repoJ" s1 record step S-3
[ "$(jq -c '[.recorded, .attempts, .reason, .tree]' <<<"$out")" = '[false,1,"1 protected path(s) changed",null]' ] \
  || fail "a protected path must refuse the step by count: $out"
[ "$(last '[.detail.reason, (.detail | has("tree"))]')" = '["1 protected path(s) changed",false]' ] || fail "no tree is recorded for a protected path: $(last .)"
grep -Fq 'db.env' "$(sfile "$repoJ")" && fail "a protected path name must not enter the state"
refused "$repoJ" s1 record step S-3
[ "$(jq -c '[.attempts, .phase]' <<<"$out")" = '[2,"implement"]' ] || fail "the second refusal in a row is counted: $out"
refused "$repoJ" s1 record step S-3
[ "$(jq -c '[.recorded, .phase]' <<<"$out")" = '[false,"blocked"]' ] || fail "the third refusal in a row must block the run: $out"
[ "$(jq -r .blocked.reason "$(sfile "$repoJ")")" = "3 refused plan steps; last: 1 protected path(s) changed" ] || fail "the block must say why"
rm "$repoJ/src/db.env"
ok "$repoJ" s1 unblock implement --reason "removed the file"
[ "$(jq -c '[.steps, .attempts.step, .step_base.rev == .rev]' "$(sfile "$repoJ")")" = '[{},0,true]' ] || fail "unblock implement starts the steps again from the current tree"
ok "$repoJ" s1 record step S-1
[ "$(last '[.detail.paths, .detail.outside]')" = '[0,0]' ] || fail "a step that changed nothing since its base records no paths: $(last .)"
# Run state written between two steps is not a plan step: the run stops.
jq '.rev += 1' "$(sfile "$repoJ")" >"$tmp" && cp "$tmp" "$(sfile "$repoJ")"
refused "$repoJ" s1 record step S-2
[ "$(jq -c '[.recorded, .phase, .blocked.reason]' <<<"$out")" = '[false,"blocked","run state was written outside the step"]' ] \
  || fail "a state written since the step base must block the run: $out"
ok "$repoJ" s1 unblock implement --reason "reviewed the state"
git -C "$repoJ" commit -q --allow-empty -m "outside the run"
refused "$repoJ" s1 record step S-1
[ "$(jq -c '[.recorded, .phase, .blocked.reason]' <<<"$out")" = '[false,"blocked","HEAD moved during the step"]' ] \
  || fail "a HEAD moved since the step base must block the run: $out"
# A run recorded before the step gate has no base: it loads, and its steps are recorded as before.
repoV="$work/repoV"
make_repo "$repoV"
ok "$repoV" s1 init oldrun
write_artifacts "$repoV" 1 a.txt
ok "$repoV" s1 approve --commit yes --branch-target current --codex reviewer
ok "$repoV" s1 advance implement
jq 'del(.step_base) | del(.attempts.step)' "$(sfile "$repoV")" >"$tmp" && cp "$tmp" "$(sfile "$repoV")"
ok "$repoV" s1 show
[ "$(jq -c '[.step_base, .attempts.step]' <<<"$out")" = '[null,0]' ] || fail "a state without a step base must load: $out"
printf 'v\n' >"$repoV/a.txt"
printf 'x\n' >"$repoV/extra.txt"
ok "$repoV" s1 record step S-1
[ "$(jq -c '[(.history[-1].detail | keys), .step_base]' "$(sfile "$repoV")")" = '[["fingerprint","step"],null]' ] \
  || fail "a run without a step base records its steps as before"
ok "$repoV" s1 advance verify
ok "$repoV" s1 record check --cmd "make test" --exit 0
refused "$repoV" s1 advance review --trigger "workflow policy"
grep -Fq 'extra.txt' "$work/err" || fail "the scope check on the way to review is unchanged: $(cat "$work/err")"
# A run that enters implement while a likely-secret path is changed has no base either.
repoZ="$work/repoZ"
make_repo "$repoZ"
printf 's\n' >"$repoZ/db.env"
ok "$repoZ" s1 init secretfirst
CONSENT_COMMIT=no write_artifacts "$repoZ" 1 a.txt
ok "$repoZ" s1 approve --commit no --branch-target current --codex reviewer
ok "$repoZ" s1 advance implement
[ "$(jq -c .step_base "$(sfile "$repoZ")")" = null ] || fail "no step base is built while a protected path is changed"
before=$(jq -S . "$(sfile "$repoZ")")
refused "$repoZ" s1 record step S-1
grep -Fq 'snapshot is incomplete' "$work/err" || fail "an incomplete snapshot refuses the step as before: $(cat "$work/err")"
[ "$before" = "$(jq -S . "$(sfile "$repoZ")")" ] || fail "that refusal writes nothing, as before"
# The tree is built from the changed paths by name, so it equals what adding everything would
# build, and the content of a likely-secret path never reaches the object store.
repoU="$work/repoU"
make_repo "$repoU"
printf 'gone\n' >"$repoU/gone.txt"
printf 'staged\n' >"$repoU/staged.txt"
git -C "$repoU" add .
git -C "$repoU" commit -qm "more files"
printf 'changed\n' >"$repoU/a.txt"
rm "$repoU/gone.txt"
printf 'new\n' >"$repoU/new file.txt"
printf 'magic\n' >"$repoU/:(glob)x.txt"
printf 'staged again\n' >"$repoU/staged.txt"
git -C "$repoU" add staged.txt
printf 'edited after staging\n' >"$repoU/staged.txt"
expected=$(cd "$repoU" && cp .git/index "$work/idxU" && GIT_INDEX_FILE="$work/idxU" git add -A -- . && GIT_INDEX_FILE="$work/idxU" git write-tree)
# step_js BODY: run BODY with the CLI module as `m` in repoU (or $step_repo); prints its result or "refused:<why>".
step_js() {
  # The CLI path travels in the environment: as an argument it would make the module run as a command.
  (cd "${step_repo:-$repoU}" && STATE_CLI="$cli" node --input-type=module -e '
    import { pathToFileURL } from "node:url";
    import { execFileSync } from "node:child_process";
    import * as fs from "node:fs";
    const m = await import(pathToFileURL(process.env.STATE_CLI).href);
    const state = { repo_root: process.cwd(), candidate: { include_ignored: [] } };
    const body = new Function("m", "state", "writeFileSync", "fs", "execFileSync", "return (async () => {" + process.argv[1] + "})()");
    try {
      console.log(await body(m, state, fs.writeFileSync, fs, execFileSync));
    } catch (error) {
      console.log("refused:" + error.message);
    }
  ' "$1" 2>/dev/null) || true
}
[ "$(step_js 'return m.worktreeTree(process.cwd(), []);')" = "$expected" ] \
  || fail "the tree of listed paths must equal the tree of the whole working tree (changed, deleted, new, staged, and odd names)"
# The same holds for ignored artifacts a candidate names: a file, or everything under a directory.
printf 'dist/\nartifact.out\n' >"$repoU/.gitignore"
mkdir -p "$repoU/dist/sub"
printf 'built\n' >"$repoU/dist/a.js"
printf 'built\n' >"$repoU/dist/sub/b.js"
printf 'built\n' >"$repoU/artifact.out"
expected=$(cd "$repoU" && cp .git/index "$work/idxU" && GIT_INDEX_FILE="$work/idxU" git add -A -- . && GIT_INDEX_FILE="$work/idxU" git add -f -- dist artifact.out \
  && GIT_INDEX_FILE="$work/idxU" git write-tree)
[ "$(step_js 'return m.worktreeTree(process.cwd(), ["dist", "artifact.out"]);')" = "$expected" ] || fail "named ignored artifacts must be in the tree, as before"
grep -Fq 'refused:cannot compute' <<<"$(step_js 'return m.worktreeTree(process.cwd(), ["dits"]);')" || fail "a named artifact that matches nothing must still refuse"
printf 'token\n' >"$repoU/dist/secrets.json"
grep -Fq 'refused:a protected path is changed' <<<"$(step_js 'return m.worktreeTree(process.cwd(), ["dist"]);')" || fail "a protected path under a named artifact must refuse the tree"
git -C "$repoU" cat-file -e "$(git -C "$repoU" hash-object dist/secrets.json)" 2>/dev/null && fail "a protected path under a named artifact must not reach the object store"
rm "$repoU/dist/secrets.json"
printf 'token\n' >"$repoU/db.env"
secret=$(git -C "$repoU" hash-object db.env)
grep -Fq 'refused:a protected path is changed' <<<"$(step_js 'return m.worktreeTree(process.cwd(), []);')" || fail "a changed protected path must refuse the tree"
git -C "$repoU" cat-file -e "$secret" 2>/dev/null && fail "the content of a protected path must never reach the object store"
rm "$repoU/db.env"
# A likely-secret file created after the step's snapshot, while the tree is being built.
late=$(step_js 'return (await m.captureStep(process.cwd(), state, { tree: async (r) => { writeFileSync("db.env", "late token\n"); return m.worktreeTree(r, []); } })).tree;')
grep -Fq 'refused:a protected path is changed' <<<"$late" || fail "a protected path created after the snapshot must refuse the step: $late"
git -C "$repoU" cat-file -e "$(git -C "$repoU" hash-object db.env)" 2>/dev/null && fail "a late protected path must not reach the object store either"
rm "$repoU/db.env"
# Any other change while the tree is captured: the tree and the fingerprint would differ, so nothing is captured.
during=$(step_js 'return (await m.captureStep(process.cwd(), state, { tree: async (r) => { writeFileSync("a.txt", "changed during capture\n"); return m.worktreeTree(r, []); } })).tree;')
grep -Fq 'refused:the working tree changed while the step was captured' <<<"$during" || fail "a change during capture must refuse: $during"
[ "$(step_js 'return (await m.captureStep(process.cwd(), state)).tree.length;')" = 40 ] || fail "an unchanged tree is captured"
# A listed file that becomes a directory before its entry is updated is not descended into: the
# likely-secret file inside is never hashed, and the step is not captured.
swap='let done = false; const between = async () => { if (done) return; done = true; fs.rmSync("a.txt"); fs.mkdirSync("a.txt"); writeFileSync("a.txt/credentials.json", "swapped token\n"); };'
swapped=$(step_js "$swap return m.worktreeTree(process.cwd(), [], { between });")
[ "${#swapped}" = 40 ] || fail "a swapped path leaves a tree without it: $swapped"
[ -d "$repoU/a.txt" ] || fail "the probe must have swapped the file for a directory"
git -C "$repoU" ls-tree -r --name-only "$swapped" | grep -q '^a\.txt' && fail "neither the swapped path nor a file under it may be in the tree"
git -C "$repoU" cat-file -e "$(git -C "$repoU" hash-object a.txt/credentials.json)" 2>/dev/null && fail "a file under a swapped directory must not reach the object store"
rm -rf "$repoU/a.txt"
printf 'changed\n' >"$repoU/a.txt"
captured=$(step_js "$swap return (await m.captureStep(process.cwd(), state, { tree: (r) => m.worktreeTree(r, [], { between }) })).tree;")
grep -Fq 'refused:the working tree changed while the step was captured' <<<"$captured" || fail "a path swapped during capture must not be captured: $captured"
git -C "$repoU" cat-file -e "$(git -C "$repoU" hash-object a.txt/credentials.json)" 2>/dev/null && fail "nor may its content reach the object store through a step"
rm -rf "$repoU/a.txt"
printf 'changed\n' >"$repoU/a.txt"
# An untracked listed file swapped the same way has no entry to remove: git refuses the directory.
swap_new='let done = false; const between = async () => { if (done) return; done = true; fs.rmSync("new file.txt"); fs.mkdirSync("new file.txt"); writeFileSync("new file.txt/credentials.json", "swapped token\n"); };'
grep -Fq 'refused:cannot compute' <<<"$(step_js "$swap_new return m.worktreeTree(process.cwd(), [], { between });")" \
  || fail "an untracked path swapped for a directory must refuse the tree"
git -C "$repoU" cat-file -e "$(git -C "$repoU" hash-object 'new file.txt/credentials.json')" 2>/dev/null && fail "a file under a swapped untracked path must not reach the object store"
rm -rf "$repoU/new file.txt"
printf 'new\n' >"$repoU/new file.txt"
# The same for a named ignored artifact: the second listing is the artifacts'.
swap_artifact='let calls = 0; const between = async () => { if (++calls !== 2) return; fs.rmSync("artifact.out"); fs.mkdirSync("artifact.out"); writeFileSync("artifact.out/secrets.json", "swapped token\n"); };'
grep -Fq 'refused:cannot compute' <<<"$(step_js "$swap_artifact return m.worktreeTree(process.cwd(), [\"dist\", \"artifact.out\"], { between });")" \
  || fail "a named artifact swapped for a directory must refuse the tree"
git -C "$repoU" cat-file -e "$(git -C "$repoU" hash-object artifact.out/secrets.json)" 2>/dev/null && fail "a file under a swapped artifact must not reach the object store"
rm -rf "$repoU/artifact.out"
# A likely-secret path that is already staged is in the index the tree starts from: refused by name.
printf 'token\n' >"$repoU/db.env"
git -C "$repoU" add db.env
grep -Fq 'refused:a protected path is changed' <<<"$(step_js 'return m.worktreeTree(process.cwd(), []);')" || fail "a staged protected path must refuse the tree"
git -C "$repoU" rm -q --cached db.env
rm "$repoU/db.env"
# A repository without a commit has no HEAD: the step base records that, and the steps still run.
repoA="$work/repoA"
mkdir -p "$repoA"
git -C "$repoA" init -q .
git -C "$repoA" config user.email probe@example.invalid
git -C "$repoA" config user.name probe
printf 'a\n' >"$repoA/a.txt"
ok "$repoA" s1 init nocommit
CONSENT_COMMIT=no write_artifacts "$repoA" 1 a.txt
ok "$repoA" s1 approve --commit no --branch-target current --codex reviewer
ok "$repoA" s1 advance implement
[ "$(jq -c '[.step_base.head, (.step_base.tree | length)]' "$(sfile "$repoA")")" = '["",40]' ] || fail "a run before the first commit has a step base without HEAD"
printf 'b\n' >"$repoA/a.txt"
ok "$repoA" s1 record step S-1
[ "$(jq -c '[.history[-1].detail.paths, .step_base.head]' "$(sfile "$repoA")")" = '[1,""]' ] || fail "a step is recorded and checked before the first commit"
# The tree equals what adding everything builds for every kind of change a step can make,
# among them a file turned into a directory and a directory turned into a file.
repoI="$work/repoI"
make_repo "$repoI"
mkdir -p "$repoI/src/lib" "$repoI/sparse"
printf 'c\n' >"$repoI/src/config"
printf 'l\n' >"$repoI/src/lib/one.js"
printf 'm\n' >"$repoI/mode.sh"
printf 'k\n' >"$repoI/kind.txt"
printf 's\n' >"$repoI/sparse/kept.txt"
printf 'u\n' >"$repoI/assumed.txt"
git -C "$repoI" add .
git -C "$repoI" commit -qm "more files"
step_repo=$repoI
same_tree() { # DESCRIPTION: the helper's tree against the tree of `git add -A`
  local want got
  want=$(cd "$repoI" && cp .git/index "$work/idxI" && GIT_INDEX_FILE="$work/idxI" git add -A -- . 2>/dev/null && GIT_INDEX_FILE="$work/idxI" git write-tree)
  got=$(step_js 'return m.worktreeTree(process.cwd(), []);')
  [ -n "$want" ] && [ "$want" = "$got" ] || fail "the tree must equal the tree of the whole working tree ($1): $got"
}
rm "$repoI/src/config"
mkdir "$repoI/src/config"
printf 'i\n' >"$repoI/src/config/index.js"
same_tree "a file turned into a directory"
rm -rf "$repoI/src/config"
git -C "$repoI" checkout -q -- src/config
rm -rf "$repoI/src/lib"
printf 'f\n' >"$repoI/src/lib"
same_tree "a directory turned into a file"
rm "$repoI/src/lib"
git -C "$repoI" checkout -q -- src/lib
chmod +x "$repoI/mode.sh"
same_tree "a mode change"
rm "$repoI/kind.txt"
ln -s mode.sh "$repoI/kind.txt"
same_tree "a file turned into a symbolic link"
git -C "$repoI" update-index --skip-worktree sparse/kept.txt
rm "$repoI/sparse/kept.txt"
same_tree "a sparse entry absent from the working tree"
git -C "$repoI" update-index --assume-unchanged assumed.txt
printf 'changed\n' >"$repoI/assumed.txt"
same_tree "an entry assumed unchanged"
printf 'n\n' >"$repoI/intent.txt"
git -C "$repoI" add -N intent.txt
same_tree "an intent-to-add entry"
rm "$repoI/src/config"
mkdir -p "$repoI/src/config/deep"
printf 'd\n' >"$repoI/src/config/deep/x.js"
rm -rf "$repoI/src/lib"
printf 'f\n' >"$repoI/src/lib"
same_tree "both replacements at once, nested"
git -C "$repoI" add -A .
rm -rf "$repoI/src/config"
printf 'back\n' >"$repoI/src/config"
same_tree "a staged directory turned back into a file"
# A commit made while the step is being captured: HEAD is compared as the capture saw it, so the
# run is blocked and the moved HEAD never becomes the step base.
repoO="$work/repoO"
make_repo "$repoO"
ok "$repoO" s1 init headrace
write_artifacts "$repoO" 1 a.txt
ok "$repoO" s1 approve --commit yes --branch-target current --codex reviewer
ok "$repoO" s1 advance implement
printf 'o\n' >"$repoO/a.txt"
step_repo=$repoO
raced=$(step_js 'const capture = async (root, st) => { execFileSync("git", ["commit", "-q", "--allow-empty", "-m", "during the step"]); return m.captureStep(root, st); };
  const result = await m.run(["record", "step", "S-1", "--owner", "s1"], process.cwd(), { capture });
  return JSON.stringify([result.ok, result.recorded, result.phase, result.blocked.reason]);')
[ "$raced" = '[false,false,"blocked","HEAD moved during the step"]' ] || fail "a commit made during capture must block the run: $raced"
[ "$(jq -c '[(.steps | has("S-1")), .step_base.head == .baseline.head, .step_base.head == $h]' --arg h "$(git -C "$repoO" rev-parse HEAD)" "$(sfile "$repoO")")" = '[false,true,false]' ] \
  || fail "the step must not be recorded and the moved HEAD must not become the step base"
# The same commit made after the capture, during the comparison: caught by the check before the write.
ok "$repoO" s1 unblock implement --reason "reviewed the commit"
late_commit=$(step_js 'const capture = async (root, st) => { const captured = await m.captureStep(root, st); execFileSync("git", ["commit", "-q", "--allow-empty", "-m", "after the capture"]); return captured; };
  const result = await m.run(["record", "step", "S-1", "--owner", "s1"], process.cwd(), { capture });
  return JSON.stringify([result.ok, result.recorded, result.phase, result.blocked.reason]);')
[ "$late_commit" = '[false,false,"blocked","HEAD moved during the step"]' ] || fail "a commit made after capture must block the run too: $late_commit"
step_repo=

# --- a quick run: the request is its approval, within limits the CLI checks ----------------
quick_spec() { CONSENT_COMMIT=${2:-no} spec_json "${3:-1}" "$1" | jq '.size = "quick"'; }
write_quick() { # REPO [SCOPE] [COMMIT] [N]
  quick_spec "${2:-a.txt}" "${3:-no}" "${4:-1}" | br "$1" s1 write spec >/dev/null || fail "write quick spec ($1)"
  plan_json | br "$1" s1 write plan >/dev/null || fail "write plan ($1)"
}
quick_approve=(approve --commit no --branch-target current --codex reviewer --size quick)
repoQ="$work/repoQ"
make_repo "$repoQ"
ok "$repoQ" s1 init quick
write_quick "$repoQ" '**'
refused "$repoQ" s1 "${quick_approve[@]}"
grep -Fq 'full run' "$work/err" || fail "a quick run over its limits must be sent to a full run: $(cat "$work/err")"
grep -Fq 'glob' "$work/err" || fail "the broken quick limit must be named: $(cat "$work/err")"
write_quick "$repoQ" a.txt no 4
refused "$repoQ" s1 "${quick_approve[@]}"
grep -Fq 'more than 3 criteria' "$work/err" || fail "the criteria limit must be named: $(cat "$work/err")"
write_quick "$repoQ" a.txt yes
refused "$repoQ" s1 approve --commit yes --branch-target current --codex reviewer --size quick
grep -Fq 'commit no' "$work/err" || fail "a quick run must not carry commit consent: $(cat "$work/err")"
write_quick "$repoQ"
refused "$repoQ" s1 approve --commit no --branch-target current --codex reviewer   # the spec says quick
grep -Fq 'size' "$work/err" || fail "a size that differs from the spec must be named: $(cat "$work/err")"
invalid "$repoQ" s1 approve --commit no --branch-target current --codex reviewer --size huge
[ "$(phase "$repoQ")" = clarify ] || fail "a refused quick approval must leave the phase"
ok "$repoQ" s1 check
grep -Fq 'the user'"'"'s change request is its approval' <<<"$(jq -r '.next[-1]' <<<"$out")" || fail "a quick run needs no approval round: $out"
grep -Fq -- '--size quick' <<<"$(jq -r '.next[-1]' <<<"$out")" || fail "the quick approval must be named: $out"
ok "$repoQ" s1 "${quick_approve[@]}"
[ "$(jq -r .size "$(sfile "$repoQ")")" = quick ] || fail "the run size must be recorded"
grep -Fq '## Size' "$(dirname "$(sfile "$repoQ")")/spec.md" || fail "spec.md must show the size"
ok "$repoQ" s1 advance implement
printf 'q\n' >"$repoQ/a.txt"
apply_steps "$repoQ"
ok "$repoQ" s1 advance verify
ok "$repoQ" s1 record check --cmd "make test" --exit 0
ok "$repoQ" s1 check
grep -Fq 'blocks a quick run' <<<"$(jq -r '.next[0]' <<<"$out")" || fail "a quick run must be told what a trigger does: $out"
# A review trigger is more than the request approved: the run stops for a full-run approval.
ok "$repoQ" s1 advance review --trigger "workflow policy"
[ "$(phase "$repoQ")" = blocked ] || fail "a review trigger must block a quick run: $(phase "$repoQ")"
[ "$(jq -c '.history[-1] | [.op, .detail.trigger, .detail.needs]' "$(sfile "$repoQ")")" = '["advance","workflow policy","full-run approval"]' ] \
  || fail "the block must record the trigger and what it needs"
[ "$(jq -c '[.review.trigger, .review.required]' "$(sfile "$repoQ")")" = '["workflow policy",true]' ] \
  || fail "the trigger a quick run met must become its review obligation"
# The only way on is a new approval as a full run: the review cannot be unblocked away.
refused "$repoQ" s1 unblock verify --reason "keep going"
grep -Fq 'unblock clarify' "$work/err" || fail "the way out of a quick run's trigger must be named: $(cat "$work/err")"
refused "$repoQ" s1 unblock implement --reason "keep going"
refused "$repoQ" s1 unblock fix --reason "keep going"
[ "$(phase "$repoQ")" = blocked ] || fail "a refused unblock must leave the run blocked"
refused "$repoQ" s1 check
grep -Fq 'unblock clarify --reason R, then write the spec without size quick' <<<"$(jq -r '.next[1]' <<<"$out")" || fail "the block must owe a full-run approval: $out"
# Promotion is a new approval of a full spec; the run's own edit stays the run's change.
ok "$repoQ" s1 unblock clarify --reason "the user approved a full run"
[ "$(jq -r .review.trigger "$(sfile "$repoQ")")" = "workflow policy" ] || fail "the met trigger must survive the return to clarify"
refused "$repoQ" s1 "${quick_approve[@]}"             # the spec is still quick
grep -Fq 'a review trigger this run already met' "$work/err" || fail "a run that met a trigger cannot be approved as quick again: $(cat "$work/err")"
CONSENT_COMMIT=no write_artifacts "$repoQ" 1 a.txt
ok "$repoQ" s1 approve --commit no --branch-target current --codex reviewer
[ "$(jq -c '[.size, .baseline.dirty]' "$(sfile "$repoQ")")" = '["full",{}]' ] || fail "a promoted run is full and its edits are not pre-existing"
# The promoted run still owes the review: no low-risk exception, and review is where it goes.
ok "$repoQ" s1 advance implement
apply_steps "$repoQ"
ok "$repoQ" s1 advance verify
ok "$repoQ" s1 record check --cmd "make test" --exit 0
refused "$repoQ" s1 record review --low-risk "small change"
grep -Fq 'review was already' "$work/err" || fail "a promoted run must not skip its review: $(cat "$work/err")"
refused "$repoQ" s1 advance qa
ok "$repoQ" s1 check
[ "$(jq -c .next <<<"$out")" = "[\"b-state.mjs advance review --trigger 'workflow policy'\"]" ] || fail "a promoted run must owe its review: $out"
ok "$repoQ" s1 advance review --trigger "workflow policy"
[ "$(phase "$repoQ")" = review ] || fail "a full run enters review: $(phase "$repoQ")"
# A second return to clarify does not drop the obligation either: not as a quick run, not as a full one.
ok "$repoQ" s1 advance blocked --reason "the user wants a narrower spec" --needs "re-approval"
ok "$repoQ" s1 unblock clarify --reason "narrower spec"
[ "$(jq -c '[.review.trigger, .review.required]' "$(sfile "$repoQ")")" = '["workflow policy",true]' ] \
  || fail "a met trigger must survive every return to clarify"
write_quick "$repoQ"
refused "$repoQ" s1 "${quick_approve[@]}"
grep -Fq 'a review trigger this run already met' "$work/err" || fail "a promoted run cannot go back to quick: $(cat "$work/err")"
CONSENT_COMMIT=no write_artifacts "$repoQ" 1 a.txt
ok "$repoQ" s1 approve --commit no --branch-target current --codex reviewer
ok "$repoQ" s1 advance implement
apply_steps "$repoQ"
ok "$repoQ" s1 advance verify
ok "$repoQ" s1 record check --cmd "make test" --exit 0
refused "$repoQ" s1 record review --low-risk "small change"
grep -Fq 'review was already' "$work/err" || fail "the review obligation must survive a second approval: $(cat "$work/err")"
refused "$repoQ" s1 advance qa

# The same holds for a run that was never quick: once it met a trigger it cannot be re-approved as quick.
repoY="$work/repoY"
make_repo "$repoY"
ok "$repoY" s1 init fullfirst
write_artifacts "$repoY" 1 a.txt
ok "$repoY" s1 approve --commit yes --branch-target current --codex reviewer
ok "$repoY" s1 advance implement
printf 'y\n' >"$repoY/a.txt"
apply_steps "$repoY"
ok "$repoY" s1 advance verify
ok "$repoY" s1 record check --cmd "make test" --exit 0
ok "$repoY" s1 advance review --trigger "approval policy"
ok "$repoY" s1 advance blocked --reason "the user wants a smaller change" --needs "re-approval"
ok "$repoY" s1 unblock clarify --reason "smaller change"
[ "$(jq -r .review.trigger "$(sfile "$repoY")")" = "approval policy" ] || fail "a full run's met trigger must survive the return to clarify"
write_quick "$repoY"
refused "$repoY" s1 "${quick_approve[@]}"
grep -Fq 'a review trigger this run already met' "$work/err" || fail "a run that met a trigger cannot become quick: $(cat "$work/err")"
CONSENT_COMMIT=no write_artifacts "$repoY" 1 a.txt
ok "$repoY" s1 approve --commit no --branch-target current --codex reviewer
ok "$repoY" s1 advance implement
apply_steps "$repoY"
ok "$repoY" s1 advance verify
ok "$repoY" s1 record check --cmd "make test" --exit 0
refused "$repoY" s1 record review --low-risk "small change"
ok "$repoY" s1 check
[ "$(jq -c .next <<<"$out")" = "[\"b-state.mjs advance review --trigger 'approval policy'\"]" ] || fail "a re-approved run must still owe its review: $out"

# The size is the approved spec's: a state edited to call a quick run full gains nothing.
repoT="$work/repoT"
make_repo "$repoT"
ok "$repoT" s1 init tamper
write_quick "$repoT"
ok "$repoT" s1 "${quick_approve[@]}"
ok "$repoT" s1 advance implement
printf 't\n' >"$repoT/a.txt"
apply_steps "$repoT"
ok "$repoT" s1 advance verify
ok "$repoT" s1 record check --cmd "make test" --exit 0
jq '.size = "full"' "$(sfile "$repoT")" >"$tmp" && cp "$tmp" "$(sfile "$repoT")"
refused "$repoT" s1 advance review --trigger "workflow policy"
grep -Fq 'size differs from the approved spec' "$work/err" || fail "an edited size must be named: $(cat "$work/err")"
[ "$(phase "$repoT")" = verify ] || fail "an edited size must not enter review: $(phase "$repoT")"
refused "$repoT" s1 record review --low-risk "small change"
refused "$repoT" s1 check
[ "$(jq -c '[.phase, .blocked.reason, .blocked.needs]' <<<"$out")" = '["blocked","recorded run size differs from the approved spec","re-approval"]' ] \
  || fail "check must block a run whose size differs from the approved spec: $out"

# --- a run without commit consent ends at QA; one unfinished run per worktree ---------------
repoN="$work/repoN"
make_repo "$repoN"
ok "$repoN" s1 init first
write_quick "$repoN"
ok "$repoN" s1 "${quick_approve[@]}"
ok "$repoN" s1 advance implement
printf 'n\n' >"$repoN/a.txt"
apply_steps "$repoN"
ok "$repoN" s1 advance verify
ok "$repoN" s1 record check --cmd "make test" --exit 0
ok "$repoN" s1 record review --low-risk "one-line change, no trigger"
ok "$repoN" s1 advance qa
refused "$repoN" s1 advance "done"                    # no QA PASS yet
write_qa "$repoN" 1 "QA PASS" pass
ok "$repoN" s1 record qa --verdict "QA PASS"
refused "$repoN" s1 advance "done"                    # the criterion is not recorded yet
grep -Fq 'AC-1' "$work/err" || fail "the open criterion must be named: $(cat "$work/err")"
ok "$repoN" s1 record ac AC-1 pass
ok "$repoN" s1 check
[ "$(jq -r '.next[0]' <<<"$out")" = "b-state.mjs advance done" ] || fail "a run without commit consent must owe advance done: $out"
refused "$repoN" s1 advance commit                    # the spec gave no commit consent
refused "$repoN" s2 init second                       # the first run is not finished
grep -Fq 'first is not finished' "$work/err" || fail "the unfinished run must be named: $(cat "$work/err")"
ok "$repoN" s1 advance "done"
[ "$(phase "$repoN")" = "done" ] || fail "a QA-passed run without commit consent must finish"
[ "$(git -C "$repoN" rev-list --count HEAD)" = 1 ] || fail "a run without commit consent must not commit"
ok "$repoN" s1 init second                            # a finished run does not hold the worktree
refused "$repoN" s1 init third
ok "$repoN" s1 init third --replace                   # only on the user's answer
[ "$(cat "$repoN/.b-agentic/active")" = "$(date -u +%Y%m%d)-third" ] || fail "--replace must make the new run active"

# --- changes already in the tree at run start stay the user's ---------------------------------
repoW="$work/repoW"
make_repo "$repoW"
printf 'mine\n' >"$repoW/a.txt"                       # a tracked change
printf 'mine\n' >"$repoW/u.txt"                       # an untracked file
printf 'SECRET=1\n' >"$repoW/.env"                    # never read, so never the user's by content
ok "$repoW" s1 init dirty
[ "$(jq -c '.baseline.dirty | keys' "$(sfile "$repoW")")" = '["a.txt","u.txt"]' ] || fail "run start must record the changed paths it can identify"
[ "$(jq -r '.baseline.dirty["a.txt"] | length' "$(sfile "$repoW")")" = 64 ] || fail "a pre-existing path is recorded by content digest"
CONSENT_COMMIT=no spec_json 1 b.txt | br "$repoW" s1 write spec >/dev/null || fail "write spec (repoW)"
plan_json | jq '.steps[0].paths = ["b.txt"]' | br "$repoW" s1 write plan >/dev/null || fail "write plan (repoW)"
ok "$repoW" s1 approve --commit no --branch-target current --codex reviewer   # no commit: a changed tree is allowed
ok "$repoW" s1 advance implement
printf 'run\n' >"$repoW/b.txt"
refused "$repoW" s1 record step S-1                   # a likely-secret file has no safe identity: no evidence yet
grep -Fq 'incomplete' "$work/err" || fail "a likely-secret file in the tree must stop the evidence: $(cat "$work/err")"
rm "$repoW/.env"
apply_steps "$repoW"
ok "$repoW" s1 advance verify
ok "$repoW" s1 record check --cmd "make test" --exit 0
ok "$repoW" s1 record review --low-risk "docs-only"
(cd "$repoW" && python3 -I -B "$run_cli" scope-check --owner s1) >"$work/scope.json" || fail "scope check with pre-existing changes"
[ "$(jq -c '[.ok, .changed, .preexisting]' "$work/scope.json")" = '[true,1,2]' ] || fail "pre-existing changes are not the run's: $(cat "$work/scope.json")"
(cd "$repoW" && python3 -I -B "$run_cli" handoff implement --owner s1) >"$work/packet.txt" || fail "packet with pre-existing changes"
[ "$(sed -n '/^## Changed paths/,/^$/p' "$work/packet.txt" | grep -c '^- ')" = 1 ] || fail "the packet must list only the run's change: $(cat "$work/packet.txt")"
grep -Fq -- '- u.txt' <<<"$(sed -n '/^## Changes in the tree before the run/,$p' "$work/packet.txt")" || fail "the packet must list pre-existing changes apart: $(cat "$work/packet.txt")"
ok "$repoW" s1 advance qa
# Once its content differs, a pre-existing path is a change of the run like any other.
printf 'the run touched it\n' >"$repoW/u.txt"
ok "$repoW" s1 check
ok "$repoW" s1 record check --cmd "make test" --exit 0
ok "$repoW" s1 record review --low-risk "docs-only"
refused "$repoW" s1 advance qa
grep -Fq 'u.txt' "$work/err" || fail "a pre-existing path the run changed must be checked against the scope: $(cat "$work/err")"
# A state edited to claim a likely-secret path as pre-existing is invalid, and the scope check never reads one.
printf 'SECRET=2\n' >"$repoW/.env"
jq '.baseline.dirty[".env"] = ("a" * 64)' "$(sfile "$repoW")" >"$work/tampered.json"
cp "$(sfile "$repoW")" "$work/state.keep" && cp "$work/tampered.json" "$(sfile "$repoW")"
invalid "$repoW" s1 show
rc=0; (cd "$repoW" && python3 -I -B "$run_cli" scope-check --owner s1) >"$work/scope.json" || rc=$?
[ "$rc" -eq 3 ] || fail "a likely-secret path must fail the scope check (rc=$rc)"
jq -e '.protected | index(".env") != null' "$work/scope.json" >/dev/null || fail "a likely-secret path is never pre-existing by content: $(cat "$work/scope.json")"
cp "$work/state.keep" "$(sfile "$repoW")" && rm "$repoW/.env"
# What a run does to a change that was there before it is the run's: deleting it, reverting it, or
# changing its mode is checked against the scope even when git no longer reports the path.
repoX="$work/repoX"
make_repo "$repoX"
printf 'mine\n' >"$repoX/a.txt"
printf 'mine\n' >"$repoX/u.txt"
printf '#!/bin/sh\n' >"$repoX/x.sh"
ok "$repoX" s1 init baseline
CONSENT_COMMIT=no spec_json 1 b.txt | br "$repoX" s1 write spec >/dev/null || fail "write spec (repoX)"
plan_json | jq '.steps[0].paths = ["b.txt"]' | br "$repoX" s1 write plan >/dev/null || fail "write plan (repoX)"
scope() { rc=0; (cd "$1" && python3 -I -B "$run_cli" scope-check --owner s1) >"$work/scope.json" || rc=$?; }
scope_ok() { scope "$repoX"; [ "$rc" -eq 0 ] || fail "$1: $(cat "$work/scope.json")"; }
scope_flags() { # PATH WHY
  scope "$repoX"
  [ "$rc" -eq 3 ] || fail "$2 (rc=$rc): $(cat "$work/scope.json")"
  jq -e --arg p "$1" '.outside_scope | index($p) != null' "$work/scope.json" >/dev/null || fail "$2: $(cat "$work/scope.json")"
}
scope_ok "untouched pre-existing changes are not the run's"
[ "$(jq .preexisting "$work/scope.json")" = 3 ] || fail "all three pre-existing changes must be recognized: $(cat "$work/scope.json")"
rm "$repoX/u.txt"
scope_flags u.txt "deleting a pre-existing untracked file is the run's change"
printf 'mine\n' >"$repoX/u.txt"
scope_ok "restoring the content makes it pre-existing again"
git -C "$repoX" checkout -q -- a.txt
scope_flags a.txt "reverting a pre-existing tracked edit is the run's change"
printf 'mine\n' >"$repoX/a.txt"
scope_ok "restoring the edit makes it pre-existing again"
chmod +x "$repoX/x.sh"
scope_flags x.sh "a mode change on a pre-existing file is the run's change"
chmod -x "$repoX/x.sh"
scope_ok "restoring the mode makes it pre-existing again"

# A link above a changed path must not be followed: nothing outside the tree is read or matched.
repoL="$work/repoL"
make_repo "$repoL"
mkdir "$repoL/d" && printf 'in\n' >"$repoL/d/s.txt"
git -C "$repoL" add d && git -C "$repoL" commit -qm "add d"
mkdir "$work/outside" && printf 'outside\n' >"$work/outside/s.txt"
rm -r "$repoL/d" && ln -s "$work/outside" "$repoL/d"
ok "$repoL" s1 init linked-dir
[ "$(jq -c '.baseline.dirty | keys' "$(sfile "$repoL")")" = '["d"]' ] || fail "a path under a linked directory must not be read: $(jq -c .baseline.dirty "$(sfile "$repoL")")"
CONSENT_COMMIT=no spec_json 1 b.txt | br "$repoL" s1 write spec >/dev/null || fail "write spec (repoL)"
plan_json | jq '.steps[0].paths = ["b.txt"]' | br "$repoL" s1 write plan >/dev/null || fail "write plan (repoL)"
outside_digest=$(printf 'outside\n' | sha256sum | cut -d' ' -f1)
jq --arg d "$outside_digest" '.baseline.dirty["d/s.txt"] = $d' "$(sfile "$repoL")" >"$tmp" && cp "$tmp" "$(sfile "$repoL")"
scope "$repoL"
[ "$rc" -eq 3 ] || fail "a recorded path under a linked directory must not match the file outside the tree (rc=$rc)"
[ "$(jq -c '[.preexisting, (.outside_scope | index("d/s.txt") != null)]' "$work/scope.json")" = '[1,true]' ] \
  || fail "the scope check must not follow a linked directory: $(cat "$work/scope.json")"

# Concurrent inits: one worktree, exactly one run.
repoR="$work/repoR"
make_repo "$repoR"
mkdir -p "$repoR/.b-agentic/runs" && printf '*\n' >"$repoR/.b-agentic/.gitignore"
( cd "$repoR" && for n in 1 2 3 4 5 6; do node "$cli" init "race$n" --owner "r$n" >/dev/null 2>&1 & done; wait ) || true
[ "$(find "$repoR/.b-agentic/runs" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1 ] || fail "concurrent inits must create exactly one run: $(ls "$repoR/.b-agentic/runs")"
[ ! -e "$repoR/.b-agentic/mutex" ] || fail "no worktree mutex may remain after init"
[ "$(cat "$repoR/.b-agentic/active")" = "$(ls "$repoR/.b-agentic/runs")" ] || fail "the active pointer must name the one run"

# Too many changed paths cannot be told apart from a run's own.
repoM="$work/repoM"
make_repo "$repoM"
for i in $(seq 1 201); do printf 'x\n' >"$repoM/f$i.txt"; done
refused "$repoM" s1 init toomany
grep -Fq 'too many' "$work/err" || fail "too many pre-existing changes must be named: $(cat "$work/err")"
[ ! -e "$repoM/.b-agentic/active" ] || fail "a refused init must not leave an active run"

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

# --- parallel worker steps: one worktree per worker, never the main tree or the state (ADR-016) ---
wt_tmp="$work/wt"
mkdir -p "$wt_tmp"
export TMPDIR="$wt_tmp"
parallel_plan() {
  jq -n '{steps: [{id: "S-1", action: "a", paths: ["src/a.txt"], done_when: "d", depends_on: []},
    {id: "S-2", action: "b", paths: ["src/b.txt"], done_when: "d", depends_on: ["S-1"]},
    {id: "S-3", action: "c", paths: ["src/c.txt"], done_when: "d", depends_on: ["S-1"]},
    {id: "S-4", action: "d", paths: ["src/d.txt"], done_when: "d", depends_on: ["S-1"]}],
    checks: ["make test"], invariants: [], stop_conditions: [],
    worker_steps: ["S-2", "S-3", "S-4"], parallel_steps: ["S-2", "S-3", "S-4"]}'
}
repoPW="$work/repoPW"
make_repo "$repoPW"
printf '.env\n' >"$repoPW/.gitignore"
git -C "$repoPW" add .gitignore
git -C "$repoPW" commit -qm "ignore env"
printf '#!/bin/sh\ntouch "%s/hook-ran"\n' "$work" >"$repoPW/.git/hooks/post-checkout"
chmod +x "$repoPW/.git/hooks/post-checkout"
ok "$repoPW" s1 init parallel
spec_json 1 'src/**' | br "$repoPW" s1 write spec >/dev/null || fail "write spec (repoPW)"
parallel_plan | br "$repoPW" s1 write plan >/dev/null || fail "write plan (repoPW)"
ok "$repoPW" s1 approve --commit yes --branch-target current --codex reviewer
ok "$repoPW" s1 advance implement
ok "$repoPW" s1 check
jq -e '.next | map(select(startswith("these worker steps may run"))) | length == 0' <<<"$out" >/dev/null || fail "no batch is named while its dependency is open: $out"
refused "$repoPW" s1 worktree add S-2
grep -Fq 'depends on' "$work/err" || fail "a waiting step gets no worktree: $(cat "$work/err")"
refused "$repoPW" s1 worktree add S-1
grep -Fq 'parallel_steps' "$work/err" || fail "an unlisted step gets no worktree: $(cat "$work/err")"
invalid "$repoPW" s1 worktree add
invalid "$repoPW" s1 worktree frob S-2
refused "$repoPW" s1 worktree remove S-2
mkdir -p "$repoPW/src"
printf 'a\n' >"$repoPW/src/a.txt"
ok "$repoPW" s1 record step S-1
ok "$repoPW" s1 check
jq -e '.next | any(startswith("these worker steps may run at the same time, each in its own worktree: S-2, S-3; for each"))' <<<"$out" >/dev/null \
  || fail "a batch names the first two ready steps in plan order: $out"
jq -e '.next | any(startswith("hand S-4")) and all(startswith("hand S-2") | not)' <<<"$out" >/dev/null \
  || fail "a step in the batch gets no line of its own, one outside it keeps its line: $out"
before=$(snap "$repoPW")
before_status=$(git -C "$repoPW" status --porcelain)
before_head=$(git -C "$repoPW" rev-parse HEAD)
# A temporary folder inside the repository, or a link into it, would put a checkout in the main tree.
mkdir -p "$repoPW/tmpin"
TMPDIR="$repoPW/tmpin" refused "$repoPW" s1 worktree add S-2
grep -Fq 'inside the repository' "$work/err" || fail "a temporary folder inside the repository is refused: $(cat "$work/err")"
ln -s "$repoPW/tmpin" "$work/alias-in"
TMPDIR="$work/alias-in" refused "$repoPW" s1 worktree add S-2
grep -Fq 'inside the repository' "$work/err" || fail "a link into the repository is refused: $(cat "$work/err")"
[ -z "$(ls -A "$repoPW/tmpin")" ] || fail "nothing is made in the repository before the refusal"
rmdir "$repoPW/tmpin"
rm "$work/alias-in"
# A configured filter a checkout could run is refused before it runs, whatever selects it and
# wherever the command is started from; one from the global configuration counts too.
git -C "$repoPW" config filter.probe.smudge "touch $work/filter-ran; cat"
refused "$repoPW" s1 worktree add S-2
grep -Fq 'smudge, or process filter' "$work/err" || fail "a configured filter is refused: $(cat "$work/err")"
[ ! -e "$work/filter-ran" ] || fail "the filter must not run"
rc=0
(cd "$repoPW/src" && node "$cli" worktree add S-2 --owner s1 >/dev/null 2>"$work/err") || rc=$?
[ "$rc" -eq 3 ] || fail "a configured filter is refused from a subdirectory too: rc=$rc $(cat "$work/err")"
git -C "$repoPW" config --unset filter.probe.smudge
printf '[filter "global"]\n\tprocess = touch %s/filter-ran-global\n' "$work" >"$work/global.cfg"
GIT_CONFIG_GLOBAL="$work/global.cfg" refused "$repoPW" s1 worktree add S-2
grep -Fq 'smudge, or process filter' "$work/err" || fail "a filter from the global configuration is refused: $(cat "$work/err")"
[ ! -e "$work/filter-ran-global" ] || fail "the global filter must not run"
old_umask=$(umask)
umask 000
ok "$repoPW" s1 worktree add S-2
umask "$old_umask"
wt2=$(jq -r .dir <<<"$out")
wt_parent=$(dirname "$wt2")
case "$wt2" in "$wt_tmp"/b-agentic-wt-u*/b-agentic-wt-*-S-2) ;; *) fail "a worktree lives in the owner-only folder under the temporary folder, named for the run and step: $wt2" ;; esac
[ "$(stat -c %a "$wt_parent")" = 700 ] || fail "the worktree folder is for its owner alone, whatever the umask: $(stat -c %a "$wt_parent")"
[ -f "$wt2/src/a.txt" ] || fail "a worktree carries the run's earlier, uncommitted step"
[ "$(git -C "$wt2" rev-parse 'HEAD^{tree}')" = "$(jq -r .step_base.tree "$(sfile "$repoPW")")" ] || fail "a worktree holds exactly the step base tree"
[ -z "$(git -C "$wt2" status --porcelain)" ] || fail "a fresh worktree is clean"
[ "$before" = "$(snap "$repoPW")" ] || fail "worktree add must not write the state"
[ "$before_status" = "$(git -C "$repoPW" status --porcelain)" ] || fail "worktree add must not touch the main tree"
[ "$before_head" = "$(git -C "$repoPW" rev-parse HEAD)" ] || fail "worktree add must not move HEAD"
[ "$(git -C "$repoPW" branch --list | wc -l)" -eq 1 ] || fail "worktree add must not make a branch"
[ ! -e "$work/hook-ran" ] || fail "no repository hook may run for a worker worktree"
chmod 755 "$wt_parent"
refused "$repoPW" s1 worktree add S-3
grep -Fq 'owner-only' "$work/err" || fail "a folder others can enter is refused: $(cat "$work/err")"
chmod 700 "$wt_parent"
ok "$repoPW" s1 worktree add S-3
wt3=$(jq -r .dir <<<"$out")
refused "$repoPW" s1 worktree add S-4
grep -Fq 'at most 2' "$work/err" || fail "a batch starts two workers at most: $(cat "$work/err")"
refused "$repoPW" s1 worktree add S-2
grep -Fq 'already has a worktree' "$work/err" || fail "one worktree per step: $(cat "$work/err")"
ok "$repoPW" s1 check
jq -e '.next | any(startswith("worktrees exist for S-2, S-3"))' <<<"$out" >/dev/null || fail "check names the worktrees that exist: $out"
# collect refuses, without writing, whatever a worker did that the gate would not accept.
printf 'x\n' >"$wt3/src/zz.txt"
refused "$repoPW" s1 worktree collect S-3
grep -Fq "outside S-3's own paths" "$work/err" || fail "a path outside the step's own paths is refused: $(cat "$work/err")"
rm "$wt3/src/zz.txt"
printf 'x\n' >"$wt3/README.md"
refused "$repoPW" s1 worktree collect S-3
grep -Fq 'outside the approved scope' "$work/err" || fail "a path outside the scope is refused: $(cat "$work/err")"
rm "$wt3/README.md"
printf 'x\n' >"$wt3/server.pem"
refused "$repoPW" s1 worktree collect S-3
grep -Fq 'protected' "$work/err" || fail "a likely-secret path is refused: $(cat "$work/err")"
rm "$wt3/server.pem"
# An ignored secret never reaches the tree, so its name is looked at on its own.
printf 'x\n' >"$wt3/.env"
refused "$repoPW" s1 worktree collect S-3
grep -Fq 'ignored files included' "$work/err" || fail "an ignored likely-secret file is refused too: $(cat "$work/err")"
rm "$wt3/.env"
orig3=$(git -C "$wt3" rev-parse HEAD)
git -C "$wt3" commit -q --allow-empty -m moved
refused "$repoPW" s1 worktree collect S-3
grep -Fq 'moved off its base commit' "$work/err" || fail "a worktree that left its base commit is refused: $(cat "$work/err")"
git -C "$wt3" checkout -q --detach "$orig3"
printf 'q\n' >"$repoPW/src/d.txt"
refused "$repoPW" s1 worktree collect S-3
grep -Fq 'main working tree changed' "$work/err" || fail "a worker that wrote the main tree is caught before anything is applied: $(cat "$work/err")"
rm "$repoPW/src/d.txt"
[ "$before" = "$(snap "$repoPW")" ] || fail "no refusal of collect may write the state"
# Collected and applied one step at a time, in plan order; the main tree must be the step base each time.
printf 'b \n' >"$wt2/src/b.txt"
printf 'c\n' >"$wt3/src/c.txt"
# A clean filter configured after the worktree was made would run when the worker's tree is built:
# collect and the record check look again, and neither builds the tree.
git -C "$repoPW" config filter.sneaky.clean "touch $work/clean-ran; cat"
printf 'b.txt filter=sneaky\n' >>"$repoPW/.git/info/attributes"
refused "$repoPW" s1 worktree collect S-2
grep -Fq 'clean, smudge, or process filter' "$work/err" || fail "collect refuses a clean filter configured since: $(cat "$work/err")"
refused "$repoPW" s1 record step S-2 --by worker
grep -Fq 'clean, smudge, or process filter' "$work/err" || fail "the record check refuses a clean filter configured since: $(cat "$work/err")"
[ ! -e "$work/clean-ran" ] || fail "the clean filter must not run"
git -C "$repoPW" config --unset filter.sneaky.clean
rm "$repoPW/.git/info/attributes"
# Building the worker's tree runs no file system monitor and no index hook; a plain git command in
# the same worktree does, which shows the traps are live.
printf '#!/bin/sh\npwd >>"%s/hook-cwd"\n' "$work" >"$work/fsm.sh"
chmod +x "$work/fsm.sh"
cp "$work/fsm.sh" "$repoPW/.git/hooks/post-index-change"
git -C "$repoPW" config core.fsmonitor "$work/fsm.sh"
git -C "$wt2" ls-files --modified >/dev/null 2>&1
GIT_INDEX_FILE="$work/probe-index" git -C "$wt2" update-index --add src/b.txt 2>/dev/null
grep -Fxq "$(cd "$wt2" && pwd -P)" "$work/hook-cwd" || fail "the control must show the monitor or hook runs in the worktree: $(cat "$work/hook-cwd" 2>&1)"
: >"$work/hook-cwd"
ok "$repoPW" s1 worktree collect S-2
! grep -Fxq "$(cd "$wt2" && pwd -P)" "$work/hook-cwd" || fail "collect must not run a monitor or hook in the worktree: $(cat "$work/hook-cwd")"
git -C "$repoPW" config --unset core.fsmonitor
rm "$repoPW/.git/hooks/post-index-change" "$work/probe-index"
# The user's diff and apply configuration must not change the printed command: prefixes, color,
# an external diff program, a textconv program, and a whitespace fix would each break or alter it.
printf '#!/bin/sh\ntouch "%s/ext-ran"\n' "$work" >"$work/ext.sh"
chmod +x "$work/ext.sh"
git -C "$repoPW" config diff.external "$work/ext.sh"
git -C "$repoPW" config diff.conv.textconv "$work/ext.sh"
git -C "$repoPW" config diff.noprefix true
git -C "$repoPW" config color.ui always
git -C "$repoPW" config apply.whitespace fix
printf '* diff=conv\n' >>"$repoPW/.git/info/attributes"
ok "$repoPW" s1 worktree collect S-2
[ "$(jq -c '[.step, .changed, (.tree | length)]' <<<"$out")" = '["S-2",1,40]' ] || fail "collect reports the step, its changed paths and the worker tree: $out"
apply2=$(jq -r .apply <<<"$out")
ok "$repoPW" s1 worktree collect S-3
apply3=$(jq -r .apply <<<"$out")
(cd "$repoPW" && bash -c "$apply2") || fail "the printed apply command must apply: $apply2"
[ "$(cat "$repoPW/src/b.txt")" = "b " ] || fail "the worker's change is applied to the main tree as it was, trailing space included"
[ ! -e "$work/ext-ran" ] || fail "no external diff or textconv program may run for the printed command"
refused "$repoPW" s1 worktree collect S-3
grep -Fq 'main working tree changed' "$work/err" || fail "a worker is collected only while the main tree is the step base: $(cat "$work/err")"
# Both changes applied before the first record: each is in scope, so only the equality check sees it.
(cd "$repoPW" && bash -c "$apply3") || fail "the second apply command must apply: $apply3"
before=$(snap "$repoPW")
refused "$repoPW" s1 record step S-2 --by worker
grep -Fq "outside its own paths" "$work/err" || fail "a record that holds another step's change is refused by name: $(cat "$work/err")"
[ "$before" = "$(snap "$repoPW")" ] || fail "that refusal comes before any write"
# The worker wrote the other step's file too: the changes are equal, but they leave its own paths.
cp "$repoPW/src/c.txt" "$wt2/src/c.txt"
refused "$repoPW" s1 record step S-2 --by worker
grep -Fq "outside its own paths" "$work/err" || fail "a worktree step that left its own paths is refused at record: $(cat "$work/err")"
[ "$before" = "$(snap "$repoPW")" ] || fail "that refusal comes before any write too"
rm "$wt2/src/c.txt"
rm "$repoPW/src/c.txt"
# The same for a path outside the approved scope: refused before the counted scope refusal, so nothing is written.
printf 'x\n' >"$repoPW/README.md"
cp "$repoPW/README.md" "$wt2/README.md"
refused "$repoPW" s1 record step S-2 --by worker
grep -Fq "outside its own paths" "$work/err" || fail "an out-of-scope path both trees share is refused as outside the step's own paths: $(cat "$work/err")"
[ "$before" = "$(snap "$repoPW")" ] || fail "no attempt is counted and nothing is written for it"
rm "$repoPW/README.md" "$wt2/README.md"
# Within its own paths but not what the worker wrote: the equality check refuses.
printf 'other\n' >"$repoPW/src/b.txt"
refused "$repoPW" s1 record step S-2 --by worker
grep -Fq "is not S-2's worker change" "$work/err" || fail "a change that differs from the worker's is refused by name: $(cat "$work/err")"
[ "$before" = "$(snap "$repoPW")" ] || fail "that refusal comes before any write as well"
printf 'b \n' >"$repoPW/src/b.txt"
printf 'x\n' >"$wt2/.env"
refused "$repoPW" s1 record step S-2 --by worker
grep -Fq 'ignored files included' "$work/err" || fail "a worker's ignored likely-secret file stops its record: $(cat "$work/err")"
[ "$before" = "$(snap "$repoPW")" ] || fail "that refusal comes before any write"
rm "$wt2/.env"
ok "$repoPW" s1 record step S-2 --by worker
[ "$(jq -c '.history[-1].detail | [.step, .by, .worktree, .paths, .outside]' "$(sfile "$repoPW")")" = '["S-2","worker",true,1,0]' ] \
  || fail "a worker step with its own worktree records it: $(jq -c '.history[-1]' "$(sfile "$repoPW")")"
ok "$repoPW" s1 worktree remove S-2
[ ! -e "$wt2" ] || fail "remove deletes the worktree folder"
[ "$(git -C "$repoPW" worktree list | grep -c 'b-agentic-wt-')" -eq 1 ] || fail "remove leaves the other worktree registered"
refused "$repoPW" s1 worktree remove S-2
ok "$repoPW" s1 worktree collect S-3
(cd "$repoPW" && bash -c "$(jq -r .apply <<<"$out")") || fail "the second apply command must apply after the first record"
[ ! -e "$work/ext-ran" ] || fail "no external diff or textconv program may run for the second command either"
git -C "$repoPW" config --unset diff.external
git -C "$repoPW" config --unset diff.conv.textconv
git -C "$repoPW" config --unset diff.noprefix
git -C "$repoPW" config --unset color.ui
git -C "$repoPW" config --unset apply.whitespace
rm "$repoPW/.git/info/attributes"
ok "$repoPW" s1 record step S-3 --by worker
[ "$(jq -c '.history[-1].detail | [.step, .worktree]' "$(sfile "$repoPW")")" = '["S-3",true]' ] || fail "the second worker step records its worktree"
ok "$repoPW" s1 worktree remove S-3
# A leftover worktree blocks verify; a folder that is already gone is removed by its own registration only.
ok "$repoPW" s1 worktree add S-4
wt4=$(jq -r .dir <<<"$out")
printf 'd\n' >"$repoPW/src/d.txt"
ok "$repoPW" s1 record step S-4 --by main
refused "$repoPW" s1 advance verify
grep -Fq 'worktrees of this run remain: S-4' "$work/err" || fail "verify is refused while a worktree remains: $(cat "$work/err")"
rm -rf "$wt4"
ok "$repoPW" s1 worktree remove S-4
[ ! -e "$wt_parent" ] || fail "the owner-only folder goes with its last worktree"
# A filter the tree's own .gitattributes selects is refused once configured; with none configured the checkout is allowed.
repoPF="$work/repoPF"
make_repo "$repoPF"
printf '* filter=probe\n' >"$repoPF/.gitattributes"
git -C "$repoPF" add .gitattributes
git -C "$repoPF" commit -qm attrs
ok "$repoPF" s1 init filtered
spec_json 1 'src/**' | br "$repoPF" s1 write spec >/dev/null || fail "write spec (repoPF)"
parallel_plan | br "$repoPF" s1 write plan >/dev/null || fail "write plan (repoPF)"
ok "$repoPF" s1 approve --commit yes --branch-target current --codex reviewer
ok "$repoPF" s1 advance implement
mkdir -p "$repoPF/src"
printf 'a\n' >"$repoPF/src/a.txt"
ok "$repoPF" s1 record step S-1
git -C "$repoPF" config filter.probe.smudge "touch $work/filter-ran-tree; cat"
refused "$repoPF" s1 worktree add S-2
grep -Fq 'smudge, or process filter' "$work/err" || fail "a filter selected by the tree's .gitattributes is refused: $(cat "$work/err")"
[ ! -e "$work/filter-ran-tree" ] || fail "the filter must not run"
git -C "$repoPF" config --unset filter.probe.smudge
ok "$repoPF" s1 worktree add S-2
ok "$repoPF" s1 worktree remove S-2
# A registration git wrote relative to its own folder is still found once the worktree folder is gone.
git -C "$repoPF" config worktree.useRelativePaths true
ok "$repoPF" s1 worktree add S-2
wt_rel=$(jq -r .dir <<<"$out")
case "$(cat "$repoPF"/.git/worktrees/*/gitdir)" in /*) fail "the registration must be relative for this case to mean anything" ;; esac
rm -rf "$wt_rel"
ok "$repoPF" s1 worktree remove S-2
[ "$(git -C "$repoPF" worktree list | wc -l)" -eq 1 ] || fail "a relative registration is removed with its missing folder"
git -C "$repoPF" config --unset worktree.useRelativePaths
[ "$(git -C "$repoPW" worktree list | wc -l)" -eq 1 ] || fail "only the main tree stays registered"
ok "$repoPW" s1 advance verify
unset TMPDIR

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

echo "state probe passed"
