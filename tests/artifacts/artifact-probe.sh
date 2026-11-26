#!/usr/bin/env bash
# Exercise claude/bin/b_run.py (the b-flow run artifact CLI, ADR-010) against throwaway
# git repositories. Needs only python3, bun, git, and jq: no network or credentials.
# Exit contract: 0 ok, 3 refused or not ok, 2 invalid input or state.
# shellcheck disable=SC2016 # Single-quoted jq programs with literal $ are the inputs under test.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cli="$root/claude/bin/b_run.py"
state_cli="$root/claude/bin/b-state.mjs"
# The runtime that runs the CLI under test: bun with the hardening flags the installer writes (ADR-018), or
# node (ARTIFACT_PROBE_RUNTIME=node), which the CLIs stay runnable under but no runtime installs them with.
js=(bun --no-env-file --config=/dev/null)
if [ "${ARTIFACT_PROBE_RUNTIME:-}" = node ]; then js=(node); fi
schema="$root/references/artifacts.yaml"
# Resolve links so paths match what the CLI reports (macOS /var is /private/var).
work=$(cd "$(mktemp -d)" && pwd -P)
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT
# A finished run may append to the run-stats store under the install home (ADR-035): HOME is a throwaway folder.
export HOME="$work/home"
mkdir -p "$HOME"
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
  (cd "$1" && "${js[@]}" "$state_cli" init demo --owner s1 >/dev/null)
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

# --- help, usage errors, and the cwd refusal tell the caller what to do (ADR-029) ----------------
nogit="$work/nogit"
mkdir -p "$nogit"
for help_args in --help -h help "write spec --help"; do
  # shellcheck disable=SC2086 # help_args is a deliberate word list.
  ok "$nogit" $help_args
  grep -Fq 'b-agentic/bin/b-run' <<<"$out" || fail "help ($help_args) must name the b-run wrapper"
  grep -Fq 'worker-profile' <<<"$out" || fail "help ($help_args) must list the commands"
done
ok "$repo" --help
# Help beside a malformed option is still help and writes nothing; without help the mistake is a usage error.
for help_args in "write spec --bogus --help" "write spec --bogus -h" "help --bogus"; do
  # shellcheck disable=SC2086 # help_args is a deliberate word list.
  ok "$repo" $help_args </dev/null
  grep -Fq 'worker-profile' <<<"$out" || fail "'$help_args' must print the usage: $out"
done
# The valueless option must come last, so these run without the owner br appends.
rc=0; out=$(cd "$repo" && python3 -I -B "$cli" write spec --help --out 2>"$work/err" </dev/null) || rc=$?
[ "$rc" -eq 0 ] || fail "help beside a valueless option must print the usage: rc=$rc $(cat "$work/err")"
grep -Fq 'worker-profile' <<<"$out" || fail "help beside a valueless option must print the usage: rc=$rc $(cat "$work/err")"
rc=0; out=$(cd "$repo" && python3 -I -B "$cli" write spec --out 2>"$work/err" </dev/null) || rc=$?
[ "$rc" -eq 2 ] || fail "a valueless option without help must still be a usage error: rc=$rc $(cat "$work/err")"
grep -Fq -- '--out needs a value' "$work/err" || fail "a valueless option without help must still be a usage error: rc=$rc $(cat "$work/err")"
invalid "$repo" write spec --bogus </dev/null
grep -Fq 'unknown argument: --bogus' "$work/err" || fail "a malformed option without help must still be a usage error: $(cat "$work/err")"
# A deleted current folder: help answers, and a command that needs the repository is refused, not a system error.
gone="$work/gone"
mkdir -p "$gone"; rc=0; out=$(cd "$gone" && rmdir "$gone" && python3 -I -B "$cli" --help 2>"$work/err") || rc=$?
[ "$rc" -eq 0 ] || fail "help from a deleted folder must print the usage: rc=$rc $(cat "$work/err")"
grep -Fq 'worker-profile' <<<"$out" || fail "help from a deleted folder must print the usage: rc=$rc $(cat "$work/err")"
mkdir -p "$gone"; rc=0; out=$(cd "$gone" && rmdir "$gone" && python3 -I -B "$cli" runs 2>"$work/err") || rc=$?
[ "$rc" -eq 3 ] || fail "runs from a deleted folder must be refused: rc=$rc $(cat "$work/err")"
grep -Fq 'not inside a git worktree (cwd: unavailable)' "$work/err" || fail "runs from a deleted folder must be refused: rc=$rc $(cat "$work/err")"
# A help-shaped value of an option is a value, not a request for help: the command still runs and fails (no run here).
br "$repo" write spec --owner --help </dev/null
if [ "$rc" -eq 0 ] || grep -Fq 'single writer of a b-flow' <<<"$out"; then
  fail "an option value that looks like --help must not print usage: rc=$rc $out"
fi
for usage_case in "frobnicate|unknown command: frobnicate; commands: schema, lint" \
  "|missing command; commands: schema, lint" \
  "lint|lint needs one KIND: followups, plan, qa, spec" \
  "write|write needs one KIND: followups, plan, qa, spec" \
  "handoff|handoff needs one PHASE: clarify, implement" \
  "runs extra|runs takes no argument" \
  "prune extra|prune takes no argument"; do
  # shellcheck disable=SC2086 # The command part is a deliberate word list.
  invalid "$repo" ${usage_case%%|*}
  grep -Fq -- "${usage_case#*|}" "$work/err" || fail "usage error for '${usage_case%%|*}' must say: ${usage_case#*|} (got: $(cat "$work/err"))"
