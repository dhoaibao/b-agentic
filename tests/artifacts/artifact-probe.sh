#!/usr/bin/env bash
# Exercise claude/bin/b_run.py (the b-flow run artifact CLI, ADR-010) against throwaway
# git repositories. Needs only python3, node, git, and jq: no network or credentials.
# Exit contract: 0 ok, 3 refused or not ok, 2 invalid input or state.
# shellcheck disable=SC2016 # Single-quoted jq programs with literal $ are the inputs under test.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cli="$root/claude/bin/b_run.py"
state_cli="$root/claude/bin/b-state.mjs"
schema="$root/references/artifacts.yaml"
work=$(mktemp -d)
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_CEILING_DIRECTORIES="$work"

fail() { echo "artifact probe failed: $*" >&2; exit 1; }

# br REPO ARGS...: run b_run.py in REPO as owner s1 (stdin passes through); sets $rc, $out.
br() {
  local repo=$1
  shift
  rc=0
  out=$(cd "$repo" && python3 -I -B "$cli" "$@" --owner s1 2>"$work/err") || rc=$?
}
ok() { br "$@"; [ "$rc" -eq 0 ] || fail "expected success ($*): rc=$rc $(cat "$work/err")"; }
refused() { br "$@"; [ "$rc" -eq 3 ] || fail "expected refusal ($*): rc=$rc $(cat "$work/err")"; }
invalid() { br "$@"; [ "$rc" -eq 2 ] || fail "expected invalid input ($*): rc=$rc $(cat "$work/err")"; }
example() { jq -c ".kinds.$1.example" "$schema"; }

