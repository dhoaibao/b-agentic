# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034 # Variables are shared with state-probe.sh and the other files it sources.
# The commit plan, a partial commit and artifacts named with --include-ignored.
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