done
refused "$nogit" runs
grep -Fq 'not inside a git worktree (cwd: ' "$work/err" || fail "the cwd refusal must name the folder: $(cat "$work/err")"
grep -Fq 'run it from inside the repository' "$work/err" || fail "the cwd refusal must say how to fix it: $(cat "$work/err")"
ok "$repo" schema
jq -e '.text_rules | length >= 4' <<<"$out" >/dev/null || fail "schema must list the text rules"
ok "$repo" schema spec
jq -e '.text_rules | map(select(test("HTML"))) | length == 1' <<<"$out" >/dev/null || fail "schema spec must list the HTML rule"
jq -e '.fields.criteria and .example and .enums.evidence' <<<"$out" >/dev/null || fail "text_rules must be additive to schema spec"

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
lint_bad spec '.scope_paths = ["config/SECRETS.yaml"]' "protected scope path in another case"
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
lint_bad spec '.consent.codex = "reviewer"' "a retired codex consent on new spec data"
lint_bad spec '.consent.push = "yes"' "a push consent field"
lint_bad spec '.criteria = []' "no criteria"
lint_bad spec '.behavior.new = ["<!-- hides the criteria"]' "an HTML comment opener"
lint_bad spec '.request = "first line\n<div>second"' "an HTML tag in the request"
grep -Fq "found '<d'" "$work/err" || fail "the HTML error must quote the match: $(cat "$work/err")"
grep -Fq 'write a placeholder as FILE or {file}' "$work/err" || fail "the HTML error must name the fix: $(cat "$work/err")"
br "$repo" lint spec < <(example spec | jq -c '.request = "a < b and 2 <3"')
[ "$rc" -eq 0 ] || fail "a bare less-than sign must still lint: $(cat "$work/err")"
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
lint_bad plan '.parallel_checks = ["pytest tests/test_export.py"]' "fewer than two checks that may run together"
lint_bad plan '.checks += ["ruff check ."] | .parallel_checks = ["pytest tests/test_export.py", "make lint"]' "a parallel check that is not a plan check"
lint_bad plan '.checks += ["ruff check ."] | .parallel_checks = ["ruff check .", "ruff check ."]' "a parallel check named twice"
lint_bad plan '.checks += ["ruff check ."] | .parallel_checks = "all"' "parallel checks that are not a list"
br "$repo" lint plan < <(example plan | jq -c '.checks += ["ruff check ."] | .parallel_checks = ["ruff check .", "pytest tests/test_export.py"]')
[ "$rc" -eq 0 ] || fail "two plan checks may be listed to run together: $(cat "$work/err")"
lint_bad plan '.worker_steps = []' "an empty worker_steps list"
lint_bad plan '.worker_steps = "S-2"' "worker steps that are not a list"
lint_bad plan '.worker_steps = ["S-9"]' "a worker step that is not a plan step"
lint_bad plan '.worker_steps = ["S-2", "S-2"]' "a worker step named twice"
lint_bad plan '.worker_steps = ["step 2"]' "a worker step that is not a step id"
br "$repo" lint plan < <(example plan | jq -c '.worker_steps = ["S-2"]')
[ "$rc" -eq 0 ] || fail "a plan step may be listed as a worker step: $(cat "$work/err")"
# parallel_steps: worker steps in their own worktrees at the same time; literal disjoint paths, readiness together.
three='.steps += [{"id": "S-3", "action": "Document it", "paths": ["docs/export.md"], "done_when": "the doc exists", "depends_on": ["S-1"]}] | .worker_steps = ["S-2", "S-3"]'
lint_bad plan "$three | .parallel_steps = []" "an empty parallel_steps list"
lint_bad plan "$three | .parallel_steps = [\"S-2\"]" "fewer than two steps that run together"
lint_bad plan "$three | .parallel_steps = \"S-2\"" "parallel steps that are not a list"
lint_bad plan "$three | .parallel_steps = [\"S-2\", \"S-2\"]" "a parallel step named twice"
lint_bad plan "$three | .parallel_steps = [\"S-2\", \"S-1\"]" "a parallel step that is not a worker step"
lint_bad plan "$three | .parallel_steps = [\"S-2\", \"S-9\"]" "a parallel step that is not a plan step"
lint_bad plan "$three | .steps[1].paths = [\"tests/*.py\"] | .parallel_steps = [\"S-2\", \"S-3\"]" "a glob path in a parallel step"
lint_bad plan "$three | .steps[2].paths = [\"tests\"] | .parallel_steps = [\"S-2\", \"S-3\"]" "a path inside another parallel step's path"
lint_bad plan "$three | .steps[2].paths = [\"tests/test_export.py\"] | .parallel_steps = [\"S-2\", \"S-3\"]" "two parallel steps with the same path"
lint_bad plan "$three | .steps[2].paths = [\"tests/./test_export.py\"] | .parallel_steps = [\"S-2\", \"S-3\"]" "an alias of another parallel step's path"
lint_bad plan "$three | .steps[2].paths = [\"tests//x.py\"] | .parallel_steps = [\"S-2\", \"S-3\"]" "a doubled separator in a parallel step path"
lint_bad plan "$three | .steps[2].paths = [\"tests/\"] | .parallel_steps = [\"S-2\", \"S-3\"]" "a trailing separator in a parallel step path"
lint_bad plan "$three | .steps[2].paths = [\"../x.py\"] | .parallel_steps = [\"S-2\", \"S-3\"]" "a parent component in a parallel step path"
lint_bad plan "$three | .steps[2].paths = [\"/abs/x.py\"] | .parallel_steps = [\"S-2\", \"S-3\"]" "an absolute parallel step path"
lint_bad plan "$three | .steps[2].depends_on = [\"S-2\"] | .parallel_steps = [\"S-2\", \"S-3\"]" "parallel steps where one waits for the other"
lint_bad plan "$three | del(.steps[2].depends_on) | .parallel_steps = [\"S-2\", \"S-3\"]" "a step that waits for the step before it, which is the other one"
br "$repo" lint plan < <(example plan | jq -c "$three | .parallel_steps = [\"S-2\", \"S-3\"]")
[ "$rc" -eq 0 ] || fail "two ready worker steps with disjoint literal paths may run together: $(cat "$work/err")"
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
lint_bad followups '.items[1].blocker_class = "unexpected path"' "a class on a non-blocker"
lint_bad followups '.items[0].blocker_class = "made up"' "a class outside the b-review list"
lint_bad followups '.items[2].escaped_from = "plan"' "escaped_from on an implement item"
lint_bad followups '.items[0].escaped_from = "review"' "a review item that escaped review"
lint_bad followups '.items[0].escaped_from = "later"' "escaped_from outside the stages"
lint_bad followups 'del(.items[0].blocker_class)' "a new blocker without a class"
lint_bad followups 'del(.items[0].escaped_from)' "a new blocker without escaped_from"
lint_bad followups '.items[2].escaped_from = "unknown"' "an unknown stage on an implement item"
br "$repo" lint followups < <(example followups | jq -c '.items[0].escaped_from = "unknown" | .items[1].escaped_from = "unknown"')
[ "$rc" -eq 0 ] || fail "a review blocker or follow-up may name an unknown stage: $(cat "$work/err")"
br "$repo" lint followups < <(example followups | jq -c '.items[0].source = "qa" | .items[0].escaped_from = "unknown"')
[ "$rc" -eq 0 ] || fail "a qa blocker may name an unknown stage: $(cat "$work/err")"
br "$repo" lint followups < <(example followups | jq -c '.items[0].source = "qa" | .items[0].escaped_from = "review"')
[ "$rc" -eq 0 ] || fail "a qa item may have escaped review: $(cat "$work/err")"
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
grep -Fq -- 'Codex' "$run_dir/spec.md" && fail "a new spec must render no Codex consent"
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
br "$repo" write followups < <(example followups | jq -c 'del(.items[0].kind, .items[0].sweep, .items[0].blocker_class, .items[0].escaped_from)')
[ "$rc" -eq 2 ] || fail "a recorded blocker cannot be rewritten as a follow-up (rc=$rc)"
br "$repo" write followups < <(example followups | jq -c '.items[2].kind = "blocker" | .items[2].source = "review" | .items[2].disposition = "open" | del(.items[2].reason)')
[ "$rc" -eq 2 ] || fail "a recorded item cannot become a blocker or change source (rc=$rc)"
br "$repo" write followups < <(example followups | jq -c '.items[1].disposition = "fixed" | .items[1].reason = "done"')
[ "$rc" -eq 0 ] || fail "closing a follow-up with a reason is allowed: $(cat "$work/err")"
# blocker_class and escaped_from: add once, never change or drop.
br "$repo" write followups < <(example followups | jq -c '.items[0].blocker_class = "correctness regression"')
[ "$rc" -eq 2 ] || fail "a recorded blocker_class cannot change (rc=$rc)"
br "$repo" write followups < <(example followups | jq -c 'del(.items[0].blocker_class)')
[ "$rc" -eq 2 ] || fail "a recorded blocker_class cannot be dropped (rc=$rc)"
br "$repo" write followups < <(example followups | jq -c 'del(.items[0].escaped_from)')
[ "$rc" -eq 2 ] || fail "a recorded escaped_from cannot be dropped (rc=$rc)"
br "$repo" write followups < <(example followups | jq -c '.items[0].escaped_from = "plan"')
[ "$rc" -eq 2 ] || fail "a recorded escaped_from cannot change (rc=$rc)"
for line in '  - Class: unexpected path' '  - Escaped from: implement'; do
  grep -Fq -- "$line" "$run_dir/followups.md" || fail "rendered follow-up line: $line"
done
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

# Follow-ups without the new fields render exactly as before: the new lines are purely additive.
for name in fu-plain fu-fields; do
  make_repo "$work/$name"
  newrun "$work/$name"
  ok "$work/$name" write spec < <(example spec)
  ok "$work/$name" write plan < <(example plan)
  setphase "$work/$name" verify
done
# Follow-ups recorded before blockers had to name a class and stage. write refuses that input now, so the
# probe records it the way the older helper did: the same data, its render, and the render's hash.
seed_legacy() { # REPO
  python3 -I -B - "$cli" "$(rundir "$1")" <<'PY'
import importlib.util, json, pathlib, sys

spec = importlib.util.spec_from_file_location("b_run", sys.argv[1])
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)
run = pathlib.Path(sys.argv[2])
recorded = json.loads((run / "artifacts.json").read_text())
entry = recorded["artifacts"]["followups"]
for item in entry["data"]["items"]:
    item.pop("blocker_class", None)
    item.pop("escaped_from", None)
body = cli.render("followups", entry["data"])
(run / "followups.md").write_text(body)
entry["sha256"] = cli.sha(body)
(run / "artifacts.json").write_text(json.dumps(recorded))
PY
}
legacy() { example followups | jq -c 'del(.items[].blocker_class, .items[].escaped_from)'; }
ok "$work/fu-plain" write followups < <(example followups)
seed_legacy "$work/fu-plain"
ok "$work/fu-fields" write followups < <(example followups)
plain_md=$(rundir "$work/fu-plain")/followups.md
fields_md=$(rundir "$work/fu-fields")/followups.md
grep -Eq 'Class:|Escaped from:' "$plain_md" && fail "legacy follow-ups must render no Class or Escaped from line"
[ "$(grep -Fv -e '  - Class: ' -e '  - Escaped from: ' "$fields_md")" = "$(cat "$plain_md")" ] \
  || fail "the new follow-up lines must be the only difference from the legacy render"
ok "$work/fu-plain" validate
# A rewrite keeps a recorded blocker that has neither field, and lint in the run agrees with write.
cp "$plain_md" "$work/plain.md.keep"
ok "$work/fu-plain" lint followups < <(legacy)
ok "$work/fu-plain" write followups < <(legacy)
cmp -s "$plain_md" "$work/plain.md.keep" || fail "a legacy rewrite must render byte for byte as before"
invalid "$work/fu-plain" lint followups < <(legacy | jq -c '.items = [.items[1]]')
# A blocker new to that run needs both fields, whatever its source or disposition.
later='.items += [{id: "Q1-1", source: "qa", summary: "Export is empty", disposition: "deferred", reason: "waits", kind: "blocker"}]'
for cmd in lint write; do
  invalid "$work/fu-plain" "$cmd" followups < <(legacy | jq -c "$later")
  grep -Fq 'blocker_class: required on a new blocker' "$work/err" || fail "$cmd must name the missing class: $(cat "$work/err")"
  invalid "$work/fu-plain" "$cmd" followups < <(legacy | jq -c "$later | .items[-1].blocker_class = \"violated acceptance\"")
  grep -Fq 'escaped_from: required on a new blocker' "$work/err" || fail "$cmd must name the missing stage: $(cat "$work/err")"
done
cmp -s "$plain_md" "$work/plain.md.keep" || fail "a refused write must change nothing"
ok "$work/fu-plain" write followups < <(legacy | jq -c "$later | .items[-1].blocker_class = \"violated acceptance\" | .items[-1].escaped_from = \"unknown\"")
ok "$work/fu-plain" validate
# A later rewrite may add one field to a recorded item that had none, once.
added=$(legacy | jq -c "$later | .items[-1].blocker_class = \"violated acceptance\" | .items[-1].escaped_from = \"unknown\" | .items[1].escaped_from = \"plan\"")
ok "$work/fu-plain" write followups <<<"$added"
grep -Fq -- '  - Escaped from: plan' "$plain_md" || fail "an added escaped_from must render"
invalid "$work/fu-plain" write followups < <(jq -c '.items[1].escaped_from = "spec"' <<<"$added")
ok "$work/fu-plain" write followups < <(jq -c '.items[0].blocker_class = "unexpected path"' <<<"$added")
added=$(jq -c '.items[0].blocker_class = "unexpected path"' <<<"$added")
# A recorded unknown may be named once: not dropped, not made a later stage, and then it stays.
invalid "$work/fu-plain" write followups < <(jq -c 'del(.items[-1].escaped_from)' <<<"$added")
invalid "$work/fu-plain" write followups < <(jq -c '.items[-1].source = "review"' <<<"$added")
invalid "$work/fu-plain" write followups < <(jq -c '.items[-1].escaped_from = "later"' <<<"$added")
named=$(jq -c '.items[-1].escaped_from = "implement"' <<<"$added")
ok "$work/fu-plain" lint followups <<<"$named"
ok "$work/fu-plain" write followups <<<"$named"
invalid "$work/fu-plain" write followups <<<"$added"
invalid "$work/fu-plain" write followups < <(jq -c '.items[-1].escaped_from = "plan"' <<<"$named")
ok "$work/fu-plain" validate

