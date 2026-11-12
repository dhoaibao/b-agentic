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
spec_json() { # N [SCOPE]: N automated criteria that run "make test"
  jq -n --argjson n "$1" --arg scope "${2:-**}" '{request: "probe request", answers: [],
    behavior: {current: [], new: ["x"], examples: [{input: "a", output: "b"}, {input: "c", output: "d"}], non_goals: []},
    criteria: [range(1; $n + 1) | {id: "AC-\(.)", when: "a", then: "b", evidence: "automated", command: "make test"}],
    scope_paths: [$scope], out_of_scope: []}'
}
plan_json() { jq -n '{steps: [{id: "S-1", action: "do", paths: ["a.txt"], done_when: "done"}], checks: ["make test"], invariants: [], stop_conditions: []}'; }
write_artifacts() { # REPO N [SCOPE]
  spec_json "$2" "${3:-**}" | br "$1" s1 write spec >/dev/null || fail "write spec ($1)"
  plan_json | br "$1" s1 write plan >/dev/null || fail "write plan ($1)"
}
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
write_artifacts "$repo" 2
invalid "$repo" s1 approve --commit yes --branch-target "bad target" --codex reviewer
ok "$repo" s1 approve --commit yes --branch-target current --codex reviewer
[ "$(phase "$repo")" = approved ] || fail "approve phase"
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
ok "$repo" s1 advance verify
refused "$repo" s1 advance review          # no passing checks yet
ok "$repo" s1 record check --cmd "make test" --exit 0
ok "$repo" s1 advance review
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
write_artifacts "$repo2" 1
ok "$repo2" s1 approve --commit no --branch-target current --codex reviewer
ok "$repo2" s1 advance implement
printf 'b\n' >"$repo2/a.txt"
ok "$repo2" s1 advance verify
ok "$repo2" s1 record check --cmd "make test" --exit 0
ok "$repo2" s1 record review --low-risk "docs-only change, no trigger"
ok "$repo2" s1 advance qa
write_qa "$repo2" 1 "QA PASS" pass
ok "$repo2" s1 record qa --verdict "QA PASS"
ok "$repo2" s1 record ac AC-1 pass
refused "$repo2" s1 advance commit
grep -Fq 'consent' "$work/err" || fail "refusal must name the missing consent: $(cat "$work/err")"

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
refused "$repo" s1 unblock verify --reason "keep going"   # spec still differs
ok "$repo" s1 unblock clarify --reason "re-approve"
[ "$(phase "$repo")" = clarify ] || fail "unblock to clarify"

# --- bounded rounds: the third failure blocks --------------------------------
repo3="$work/repo3"
make_repo "$repo3"
ok "$repo3" s1 init rounds
write_artifacts "$repo3" 1
ok "$repo3" s1 approve --commit yes --branch-target current --codex standing
ok "$repo3" s1 advance implement
printf 'x\n' >"$repo3/a.txt"
ok "$repo3" s1 advance verify
ok "$repo3" s1 record check --cmd "make test" --exit 1
ok "$repo3" s1 record check --cmd "make test" --exit 1
[ "$(phase "$repo3")" = verify ] || fail "two failures must not block"
ok "$repo3" s1 record check --cmd "make test" --exit 1
[ "$(phase "$repo3")" = blocked ] || fail "third failure must block"
[ "$(jq -r .attempts.verify "$(sfile "$repo3")")" = 3 ] || fail "attempt counter"

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
  write_artifacts "$repo" 1
  ok "$repo" s1 approve --commit yes --branch-target "$target" --codex reviewer
  ok "$repo" s1 advance implement
  printf 'feature\n' >"$repo/f.txt"
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
ok "$repo6" s1 record commit "$sha"
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
tmp=$(mktemp)
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
ok "$repo12" s1 advance verify
ok "$repo12" s1 record check --cmd "make test" --exit 1
ok "$repo12" s1 record check --cmd "make test" --exit 0
ok "$repo12" s1 advance review
[ "$(jq -r .attempts.verify "$(sfile "$repo12")")" = 0 ] || fail "entering review resets the verify attempts"

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
printf 'x\n' >"$repo18/extra.txt"
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
ok "$repo22" s1 advance verify
ok "$repo22" s1 record check --cmd "make test" --exit 0
ok "$repo22" s1 advance review
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
tmp=$(mktemp)
jq 'del(.spec.plan_sha256) | del(.qa.artifact_rev)' "$(sfile "$repo21")" >"$tmp" && cp "$tmp" "$(sfile "$repo21")"
rm -f "$d21/artifacts.json"
ok "$repo21" s1 show
refused "$repo21" s1 check
[ "$(phase "$repo21")" = blocked ] || fail "a legacy run without recorded artifacts must block: $(phase "$repo21")"
ok "$repo21" s1 unblock clarify --reason "rebuild the artifacts after the upgrade"
write_artifacts "$repo21" 1
ok "$repo21" s1 approve --commit yes --branch-target current --codex reviewer
[ "$(phase "$repo21")" = approved ] || fail "a rebuilt legacy run must approve again"

# --- no command outside a git worktree ---------------------------------------
mkdir -p "$work/plain"
refused "$work/plain" s1 show

echo "state probe passed"
