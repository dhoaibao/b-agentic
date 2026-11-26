# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034,SC2088 # Variables are shared with state-probe.sh and the other files it sources; the quoted tilde is the literal text the CLI reads.
# The local run-stats store (ADR-035): one numbers-only line per finished run, off by a flag file,
# created only inside an existing private install home. HOME is a throwaway folder (state-probe.sh).
stats_home="$HOME/.claude/b-agentic"
stats_store="$stats_home/run-stats.jsonl"
stats_off="$stats_home/run-stats.off"
pi_home="$HOME/.pi/agent/b-agentic"
pi_dir='~/.pi/agent/b-agentic/bin'

# Portable helpers: the macOS job runs this shard too, so no GNU stat and no padded wc output.
mode_of() { python3 -I -B -c 'import os, sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$1"; }
lines_of() { python3 -I -B -c 'import sys; print(open(sys.argv[1], "rb").read().count(b"\n"))' "$1"; }

# ready_run REPO SLUG: a quick run through QA, one step short of done.
ready_run() {
  local repo=$1 slug=$2
  ok "$repo" s1 init "$slug"
  quick_spec a.txt no 1 | br "$repo" s1 write spec >/dev/null || fail "write spec ($repo)"
  plan_json | br "$repo" s1 write plan >/dev/null || fail "write plan ($repo)"
  ok "$repo" s1 "${quick_approve[@]}"
  ok "$repo" s1 advance implement
  printf '%s\n' "$slug" >"$repo/a.txt"
  apply_steps "$repo"
  ok "$repo" s1 advance verify
  ok "$repo" s1 record check --cmd "make test" --exit 0
  ok "$repo" s1 record review --low-risk "one-line change, no trigger"
  ok "$repo" s1 advance qa
  write_qa "$repo" 1 "QA PASS" pass
  ok "$repo" s1 record qa --verdict "QA PASS"
  ok "$repo" s1 record ac AC-1 pass
}
# finish_run REPO SLUG: ready_run to done, then commit its change so the next run starts clean.
finish_run() {
  ready_run "$@"
  ok "$1" s1 advance "done"
  git -C "$1" commit -qam "run $2"
}
# stats REPO ARGS...: the b-run stats command in REPO, with a time limit so a hang fails the shard.
stats() {
  local repo=$1
  shift
  python3 -I -B - "$run_cli" "$repo" "$@" <<'PY'
import subprocess
import sys

cli, repo, args = sys.argv[1], sys.argv[2], sys.argv[3:]
try:
    done = subprocess.run(["python3", "-I", "-B", cli, "stats", *args, "--owner", "s1"], cwd=repo, timeout=20)
except subprocess.TimeoutExpired:
    print("stats timed out", file=sys.stderr)
    sys.exit(124)
sys.exit(done.returncode)
PY
}
# store_py ARGS...: run the Python on stdin with b_run loaded as b_run and the store path as the first argument.
store_py() {
  python3 -I -B -c '
import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location("b_run", sys.argv[1])
b_run = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b_run)
block = b_run._stats_block(b_run.load_schema())
store = sys.argv[2]
exec(sys.stdin.read())
' "$run_cli" "$@"
}

repoS="$work/repoS"
make_repo "$repoS"

# --- no install home: the run still finishes, nothing is created, the reason is reported (AC-3) ---
finish_run "$repoS" first
[ "$(phase "$repoS")" = "done" ] || fail "a run must finish without an install home"
jq -e '.run_stats == "skipped:no-install-home" and (has("notice") | not)' <<<"$out" >/dev/null || fail "a missing home must be reported: $out"
[ ! -e "$HOME/.claude" ] || fail "the store must never create the install home"
stats "$repoS" | jq -e '.stores.claude.exists == false and .missing == 1 and .finished_runs == 1' >/dev/null \
  || fail "the report must show the unrecorded run"

# --- a symlinked or group-writable home is skipped, never followed or repaired (AC-3) ----------------
mkdir -p "$work/elsewhere/b-agentic" "$HOME/.claude"
ln -s "$work/elsewhere/b-agentic" "$stats_home"
stats "$repoS" --record | jq -e '.appended == 0 and .skipped["home-not-plain"] == 1' >/dev/null || fail "a symlinked home must be skipped"
[ -z "$(ls -A "$work/elsewhere/b-agentic")" ] || fail "nothing may be written through a symlinked home"
rm -f "$stats_home"
mkdir -p "$stats_home"
# The home rule, on stat results: others never write; a group writes only when it is the user's own private group.
store_py "$stats_store" <<'PY' || fail "the install home rule must refuse other-writable and shared-group homes"
from types import SimpleNamespace

uid, gid = os.getuid(), os.getgid()


def home(mode, owner=uid, group=gid):
    return SimpleNamespace(st_uid=owner, st_gid=group, st_mode=0o40000 | mode)


original, listxattr = b_run._own_private_group, getattr(os, "listxattr", None)
fd = os.open(os.path.dirname(store), os.O_RDONLY | os.O_DIRECTORY)
try:
    b_run._own_private_group = lambda _gid: True
    os.listxattr = lambda _fd: []
    assert b_run._home_private(home(0o700), fd) and b_run._home_private(home(0o755), fd)
    assert b_run._home_private(home(0o775), fd), "a group-writable home of the user's private group is accepted"
    assert not b_run._home_private(home(0o757), fd) and not b_run._home_private(home(0o777), fd), "others must not write"
    assert not b_run._home_private(home(0o700, owner=uid + 1), fd), "another owner must be refused"
    assert not b_run._home_private(home(0o775, group=gid + 1), fd), "a group that is not the user's primary group must be refused"
    os.listxattr = lambda _fd: ["system.posix_acl_access"]
    assert not b_run._home_private(home(0o775), fd), "an ACL can grant another account write access behind the group bits"
    assert b_run._home_private(home(0o755), fd), "without group write bits an ACL mask leaves no write access"
    os.listxattr = lambda _fd: (_ for _ in ()).throw(OSError("unsupported"))
    assert not b_run._home_private(home(0o775), fd), "a home whose ACLs cannot be checked must be refused"
    os.listxattr = lambda _fd: []
    b_run._own_private_group = lambda _gid: False
    assert b_run._home_private(home(0o755), fd), "a group that cannot write needs no private group"
    assert not b_run._home_private(home(0o775), fd), "a group-writable home of a shared group must be refused"
finally:
    b_run._own_private_group = original
    if listxattr is not None:
        os.listxattr = listxattr
    os.close(fd)