# --- a retained older schema beside the newer helper (an install keeps a user-edited artifacts.yaml) -----------
# old_cli NAME JQ: a copy of the helper beside the schema JQ makes, laid out as an install is.
old_cli() {
  mkdir -p "$work/$1/bin" "$work/$1/references"
  cp "$cli" "$work/$1/bin/b_run.py"
  jq "$2" "$schema" >"$work/$1/references/artifacts.yaml"
}
fields='.kinds.followups.fields.items.items.fields'
# Before unknown: a stage cannot be said to be unknown, so only the class is required.
old_cli no-unknown '.enums.escape_stage -= ["unknown"]'
# Before both fields: neither can be recorded, so neither is required.
old_cli no-fields "del($fields.blocker_class, $fields.escaped_from)"
shipped_cli=$cli
cli="$work/no-unknown/bin/b_run.py"
br "$repo" lint followups --run absent < <(example followups | jq -c 'del(.items[0].blocker_class)')
[ "$rc" -eq 2 ] || fail "an older schema with blocker_class still requires it (rc=$rc)"
br "$repo" lint followups --run absent < <(example followups | jq -c '.items[0].escaped_from = "unknown"')
[ "$rc" -eq 2 ] || fail "an older schema without unknown still refuses it (rc=$rc)"
br "$repo" lint followups --run absent < <(example followups | jq -c 'del(.items[0].escaped_from)')
[ "$rc" -eq 0 ] || fail "an older schema without unknown must not require escaped_from: $(cat "$work/err")"
cli="$work/no-fields/bin/b_run.py"
br "$repo" lint followups --run absent < <(example followups | jq -c 'del(.items[0].blocker_class, .items[0].escaped_from)')
[ "$rc" -eq 0 ] || fail "a schema without the fields must not require them: $(cat "$work/err")"
cli=$shipped_cli

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
printf 'x\n' >"$repo/src/DB.ENV"
refused "$repo" scope-check
jq -e '.protected == ["src/DB.ENV"]' <<<"$out" >/dev/null || fail "a protected path in another case must be reported: $out"
rm "$repo/src/DB.ENV"
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
ok "$repo" scope-check
[ "$(jq -c 'keys' <<<"$out")" = '["changed","ok","outside_scope","preexisting","protected"]' ] || fail "scope-check without tree ids keeps its output: $out"

# --- scope-check for what one step changed: the paths that differ between two tree ids -------
tree_of() { (cd "$1" && rm -f "$work/idx" && GIT_INDEX_FILE="$work/idx" git add -A . && GIT_INDEX_FILE="$work/idx" git write-tree); }
base_tree=$(tree_of "$repo")
mkdir -p "$repo/src" "$repo/tests/unit"
printf 'x\n' >"$repo/src/export.py"
printf 'x\n' >"$repo/tests/unit/test_export.py"
step_tree=$(tree_of "$repo")
ok "$repo" scope-check --base "$base_tree" --tree "$step_tree" --step S-1
[ "$(jq -c '[.ok, .changed, .outside_step, .outside_scope, .protected]' <<<"$out")" = '[true,2,1,[],[]]' ] \
  || fail "a step inside the scope passes, and a path outside its own paths is only counted: $out"
ok "$repo" scope-check --base "$step_tree" --tree "$step_tree" --step S-2
[ "$(jq -c '[.changed, .outside_step]' <<<"$out")" = '[0,0]' ] || fail "equal trees have no delta: $out"
printf 'x\n' >"$repo/README.md"
rm "$repo/a.txt"
wide_tree=$(tree_of "$repo")
refused "$repo" scope-check --base "$step_tree" --tree "$wide_tree" --step S-2
[ "$(jq -c '[.changed, .outside_scope]' <<<"$out")" = '[2,["README.md","a.txt"]]' ] || fail "an added and a deleted path outside the scope are both named: $out"
git -C "$repo" checkout -q -- a.txt
rm "$repo/README.md"
printf 'x\n' >"$repo/src/db.env"
env_tree=$(tree_of "$repo")
refused "$repo" scope-check --base "$step_tree" --tree "$env_tree" --step S-2
[ "$(jq -c '.protected' <<<"$out")" = '["src/db.env"]' ] || fail "a protected path in the delta must be reported: $out"
rm "$repo/src/db.env"
invalid "$repo" scope-check --base "$base_tree" --tree "$step_tree" --step S-9
invalid "$repo" scope-check --base "$base_tree"
invalid "$repo" scope-check --base "$base_tree" --tree "$step_tree"
invalid "$repo" scope-check --tree "$step_tree" --step S-1
invalid "$repo" scope-check --base HEAD --tree "$step_tree" --step S-1
refused "$repo" scope-check --base 0000000000000000000000000000000000000001 --tree "$step_tree" --step S-1
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
grep -Fq 'Review gate: not recorded' <<<"$out" || fail "a review with no gate must read not recorded: $out"
jq '.review.gate = "reviewer" | .review.gate_reason = "codex unavailable: usage limit"' "$state_file" >"$tmp" && cp "$tmp" "$state_file"
ok "$repo" handoff qa
grep -Fq 'Review gate: reviewer (codex unavailable: usage limit)' <<<"$out" || fail "the QA packet must name the gate and its reason: $out"
jq '.review.gate = "codex" | .review.gate_reason = ""' "$state_file" >"$tmp" && cp "$tmp" "$state_file"
ok "$repo" handoff qa
grep -Fq 'Review gate: codex' <<<"$out" || fail "the QA packet must name a codex gate: $out"
jq '.review.gate = "" | .review.gate_reason = ""' "$state_file" >"$tmp" && cp "$tmp" "$state_file"
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
ok "$repo" write followups < <(example followups | jq -c '.items += [{id: "R2-1", source: "review", summary: "Flag is undocumented", disposition: "open", kind: "blocker", blocker_class: "violated acceptance", escaped_from: "implement"}]')
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
grep -Fq -- '- spec.md: not written (`~/.claude/b-agentic/bin/b-run schema spec`)' <<<"$out" || fail "the clarify packet must name the b-run wrapper: $out"
# shellcheck disable=SC2088 # The folder is the literal text ~/... that the CLI prints, never expanded.
override_out=$(cd "$dep_repo" && B_AGENTIC_HELPER_DIR='~/.pi/agent/b-agentic/bin' python3 -I -B "$cli" handoff clarify --owner s1)
grep -Fq -- '- spec.md: not written (`~/.pi/agent/b-agentic/bin/b-run schema spec`)' <<<"$override_out" || fail "the helper folder override must reach the packet: $override_out"
unsafe_out=$(cd "$dep_repo" && B_AGENTIC_HELPER_DIR='x; rm -rf y' python3 -I -B "$cli" handoff clarify --owner s1)
grep -Fq -- '(`~/.claude/b-agentic/bin/b-run schema spec`)' <<<"$unsafe_out" || fail "an unsafe helper folder override must be ignored: $unsafe_out"
# shellcheck disable=SC2088 # Same literal ~/... text as above.
help_line=$(B_AGENTIC_HELPER_DIR='~/.pi/agent/b-agentic/bin' python3 -I -B "$cli" help | grep -F -- 'b-run <command>')
grep -Fq '`~/.pi/agent/b-agentic/bin/b-run <command>`' <<<"$help_line" || fail "the help text must name the override folder: $help_line"
help_line=$(python3 -I -B "$cli" help | grep -F -- 'b-run <command>')
grep -Fq '`~/.claude/b-agentic/bin/b-run <command>`' <<<"$help_line" || fail "the help text must keep the Claude Code folder: $help_line"
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
# parallel_checks is optional as well: only a plan that lists it renders and marks it.
[ "$(jq -c '.artifacts.plan.parallel_checks' <<<"$out")" = '[]' ] || fail "a plan without parallel_checks lists none: $out"
ok "$dep_repo" handoff verify
grep -Fxq -- '- `pytest tests/test_export.py`: not recorded' <<<"$out" || fail "a plan without parallel_checks keeps its packet line: $out"
grep -Fq 'may run together' <<<"$out" && fail "a plan without parallel_checks marks no check: $out"
plain_packet=$out
ok "$dep_repo" write plan < <(example plan | jq -c '.checks += ["ruff check .", "make docs"] | .parallel_checks = ["ruff check .", "pytest tests/test_export.py"]')
[ "$(sed -n '/^## Checks that may run together$/,/^$/p' "$(rundir "$dep_repo")/plan.md" | tr '\n' '|')" = '## Checks that may run together|- `ruff check .`|- `pytest tests/test_export.py`||' ] \
  || fail "a plan with parallel_checks must render them: $(cat "$(rundir "$dep_repo")/plan.md")"
ok "$dep_repo" validate
[ "$(jq -c '.artifacts.plan.parallel_checks' <<<"$out")" = '["ruff check .","pytest tests/test_export.py"]' ] || fail "the summary must list the parallel checks: $out"
ok "$dep_repo" handoff verify
grep -Fxq -- '- `pytest tests/test_export.py`: not recorded (may run together)' <<<"$out" || fail "a listed check must be marked: $out"
grep -Fxq -- '- `ruff check .`: not recorded (may run together)' <<<"$out" || fail "every listed check must be marked: $out"
grep -Fxq -- '- `make docs`: not recorded' <<<"$out" || fail "a check that is not listed keeps its line: $out"
ok "$dep_repo" write plan < <(example plan | jq -c '.steps[1].depends_on = []')
grep -Fq 'run together' "$(rundir "$dep_repo")/plan.md" && fail "a plan rewritten without parallel_checks must not render them"
ok "$dep_repo" handoff verify
[ "$out" = "$plain_packet" ] || fail "the verify packet of a plan without parallel_checks must keep its bytes: $out"

# worker_steps is optional too: only a plan that lists it renders, summarizes, and marks it.
ok "$dep_repo" write plan < <(example plan)
ok "$dep_repo" validate
[ "$(jq -c '.artifacts.plan.worker_steps' <<<"$out")" = '[]' ] || fail "a plan without worker_steps lists none: $out"
grep -Fq 'Worker steps' "$(rundir "$dep_repo")/plan.md" && fail "a plan without worker_steps must not render a section"
ok "$dep_repo" handoff implement
plain_implement=$out
grep -Fq 'worker step' <<<"$plain_implement" && fail "a plan without worker_steps marks no step: $plain_implement"
ok "$dep_repo" write plan < <(example plan | jq -c '.worker_steps = ["S-2"]')
[ "$(sed -n '/^## Worker steps$/,/^$/p' "$(rundir "$dep_repo")/plan.md" | tr '\n' '|')" = '## Worker steps|- S-2||' ] \
  || fail "a plan with worker_steps must render them: $(cat "$(rundir "$dep_repo")/plan.md")"