make_repo() {
  mkdir -p "$1"
  git -C "$1" init -q .
  git -C "$1" config user.email probe@example.invalid
  git -C "$1" config user.name probe
  printf 'a\n' >"$1/a.txt"
  git -C "$1" add .
  git -C "$1" commit -qm init
}
newrun() { # REPO: create a run through b-state (clarify phase, locked by s1)
  (cd "$1" && node "$state_cli" init demo --owner s1 >/dev/null)
}
rundir() { printf '%s' "$1"/.b-agentic/runs/*; }
setphase() { # REPO PHASE: test-only state edit, as the probe may bypass the CLI
  local file tmp
  file=$(rundir "$1")/state.json
  tmp=$(mktemp -p "$work")
  jq --arg p "$2" '.phase = $p' "$file" >"$tmp" && cp "$tmp" "$file"
}

# --- schema and examples ------------------------------------------------------------
repo="$work/repo"
make_repo "$repo"
ok "$repo" selftest
ok "$repo" schema
[ "$(jq -c '.kinds' <<<"$out")" = '["followups","plan","qa","spec"]' ] || fail "schema must list the kinds"
ok "$repo" schema spec
jq -e '.fields.criteria and .example and .enums.evidence' <<<"$out" >/dev/null || fail "schema spec must show fields, example, and enums"
invalid "$repo" schema nope
invalid "$repo" frobnicate
[ ! -e "$root/claude/bin/__pycache__" ] || fail "-B must keep bytecode out of the install folder"

# --- lint rejects every schema and rule violation without writing --------------------
lint_bad() { # KIND JQ-EDIT DESCRIPTION
  br "$repo" lint "$1" < <(example "$1" | jq -c "$2")
  [ "$rc" -eq 2 ] || fail "lint must reject: $3 (rc=$rc out=$out)"
}
br "$repo" lint spec < <(example spec)
[ "$rc" -eq 0 ] || fail "the spec example must lint: $(cat "$work/err")"
lint_bad spec 'del(.criteria[0].command)' "automated criterion without a command"
lint_bad spec '.criteria[0].source = "x"' "automated criterion with a source"
lint_bad spec '.criteria[1].command = "make"' "inspection criterion with a command"
lint_bad spec 'del(.criteria[1].source)' "inspection criterion without a source"
lint_bad spec '.criteria[1].id = "AC-3"' "non-contiguous ids"
lint_bad spec '.criteria[0].evidence = "magic"' "unknown evidence type"
lint_bad spec '.criteria[0].command = "run `x`"' "backtick in a command"
lint_bad spec '.criteria[0].extra = 1' "unknown field"
lint_bad spec '.scope_paths = ["config/secrets.yaml"]' "protected scope path"
lint_bad spec '.scope_paths = ["/etc/passwd"]' "absolute scope path"
lint_bad spec '.scope_paths = ["../x"]' "scope path with .."
lint_bad spec '.behavior.examples = [.behavior.examples[0]]' "fewer than two examples"
lint_bad spec '.behavior.new = []' "no new behavior"
lint_bad spec '.criteria[0].when = "two\nlines"' "multi-line when"
lint_bad spec '.criteria[0].then = (" " * 400)' "blank then"
lint_bad spec '.request = ""' "empty request"
lint_bad spec 'del(.criteria)' "missing criteria"
lint_bad spec 'del(.consent)' "missing consent"
lint_bad spec '.consent.commit = "maybe"' "consent commit outside yes or no"
lint_bad spec '.consent.branch_target = "bad target"' "consent branch target outside the pattern"
lint_bad spec '.consent.codex = "always"' "consent codex outside the vocabulary"
lint_bad spec '.consent.push = "yes"' "a push consent field"
lint_bad spec '.criteria = []' "no criteria"
lint_bad spec '.behavior.new = ["<!-- hides the criteria"]' "an HTML comment opener"
lint_bad spec '.request = "first line\n<div>second"' "an HTML tag in the request"
lint_bad spec '.criteria[1].source = "see </details>"' "a closing tag"
br "$repo" lint spec < <(example spec | jq -c '.criteria[0].command = "pytest tests/test_export.py < in.txt" | .behavior.new = ["a < b is fine"]')
[ "$rc" -eq 0 ] || fail "a bare < is allowed: $(cat "$work/err")"
lint_bad spec '.size = "huge"' "a size outside the vocabulary"
lint_bad plan '.steps[0].id = "S-2"' "plan ids out of order"
lint_bad plan '.checks = []' "no checks"
lint_bad plan '.checks = ["a", "a"]' "duplicate checks"
lint_bad plan '.steps[1].depends_on = ["S-2"]' "a step that depends on itself"
lint_bad plan '.steps[0].depends_on = ["S-2"]' "a step that depends on a later step"
lint_bad plan '.steps[1].depends_on = ["S-9"]' "a step that depends on an unknown step"
lint_bad plan '.steps[1].depends_on = ["S-1", "S-1"]' "a dependency named twice"
lint_bad qa '.verdict = "QA PASS" | .rows[0].result = "fail"' "QA PASS with a failing row"
lint_bad qa '.verdict = "QA FAIL"' "QA FAIL with only passing rows"
lint_bad qa '.rows[0].result = "waived"' "waived row without waived_by"
lint_bad qa '.rows[0].waived_by = "user"' "waived_by on a non-waived row"
lint_bad qa '.rows[0].result = "met"' "result outside the vocabulary"
lint_bad followups '.items[0].reason = null | del(.items[0].reason)' "closed follow-up without a reason"
lint_bad followups '.items += [.items[0]]' "duplicate follow-up id"
lint_bad followups '.items[0].id = "X-1"' "bad follow-up id"
lint_bad followups '.items[0].disposition = "ignored"' "bad disposition"
lint_bad followups 'del(.items[0].sweep)' "fixed blocker without a sweep"
lint_bad followups '.items[0].source = "implement"' "blocker from implement"
lint_bad followups '.items[1].sweep = "x"' "sweep on a non-blocker"
br "$repo" lint spec < <(printf 'not json')
[ "$rc" -eq 2 ] || fail "non-JSON input must be invalid"
[ -z "$(ls -A "$repo/.b-agentic" 2>/dev/null)" ] || fail "lint must not create run files"

# --- write: single writer, phases, locks, cross-artifact rules ---------------------------
newrun "$repo"
invalid "$repo" write nope < <(printf '{}')                   # an unknown kind is invalid input, not a refusal
run_dir=$(rundir "$repo")
br "$repo" write plan < <(example plan)
[ "$rc" -eq 3 ] || fail "a plan needs the spec first (rc=$rc)"
br "$repo" write spec < <(example spec)
[ "$rc" -eq 0 ] || fail "write spec: $(cat "$work/err")"
[ "$(jq -r .file <<<"$out")" = spec.md ] || fail "write spec result"
head -1 "$run_dir/spec.md" | grep -Fq '<!-- b-run:spec v1 -->' || fail "rendered spec marker"
grep -Fq -- '- AC-1: WHEN export runs with --json THEN stdout is valid JSON' "$run_dir/spec.md" || fail "rendered criterion"
for line in '## Consent' '- Commit: no' '- Push or PR: never'; do
  grep -Fq -- "$line" "$run_dir/spec.md" || fail "rendered consent: $line"
done
[ "$(jq -r '.artifacts.spec.sha256' "$run_dir/artifacts.json")" = "$(sha256sum "$run_dir/spec.md" | cut -d' ' -f1)" ] || fail "recorded sha256"
[ "$(jq -r '.artifacts.spec.rev' "$run_dir/artifacts.json")" = 1 ] || fail "first revision"
br "$repo" write spec >/dev/null < <(example spec)
[ "$(jq -r '.artifacts.spec.rev' "$run_dir/artifacts.json")" = 2 ] || fail "a rewrite bumps the revision"
br "$repo" write plan < <(example plan | jq -c '.steps[0].paths = ["docs/readme.md"]')
[ "$rc" -eq 2 ] || fail "a plan step outside the spec scope must be invalid (rc=$rc)"
br "$repo" write plan < <(example plan | jq -c '.checks = ["other command"]')
[ "$rc" -eq 2 ] || fail "checks must include the spec command (rc=$rc)"
ok "$repo" write plan < <(example plan)
br "$repo" write qa < <(example qa)
[ "$rc" -eq 3 ] || fail "qa is refused outside phase qa (rc=$rc)"
grep -Fq 'phase clarify' "$work/err" || fail "the phase must be named: $(cat "$work/err")"
br "$repo" write followups < <(example followups)
[ "$rc" -eq 3 ] || fail "followups are refused in clarify (rc=$rc)"
ok "$repo" validate
[ "$(jq -c '.artifacts.plan.checks' <<<"$out")" = '["pytest tests/test_export.py"]' ] || fail "validate summary"
ok "$repo" validate --json
jq -e '.hashes.spec and .revs.spec == 2' <<<"$out" >/dev/null || fail "validate --json hashes and revisions"

# The run lock decides who may write.
example spec | (cd "$repo" && python3 -I -B "$cli" write spec --owner other 2>"$work/err") || rc=$?
[ "${rc:-0}" -ne 0 ] || fail "a session without the lock must not write"
grep -Fq 'locked by another session' "$work/err" || fail "the lock owner must be named: $(cat "$work/err")"

# Phase rules for qa and followups.
setphase "$repo" qa
ok "$repo" write qa < <(example qa)
cp "$run_dir/qa.md" "$work/qa.md.keep"
setphase "$repo" verify
ok "$repo" write followups < <(example followups)
ok "$repo" validate
[ "$(jq -c '.artifacts.followups.items' <<<"$out")" \
  = '[{"id":"R1-1","kind":"blocker","disposition":"fixed"},{"id":"R1-2","kind":"followup","disposition":"deferred"},{"id":"F-1","kind":"followup","disposition":"open"}]' ] \
  || fail "the validate summary must give each follow-up's kind and disposition: $out"
br "$repo" write followups < <(example followups | jq -c '.items = [.items[1]]')
[ "$rc" -eq 2 ] || fail "dropping a recorded follow-up id must be invalid (rc=$rc)"
br "$repo" write followups < <(example followups | jq -c 'del(.items[0].kind) | del(.items[0].sweep)')
[ "$rc" -eq 2 ] || fail "a recorded blocker cannot be rewritten as a follow-up (rc=$rc)"
br "$repo" write followups < <(example followups | jq -c '.items[2].kind = "blocker" | .items[2].source = "review" | .items[2].disposition = "open" | del(.items[2].reason)')
[ "$rc" -eq 2 ] || fail "a recorded item cannot become a blocker or change source (rc=$rc)"
br "$repo" write followups < <(example followups | jq -c '.items[1].disposition = "fixed" | .items[1].reason = "done"')
[ "$rc" -eq 0 ] || fail "closing a follow-up with a reason is allowed: $(cat "$work/err")"
setphase "$repo" qa
br "$repo" write qa < <(example qa | jq -c '.rows = [.rows[0]]')
[ "$rc" -eq 2 ] || fail "qa rows must cover every criterion (rc=$rc)"
br "$repo" write qa < <(example qa | jq -c '.rows[1].source = "something else"')
[ "$rc" -eq 2 ] || fail "a qa row must repeat the spec source (rc=$rc)"
br "$repo" write qa < <(example qa | jq -c '.rows[0].command = "unplanned command"')
[ "$rc" -eq 2 ] || fail "a qa row command must be the spec command or a plan check (rc=$rc)"
br "$repo" write qa < <(example qa | jq -c '.rows[0].evidence = "inspection" | .rows[0].source = "x" | del(.rows[0].command)')
[ "$rc" -eq 2 ] || fail "a qa row must repeat the spec evidence (rc=$rc)"
setphase "$repo" clarify

# --- validate detects every bypass ---------------------------------------------------------
ok "$repo" validate
printf '\nhand edit\n' >>"$run_dir/plan.md"
refused "$repo" validate
jq -e '.problems[0] | contains("plan.md differs")' <<<"$out" >/dev/null || fail "a hand edit must be named: $out"
ok "$repo" write plan < <(example plan)                      # a rewrite repairs it
ok "$repo" validate
printf 'x\n' >"$run_dir/notes.md"
refused "$repo" validate
jq -e '.problems[0] | contains("unknown file")' <<<"$out" >/dev/null || fail "an unknown file must be named: $out"
rm "$run_dir/notes.md"
cp "$run_dir/qa.md" "$work/qa.keep" 2>/dev/null || true
rm "$run_dir/spec.md"
refused "$repo" validate
printf 'forged\n' >"$run_dir/spec.md"
refused "$repo" validate
ok "$repo" write spec < <(example spec)
ok "$repo" validate
ln -s /etc/hostname "$run_dir/lock.link" 2>/dev/null || true
refused "$repo" validate
rm -f "$run_dir/lock.link"
# A symlinked artifact is never followed.
rm "$run_dir/plan.md"
ln -s "$run_dir/spec.md" "$run_dir/plan.md"
refused "$repo" validate
rm "$run_dir/plan.md"
ok "$repo" write plan < <(example plan)
ok "$repo" validate

# A rewrite keeps dependents that still pass and drops the ones it invalidates.
[ -f "$run_dir/qa.md" ] || fail "the earlier qa.md must still exist here"
br "$repo" write spec < <(example spec | jq -c '.out_of_scope = ["more"]')
[ "$rc" -eq 0 ] && [ "$(jq -c .dropped <<<"$out")" = '[]' ] || fail "a compatible spec rewrite keeps the plan and qa: $out"
br "$repo" write spec < <(example spec | jq -c '.criteria[1].source = "a different source"')
[ "$rc" -eq 0 ] && [ "$(jq -c .dropped <<<"$out")" = '["qa"]' ] || fail "an incompatible spec rewrite drops only qa: $out"
[ ! -e "$run_dir/qa.md" ] || fail "a dropped qa.md must be removed"
ok "$repo" validate
br "$repo" write spec < <(example spec | jq -c '.criteria[0].command = "pytest -q"')
[ "$rc" -eq 0 ] && [ "$(jq -c .dropped <<<"$out")" = '["plan"]' ] || fail "a changed command drops the plan: $out"
ok "$repo" write spec < <(example spec)
ok "$repo" write plan < <(example plan)
ok "$repo" validate

# --- one command at a time per run ----------------------------------------------------------
printf '{"pid":%s,"token":"live"}\n' "$$" >"$run_dir/mutex"
br "$repo" write spec < <(example spec)
[ "$rc" -eq 3 ] || fail "a live mutex holder must refuse the write (rc=$rc)"
printf '{"pid":2147483646,"token":"dead"}\n' >"$run_dir/mutex"
br "$repo" write spec < <(example spec)
[ "$rc" -eq 3 ] || fail "a dead mutex holder must still refuse (rc=$rc)"
grep -Fq 'delete' "$work/err" || fail "a dead holder must say how to clear it: $(cat "$work/err")"
rm -f "$run_dir/mutex"
ok "$repo" write spec < <(example spec)
[ ! -e "$run_dir/mutex" ] || fail "the mutex must be released"

# --- scope-check -----------------------------------------------------------------------------
ok "$repo" scope-check
printf 'x\n' >"$repo/src_export.txt"
refused "$repo" scope-check
jq -e '.outside_scope == ["src_export.txt"]' <<<"$out" >/dev/null || fail "scope-check must list the path: $out"
rm "$repo/src_export.txt"
mkdir -p "$repo/src" "$repo/tests/unit"
printf 'x\n' >"$repo/src/export.py"
printf 'x\n' >"$repo/tests/unit/test_export.py"
ok "$repo" scope-check
printf 'x\n' >"$repo/src/db.env"
refused "$repo" scope-check
jq -e '.protected == ["src/db.env"] and (.outside_scope | length) == 1' <<<"$out" >/dev/null || fail "a protected path must be reported: $out"
rm "$repo/src/db.env"
# Ignored artifacts that the candidate names are checked like changed paths.
state_file=$(rundir "$repo")/state.json
tmp=$(mktemp -p "$work")
jq '.candidate.include_ignored = ["dist/release.js"]' "$state_file" >"$tmp" && cp "$tmp" "$state_file"
refused "$repo" scope-check
jq -e '.outside_scope | index("dist/release.js") != null' <<<"$out" >/dev/null || fail "an included ignored path outside scope must be reported: $out"
jq '.candidate.include_ignored = ["tests"]' "$state_file" >"$tmp" && cp "$tmp" "$state_file"
ok "$repo" scope-check                                  # a directory inside the scope is fine
# A narrower glob does not cover the nested files of an included directory.
ok "$repo" write spec < <(example spec | jq -c '.scope_paths = ["src/export.py", "tests/*"]')
jq '.candidate.include_ignored = ["tests"]' "$state_file" >"$tmp" && cp "$tmp" "$state_file"
refused "$repo" scope-check
jq -e '.outside_scope | index("tests/unit/test_export.py") != null' <<<"$out" >/dev/null || fail "nested files of an included directory must be checked: $out"
# A symlinked directory inside an included directory is a shipped path too: checked, never followed.
ok "$repo" write spec < <(example spec | jq -c '.scope_paths = ["src/export.py", "tests/unit/test_export.py"]')
mkdir -p "$work/elsewhere"
ln -s "$work/elsewhere" "$repo/tests/unit/linked"
jq '.candidate.include_ignored = ["tests"]' "$state_file" >"$tmp" && cp "$tmp" "$state_file"
refused "$repo" scope-check
jq -e '.outside_scope | index("tests/unit/linked") != null' <<<"$out" >/dev/null || fail "a directory symlink inside an included directory must be checked: $out"
rm "$repo/tests/unit/linked"
ok "$repo" scope-check
ok "$repo" write spec < <(example spec)
ok "$repo" write plan < <(example plan)                  # the narrow scope had dropped the plan
jq '.candidate.include_ignored = []' "$state_file" >"$tmp" && cp "$tmp" "$state_file"
git -C "$repo" mv a.txt renamed.txt
refused "$repo" scope-check
jq -e '.outside_scope | index("renamed.txt") != null and index("a.txt") != null' <<<"$out" >/dev/null || fail "renames report both paths: $out"
git -C "$repo" mv renamed.txt a.txt
rm -rf "$repo/src" "$repo/tests"

# --- handoff packets ---------------------------------------------------------------------------
setphase "$repo" review
ok "$repo" handoff review
grep -Fq 'REVIEW handoff for run' <<<"$out" || fail "review packet header"
grep -Fq -- '- AC-1: WHEN export runs with --json THEN stdout is valid JSON (automated; command `pytest tests/test_export.py`)' <<<"$out" || fail "packet criteria: $out"
grep -Fq 'Round: 1' <<<"$out" || fail "review round"
grep -Fq 'Review trigger: none recorded' <<<"$out" || fail "no trigger before one is recorded"
grep -Fq 'Prior review' <<<"$out" && fail "round 1 has no prior review section"
jq '.review.trigger = "approval policy"' "$state_file" >"$tmp" && cp "$tmp" "$state_file"
ok "$repo" handoff review
grep -Fq 'Review trigger: approval policy' <<<"$out" || fail "the recorded trigger must be printed: $out"
# A re-review carries the earlier blockers with their dispositions and sweep scope.
jq '.review.round = 1 | .attempts.review_needs_fixes = 1' "$state_file" >"$tmp" && cp "$tmp" "$state_file"
ok "$repo" write followups < <(example followups)
ok "$repo" handoff review
grep -Fq 'Round: 2' <<<"$out" || fail "re-review round: $out"
grep -Fq 'Consecutive NEEDS FIXES: 1' <<<"$out" || fail "re-review consecutive count: $out"
grep -Fq -- '- R1-1 fixed: Unchecked path escapes the scope' <<<"$out" || fail "the prior blocker must be listed: $out"
grep -Fq 'Sweep: src/export.py; swept all path joins' <<<"$out" || fail "the sweep scope must be listed: $out"
grep -Fq -- '- F-1' <<<"$(sed -n '/Prior review/,/Earlier follow-ups/p' <<<"$out")" && fail "only blockers belong in the prior review section"
jq '.review.round = 0 | .review.trigger = "" | .attempts.review_needs_fixes = 0' "$state_file" >"$tmp" && cp "$tmp" "$state_file"
ok "$repo" handoff qa
grep -Fq 'QA handoff' <<<"$out" || fail "qa packet header"
invalid "$repo" handoff nope
refused "$repo" handoff review --out "$repo/focus.md"
[ ! -e "$repo/focus.md" ] || fail "a packet must not be written inside the repository"
ok "$repo" handoff review --out "$work/focus.md"
grep -Fq 'Acceptance criteria' "$work/focus.md" || fail "packet --out file"
grep -Fq 'clarify, implement, verify, review, fix, qa, commit' "$work/err" && fail "a valid phase must not print the phase list"
invalid "$repo" handoff nope
grep -Fq 'clarify, implement, verify, review, fix, qa, commit' "$work/err" || fail "an unknown phase must name the phases: $(cat "$work/err")"
# The review and QA packets keep their sections; every other phase has a packet too.
ok "$repo" handoff qa
[ "$(grep '^## ' <<<"$out" | tr '\n' '|')" = '## Acceptance criteria|## Scope|## Recorded checks|## Changed paths|## Included ignored artifacts|## Earlier follow-ups|' ] \
  || fail "the QA packet sections must not change: $out"
ok "$repo" handoff implement
grep -Fq 'IMPLEMENT handoff for run' <<<"$out" || fail "implement packet header"
grep -Fq -- '- S-1 [open]: Add the --json flag' <<<"$out" || fail "an unrecorded step must be open: $out"
grep -Fq '  - Depends on: S-1' <<<"$out" || fail "the packet must name what a step waits for: $out"
grep -Fq '  - Depends on: none' <<<"$out" || fail "the first step waits for none: $out"
grep -Fq -- '- A path outside the spec scope is needed' <<<"$out" || fail "the packet must carry the stop conditions: $out"
jq '.steps = {"S-1": {status: "done", fingerprint: ("a" * 64)}}' "$state_file" >"$tmp" && cp "$tmp" "$state_file"
ok "$repo" handoff implement
grep -Fq -- '- S-1 [recorded]: Add the --json flag' <<<"$out" || fail "a recorded step must be marked: $out"
grep -Fq -- '- S-2 [open]: Cover it with a test' <<<"$out" || fail "the next step must stay open: $out"
ok "$repo" handoff verify
grep -Fq -- '- `pytest tests/test_export.py`: not recorded' <<<"$out" || fail "a plan check without a result must be named: $out"
jq '.candidate.checks = [{cmd: "pytest tests/test_export.py", exit: 1}] | .attempts.verify = 1' "$state_file" >"$tmp" && cp "$tmp" "$state_file"
ok "$repo" handoff verify
grep -Fq -- '- `pytest tests/test_export.py`: exit 1' <<<"$out" || fail "the latest result of a plan check must be printed: $out"
grep -Fq 'Failed verify attempts: 1' <<<"$out" || fail "the verify attempts must be printed: $out"
jq '.candidate.checks = [] | .attempts.verify = 0 | .steps = {}' "$state_file" >"$tmp" && cp "$tmp" "$state_file"
setphase "$repo" fix
ok "$repo" write followups < <(example followups | jq -c '.items += [{id: "R2-1", source: "review", summary: "Flag is undocumented", disposition: "open", kind: "blocker"}]')
ok "$repo" handoff fix
grep -Fq -- '- R2-1: Flag is undocumented' <<<"$(sed -n '/## Open blockers/,/## QA results/p' <<<"$out")" || fail "the open blocker must be listed: $out"
grep -Fq -- '- R1-1' <<<"$(sed -n '/## Open blockers/,/## QA results/p' <<<"$out")" && fail "a fixed blocker is not open: $out"
grep -Fq -- '- R1-1 fixed: src/export.py; swept all path joins' <<<"$out" || fail "the earlier sweep must be listed: $out"
ok "$repo" handoff commit
grep -Fq -- '- Commit: no' <<<"$out" || fail "the commit packet must carry the spec's consent: $out"
grep -Fq -- '- Base: not recorded' <<<"$out" || fail "a commit packet before the commit gate has no approved candidate: $out"
grep -Fq -- '- F-1 open: Document the flag in the README' <<<"$out" || fail "open follow-ups must be listed: $out"
refused "$repo" handoff implement --out "$repo/packet.md"
[ ! -e "$repo/packet.md" ] || fail "no packet may be written inside the repository"
setphase "$repo" clarify

# --- depends_on is optional: a plan without it keeps its bytes, and clarify needs no artifacts ---
dep_repo="$work/dep"
make_repo "$dep_repo"
newrun "$dep_repo"
ok "$dep_repo" handoff clarify
grep -Fq -- '- spec.md: not written' <<<"$out" || fail "the clarify packet must work before the spec exists: $out"
refused "$dep_repo" handoff implement
ok "$dep_repo" write spec < <(example spec)
ok "$dep_repo" write plan < <(example plan | jq -c 'del(.steps[].depends_on)')
expected='<!-- b-run:plan v1 -->
# Plan

## Steps
- S-1: Add the --json flag
  - Paths: `src/export.py`
  - Done when: export --json prints valid JSON
- S-2: Cover it with a test
  - Paths: `tests/test_export.py`
  - Done when: the test passes

## Checks
- `pytest tests/test_export.py`

## Invariants
- The table output is unchanged

## Stop conditions
- A path outside the spec scope is needed'
[ "$(cat "$(rundir "$dep_repo")/plan.md")" = "$expected" ] || fail "a plan without depends_on must render as it always did"
ok "$dep_repo" validate
[ "$(jq -c '.artifacts.plan.steps' <<<"$out")" = '[{"id":"S-1","depends_on":[]},{"id":"S-2","depends_on":["S-1"]}]' ] \
  || fail "a step without depends_on waits for the step before it: $out"
ok "$dep_repo" write plan < <(example plan | jq -c '.steps[1].depends_on = []')
grep -Fq '  - Depends on: none' "$(rundir "$dep_repo")/plan.md" || fail "an empty depends_on must be rendered"
ok "$dep_repo" validate
[ "$(jq -c '.artifacts.plan.steps[1].depends_on' <<<"$out")" = '[]' ] || fail "an empty depends_on means the step waits for none: $out"
ok "$dep_repo" handoff clarify
grep -Fq -- '- plan.md: written' <<<"$out" || fail "the clarify packet must report the written plan: $out"
# The run size is optional too: a spec without it is a full run and keeps its bytes.
grep -Fq '## Size' "$(rundir "$dep_repo")/spec.md" && fail "a spec without a size must not render one"
[ "$(tail -n 1 "$(rundir "$dep_repo")/spec.md")" = '- Push or PR: never' ] || fail "a spec without a size must end as it always did"
ok "$dep_repo" validate
[ "$(jq -c '[.artifacts.spec.size, .artifacts.spec.answers]' <<<"$out")" = '["full",1]' ] || fail "the summary must give the size and the answer count: $out"
ok "$dep_repo" write spec < <(example spec | jq -c '.size = "quick"')
[ "$(tail -n 2 "$(rundir "$dep_repo")/spec.md" | tr '\n' '|')" = '## Size|quick|' ] || fail "a quick spec must render its size"
ok "$dep_repo" validate
[ "$(jq -r '.artifacts.spec.size' <<<"$out")" = quick ] || fail "the summary must give the recorded size: $out"

# --- the owner: --owner, then CLAUDE_CODE_SESSION_ID, then PI_SESSION_ID -----------------------
owner_repo="$work/owner"
make_repo "$owner_repo"
newrun "$owner_repo"
# bo [VAR=VALUE...]: write the spec without --owner under only the given session variables.
bo() {
  rc=0
  out=$(cd "$owner_repo" && example spec |
    env -u CLAUDE_CODE_SESSION_ID -u PI_SESSION_ID "$@" python3 -I -B "$cli" write spec 2>"$work/err") || rc=$?
}
bo PI_SESSION_ID=s1
[ "$rc" -eq 0 ] || fail "PI_SESSION_ID must name the owner without --owner: rc=$rc $(cat "$work/err")"
bo PI_SESSION_ID=other
[ "$rc" -eq 3 ] || fail "a PI_SESSION_ID without the lock must be refused (rc=$rc)"
grep -Fq 'locked by another session' "$work/err" || fail "the lock owner must be named: $(cat "$work/err")"
bo
[ "$rc" -eq 2 ] || fail "no owner at all must be invalid input (rc=$rc)"
grep -Fq 'CLAUDE_CODE_SESSION_ID or PI_SESSION_ID' "$work/err" || fail "the error must name both session variables: $(cat "$work/err")"
bo CLAUDE_CODE_SESSION_ID=s1 PI_SESSION_ID=other
[ "$rc" -eq 0 ] || fail "CLAUDE_CODE_SESSION_ID must win over PI_SESSION_ID: rc=$rc $(cat "$work/err")"
bo CLAUDE_CODE_SESSION_ID=other PI_SESSION_ID=s1
[ "$rc" -eq 3 ] || fail "PI_SESSION_ID must not override CLAUDE_CODE_SESSION_ID (rc=$rc)"
rc=0
out=$(cd "$owner_repo" && example spec |
  env CLAUDE_CODE_SESSION_ID=other PI_SESSION_ID=other python3 -I -B "$cli" write spec --owner s1 2>"$work/err") || rc=$?
[ "$rc" -eq 0 ] || fail "--owner must override both session variables: rc=$rc $(cat "$work/err")"

# --- no run, no repository --------------------------------------------------------------------
repo2="$work/repo2"
make_repo "$repo2"
refused "$repo2" validate
mkdir -p "$work/plain"
refused "$work/plain" validate

echo "artifact probe passed"
