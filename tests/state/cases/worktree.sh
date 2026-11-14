# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034 # Variables are shared with state-probe.sh and the other files it sources.
# Parallel worker steps in their own worktrees (ADR-016).
# --- parallel worker steps: one worktree per worker, never the main tree or the state (ADR-016) ---
wt_tmp="$work/wt"
mkdir -p "$wt_tmp"
# The CLI resolves links in the temporary folder (macOS /var is /private/var), so compare against the real path.
wt_tmp=$(cd "$wt_tmp" && pwd -P)
export TMPDIR="$wt_tmp"
# Octal mode of a path, portable across GNU and BSD stat.
mode_of() { node -e 'process.stdout.write((require("fs").statSync(process.argv[1]).mode & 0o777).toString(8))' "$1"; }
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
[ "$(mode_of "$wt_parent")" = 700 ] || fail "the worktree folder is for its owner alone, whatever the umask: $(mode_of "$wt_parent")"
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
# A likely-secret path in the main tree makes the snapshot incomplete: a worktree step is refused without counting.
printf 'x\n' >"$repoPW/server.pem"
refused "$repoPW" s1 record step S-2 --by worker
grep -Fq 'protected path' "$work/err" || fail "a likely-secret path in the main tree is refused for a worktree step: $(cat "$work/err")"
[ "$before" = "$(snap "$repoPW")" ] || fail "no attempt is counted and nothing is written for it either"
rm "$repoPW/server.pem"
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