ok "$dep_repo" validate
[ "$(jq -c '.artifacts.plan.worker_steps' <<<"$out")" = '["S-2"]' ] || fail "the summary must list the worker steps: $out"
ok "$dep_repo" handoff implement
grep -Fxq -- '- S-2 [open]: Cover it with a test (worker step)' <<<"$out" || fail "a worker step must be marked in the full packet: $out"
[ "${out// (worker step)/}" = "$plain_implement" ] || fail "the marker is the only difference in the full packet: $out"
# The packet of one step: what that step needs, and what the main session compares afterwards.
dep_state="$(rundir "$dep_repo")/state.json"
ok "$dep_repo" handoff implement --step S-2
grep -Fxq 'Step: S-2 (worker step)' <<<"$out" || fail "the step packet must say who applies the step: $out"
# On Pi the packets match Claude Code for worker steps and worktrees; help still prints PI_SESSION_ID.
# shellcheck disable=SC2088 # The folder is the literal text ~/... that the CLI prints, never expanded.
pi_override='~/.pi/agent/b-agentic/bin'
B_AGENTIC_HELPER_DIR="$pi_override" ok "$dep_repo" handoff implement --step S-2
grep -Fxq 'Step: S-2 (worker step)' <<<"$out" || fail "the Pi step packet must say worker step: $out"
grep -Fq -- '- Never write under .b-agentic, a likely-secret path, or git history, and run no b-state.mjs or b_run.py command (nor its b-state or b-run wrapper).' <<<"$out" \
  || fail "the Pi worker-step packet must forbid the state/run wrappers: $out"
B_AGENTIC_HELPER_DIR="$pi_override" ok "$dep_repo" handoff implement
grep -Fxq -- '- S-2 [open]: Cover it with a test (worker step)' <<<"$out" || fail "the Pi full packet must mark the worker step: $out"
pi_help=$(B_AGENTIC_HELPER_DIR="$pi_override" python3 -I -B "$cli" help | grep -F -- '--owner NAME')
grep -Fq '(default: PI_SESSION_ID)' <<<"$pi_help" || fail "the Pi help must name PI_SESSION_ID: $pi_help"
claude_help=$(python3 -I -B "$cli" help | grep -F -- '--owner NAME')
grep -Fq '(default: CLAUDE_CODE_SESSION_ID)' <<<"$claude_help" || fail "the Claude Code help keeps CLAUDE_CODE_SESSION_ID: $claude_help"
ok "$dep_repo" handoff implement --step S-2
grep -Fxq 'Step base tree: not recorded' <<<"$out" || fail "a run without a step base says so: $out"
grep -Fxq "State revision: $(jq -r .rev "$dep_state")" <<<"$out" || fail "the packet must carry the state revision: $out"
grep -Fxq 'Follow-ups revision: 0' <<<"$out" || fail "the packet must carry the follow-ups revision: $out"
grep -Fxq -- '- S-2 [open]: Cover it with a test' <<<"$out" || fail "the step packet must carry the step: $out"
grep -Fxq '  - Depends on: S-1 (open)' <<<"$out" || fail "the step packet must give the status of what the step waits for: $out"
[ "$(grep '^## ' <<<"$out" | tr '\n' '|')" = '## Step|## Acceptance criteria|## Scope|## Out of scope|## Invariants|## Stop conditions|## Boundaries|## Changed paths|' ] \
  || fail "the step packet sections: $out"
grep -Fq -- '- Never write under .b-agentic, a likely-secret path, or git history, and run no b-state.mjs or b_run.py command (nor its b-state or b-run wrapper).' <<<"$out" \
  || fail "the step packet must state its boundaries: $out"
ok "$dep_repo" handoff implement --step S-1
grep -Fxq 'Step: S-1 (main session step)' <<<"$out" || fail "an unlisted step is the main session's: $out"
grep -Fxq '  - Depends on: none' <<<"$out" || fail "the first step waits for none: $out"
jq '.steps = {"S-1": {status: "done", fingerprint: ("a" * 64)}} | .step_base = {tree: ("b" * 40), fingerprint: ("c" * 64), head: ("d" * 40), rev: .rev}' "$dep_state" >"$tmp" && cp "$tmp" "$dep_state"
ok "$dep_repo" handoff implement --step S-2
grep -Fxq '  - Depends on: S-1 (recorded)' <<<"$out" || fail "a recorded dependency is marked: $out"
grep -Fxq "Step base tree: $(printf 'b%.0s' $(seq 1 40))" <<<"$out" || fail "the packet must carry the recorded step base: $out"
jq '.steps = {} | .step_base = null' "$dep_state" >"$tmp" && cp "$tmp" "$dep_state"
invalid "$dep_repo" handoff implement --step S-9
grep -Fq 'plan step' "$work/err" || fail "an unknown step must be named invalid: $(cat "$work/err")"
invalid "$dep_repo" handoff verify --step S-1
grep -Fq 'only with handoff implement' "$work/err" || fail "--step belongs to the implement packet: $(cat "$work/err")"
invalid "$dep_repo" handoff implement --step
ok "$dep_repo" write plan < <(example plan)
grep -Fq 'Worker steps' "$(rundir "$dep_repo")/plan.md" && fail "a plan rewritten without worker_steps must not render them"
ok "$dep_repo" handoff implement
[ "$out" = "$plain_implement" ] || fail "the full implement packet of a plan without worker_steps must keep its bytes: $out"
# parallel_steps renders and summarizes only when listed; a plan without it keeps every byte.
ok "$dep_repo" write plan < <(example plan | jq -c "$three | .steps[2].paths = [\"tests/test_other.py\"] | .parallel_steps = [\"S-2\", \"S-3\"]")
[ "$(sed -n '/^## Steps that may run together$/,/^$/p' "$(rundir "$dep_repo")/plan.md" | tr '\n' '|')" = '## Steps that may run together|- S-2|- S-3||' ] \
  || fail "a plan with parallel_steps must render them: $(cat "$(rundir "$dep_repo")/plan.md")"
ok "$dep_repo" validate
[ "$(jq -c '.artifacts.plan.parallel_steps' <<<"$out")" = '["S-2","S-3"]' ] || fail "the summary must list the parallel steps: $out"
# A step with a registered worktree of this run says where the worker works; one without keeps its bytes.
ok "$dep_repo" handoff implement --step S-2
no_dir_packet=$out
grep -Fq 'Working directory' <<<"$out" && fail "a step without a worktree names no working directory: $out"
wt_run=$(jq -r .run_id "$dep_state")
wt_tag=$(printf '%s' "$(cd "$dep_repo" && pwd -P)" | sha256sum | cut -c1-8)
wt_path="$work/b-agentic-wt-$wt_tag-$wt_run-S-2"
git -C "$dep_repo" worktree add -q --detach "$wt_path" HEAD
ok "$dep_repo" handoff implement --step S-2
grep -Fxq "Working directory: $wt_path" <<<"$out" || fail "the packet of a step with a run worktree must name it: $out"
[ "$(grep -v '^Working directory: ' <<<"$out")" = "$no_dir_packet" ] || fail "the working directory line is the only difference in the step packet: $out"
ok "$dep_repo" handoff implement --step S-3
grep -Fq 'Working directory' <<<"$out" && fail "another step's packet names no working directory: $out"
git -C "$dep_repo" worktree remove --force "$wt_path"
ok "$dep_repo" write plan < <(example plan)
grep -Fq 'may run together' "$(rundir "$dep_repo")/plan.md" && fail "a plan rewritten without parallel_steps must not render them"
ok "$dep_repo" validate
[ "$(jq -c '.artifacts.plan.parallel_steps' <<<"$out")" = '[]' ] || fail "a plan without parallel_steps lists none: $out"
ok "$dep_repo" handoff implement
[ "$out" = "$plain_implement" ] || fail "the full implement packet of a plan without parallel_steps must keep its bytes: $out"

