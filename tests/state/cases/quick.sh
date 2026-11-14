# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034 # Variables are shared with state-probe.sh and the other files it sources.
# Quick runs, runs without commit consent, changes present at start and the scope check.
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