PY
chmod 757 "$stats_home"
stats "$repoS" --record | jq -e '.appended == 0 and .skipped["home-not-private"] == 1' >/dev/null || fail "an other-writable home must be skipped"
[ ! -e "$stats_store" ] || fail "an other-writable home must get no store"
chmod 700 "$stats_home"

# --- first use: the store is created 0600, one line, one notice (AC-1) ---------------------------------
stats "$repoS" --record >"$work/rec.json" || fail "stats --record must succeed"
jq -e '.created == true and .appended == 1 and (.notice | contains("run-stats.off"))' "$work/rec.json" >/dev/null \
  || fail "the first record must create the store and carry the notice: $(cat "$work/rec.json")"
[ "$(mode_of "$stats_store")" = 600 ] || fail "the store must be 0600: $(mode_of "$stats_store")"
[ "$(lines_of "$stats_store")" = 1 ] || fail "one finished run, one line"
allowed=$(jq -r '.run_stats.fields | keys | join(" ")' "$root/references/artifacts.yaml")
for key in $(jq -r 'keys[]' "$stats_store"); do
  case " $allowed " in *" $key "*) ;; *) fail "the line holds a field outside run_stats: $key" ;; esac
done
if grep -Fq "first" "$stats_store" || grep -Fq "$repoS" "$stats_store" || grep -Fq "make test" "$stats_store"; then
  fail "the line must hold no run slug, path, or command: $(cat "$stats_store")"
fi
jq -e '.v == 1 and .size == "quick" and .end == "qa" and .criteria == 1 and .review.low_risk == true and .ac.pass == 1 and .runtime == "claude"
  and (.repo | test("^[0-9a-f]{16}$")) and (.run | test("^[0-9a-f]{16}$")) and (.date | test("^\\d{4}-\\d{2}-\\d{2}$"))' "$stats_store" >/dev/null \
  || fail "the line must hold the run's numbers: $(cat "$stats_store")"

# --- exactly once, and a later run notices nothing new --------------------------------------------------
stats "$repoS" --record | jq -e '.appended == 0 and .already == 1 and (has("notice") | not)' >/dev/null \
  || fail "a recorded run must not be written twice"
finish_run "$repoS" second
jq -e '.run_stats == "written" and (has("notice") | not)' <<<"$out" >/dev/null || fail "the second run is written without a notice: $out"
[ "$(lines_of "$stats_store")" = 2 ] || fail "advance done must append the finished run's line"
stats "$repoS" | jq -e '.stores.claude.valid == 2 and .repos == 1 and .repo_lines == 2 and .missing == 0' >/dev/null \
  || fail "the report must count both lines for this repository"

# --- a run with commit consent writes its line too, ending at its commit (AC-1) -------------------------
repoC="$work/repoC"
to_commit "$repoC" current
git -C "$repoC" add f.txt
git -C "$repoC" commit -qm "feat: add f"
ok "$repoC" s1 record commit "$(git -C "$repoC" rev-parse HEAD)"
ok "$repoC" s1 advance "done"
jq -e '.run_stats == "written"' <<<"$out" >/dev/null || fail "a committed run must be recorded: $out"
stats "$repoC" | jq -e '.repo_lines == 1' >/dev/null || fail "the committed run must be counted"
jq -e 'select(.end == "commit" and .size == "full" and .commits == 1)' "$stats_store" >/dev/null || fail "the committed run's line must say it ended at its commit"

# --- canaries in every free-text field never reach the line (AC-5) --------------------------------------
repoK="$work/repoK"
make_repo "$repoK"
ok "$repoK" s1 init canary-slug-zzz
jq -n '{request: "canary-request-zzz", answers: [], behavior: {current: [], new: ["canary-behavior-zzz"],
  examples: [{input: "a", output: "b"}, {input: "c", output: "d"}], non_goals: []},
  criteria: [{id: "AC-1", when: "a", then: "b", evidence: "automated", command: "make canary-cmd-zzz"}],
  scope_paths: ["a.txt"], out_of_scope: [], consent: {commit: "no", branch_target: "current"}, size: "quick"}' \
  | br "$repoK" s1 write spec >/dev/null || fail "write canary spec"
jq -n '{steps: [{id: "S-1", action: "canary-action-zzz", paths: ["a.txt"], done_when: "canary-done-zzz"}], checks: ["make canary-cmd-zzz"], invariants: [], stop_conditions: []}' \
  | br "$repoK" s1 write plan >/dev/null || fail "write canary plan"
ok "$repoK" s1 "${quick_approve[@]}"
ok "$repoK" s1 advance implement
printf 'canary\n' >"$repoK/a.txt"
apply_steps "$repoK"
ok "$repoK" s1 advance verify
ok "$repoK" s1 record check --cmd "make canary-cmd-zzz" --exit 0
ok "$repoK" s1 record review --low-risk "canary-reason-zzz"
ok "$repoK" s1 advance qa
jq -n '{rows: [{ac: "AC-1", evidence: "automated", command: "make canary-cmd-zzz", result: "pass"}], regression_scope: "canary-scope-zzz", not_covered: [], verdict: "QA PASS"}' \
  | br "$repoK" s1 write qa >/dev/null || fail "write canary qa"
ok "$repoK" s1 record qa --verdict "QA PASS"
ok "$repoK" s1 record ac AC-1 pass
ok "$repoK" s1 advance "done"
jq -e '.run_stats == "written"' <<<"$out" >/dev/null || fail "the canary run must be recorded: $out"
if grep -Fq zzz "$stats_store"; then fail "a free-text canary reached the store"; fi
if grep -Eq '[0-9a-f]{40}|"/|/home/|/tmp/' "$stats_store"; then fail "the store holds a commit id or an absolute path"; fi

# --- blocked, replaced, and unfinished runs add nothing (AC-7) --------------------------------------------
before=$(lines_of "$stats_store")
repoB="$work/repoB"
make_repo "$repoB"
ok "$repoB" s1 init blocked-run
jq '.phase = "blocked"' "$(sfile "$repoB")" >"$work/tmp.json" && cp "$work/tmp.json" "$(sfile "$repoB")"
stats "$repoB" --record | jq -e '.appended == 0 and .already == 0' >/dev/null || fail "a blocked run must not be recorded"
ok "$repoB" s1 init replaced-run --replace
stats "$repoB" --record | jq -e '.appended == 0' >/dev/null || fail "a replaced and an unfinished run must not be recorded"
stats "$repoB" --record --run "$(cat "$repoB/.b-agentic/active")" | jq -e '.appended == 0 and .skipped["not-done"] == 1' >/dev/null \
  || fail "an unfinished run named with --run must be refused"