# --- the b-worker profile in effect (a project profile over the user's) stays inside the worker's allowlist ---
wp_home="$work/wphome"
wp_repo="$work/wprepo"
make_repo "$wp_repo"
mkdir -p "$wp_home/.claude/agents" "$wp_repo/.claude/agents"
wp() { rc=0; out=$(cd "$wp_repo" && HOME="$wp_home" python3 -I -B "$cli" worker-profile --owner s1 2>"$work/err") || rc=$?; }
write_profile() { # FILE TOOLS [EXTRA-FRONTMATTER-LINE]
  { printf -- '---\nname: b-worker\ndescription: "x"\ntools: %s\nmodel: sonnet\neffort: high\n' "$2"; [ -z "${3:-}" ] || printf '%s\n' "$3"; printf -- '---\n\nbody\n'; } >"$1"
}
generated_tools=$(grep '^tools: ' "$root/claude/agents/b-worker.md" | cut -c8-)
wp
[ "$rc" -eq 3 ] && [ "$(jq -r .source <<<"$out")" = none ] || fail "no profile installed must not start a worker: rc=$rc $out"
cp "$root/claude/agents/b-worker.md" "$wp_home/.claude/agents/b-worker.md"
wp
[ "$rc" -eq 0 ] && [ "$(jq -c '[.ok, .source]' <<<"$out")" = '[true,"user"]' ] || fail "the generated profile must pass: rc=$rc $out"
profile_case() { # DESCRIPTION TOOLS [EXTRA]: a project profile that must be refused
  write_profile "$wp_repo/.claude/agents/b-worker.md" "$2" "${3:-}"
  wp
  [ "$rc" -eq 3 ] && [ "$(jq -c '[.ok, .source]' <<<"$out")" = '[false,"project"]' ] || fail "a project profile with $1 must be refused, though the user's is fine: rc=$rc $out"
}
profile_case "the Skill tool" "$generated_tools, Skill"
grep -Fq "'Skill'" <<<"$out" || fail "the refusal must name the tool: $out"
profile_case "a mutating MCP tool" "$generated_tools, mcp__playwright__browser_click"
grep -Fq 'browser_click' <<<"$out" || fail "the refusal must name the MCP tool: $out"
profile_case "an unknown tool" "$generated_tools, Frobnicate"
profile_case "NotebookEdit" "$generated_tools, NotebookEdit"
profile_case "the Agent tool" "$generated_tools, Agent"
profile_case "AskUserQuestion" "$generated_tools, AskUserQuestion"
profile_case "a permission mode" "$generated_tools" "permissionMode: bypassPermissions"
profile_case "hooks" "$generated_tools" "hooks: {}"
profile_case "an isolation field" "$generated_tools" "isolation: worktree"
profile_case "an omitted tools list (it grants every tool)" ""
printf -- '---\nname: b-worker\ndescription: "x"\nmodel: sonnet\n---\n\nbody\n' >"$wp_repo/.claude/agents/b-worker.md"
wp
[ "$rc" -eq 3 ] || fail "a profile without a tools line must be refused: rc=$rc $out"
printf -- '---\nname: b-worker\ntools:\n  - Read\n  - Skill\nmodel: sonnet\n---\n\nbody\n' >"$wp_repo/.claude/agents/b-worker.md"
wp
[ "$rc" -eq 3 ] || fail "a YAML list of tools must be refused, not read as empty: rc=$rc $out"
printf 'no frontmatter\n' >"$wp_repo/.claude/agents/b-worker.md"
wp
[ "$rc" -eq 3 ] || fail "a file called b-worker.md is a candidate even without frontmatter: rc=$rc $out"
rm "$wp_repo/.claude/agents/b-worker.md"
printf 'notes\n' >"$wp_repo/.claude/agents/notes.md"
wp
[ "$rc" -eq 0 ] && [ "$(jq -r .source <<<"$out")" = user ] || fail "another file without frontmatter is not an agent profile and is ignored: rc=$rc $out"
rm "$wp_repo/.claude/agents/notes.md"
# The harness identifies an agent by the name in its frontmatter, in any file under the agents folder.
write_profile "$wp_repo/.claude/agents/custom.md" "$generated_tools, Skill"
wp
[ "$rc" -eq 3 ] && [ "$(jq -r .source <<<"$out")" = project ] || fail "a profile named b-worker in another file must be checked: rc=$rc $out"
grep -Fq 'custom.md' <<<"$out" || fail "the refusal must name the file: $out"
rm "$wp_repo/.claude/agents/custom.md"
mkdir -p "$wp_repo/.claude/agents/team/deep"
write_profile "$wp_repo/.claude/agents/team/deep/anything.md" "$generated_tools, mcp__playwright__browser_click"
wp
[ "$rc" -eq 3 ] || fail "a profile in a nested folder must be checked: rc=$rc $out"
grep -Fq 'team/deep/anything.md' <<<"$out" || fail "the refusal must name the nested file: $out"
rm -rf "$wp_repo/.claude/agents/team"
printf -- '---\nname: helper\ntools: Read, Skill\n---\n\nbody\n' >"$wp_repo/.claude/agents/b-worker.md"
wp
[ "$rc" -eq 3 ] || fail "a file called b-worker.md is checked whatever name it declares: rc=$rc $out"
rm "$wp_repo/.claude/agents/b-worker.md"
printf -- '---\nname: helper\ndescription: "name: b-worker is only text here"\ntools: Read, Skill\n---\n\nbody\n' >"$wp_repo/.claude/agents/helper.md"
wp
[ "$rc" -eq 0 ] && [ "$(jq -r .source <<<"$out")" = user ] || fail "an ordinary agent with another name is not the worker and is ignored: rc=$rc $out"
rm "$wp_repo/.claude/agents/helper.md"
printf -- '---\nname: "b-worker"\ntools: Read, Skill\n---\n\nbody\n' >"$wp_repo/.claude/agents/b-worker.md"
wp
[ "$rc" -eq 3 ] || fail "a quoted name is still the worker: rc=$rc $out"
rm "$wp_repo/.claude/agents/b-worker.md"
# YAML spellings of the name that a line parser could miss: each must be checked, or refused as unreadable.
yaml_case() { # DESCRIPTION CONTENT-FOR-printf-%b: a project file that must be refused though a good user profile exists
  printf '%b' "$2" >"$wp_repo/.claude/agents/other.md"
  wp
  [ "$rc" -eq 3 ] || fail "$1 must be refused: rc=$rc $out"
  [ "$(jq -r .source <<<"$out")" = project ] || fail "$1 must be a project problem: $out"
  rm "$wp_repo/.claude/agents/other.md"
}
yaml_case "a name with a trailing comment" '---\nname: b-worker # project override\ntools: Read, Skill\n---\n\nbody\n'
yaml_case "a quoted name key" '---\n"name": b-worker\ntools: Read, Skill\n---\n\nbody\n'
yaml_case "a single-quoted name key" "---\n'name': b-worker\ntools: Read, Skill\n---\n\nbody\n"
yaml_case "a folded name" '---\nname: >\n  b-worker\ntools: Read, Skill\n---\n\nbody\n'
yaml_case "a literal block name" '---\nname: |\n  b-worker\ntools: Read, Skill\n---\n\nbody\n'
yaml_case "CRLF line ends" '---\r\nname: b-worker\r\ntools: Read, Skill\r\n---\r\n\r\nbody\r\n'
yaml_case "a byte order mark" '\xef\xbb\xbf---\nname: b-worker\ntools: Read, Skill\n---\n\nbody\n'
yaml_case "a flow mapping" '---\n{name: b-worker, tools: Read}\n---\n\nbody\n'
yaml_case "an indented mapping" '---\n  name: b-worker\n  tools: Read, Skill\n---\n\nbody\n'
yaml_case "a tagged name" '---\nname: !!str b-worker\ntools: Read, Skill\n---\n\nbody\n'
yaml_case "an anchored name" '---\nname: &n b-worker\ntools: Read, Skill\n---\n\nbody\n'
yaml_case "an escaped name" '---\nname: "b\\u002dworker"\ntools: Read, Skill\n---\n\nbody\n'
yaml_case "a name key written with a question mark" '---\n? name\n: b-worker\ntools: Read, Skill\n---\n\nbody\n'
yaml_case "a quoted key spelled with an escape" '---\n"nam\\u0065": b-worker\ntools: Read, Skill\n---\n\nbody\n'
yaml_case "a name merged in from an anchor" '---\nbase: &b {"nam\\u0065": "b\\u002dworker"}\n<<: *b\ntools: Read, Skill\n---\n\nbody\n'
yaml_case "a quoted name with spaces inside the quotes" '---\nname: " b-worker "\ntools: Read, Skill\n---\n\nbody\n'
yaml_case "a repeated name" '---\nname: helper\nname: b-worker\ntools: Read, Skill\n---\n\nbody\n'
yaml_case "a differently cased name" '---\nname: B-Worker\ntools: Read, Skill\n---\n\nbody\n'
yaml_case "a nested name that reads b-worker" '---\nname: helper\nmeta:\n  name: b-worker\ntools: Read, Skill\n---\n\nbody\n'
yaml_case "a header that is not closed" '---\nname: b-worker\ntools: Read, Skill\n\nbody\n'
yaml_case "a header with a tag after the dashes" '--- !x\nname: b-worker\ntools: Read, Skill\n---\n\nbody\n'
yaml_case "a quoted tools key" '---\nname: b-worker\n"tools": Read, Skill\n---\n\nbody\n'
yaml_case "a tools list over several lines" '---\nname: b-worker\ntools: >\n  Read, Skill\n---\n\nbody\n'
# The same spellings are fine when the profile is the generated one, and an ordinary agent is left alone.
printf '%b' "---\r\nname: b-worker # the worker\r\ndescription: \"x\"\r\ntools: $generated_tools # allowlist\r\nmodel: sonnet\r\n---\r\n\r\nbody\r\n" >"$wp_repo/.claude/agents/other.md"
wp
[ "$rc" -eq 0 ] || fail "a good profile written with CRLF and comments must pass: rc=$rc $out"
rm "$wp_repo/.claude/agents/other.md"
printf -- '---\nname: code-reviewer\n\n# a comment\ndescription: >\n  Reviews code. name: not a key here\n  "quoted text" at the start of a line\ntools: Read, Grep, Skill\n\nmodel: opus\ncolor: blue\n---\n\nbody\n' >"$wp_repo/.claude/agents/reviewer.md"
wp
[ "$rc" -eq 0 ] || fail "an ordinary agent with block-scalar text must be left alone: rc=$rc $out"
rm "$wp_repo/.claude/agents/reviewer.md"
printf 'docs\n' >"$wp_repo/.claude/agents/README.md"
write_profile "$wp_repo/.claude/agents/b-worker.md" "$generated_tools"
wp
[ "$rc" -eq 0 ] || fail "a plain document next to a good profile must not stop the worker: rc=$rc $out"
write_profile "$wp_repo/.claude/agents/second.md" "$generated_tools"
wp
[ "$rc" -eq 3 ] || fail "two profiles of the same name in one scope are ambiguous: rc=$rc $out"
grep -Fq 'more than one profile' <<<"$out" || fail "the refusal must say why: $out"
rm "$wp_repo/.claude/agents/second.md" "$wp_repo/.claude/agents/README.md" "$wp_repo/.claude/agents/b-worker.md"
mkdir -p "$work/linked-agents"
write_profile "$work/linked-agents/b-worker.md" "$generated_tools, Skill"
ln -s "$work/linked-agents" "$wp_repo/.claude/agents/linked"
wp
[ "$rc" -eq 3 ] || fail "a linked folder under the agents folder cannot be checked: rc=$rc $out"
grep -Fq 'symbolic link' <<<"$out" || fail "the refusal must say why: $out"
rm "$wp_repo/.claude/agents/linked"
write_profile "$wp_repo/.claude/agents/b-worker.md" "Read, Edit"
wp
[ "$rc" -eq 0 ] && [ "$(jq -r .source <<<"$out")" = project ] || fail "a narrower project profile stays inside the allowlist: rc=$rc $out"
write_profile "$wp_repo/.claude/agents/b-worker.md" "$generated_tools"
wp
[ "$rc" -eq 0 ] && [ "$(jq -r .source <<<"$out")" = project ] || fail "a project profile equal to the generated one passes: rc=$rc $out"
rm "$wp_repo/.claude/agents/b-worker.md"
write_profile "$work/elsewhere-profile.md" "$generated_tools"
ln -s "$work/elsewhere-profile.md" "$wp_repo/.claude/agents/b-worker.md"
wp
[ "$rc" -eq 3 ] || fail "a symlinked profile must not be followed: rc=$rc $out"
rm "$wp_repo/.claude/agents/b-worker.md"
write_profile "$wp_home/.claude/agents/b-worker.md" "$generated_tools, Skill"
wp
[ "$rc" -eq 3 ] && [ "$(jq -r .source <<<"$out")" = user ] || fail "a user profile that grants more must be refused too: rc=$rc $out"
# A profile in a folder between the working directory and the repository root is a project profile too.
write_profile "$wp_home/.claude/agents/b-worker.md" "$generated_tools"
mkdir -p "$wp_repo/pkg/inner/.claude/agents"
write_profile "$wp_repo/pkg/inner/.claude/agents/b-worker.md" "$generated_tools, Skill"
rc=0
out=$(cd "$wp_repo/pkg/inner" && HOME="$wp_home" python3 -I -B "$cli" worker-profile --owner s1 2>"$work/err") || rc=$?
[ "$rc" -eq 3 ] && [ "$(jq -r .source <<<"$out")" = project ] || fail "a profile in the working directory must be checked: rc=$rc $out"
rc=0
out=$(cd "$wp_repo/pkg" && HOME="$wp_home" python3 -I -B "$cli" worker-profile --owner s1 2>"$work/err") || rc=$?
[ "$rc" -eq 0 ] && [ "$(jq -r .source <<<"$out")" = user ] || fail "a profile below the working directory is not in effect: rc=$rc $out"

