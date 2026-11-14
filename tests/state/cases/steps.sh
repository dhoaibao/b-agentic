# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034 # Variables are shared with state-probe.sh and the other files it sources.
# The implement step cursor and the step gate against the approved scope.
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