[ "$(lines_of "$stats_store")" = "$before" ] || fail "no unfinished run may change the store"

# --- the flag file turns it off in any form, and nothing already stored is touched (AC-2) --------------------
before=$(lines_of "$stats_store")
for form in dangling-link file folder; do
  case $form in
    dangling-link) ln -s "$work/nowhere" "$stats_off" ;;
    file) : >"$stats_off" ;;
    folder) mkdir "$stats_off" ;;
  esac
  finish_run "$repoS" "off-$form"
  jq -e '.run_stats == "skipped:disabled"' <<<"$out" >/dev/null || fail "run-stats.off as $form must report skipped:disabled: $out"
  [ "$(lines_of "$stats_store")" = "$before" ] || fail "run-stats.off as $form must stop the append"
  if [ -d "$stats_off" ] && [ ! -L "$stats_off" ]; then rmdir "$stats_off"; else rm -f "$stats_off"; fi
done
stats "$repoS" --record | jq -e '.appended == 3' >/dev/null || fail "catch-up must add the three runs finished while it was off"
# With the flag present and no store at all, nothing is created.
mv "$stats_store" "$work/moved-store"
: >"$stats_off"
stats "$repoS" --record | jq -e '.appended == 0 and .skipped.disabled == 1' >/dev/null || fail "the off flag must be reported as disabled"
[ ! -e "$stats_store" ] || fail "the off flag must stop the store from being created"
stats "$repoS" | jq -e '.stores.claude.disabled == true' >/dev/null || fail "the report must show disabled"
rm -f "$stats_off"
mv "$work/moved-store" "$stats_store"

# --- an off flag created while the writer scans is still honored (AC-2) -------------------------------------------
store_py "$stats_store" "$stats_off" <<'PY' || fail "the off flag must be rechecked right before the write"
off = sys.argv[3]
real = b_run.stats_lines


def scan_then_opt_out(data):
    open(off, "w").close()
    return real(data)


b_run.stats_lines = scan_then_opt_out
size = os.path.getsize(store)
result = b_run.stats_append("claude", block, {"repo": "a" * 16, "run": "b" * 16}, b'{"v":1}\n')
os.unlink(off)
assert result["status"] == "skipped" and result["reason"] == "disabled", result
assert os.path.getsize(store) == size, "a line was appended after the opt-out"
PY

# --- a short write is rolled back and an unterminated tail is ended, so no line is corrupted ----------------------
cp "$stats_store" "$work/store-backup"
store_py "$stats_store" <<'PY' || fail "a short write must leave the store as it was"
size = os.path.getsize(store)
real = os.write