# Pi worker-profile: checks rendered Pi b-worker in ~/.pi/agent/agents, .pi/agents, .agents, and settings overrides.
pi_wp_home="$work/pi-wphome"
pi_wp_repo="$work/pi-wprepo"
make_repo "$pi_wp_repo"
python3 -I -B "$root/tooling/generate/registry_sync.py" --render pi --out "$work/pi-rendered" >/dev/null || fail "render pi for worker-profile failed"
pi_wp() { rc=0; out=$(cd "$pi_wp_repo" && HOME="$pi_wp_home" B_AGENTIC_HELPER_DIR="$pi_override" python3 -I -B "$cli" worker-profile --owner s1 2>"$work/err") || rc=$?; }
pi_wp
[ "$rc" -eq 3 ] && [ "$(jq -r .source <<<"$out")" = none ] || fail "no Pi profile installed must fail: rc=$rc $out"
mkdir -p "$pi_wp_home/.pi/agent/agents"
cp "$work/pi-rendered/agents/b-worker.md" "$pi_wp_home/.pi/agent/agents/b-worker.md"
pi_wp
[ "$rc" -eq 0 ] && [ "$(jq -c '[.ok, .source]' <<<"$out")" = '[true,"user"]' ] || fail "rendered Pi worker profile must pass: rc=$rc $out"
mkdir -p "$pi_wp_repo/.pi/agents"
sed 's/^tools: /tools: subagent, /' "$work/pi-rendered/agents/b-worker.md" >"$pi_wp_repo/.pi/agents/b-worker.md"
pi_wp
[ "$rc" -eq 3 ] && [ "$(jq -r .source <<<"$out")" = project ] || fail "Pi project profile adding subagent must fail: rc=$rc $out"
sed 's/^excludeTools: .*/excludeTools: ask_user_question/' "$work/pi-rendered/agents/b-worker.md" >"$pi_wp_repo/.pi/agents/b-worker.md"
pi_wp
[ "$rc" -eq 3 ] || fail "Pi project profile missing subagent exclusion must fail: rc=$rc $out"
sed 's/^allowNestedSubagents: false/allowNestedSubagents: true/' "$work/pi-rendered/agents/b-worker.md" >"$pi_wp_repo/.pi/agents/b-worker.md"
pi_wp
[ "$rc" -eq 3 ] || fail "Pi project profile allowing nested subagents must fail: rc=$rc $out"
rm "$pi_wp_repo/.pi/agents/b-worker.md"
mkdir -p "$pi_wp_repo/.agents"
sed 's/^tools: /tools: subagent, /' "$work/pi-rendered/agents/b-worker.md" >"$pi_wp_repo/.agents/b-worker.md"
pi_wp
[ "$rc" -eq 3 ] && [ "$(jq -r .source <<<"$out")" = project ] || fail "legacy .agents/b-worker.md with widened tools must fail: rc=$rc $out"
rm "$pi_wp_repo/.agents/b-worker.md"
printf '{"subagents":{"agentOverrides":{"b-worker":{"tools":"bash"}}}}\n' >"$pi_wp_repo/.pi/settings.json"
pi_wp
[ "$rc" -eq 3 ] || fail "project settings agentOverrides.b-worker must fail worker-profile: rc=$rc $out"
rm "$pi_wp_repo/.pi/settings.json"
printf '{"subagents":{"agentOverridesByProvider":{"openai":{"b-worker":{"model":"openai/gpt-6.1-terra"}}}}}\n' >"$pi_wp_home/.pi/agent/settings.json"
pi_wp
[ "$rc" -eq 3 ] || fail "user settings agentOverridesByProvider.openai.b-worker must fail worker-profile: rc=$rc $out"
printf '{"subagents":{"agentScanDirs":["~/extra-agents"]}}\n' >"$pi_wp_home/.pi/agent/settings.json"
pi_wp
[ "$rc" -eq 3 ] || fail "user settings agentScanDirs must fail worker-profile: rc=$rc $out"
printf '{"subagents":{"agentExcludeDirs":["~/.pi/agent/agents"]}}\n' >"$pi_wp_home/.pi/agent/settings.json"
pi_wp
[ "$rc" -eq 3 ] || fail "user settings agentExcludeDirs must fail worker-profile: rc=$rc $out"
printf '{"subagents":{"defaultExtensions":[]}}\n' >"$pi_wp_home/.pi/agent/settings.json"
pi_wp
[ "$rc" -eq 3 ] || fail "user settings defaultExtensions must fail worker-profile: rc=$rc $out"
rm "$pi_wp_home/.pi/agent/settings.json"
# A shadowing ~/.agents/b-worker.md alongside ~/.pi/agent/agents/b-worker.md must be refused.
mkdir -p "$pi_wp_home/.agents"
cp "$work/pi-rendered/agents/b-worker.md" "$pi_wp_home/.agents/b-worker.md"
pi_wp
[ "$rc" -eq 3 ] || fail "a shadowing ~/.agents/b-worker.md must fail worker-profile: rc=$rc $out"
rm -rf "$pi_wp_home/.agents"
# Frontmatter ending with '...' is not closed in Pi: any permission field after '...' must be caught and '...' refused.
printf -- '---\nname: b-worker\ntools: read, edit, write, bash\nexcludeTools: subagent, ask_user_question\nallowNestedSubagents: false\n...\ntools: read, subagent\n---\n\nbody\n' >"$pi_wp_repo/.pi/agents/b-worker.md"
pi_wp
[ "$rc" -eq 3 ] || fail "Pi frontmatter with permission field after '...' must fail worker-profile: rc=$rc $out"
printf -- '---\nname: b-worker\ntools: read, edit, write, bash\nexcludeTools: subagent, ask_user_question\nallowNestedSubagents: false\n...\n\nbody\n' >"$pi_wp_repo/.pi/agents/b-worker.md"
pi_wp
[ "$rc" -eq 3 ] || fail "Pi frontmatter closed only with '...' must fail worker-profile: rc=$rc $out"
rm "$pi_wp_repo/.pi/agents/b-worker.md"
pi_wp
[ "$rc" -eq 0 ] || fail "Pi worker-profile passes again once overrides are removed: rc=$rc $out"
# worker-profile --step S-n checks the actual worktree cwd (catching a shadowing profile near the worktree).
pi_wt_base="$work/pi-wt-base"
mkdir -p "$pi_wt_base/.pi/agents"
sed 's/^tools: /tools: subagent, /' "$work/pi-rendered/agents/b-worker.md" >"$pi_wt_base/.pi/agents/b-worker.md"
newrun "$pi_wp_repo"
( cd "$pi_wp_repo" && example spec | jq -c '.scope_paths = ["a.txt","b.txt"]' | env HOME="$pi_wp_home" B_AGENTIC_HELPER_DIR="$pi_override" python3 -I -B "$cli" write spec --owner s1 >/dev/null )
( cd "$pi_wp_repo" && example plan | jq -c '.steps = [{id:"S-1",action:"a",paths:["a.txt"],done_when:"d"},{id:"S-2",action:"b",paths:["b.txt"],done_when:"d",depends_on:[]}] | .worker_steps = ["S-1","S-2"] | .parallel_steps = ["S-1","S-2"]' \
  | env HOME="$pi_wp_home" B_AGENTIC_HELPER_DIR="$pi_override" python3 -I -B "$cli" write plan --owner s1 >/dev/null )
pi_wt_tag=$(printf '%s' "$pi_wp_repo" | sha256sum | cut -c1-8)
pi_wt_run=$(jq -r .run_id "$(rundir "$pi_wp_repo")/state.json")
pi_wt_dir="$pi_wt_base/b-agentic-wt-$pi_wt_tag-$pi_wt_run-S-2"
git -C "$pi_wp_repo" worktree add -q --detach "$pi_wt_dir" HEAD
rc=0
out=$(cd "$pi_wp_repo" && HOME="$pi_wp_home" B_AGENTIC_HELPER_DIR="$pi_override" python3 -I -B "$cli" worker-profile --step S-2 --owner s1 2>"$work/err") || rc=$?
[ "$rc" -eq 3 ] && [ "$(jq -r .source <<<"$out")" = project ] || fail "worker-profile --step S-2 must catch a profile near the worktree cwd: rc=$rc $out"
git -C "$pi_wp_repo" worktree remove --force "$pi_wt_dir"
rm -rf "$pi_wt_base/.pi"
pi_wp
[ "$rc" -eq 0 ] || fail "Pi worker-profile passes again after worktree cleanup: rc=$rc $out"

