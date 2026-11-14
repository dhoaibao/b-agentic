# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034 # Variables are shared with state-probe.sh and the other files it sources.
# State coupled to artifacts, scope re-checks, old runs, consent in the spec and review triggers.
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

