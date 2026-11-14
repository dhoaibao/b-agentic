# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034 # Variables are shared with state-probe.sh and the other files it sources.
# A complete run to done, acceptance results, consent, retry and history.
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