# --- the owner: --owner, then CLAUDE_CODE_SESSION_ID -----------------------
owner_repo="$work/owner"
make_repo "$owner_repo"
newrun "$owner_repo"
# bo [VAR=VALUE...]: write the spec without --owner under only the given session variables.
bo() {
  rc=0
  out=$(cd "$owner_repo" && example spec |
    env -u CLAUDE_CODE_SESSION_ID -u PI_SESSION_ID "$@" python3 -I -B "$cli" write spec 2>"$work/err") || rc=$?
}
bo CLAUDE_CODE_SESSION_ID=s1
[ "$rc" -eq 0 ] || fail "CLAUDE_CODE_SESSION_ID must name the owner without --owner: rc=$rc $(cat "$work/err")"
bo CLAUDE_CODE_SESSION_ID=other
[ "$rc" -eq 3 ] || fail "a CLAUDE_CODE_SESSION_ID without the lock must be refused (rc=$rc)"
grep -Fq 'locked by another session' "$work/err" || fail "the lock owner must be named: $(cat "$work/err")"
bo
[ "$rc" -eq 2 ] || fail "no owner at all must be invalid input (rc=$rc)"
grep -Fq 'CLAUDE_CODE_SESSION_ID' "$work/err" || fail "the error must name the session variable: $(cat "$work/err")"
! grep -Fq 'PI_SESSION_ID' "$work/err" || fail "the Claude Code error must not mention the Pi variable: $(cat "$work/err")"
bo PI_SESSION_ID=s1
[ "$rc" -eq 0 ] || fail "PI_SESSION_ID must name the owner without --owner: rc=$rc $(cat "$work/err")"
bo CLAUDE_CODE_SESSION_ID=other PI_SESSION_ID=s1
[ "$rc" -eq 3 ] || fail "CLAUDE_CODE_SESSION_ID must win over PI_SESSION_ID (rc=$rc)"
bo B_AGENTIC_HELPER_DIR='~/.pi/agent/b-agentic/bin'
[ "$rc" -eq 2 ] || fail "no owner under the helper folder override must be invalid input (rc=$rc)"
grep -Fq 'or set PI_SESSION_ID' "$work/err" || fail "the override error must name the Pi variable: $(cat "$work/err")"
! grep -Fq 'CLAUDE_CODE_SESSION_ID' "$work/err" || fail "the override error must not name the Claude Code variable: $(cat "$work/err")"
rc=0
out=$(cd "$owner_repo" && example spec |
  env CLAUDE_CODE_SESSION_ID=other python3 -I -B "$cli" write spec --owner s1 2>"$work/err") || rc=$?
[ "$rc" -eq 0 ] || fail "--owner must override the session variable: rc=$rc $(cat "$work/err")"

# --- no run, no repository --------------------------------------------------------------------
repo2="$work/repo2"
make_repo "$repo2"
refused "$repo2" validate
mkdir -p "$work/plain"
refused "$work/plain" validate

# --- a spec written before ADR-021 keeps its codex consent: it validates and re-renders the same ---
legacy_repo="$work/legacy"
make_repo "$legacy_repo"
newrun "$legacy_repo"
ok "$legacy_repo" write spec < <(example spec)
ok "$legacy_repo" write plan < <(example plan)
legacy_dir=$(rundir "$legacy_repo")
python3 -I - "$legacy_dir" <<'PY'
import hashlib
import json
import sys

d = sys.argv[1]
body = open(f"{d}/spec.md").read()
assert "- Branch target: current\n" in body
body = body.replace("- Branch target: current\n", "- Branch target: current\n- Codex: reviewer\n")
open(f"{d}/spec.md", "w").write(body)
artifacts = json.load(open(f"{d}/artifacts.json"))
spec = artifacts["artifacts"]["spec"]
spec["data"]["consent"]["codex"] = "reviewer"
spec["sha256"] = hashlib.sha256(body.encode()).hexdigest()
json.dump(artifacts, open(f"{d}/artifacts.json", "w"), indent=2)
PY
ok "$legacy_repo" validate
grep -Fq -- '- Codex: reviewer' "$legacy_dir/spec.md" || fail "a legacy spec must keep rendering its Codex consent"
# New data is refused even in a run that holds a legacy spec.
invalid "$legacy_repo" write spec < <(example spec | jq -c '.consent.codex = "reviewer"')
ok "$legacy_repo" write spec < <(example spec)
grep -Fq 'Codex' "$legacy_dir/spec.md" && fail "a rewritten spec must drop the retired Codex consent"
ok "$legacy_repo" validate

# --- runs and prune: only finished, old, non-active runs of plain files are ever removed ------
old_stamp=2026-01-01T00:00:00.000Z
new_stamp=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
mkrun() { # REPO NAME PHASE UPDATED [RUN_ID]: a run folder with the files a real run holds
  local dir=$1/.b-agentic/runs/$2
  mkdir -p "$dir"
  jq -n --arg id "${5:-$2}" --arg phase "$3" --arg at "$4" '{run_id: $id, phase: $phase, updated_at: $at}' >"$dir/state.json"
  printf 'x\n' >"$dir/lock"
  printf 'spec\n' >"$dir/spec.md"
}
listing() { (cd "$1/.b-agentic/runs" && find . -mindepth 1 | LC_ALL=C sort | tr '\n' ' '); }
prunerepo="$work/prune"
make_repo "$prunerepo"
mkdir -p "$prunerepo/.b-agentic/runs"
mkrun "$prunerepo" 20260101-done-old "done" "$old_stamp"
mkrun "$prunerepo" 20260102-done-old2 "done" "$old_stamp"
mkrun "$prunerepo" 20260103-done-new "done" "$new_stamp"
mkrun "$prunerepo" 20260104-clarify-old clarify "$old_stamp"
mkrun "$prunerepo" 20260105-blocked-old blocked "$old_stamp"
mkrun "$prunerepo" 20260106-active-done-old "done" "$old_stamp"
printf '20260106-active-done-old\n' >"$prunerepo/.b-agentic/active"
mkrun "$prunerepo" 20260107-bad-state "done" "$old_stamp"
printf 'not json\n' >"$prunerepo/.b-agentic/runs/20260107-bad-state/state.json"
mkrun "$prunerepo" 20260108-mismatch "done" "$old_stamp" 20260199-other
mkrun "$prunerepo" 20260109-subdir "done" "$old_stamp"
mkdir "$prunerepo/.b-agentic/runs/20260109-subdir/nested"
mkrun "$prunerepo" 20260110-mutexfile "done" "$old_stamp"
printf 'm\n' >"$prunerepo/.b-agentic/runs/20260110-mutexfile/mutex"
mkrun "$prunerepo" 20260113-no-date "done" ""
mkdir -p "$work/outside-run"
jq -n --arg at "$old_stamp" '{run_id: "20260111-linkrun", phase: "done", updated_at: $at}' >"$work/outside-run/state.json"
ln -s "$work/outside-run" "$prunerepo/.b-agentic/runs/20260111-linkrun"
printf 'f\n' >"$prunerepo/.b-agentic/runs/20260112-afile"
mkdir "$prunerepo/.b-agentic/runs/not-a-run"
before=$(listing "$prunerepo")
want='["20260101-done-old","20260102-done-old2"]'

# AC-1, AC-5: both commands only report by default, and prune lists exactly the eligible runs.
ok "$prunerepo" prune
[ "$(jq -c .eligible <<<"$out")" = "$want" ] || fail "prune must list the finished old runs only: $out"
[ "$(jq -r .applied <<<"$out")" = false ] || fail "prune without --apply must report applied false"
[ "$(listing "$prunerepo")" = "$before" ] || fail "prune without --apply must delete nothing"
ok "$prunerepo" runs
[ "$(jq -c .eligible <<<"$out")" = "$want" ] || fail "runs must list the same eligible runs: $out"
jq -e '.runs == 13 and .bytes > 0 and .over_threshold == false and .kept.active == 1 and .kept.unfinished == 2 and .kept.recent == 1
  and .kept.unreadable == 3 and .kept.unexpected == 3 and .kept.symlink == 1 and .kept.ignored == 1' <<<"$out" >/dev/null \
  || fail "runs must count every kept reason: $out"
[ "$(jq 'has("removed")' <<<"$out")" = false ] || fail "runs must have no deletion result"
[ "$(listing "$prunerepo")" = "$before" ] || fail "runs must delete nothing"
invalid "$prunerepo" runs --apply
invalid "$prunerepo" prune --days 0
invalid "$prunerepo" prune --days x
invalid "$prunerepo" prune --days 3651
invalid "$prunerepo" prune extra
# An option these commands do not use is refused, never ignored: --run must not widen a prune to every run.
for unused in "--run 20260101-done-old" "--out /tmp/x" "--step S-1" "--base x" "--tree x" "--json"; do
  # shellcheck disable=SC2086 # The option and its value are meant to split.
  invalid "$prunerepo" prune --apply $unused
  # shellcheck disable=SC2086
  invalid "$prunerepo" runs $unused
done
[ "$(listing "$prunerepo")" = "$before" ] || fail "a refused option must delete nothing"
ok "$prunerepo" prune --days 3650
[ "$(jq -c .eligible <<<"$out")" = '[]' ] || fail "no run is older than the longest --days: $out"

# AC-3: a running init (mutex) blocks --apply.
printf 'busy\n' >"$prunerepo/.b-agentic/mutex"
refused "$prunerepo" prune --apply
[ "$(listing "$prunerepo")" = "$before" ] || fail "a refused --apply must delete nothing"
rm -f "$prunerepo/.b-agentic/mutex"

