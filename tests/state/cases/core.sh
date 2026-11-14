# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034 # Variables are shared with state-probe.sh and the other files it sources.
# init, approve, lock, step guards, resume, spec change, bounded rounds, unsafe folders.
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