def short(fd, data):
    return real(fd, data[: len(data) // 2])


os.write = short
try:
    result = b_run.stats_append("claude", block, {"repo": "c" * 16, "run": "d" * 16}, b'{"v":1,"repo":"cccccccccccccccc"}\n')
finally:
    os.write = real
assert result["status"] == "skipped" and result["reason"] == "short-write", result
assert os.path.getsize(store) == size, "a partial line was left behind"
PY
printf '{"v":1,"repo":"unterminated' >>"$stats_store"
store_py "$stats_store" <<'PY' || fail "an unterminated tail must be ended before the next line"
line = b'{"v":1,"repo":"eeeeeeeeeeeeeeee","run":"ffffffffffffffff"}\n'
result = b_run.stats_append("claude", block, {"repo": "e" * 16, "run": "f" * 16}, line)
assert result["status"] == "written", result
last = open(store, "rb").read().split(b"\n")[-2] + b"\n"
assert last == line, last
PY
cp "$work/store-backup" "$stats_store"
chmod 600 "$stats_store"
stats "$repoS" --record | jq -e '.appended == 0' >/dev/null || fail "everything is recorded, so catch-up must add nothing"

# --- unsafe stores are skipped, never repaired (AC-4) -------------------------------------------------------------------
count=$(lines_of "$stats_store")
finish_run "$repoS" third
[ "$(lines_of "$stats_store")" = $((count + 1)) ] || fail "a safe store must take the line"
chmod 644 "$stats_store"
finish_run "$repoS" fourth
jq -e '.run_stats == "skipped:store-loose-mode"' <<<"$out" >/dev/null || fail "a loose mode must be named: $out"
[ "$(mode_of "$stats_store")" = 644 ] || fail "a loose mode must be left as found"
chmod 600 "$stats_store"
mv "$stats_store" "$work/real-store"
ln -s "$work/real-store" "$stats_store"
stats "$repoS" --record | jq -e '.appended == 0 and (.skipped | length) == 1' >/dev/null || fail "a symlinked store must be skipped"
[ "$(lines_of "$work/real-store")" = $((count + 1)) ] || fail "nothing may be appended through a symlinked store"
rm -f "$stats_store"
mv "$work/real-store" "$stats_store"
ln "$stats_store" "$work/hard-link"
stats "$repoS" --record | jq -e '.appended == 0 and .skipped["store-not-plain"] == 1' >/dev/null || fail "a hard-linked store must be skipped"
rm -f "$work/hard-link"
mv "$stats_store" "$work/real-store"
mkdir "$stats_store"
stats "$repoS" --record | jq -e '.appended == 0 and (.skipped | length) == 1' >/dev/null || fail "a folder at the store path must be skipped"
rmdir "$stats_store"
mkfifo "$stats_store"
stats "$repoS" | jq -e '.stores.claude.exists == false' >/dev/null || fail "a FIFO at the store path must be reported without hanging"
stats "$repoS" --record | jq -e '.appended == 0 and (.skipped | length) == 1' >/dev/null || fail "a FIFO at the store path must be skipped without hanging"
rm -f "$stats_store"
mv "$work/real-store" "$stats_store"
stats "$repoS" --record | jq -e '.appended == 1' >/dev/null || fail "the fourth run must be recorded once the store is safe"
# A store at its size cap takes no line.
store_py "$stats_store" <<'PY' || fail "a store at its size cap must take no line"
capped = dict(block)
capped["max_file"] = os.path.getsize(store) + 10
result = b_run.stats_append("claude", capped, {"repo": "1" * 16, "run": "2" * 16}, b'{"v":1,"repo":"1111111111111111"}\n')
assert result["status"] == "skipped" and result["reason"] == "store-full", result
PY

# --- a malformed line is counted, never fatal ------------------------------------------------------------------------------
printf 'not json\n{"v":1}\n' >>"$stats_store"
stats "$repoS" | jq -e '.stores.claude.malformed == 2' >/dev/null || fail "malformed lines must be counted"
cp "$work/store-backup" "$work/store-clean"
python3 -I -B - "$stats_store" "$work/store-clean" <<'PY'
import sys

keep = [line for line in open(sys.argv[1], "rb").read().split(b"\n") if line.startswith(b'{"v":1,"repo":"') and len(line) > 40]
open(sys.argv[1], "wb").write(b"\n".join(keep) + b"\n")
PY
chmod 600 "$stats_store"

# --- two worktrees finishing same-day, same-slug runs keep both lines ---------------------------------------------
git -C "$repoS" worktree add -q "$work/wtS" -b wts
before=$(lines_of "$stats_store")
finish_run "$work/wtS" shared-slug
jq -e '.run_stats == "written"' <<<"$out" >/dev/null || fail "the worktree run must be recorded: $out"
finish_run "$repoS" shared-slug
jq -e '.run_stats == "written"' <<<"$out" >/dev/null || fail "a same-slug run in another worktree must not be dropped as stored: $out"
[ "$(lines_of "$stats_store")" = $((before + 2)) ] || fail "two same-slug runs of one repository must leave two lines"
stats "$work/wtS" | jq -e '.missing == 0' >/dev/null || fail "the worktree's run must count as recorded"

# --- a run's key does not depend on the repository's root commits (AC-1) ---------------------------------------------
# Merging unrelated history changes the repository key; the finished runs are still recorded, not written again.
before=$(lines_of "$stats_store")
stats "$repoS" | jq -e '.missing == 0' >/dev/null || fail "every finished run is recorded before the history changes"
branchS=$(git -C "$repoS" branch --show-current)
git -C "$repoS" switch -q --orphan unrelated
git -C "$repoS" commit -q --allow-empty -m "unrelated root"
git -C "$repoS" switch -q "$branchS"
git -C "$repoS" merge -q --allow-unrelated-histories -m "merge unrelated" unrelated
stats "$repoS" | jq -e '.missing == 0 and .repo != null' >/dev/null || fail "a new root commit must not make recorded runs missing"
stats "$repoS" --record | jq -e '.appended == 0' >/dev/null || fail "a new root commit must not write recorded runs again"
[ "$(lines_of "$stats_store")" = "$before" ] || fail "the store must not grow when only the repository key changed"

# --- lines written with the earlier repository-based key still count as recorded (AC-2) -------------------------------
mv "$stats_store" "$work/new-keys-store"
store_py "$stats_store" "$repoC" <<'PY' || fail "a line with the earlier run key must count as recorded"
import json
import sys

repo = sys.argv[3]
root = b_run.Path(repo)
_run_id, state, folder = b_run._finished_runs(root)[0]
repo_key = b_run.stats_repo_key(root)
legacy = b_run.stats_legacy_run_key(repo_key, state)
record = b_run.stats_record(state, b_run.load_artifacts(folder), repo_key, b_run.load_schema())
record["run"] = legacy
line = (json.dumps(record, separators=(",", ":")) + "\n").encode()
os.close(os.open(store, os.O_CREAT | os.O_WRONLY, 0o600))
os.chmod(store, 0o600)
assert b_run.stats_append("claude", block, record, line)["status"] == "written"
PY
stats "$repoC" | jq -e '.missing == 0 and .repo_lines == 1' >/dev/null || fail "the report must recognise the earlier run key"

# --- a stored row stays counted when its run folder is gone, as after prune ------------------------------------------
store_py "$stats_store" "$repoC" <<'PY' || fail "a row whose run folder is gone must stay counted"
import json
import sys

root = b_run.Path(sys.argv[3])
_run_id, state, folder = b_run._finished_runs(root)[0]
repo_key = b_run.stats_repo_key(root)
record = b_run.stats_record(state, b_run.load_artifacts(folder), repo_key, b_run.load_schema())
record["run"] = "0123456789abcdef"
line = (json.dumps(record, separators=(",", ":")) + "\n").encode()
assert b_run.stats_append("claude", block, record, line)["status"] == "written"
PY
stats "$repoC" | jq -e '.repo_lines == 2 and .missing == 0' >/dev/null || fail "repo_lines must keep rows of pruned runs"
stats "$repoC" --record | jq -e '.appended == 0 and .already == 1' >/dev/null || fail "catch-up must not write a run recorded under the earlier key"
rm -f "$stats_store"
mv "$work/new-keys-store" "$stats_store"

# --- other repositories get their own key; the report never names a repository ---------------------------------------
repoS2="$work/repoS2"
make_repo "$repoS2"
git -C "$repoS2" commit -q --allow-empty -m "second root" --amend --date="2001-01-01T00:00:00" --no-edit
finish_run "$repoS2" other
jq -e '.run_stats == "written"' <<<"$out" >/dev/null || fail "a second repository must write its own line: $out"
stats "$repoS2" | jq -e '.repos >= 2 and .repo_lines == 1' >/dev/null || fail "two repositories must have distinct keys"

# --- concurrent catch-up against one new store: created once, each key written once (AC-6) ----------------------
mv "$stats_store" "$work/old-store"
pids=()
for repo in "$repoS" "$repoS2" "$repoC" "$repoK"; do
  stats "$repo" --record >"$work/race-$(basename "$repo").json" &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || fail "a concurrent catch-up failed"; done
[ "$(jq -s '[.[] | select(.created == true)] | length' "$work"/race-*.json)" = 1 ] || fail "the store must be created by exactly one writer"
[ "$(mode_of "$stats_store")" = 600 ] || fail "the raced store must be 0600"
jq -R -s -e 'split("\n") | map(select(length > 0) | fromjson? | .run // empty) | length == (unique | length)' "$stats_store" >/dev/null \
  || fail "a run key was written twice by concurrent writers"
rm -f "$stats_store"
mv "$work/old-store" "$stats_store"

# --- Pi writes beside the Pi install, from a run started under the Pi helper dir (AC-9) ---------------------------
mkdir -p "$pi_home"
chmod 700 "$pi_home"
repoP="$work/repoP"
make_repo "$repoP"
pi_ok() { B_AGENTIC_HELPER_DIR="$pi_dir" ok "$@"; }
before=$(lines_of "$stats_store")
pi_ok "$repoP" s1 init pi-run
quick_spec a.txt no 1 | br "$repoP" s1 write spec >/dev/null || fail "write pi spec"
plan_json | br "$repoP" s1 write plan >/dev/null || fail "write pi plan"
pi_ok "$repoP" s1 "${quick_approve[@]}"
pi_ok "$repoP" s1 advance implement
printf 'pi\n' >"$repoP/a.txt"
pi_ok "$repoP" s1 record step S-1
pi_ok "$repoP" s1 advance verify
pi_ok "$repoP" s1 record check --cmd "make test" --exit 0
pi_ok "$repoP" s1 record review --low-risk "one-line change, no trigger"
pi_ok "$repoP" s1 advance qa
write_qa "$repoP" 1 "QA PASS" pass
pi_ok "$repoP" s1 record qa --verdict "QA PASS"
pi_ok "$repoP" s1 record ac AC-1 pass
pi_ok "$repoP" s1 advance "done"
jq -e '.run_stats == "written" and (.notice | contains("~/.pi/agent/b-agentic/run-stats.jsonl"))' <<<"$out" >/dev/null \
  || fail "a Pi run must write its own store and name it: $out"
[ "$(lines_of "$stats_store")" = "$before" ] || fail "the Pi runtime must not touch the Claude Code store"
[ "$(mode_of "$pi_home/run-stats.jsonl")" = 600 ] || fail "the Pi store must be 0600"
jq -e '.runtime == "pi"' "$pi_home/run-stats.jsonl" >/dev/null || fail "a Pi line records runtime pi"
# A catch-up writes only its own runtime's runs: none of the Claude Code runs reach the Pi store.
B_AGENTIC_HELPER_DIR="$pi_dir" stats "$repoS" --record | jq -e '.appended == 0 and .skipped["other-runtime"] > 0' >/dev/null \
  || fail "a Pi catch-up must skip the Claude Code runs of a repository"
B_AGENTIC_HELPER_DIR="$pi_dir" stats "$repoP" --record | jq -e '.appended == 0 and .already == 1' >/dev/null || fail "the Pi run is already recorded"
for named in "$repoS/.b-agentic/runs"/*; do break; done
B_AGENTIC_HELPER_DIR="$pi_dir" stats "$repoS" --record --run "$(basename "$named")" | jq -e '.appended == 0 and .skipped["other-runtime"] == 1' >/dev/null \
  || fail "a named catch-up through the other runtime must not write a Claude Code run"
[ "$(lines_of "$pi_home/run-stats.jsonl")" = 1 ] || fail "the Pi store must hold only the Pi run"

# --- a shallow clone has no stable repository key: nothing is keyed, so deepening it cannot duplicate a run -------------
git clone -q --depth 1 "file://$repoS" "$work/shallowS"
stats "$work/shallowS" | jq -e '.repo == null and .missing == 0' >/dev/null || fail "a shallow clone must have no repository key"
stats "$work/shallowS" --record | jq -e '.appended == 0 and .skipped["no-repo-key"] == 1' >/dev/null || fail "a shallow clone must record nothing"

# --- phase durations come from the history timestamps, which end in Z ------------------------------------------------------
jq -e '.dur_s | length > 0' <(head -1 "$stats_store") >/dev/null || fail "a recorded line must carry phase durations"
python3 -I -B - "$run_cli" <<'PY' || fail "durations must be read from timestamps that end in Z"
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("b_run", sys.argv[1])
b_run = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b_run)
history = [
    {"at": "2026-11-25T09:00:00.000Z", "to": "clarify"},
    {"at": "2026-11-25T09:00:10.000Z", "to": "approved"},
    {"at": "2026-11-25T09:01:10.500Z", "to": "implement"},
]
per_phase, total = b_run._history_seconds(history)
assert per_phase == {"clarify": 10, "approved": 60} and total == 70, (per_phase, total)
PY

# --- started_at keeps stats_run_key stable when history truncation drops the init entry -------------------------------
python3 -I -B - "$run_cli" <<'PY' || fail "_run_started must prefer started_at and keep untruncated keys identical"
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("b_run", sys.argv[1])
b_run = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b_run)

base = {"run_id": "20261126-demo", "history": [{"at": "2026-11-26T00:00:00.000Z", "op": "init"}]}
with_started = {**base, "started_at": "2026-11-26T00:00:00.000Z"}
assert b_run._run_started(with_started) == "2026-11-26T00:00:00.000Z"
assert b_run._run_started(base) == "2026-11-26T00:00:00.000Z"
assert b_run.stats_run_key(with_started) == b_run.stats_run_key(base)
assert b_run.stats_legacy_run_key("0" * 16, with_started) == b_run.stats_legacy_run_key("0" * 16, base)
truncated = {
    "run_id": "20261126-demo",
    "started_at": "2026-11-26T00:00:00.000Z",
    "history": [{"at": "2026-11-26T00:05:00.000Z", "op": "check"}],
}
assert b_run._run_started(truncated) == "2026-11-26T00:00:00.000Z"
assert b_run.stats_run_key(truncated) == b_run.stats_run_key(base)
for bad in ("not-a-date", "\ud800", "2026-11-26T00:00:00.001Z"):
    retained_conflict = {**base, "started_at": bad}
    assert b_run._run_started(retained_conflict) == "2026-11-26T00:00:00.000Z"
    assert b_run.stats_run_key(retained_conflict) == b_run.stats_run_key(base)
    assert b_run.stats_legacy_run_key("0" * 16, retained_conflict) == b_run.stats_legacy_run_key("0" * 16, base)
non_iso_init = {"run_id": "20261126-demo", "history_dropped": 0, "history": [{"at": "t", "op": "init"}]}
assert b_run._run_started({**non_iso_init, "started_at": "2026-11-26T00:00:00.001Z"}) == "t"
assert b_run.stats_run_key({**non_iso_init, "started_at": "2026-11-26T00:00:00.001Z"}) == b_run.stats_run_key(non_iso_init)
assert b_run.stats_legacy_run_key("0" * 16, {**non_iso_init, "started_at": "2026-11-26T00:00:00.001Z"}) == b_run.stats_legacy_run_key("0" * 16, non_iso_init)
assert b_run._is_valid_timestamp("0099-01-01T00:00:00Z") and not b_run._is_valid_timestamp("0000-01-01T00:00:00Z")
assert not b_run._is_valid_timestamp("2026-11-26T00:00:00.000000\u0661Z")
null_dropped_conflict = {**base, "history_dropped": None, "started_at": "2026-11-26T00:00:00.001Z"}
assert b_run._run_started(null_dropped_conflict) == "2026-11-26T00:00:00.000Z"
assert b_run.stats_run_key(null_dropped_conflict) == b_run.stats_run_key(base)
assert b_run.stats_legacy_run_key("0" * 16, null_dropped_conflict) == b_run.stats_legacy_run_key("0" * 16, base)
for bad in ("not-a-date", "\ud800", "", None, "2026-11-26T00:00:00.000000\u0661Z"):
    truncated_bad = {**truncated, "history_dropped": 1, "started_at": bad}
    try:
        b_run.stats_run_key(truncated_bad)
    except b_run.Invalid:
        pass
    else:
        raise AssertionError(f"invalid truncated started_at {bad!r} must raise Invalid")
PY

repoT="$work/repoT"
make_repo "$repoT"
finish_run "$repoT" trunc
jq -e '.run_stats == "written"' <<<"$out" >/dev/null || fail "finish_run for repoT must write its line: $out"
before=$(lines_of "$stats_store")
tmp=$(mktemp -p "$work")
# Retained init with invalid or conflicting started_at still preserves the known init key and never aborts or duplicates.
cp "$(sfile "$repoT")" "$work/repoT-clean.json"
for bad_val in '"not-a-date"' '"2026-11-26T00:00:00.001Z"'; do
  jq ".started_at = $bad_val" "$work/repoT-clean.json" >"$tmp" && cp "$tmp" "$(sfile "$repoT")"
  stats "$repoT" | jq -e '.missing == 0 and .repo_lines == 1' >/dev/null \
    || fail "retained init with $bad_val started_at must keep matching the recorded key"
  stats "$repoT" --record | jq -e '.appended == 0 and .already == 1' >/dev/null \
    || fail "stats --record with retained init and $bad_val started_at must not append a replacement line"
done
python3 -I -B - "$work/repoT-clean.json" "$(sfile "$repoT")" <<'PY'
import json, sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
data["started_at"] = "__SURROGATE__"
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    fh.write(json.dumps(data).replace('"__SURROGATE__"', '"\\ud800"'))
PY
stats "$repoT" | jq -e '.missing == 0 and .repo_lines == 1' >/dev/null \
  || fail "retained init with surrogate started_at must not abort stats report"
stats "$repoT" --record | jq -e '.appended == 0 and .already == 1' >/dev/null \
  || fail "stats --record with retained init and surrogate started_at must not append"
# Retained init with explicit history_dropped: null and conflicting started_at still preserves the known init key.
jq '.history_dropped = null | .started_at = "2026-11-26T00:00:00.001Z"' "$work/repoT-clean.json" >"$tmp" && cp "$tmp" "$(sfile "$repoT")"
stats "$repoT" | jq -e '.missing == 0 and .repo_lines == 1' >/dev/null \
  || fail "retained init with null history_dropped must keep matching the recorded key"
stats "$repoT" --record | jq -e '.appended == 0 and .already == 1' >/dev/null \
  || fail "stats --record with retained init and null history_dropped must not append"
# Truncated history with invalid, null, non-ASCII digit, or surrogate started_at must not abort report or append a replacement key.
for bad_trunc in '"not-a-date"' 'null' '"2026-11-26T00:00:00.000000\u0661Z"'; do
  jq ".history = .history[1:] | .history_dropped = 1 | .started_at = $bad_trunc" "$work/repoT-clean.json" >"$tmp" && cp "$tmp" "$(sfile "$repoT")"
  stats "$repoT" | jq -e '.ok == true and .finished_runs == 0' >/dev/null || fail "truncated $bad_trunc started_at must not abort stats report"
  stats "$repoT" --record | jq -e '.appended == 0 and .skipped["bad-record"] == 1' >/dev/null \
    || fail "truncated $bad_trunc started_at must be skipped as bad-record"
done
python3 -I -B - "$work/repoT-clean.json" "$(sfile "$repoT")" <<'PY'
import json, sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
data["history"] = data["history"][1:]
data["history_dropped"] = 1
data["started_at"] = "__SURROGATE__"
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    fh.write(json.dumps(data).replace('"__SURROGATE__"', '"\\ud800"'))
PY
stats "$repoT" | jq -e '.ok == true and .finished_runs == 0' >/dev/null || fail "truncated surrogate started_at must not abort stats report"
stats "$repoT" --record | jq -e '.appended == 0 and .skipped["bad-record"] == 1' >/dev/null \
  || fail "truncated surrogate started_at must be skipped as bad-record"
# Truncated history with valid started_at stays matched and never duplicates.
jq '.history = .history[1:] | .history_dropped = 1' "$work/repoT-clean.json" >"$tmp" && cp "$tmp" "$(sfile "$repoT")"
[ "$(jq -r '.started_at != .history[0].at' "$(sfile "$repoT")")" = true ] || fail "dropped init entry must leave a later history[0].at"
stats "$repoT" | jq -e '.missing == 0 and .repo_lines == 1' >/dev/null \
  || fail "a recorded run whose init entry was truncated must stay matched"
stats "$repoT" --record | jq -e '.appended == 0 and .already == 1' >/dev/null \
  || fail "catch-up must not append a duplicate line after history truncation"
[ "$(lines_of "$stats_store")" = "$before" ] || fail "store line count must not grow after history truncation"

# --- the kit version (ADR-036): read from install.json beside the running helpers, at init and at done ----------------
# Two helper copies laid out like install homes, one per runtime; the stores stay under the throwaway HOME.
kit_claude="$work/kit-claude/b-agentic"
kit_pi="$work/kit-pi/b-agentic"
for installed in "$kit_claude" "$kit_pi"; do
  mkdir -p "$installed/bin" "$installed/references"
  cp "$root"/claude/bin/*.mjs "$root/claude/bin/b_run.py" "$installed/bin/"
  cp "$root/references/artifacts.yaml" "$installed/references/"
done
kit_a=$(printf '%040d' 0 | tr 0 a)
kit_b=$(printf '%040d' 0 | tr 0 b)
kit_c=$(printf '%040d' 0 | tr 0 c)
# kit_json COMMIT DIRTY: the four fields, in key order.
kit_json() { jq -cnS --arg commit "$1" --argjson dirty "$2" '{kit_seq: 7, kit_date: "2026-11-20", kit_commit: $commit, kit_dirty: $dirty}'; }
# kit_set HOME TARGET COMMIT DIRTY: a valid install.json beside that copy's helpers.
kit_set() {
  rm -rf "$1/install.json"
  kit_json "$3" "$4" | jq --arg target "$2" '. + {schema: 1, target: $target}' >"$1/install.json"
}
# kit_break HOME STATE: put install.json into a state that must give no kit version.
kit_break() {
  local file="$1/install.json"
  kit_set "$1" claude "$kit_a" false
  case $2 in
    missing) rm -f "$file" ;;
    unreadable) chmod 000 "$file" ;;
    malformed) printf '{"target":' >"$file" ;;
    not-an-object) printf 'null\n' >"$file" ;;
    other-target) kit_set "$1" pi "$kit_a" false ;;
    partial) jq 'del(.kit_date)' "$file" >"$1/next.json" && mv "$1/next.json" "$file" ;;
    bad-value) jq '.kit_date = "2026-02-30"' "$file" >"$1/next.json" && mv "$1/next.json" "$file" ;;
    symlink) mv "$file" "$1/linked.json" && ln -s linked.json "$file" ;;
    oversized) python3 -I -B -c 'import json, sys; data = json.load(open(sys.argv[1])); data["pad"] = "x" * (1 << 20); json.dump(data, open(sys.argv[1], "w"))' "$file" ;;
    directory) rm -f "$file" && mkdir "$file" ;;
    fifo) rm -f "$file" && mkfifo "$file" ;;
  esac
}
kit_states=(missing malformed not-an-object other-target partial bad-value symlink oversized directory fifo)
# Root reads a mode-000 file, so that case means nothing for it.
if [ "$(id -u)" != 0 ]; then kit_states+=(unreadable); fi
# timed REPO ARGS...: the b-state CLI with a time limit, so a helper that waits on install.json fails the shard.
timed() {
  local repo=$1
  shift
  python3 -I -B - "$repo" "${js[@]}" "$cli" "$@" --owner s1 <<'PY'
import subprocess
import sys

try:
    done = subprocess.run(sys.argv[2:], cwd=sys.argv[1], timeout=30, stdin=subprocess.DEVNULL)
except subprocess.TimeoutExpired:
    print("b-state timed out", file=sys.stderr)
    sys.exit(124)
sys.exit(done.returncode)
PY
}
# kit_line [STORE]: the kit fields of the store's last line.
kit_line() { tail -n 1 "${1:-$stats_store}" | jq -cS '{kit_seq, kit_date, kit_commit, kit_dirty, kit_changed} | with_entries(select(.value != null))'; }
active_state() { printf '%s/.b-agentic/runs/%s/state.json' "$1" "$(cat "$1/.b-agentic/active")"; }
mv "$stats_store" "$work/pre-kit-store"

# Capture on Claude Code, and each kit_changed case (AC-5).
repoV="$work/repoV"
make_repo "$repoV"
kit_capture() { # SLUG INIT_COMMIT INIT_DIRTY DONE_COMMIT DONE_DIRTY CHANGED(true|false|none)
  local cli="$kit_claude/bin/b-state.mjs" state expected
  kit_set "$kit_claude" claude "$2" "$3"
  ready_run "$repoV" "$1"
  state=$(active_state "$repoV")
  [ "$(jq -cS '.kit' "$state")" = "$(jq -cnS --argjson init "$(kit_json "$2" "$3")" '{init: $init}')" ] || fail "init must save the version ($1): $(jq -c .kit "$state")"
  kit_set "$kit_claude" claude "$4" "$5"
  ok "$repoV" s1 advance "done"
  jq -e '.run_stats == "written"' <<<"$out" >/dev/null || fail "the kit run must be recorded ($1): $out"
  git -C "$repoV" commit -qam "run $1"
  [ "$(jq -cS '.kit.done' "$state")" = "$(kit_json "$4" "$5")" ] || fail "done must save the version ($1): $(jq -c .kit "$state")"
  expected=$(kit_json "$2" "$3")
  if [ "$6" != none ]; then expected=$(jq -cS --argjson changed "$6" '. + {kit_changed: $changed}' <<<"$expected"); fi
  [ "$(kit_line)" = "$expected" ] || fail "the line's kit fields ($1): $(kit_line), expected $expected"
}
kit_capture kit-same "$kit_a" false "$kit_a" false false
kit_capture kit-moved "$kit_a" false "$kit_b" false true
kit_capture kit-dirtied "$kit_a" false "$kit_a" true true
kit_capture kit-cleaned "$kit_a" true "$kit_a" false true
kit_capture kit-both-dirty "$kit_a" true "$kit_a" true none
kit_capture kit-dirty-moved "$kit_a" true "$kit_b" true true
[ "$(tail -n 1 "$stats_store" | wc -c | tr -d ' ')" -lt "$(jq .run_stats.max_line "$root/references/artifacts.yaml")" ] || fail "a line with the kit fields must stay under max_line"

# A catch-up takes the version from state.json, never from what is installed now (AC-7).
rm -f "$stats_store"
kit_set "$kit_claude" claude "$kit_c" false
(run_cli="$kit_claude/bin/b_run.py" && stats "$repoV" --record) | jq -e '.appended == 6' >/dev/null || fail "catch-up must record the six kit runs"
jq -s -e --arg c "$kit_c" 'length == 6 and all(.kit_seq == 7 and .kit_commit != $c and (has("kit_changed") or .kit_dirty))' "$stats_store" >/dev/null \
  || fail "catch-up must keep each run's own version: $(cat "$stats_store")"

# An older artifacts.yaml kept beside newer helpers has no kit fields: the line is written without them.
cp "$kit_claude/references/artifacts.yaml" "$work/kit-schema"
jq 'del(.run_stats.fields.kit_seq, .run_stats.fields.kit_date, .run_stats.fields.kit_commit, .run_stats.fields.kit_dirty, .run_stats.fields.kit_changed)' \
  "$work/kit-schema" >"$kit_claude/references/artifacts.yaml"
rm -f "$stats_store"
(run_cli="$kit_claude/bin/b_run.py" && stats "$repoV" --record) | jq -e '.appended == 6 and (.skipped | length) == 0' >/dev/null || fail "an older schema must not drop any run"
jq -s -e 'length == 6 and all(keys | any(startswith("kit_")) | not)' "$stats_store" >/dev/null || fail "an older schema must get no kit field: $(cat "$stats_store")"
cp "$work/kit-schema" "$kit_claude/references/artifacts.yaml"

# Pi: the same capture under the Pi helper folder, from install.json beside the Pi helpers (AC-5).
pi_kit_run() {
  local cli="$kit_pi/bin/b-state.mjs"
  make_repo "$work/repoVP"
  kit_set "$kit_pi" pi "$kit_a" false
  B_AGENTIC_HELPER_DIR="$pi_dir" ready_run "$work/repoVP" pi-kit
  B_AGENTIC_HELPER_DIR="$pi_dir" ok "$work/repoVP" s1 advance "done"
  jq -e '.run_stats == "written"' <<<"$out" >/dev/null || fail "the Pi kit run must be recorded: $out"
}
pi_kit_run
[ "$(kit_line "$pi_home/run-stats.jsonl")" = "$(kit_json "$kit_a" false | jq -cS '. + {kit_changed: false}')" ] || fail "the Pi line's kit fields: $(kit_line "$pi_home/run-stats.jsonl")"
jq -e '.kit.init == .kit.done and .runtime == "pi"' "$(active_state "$work/repoVP")" >/dev/null || fail "the Pi run's state must hold both versions"

# An install.json that gives no version never fails or stalls init (AC-6) ...
repoI="$work/repoI"
make_repo "$repoI"
kit_init_cases() {
  local cli="$kit_claude/bin/b-state.mjs" broken
  for broken in "${kit_states[@]}"; do
    kit_break "$kit_claude" "$broken"
    timed "$repoI" init "init-$broken" --replace >/dev/null || fail "init must succeed with a $broken install.json"
    jq -e '.phase == "clarify" and (has("kit") | not)' "$(active_state "$repoI")" >/dev/null || fail "a $broken install.json must give no version at init: $(jq -c .kit "$(active_state "$repoI")")"
  done
}
kit_init_cases
# ... or advance done: the run keeps its init version, and the line says nothing about a change.
repoD="$work/repoD"
make_repo "$repoD"
kit_done_cases() {
  local cli="$kit_claude/bin/b-state.mjs" broken state
  kit_set "$kit_claude" claude "$kit_a" false
  ready_run "$repoD" done-cases
  state=$(active_state "$repoD")
  cp -R "$repoD/.b-agentic" "$work/ready-run"
  for broken in "${kit_states[@]}"; do
    rm -rf "$repoD/.b-agentic" "$stats_store"
    cp -R "$work/ready-run" "$repoD/.b-agentic"
    kit_break "$kit_claude" "$broken"
    out=$(timed "$repoD" advance "done") || fail "advance done must succeed with a $broken install.json: $out"
    jq -e '.phase == "done" and .run_stats == "written"' <<<"$out" >/dev/null || fail "the run must finish and be recorded ($broken): $out"
    jq -e '(.kit | has("done") | not) and (.kit | has("init"))' "$state" >/dev/null || fail "a $broken install.json must give no version at done: $(jq -c .kit "$state")"
    [ "$(kit_line)" = "$(kit_json "$kit_a" false)" ] || fail "the line keeps only the init version ($broken): $(kit_line)"
  done
}
kit_done_cases

# A run that started without a version never takes one from done or from a later catch-up (AC-7).
repoO="$work/repoO"
make_repo "$repoO"
kit_old_run() {
  local cli="$kit_claude/bin/b-state.mjs"
  kit_break "$kit_claude" missing
  ready_run "$repoO" no-kit
  kit_set "$kit_claude" claude "$kit_a" false
  rm -f "$stats_store"
  ok "$repoO" s1 advance "done"
  jq -e '.run_stats == "written"' <<<"$out" >/dev/null || fail "a run without a version must be recorded: $out"
}
kit_old_run
state=$(active_state "$repoO")
[ "$(jq -cS '.kit' "$state")" = "$(jq -cnS --argjson at_done "$(kit_json "$kit_a" false)" '{"done": $at_done}')" ] || fail "only the done version is saved: $(jq -c .kit "$state")"
[ "$(kit_line)" = '{}' ] || fail "the line must not take the done version: $(kit_line)"
kit_catch_up() { # WHAT: record repoO again from an empty store; the line has no kit field.
  rm -f "$stats_store"
  (run_cli="$kit_claude/bin/b_run.py" && stats "$repoO" --record) | jq -e '.appended == 1 and (.skipped | length) == 0' >/dev/null || fail "catch-up must record the run ($1)"
  [ "$(kit_line)" = '{}' ] || fail "catch-up must add no kit field ($1): $(kit_line)"
}
kit_catch_up "done version only"
jq 'del(.kit)' "$state" >"$tmp" && cp "$tmp" "$state"
kit_catch_up "state from an earlier helper"
# A malformed version in state.json is refused by b-state and left out of the line, never a skipped run.
zero_seq='.kit = {init: {kit_seq: 0, kit_date: "2026-11-20", kit_commit: ("a" * 40), kit_dirty: false}}'
for edit in '.kit = {init: {kit_seq: 7}}' "$zero_seq" '.kit = []' '.kit = {init: "x", done: null}'; do
  jq "$edit" "$state" >"$tmp" && cp "$tmp" "$state"
  invalid "$repoO" s1 show
  kit_catch_up "$edit"
done

# The store check rejects each malformed kit value (AC-7).
store_py "$stats_store" <<'PY' || fail "stats_check must reject malformed kit values"
import json

record = json.loads(open(store, "rb").readline())
good = {"kit_seq": 7, "kit_date": "2026-11-20", "kit_commit": "a" * 40, "kit_dirty": False, "kit_changed": True}
schema = b_run.load_schema()
b_run.stats_check({**record, **good}, schema)
b_run.stats_check(record, schema)
bad = {
    "kit_seq": ["7", -1, 0, True],
    "kit_date": ["2026-02-30", "20261120", 20261120],
    "kit_commit": ["a" * 39, "A" * 40, "/home/someone"],
    "kit_dirty": [0, "false"],
    "kit_changed": [1, "yes"],
}
for name, values in bad.items():
    for value in values:
        try:
            b_run.stats_check({**record, **good, name: value}, schema)
        except b_run.Invalid:
            continue
        raise AssertionError(f"{name}={value!r} was accepted")
version = {name: good[name] for name in good if name != "kit_changed"}
b_run.stats_check({**record, **version}, schema)
partial = [{name: value for name, value in good.items() if name != dropped} for dropped in version]
partial += [{name: good[name]} for name in good]
for fields in partial:
    try:
        b_run.stats_check({**record, **fields}, schema)
    except b_run.Invalid:
        continue
    raise AssertionError(f"an incomplete kit group was accepted: {sorted(fields)}")
PY
bad_line=$(tail -n 1 "$stats_store" | jq -c '. + {kit_commit: "not-a-commit"}')
printf '%s\n' "$bad_line" >>"$stats_store"
stats "$repoO" | jq -e '.stores.claude.malformed == 1 and .stores.claude.valid == 1' >/dev/null || fail "a line with a malformed kit value must be counted as malformed"
rm -f "$stats_store"
mv "$work/pre-kit-store" "$stats_store"

# --- invalid use -------------------------------------------------------------------------------------------------------------------
if stats "$repoS" --run "20260101-x" 2>/dev/null; then fail "--run without --record must be refused"; fi
if stats "$repoS" --apply 2>/dev/null; then fail "stats must refuse --apply"; fi