# AC-2, AC-3: --apply removes exactly the eligible runs and never follows the link.
ok "$prunerepo" prune --apply
[ "$(jq -c .removed <<<"$out")" = "$want" ] || fail "prune --apply must remove exactly the eligible runs: $out"
[ "$(jq -r .ok <<<"$out")" = true ] || fail "prune --apply must succeed: $out"
[ ! -e "$prunerepo/.b-agentic/runs/20260101-done-old" ] || fail "an eligible run must be gone"
[ ! -e "$prunerepo/.b-agentic/runs/20260102-done-old2" ] || fail "an eligible run must be gone"
for kept in 20260103-done-new 20260104-clarify-old 20260105-blocked-old 20260106-active-done-old 20260107-bad-state 20260108-mismatch \
  20260109-subdir 20260110-mutexfile 20260113-no-date 20260111-linkrun 20260112-afile not-a-run; do
  [ -e "$prunerepo/.b-agentic/runs/$kept" ] || [ -L "$prunerepo/.b-agentic/runs/$kept" ] || fail "prune must keep $kept"
done
[ -f "$work/outside-run/state.json" ] || fail "prune must not follow a link out of the runs folder"
[ -d "$prunerepo/.b-agentic/runs/20260109-subdir/nested" ] || fail "prune must not touch a run holding a folder"
ok "$prunerepo" prune --apply
[ "$(jq -c .removed <<<"$out")" = '[]' ] || fail "a second prune --apply has nothing left to remove: $out"

# AC-3: a link in place of .b-agentic or of the runs folder is refused, and its target stays intact.
for linked in runs base; do
  linkrepo="$work/link-$linked"
  target="$work/target-$linked"
  make_repo "$linkrepo"
  mkrun "$target" 20260101-done-old "done" "$old_stamp"
  if [ "$linked" = runs ]; then
    mkdir -p "$linkrepo/.b-agentic"
    ln -s "$target/.b-agentic/runs" "$linkrepo/.b-agentic/runs"
  else
    ln -s "$target/.b-agentic" "$linkrepo/.b-agentic"
  fi
  refused "$linkrepo" prune --apply
  refused "$linkrepo" runs
  [ -f "$target/.b-agentic/runs/20260101-done-old/state.json" ] || fail "a linked $linked must not be followed"
done

# AC-3: a link swapped in for .b-agentic after the scan began must not move a removal outside the worktree.
racerepo="$work/race"
racetarget="$work/race-target"
make_repo "$racerepo"
mkrun "$racerepo" 20260101-done-old "done" "$old_stamp"
mkrun "$racetarget" 20260101-done-old "done" "$old_stamp"
python3 -I -B - "$root/claude/bin" "$racerepo" "$racetarget" <<'PY' || fail "the .b-agentic swap must not redirect prune"
import os
import sys

sys.path.insert(0, sys.argv[1])
import b_run

repo, target = sys.argv[2], sys.argv[3]
base = os.path.join(repo, ".b-agentic")
real = b_run._read_active


def swap(base_fd):
    # Runs after .b-agentic was opened and before runs is: the point the old path-based open could be redirected.
    os.rename(base, base + ".orig")
    os.symlink(os.path.join(target, ".b-agentic"), base)
    return real(base_fd)


b_run._read_active = swap
os.chdir(repo)
result = b_run.cmd_prune({"apply": True})
assert result["removed"] == ["20260101-done-old"], result
PY
[ -f "$racetarget/.b-agentic/runs/20260101-done-old/state.json" ] || fail "prune followed a swapped link and deleted outside the worktree"
[ ! -e "$racerepo/.b-agentic.orig/runs/20260101-done-old" ] || fail "prune must remove from the folder it opened"

# AC-2: a folder swapped in for an inspected run is never emptied: removal follows the inspected folder.
swaprepo="$work/swap"
make_repo "$swaprepo"
mkrun "$swaprepo" 20260101-done-old "done" "$old_stamp"
python3 -I -B - "$root/claude/bin" "$swaprepo" <<'PY' || fail "a replaced run folder must be kept"
import os
import sys

sys.path.insert(0, sys.argv[1])
import b_run

repo = sys.argv[2]
runs = os.path.join(repo, ".b-agentic", "runs")
real = b_run._inspect_run


def swap(runs_fd, name, active, cutoff):
    category, size, fd = real(runs_fd, name, active, cutoff)
    # Runs after the inspection and before the removal: another folder takes the name.
    os.rename(os.path.join(runs, name), os.path.join(runs, name + "-moved"))
    os.mkdir(os.path.join(runs, name))
    with open(os.path.join(runs, name, "precious.txt"), "w") as handle:
        handle.write("keep\n")
    return category, size, fd


b_run._inspect_run = swap
os.chdir(repo)
result = b_run.cmd_prune({"apply": True})
assert result["ok"] is False and result["removed"] == [] and len(result["problems"]) == 1, result
PY
[ -f "$swaprepo/.b-agentic/runs/20260101-done-old/precious.txt" ] || fail "prune emptied a folder it had not inspected"

# AC-5: no runs folder is an ok report of zero; the hint threshold is more than 40 runs.
emptyrepo="$work/empty-runs"
make_repo "$emptyrepo"
ok "$emptyrepo" runs
jq -e '.runs == 0 and .bytes == 0 and .over_threshold == false' <<<"$out" >/dev/null || fail "no runs folder must report zero: $out"
manyrepo="$work/many-runs"
make_repo "$manyrepo"
for i in $(seq 1 40); do mkrun "$manyrepo" "20261101-run-$i" "done" "$new_stamp"; done
ok "$manyrepo" runs
jq -e '.runs == 40 and .over_threshold == false' <<<"$out" >/dev/null || fail "40 runs must not be over the threshold: $out"
mkrun "$manyrepo" 20261101-run-41 "done" "$new_stamp"
ok "$manyrepo" runs
jq -e '.runs == 41 and .over_threshold == true' <<<"$out" >/dev/null || fail "41 runs must be over the threshold: $out"

# --- stats --record: written once per key, honors the off file, one creation across concurrent repositories (ADR-035) ---
stats_home="$HOME/.claude/b-agentic"
mkdir -p "$stats_home"
chmod 700 "$stats_home"
statsrepos=()
for name in sa sb sc; do
  repo="$work/stats-$name"
  make_repo "$repo"
  # Distinct root commits give each repository its own key even when the probe makes them in one second.
  git -C "$repo" commit -q --amend -m "root $name"
  mkdir -p "$repo/.b-agentic/runs"
  # A run's key is its id and init time, so the repositories' runs carry distinct ids.
  mkrun "$repo" "20261101-one-$name" "done" "$new_stamp"
  mkrun "$repo" "20261102-two-$name" "done" "$new_stamp"
  mkrun "$repo" "20261103-open-$name" clarify "$new_stamp"
  statsrepos+=("$repo")
done
# A line is a numbers-only record: the report reads it back without malformed lines.
ok "${statsrepos[0]}" stats
jq -e '.stores.claude.exists == false and .finished_runs == 2 and .missing == 2' <<<"$out" >/dev/null || fail "stats must count the unrecorded finished runs only: $out"
: >"$stats_home/run-stats.off"
ok "${statsrepos[0]}" stats --record
jq -e '.appended == 0 and .skipped.disabled == 1 and .created == false' <<<"$out" >/dev/null || fail "the off file must stop stats --record: $out"
[ ! -e "$stats_home/run-stats.jsonl" ] || fail "the off file must stop the store from being created"
rm -f "$stats_home/run-stats.off"
pids=()
for repo in "${statsrepos[@]}"; do
  (cd "$repo" && python3 -I -B "$cli" stats --record --owner s1 >"$work/stats-$(basename "$repo").json") &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || fail "a concurrent stats --record failed"; done
[ "$(jq -s '[.[] | select(.created == true)] | length' "$work"/stats-stats-*.json)" = 1 ] || fail "the store must be created by exactly one of three concurrent writers"
[ "$(python3 -I -B -c 'import os, sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$stats_home/run-stats.jsonl")" = 600 ] || fail "the store must be 0600"
[ "$(jq -R -s 'split("\n") | map(select(length > 0) | fromjson | .run) | unique | length' "$stats_home/run-stats.jsonl")" = 6 ] || fail "each of the six finished runs must be written once"
[ "$(jq -R -s 'split("\n") | map(select(length > 0)) | length' "$stats_home/run-stats.jsonl")" = 6 ] || fail "concurrent writers must leave exactly six lines"
# The same three writers register their checkouts: one creates the registry, and each leaves one line (ADR-037).
[ "$(jq -s '[.[] | select(.registry == "written")] | length' "$work"/stats-stats-*.json)" = 3 ] || fail "each concurrent writer must register its checkout: $(cat "$work"/stats-stats-*.json)"
[ "$(jq -s '[.[] | select((.notice // "") | contains("run-stats-repos.jsonl"))] | length' "$work"/stats-stats-*.json)" = 1 ] || fail "the registry must be created by exactly one of three concurrent writers"
[ "$(python3 -I -B -c 'import os, sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$stats_home/run-stats-repos.jsonl")" = 600 ] || fail "the registry must be 0600"
jq -e -s 'length == 3 and (map(.repo) | unique | length) == 3 and (map(.path) | unique | length) == 3' "$stats_home/run-stats-repos.jsonl" >/dev/null || fail "the registry must hold one line per key and path: $(cat "$stats_home/run-stats-repos.jsonl")"
if grep -qF "$work" "$stats_home/run-stats.jsonl"; then fail "no path may enter the store"; fi
ok "${statsrepos[0]}" stats --record
jq -e '.appended == 0 and .already == 2 and .created == false and .registry == "already" and (has("notice") | not)' <<<"$out" >/dev/null || fail "a second stats --record must write nothing: $out"
[ "$(wc -l <"$stats_home/run-stats-repos.jsonl" | tr -d ' ')" = 3 ] || fail "a second stats --record must add no registry line"
ok "${statsrepos[0]}" stats
jq -e '.missing == 0 and .repo_lines == 2 and .stores.claude.valid == 6 and .stores.claude.malformed == 0 and .repos == 3' <<<"$out" >/dev/null || fail "the report must count every line: $out"
ok "${statsrepos[0]}" stats --record --run 20261103-open-sa
jq -e '.skipped["not-done"] == 1' <<<"$out" >/dev/null || fail "an unfinished run must not be recorded: $out"
invalid "${statsrepos[0]}" stats --days 3
invalid "${statsrepos[0]}" stats --run 20261101-one-sa

echo "artifact probe passed"
