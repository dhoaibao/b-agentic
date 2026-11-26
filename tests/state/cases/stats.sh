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

# --- a blocker whose escape stage is not known is counted under its own key, in a store of its own -------------
repoU="$work/repoU"
unknown_home="$work/unknown-home"
unknown_store="$unknown_home/.claude/b-agentic/run-stats.jsonl"
mkdir -p "$unknown_home/.claude/b-agentic"
chmod 700 "$unknown_home/.claude/b-agentic"
make_repo "$repoU"
HOME="$unknown_home" ready_run "$repoU" unknown-stage
jq -n '{items: [{id: "R1-1", source: "review", summary: "x", disposition: "rejected", reason: "y", kind: "blocker",
  blocker_class: "unexpected path", escaped_from: "unknown"}]}' \
  | HOME="$unknown_home" br "$repoU" s1 write followups >/dev/null || fail "write followups (unknown stage)"
HOME="$unknown_home" ok "$repoU" s1 advance "done"
jq -e '.run_stats == "written"' <<<"$out" >/dev/null || fail "the run with an unknown stage must be recorded: $out"
jq -e '.escaped_from == {unknown: 1} and .blockers.by_class == {"unexpected path": 1}' "$unknown_store" >/dev/null \
  || fail "the line must count the unknown stage apart from unclassified: $(cat "$unknown_store")"
[ "$(wc -c <"$unknown_store")" -le 2048 ] || fail "the line must stay within max_line"
out=$(HOME="$unknown_home" stats "$repoU") || fail "stats over the unknown-stage store failed"
jq -e '.stores.claude | .valid == 1 and .malformed == 0' <<<"$out" >/dev/null || fail "the line must pass the line checks: $out"

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

# --- the summary (ADR-035): numbers only from both stores, over synthetic lines in a HOME of its own ---------------
sum_home="$work/sum-home"
sum_claude="$sum_home/.claude/b-agentic"
sum_pi="$sum_home/.pi/agent/b-agentic"
cat >"$work/summary_lines.py" <<'PY'
import json


def line(run, **over):
    """One valid store line; run is a short number turned into a 16-hex key."""
    record = {
        "v": 1, "repo": "1" * 16, "run": f"{run:016x}", "date": "2026-11-25", "runtime": "claude",
        "size": "full", "end": "commit", "steps": 3, "criteria": 2, "scope_paths": 4,
        "worker_steps": 0, "parallel_steps": 0, "dur_s": {"implement": 100, "review": 50}, "total_s": 150,
        "history_complete": True,
        "review": {"rounds": 1, "by_gate": {"codex": 1}, "low_risk": False, "verdict": "READY FOR PR"},
        "qa": {"rounds": 1, "verdict": "QA PASS"}, "fix_rounds": 0, "blocked_count": 0,
        "checks_total": 5, "checks_failed": 0, "commits": 1, "ac": {"pass": 2},
        "blockers": {"review": 0, "qa": 0, "by_class": {}}, "escaped_from": {},
    }
    record.update(over)
    return {name: value for name, value in record.items() if value is not None}


def kit(seq, day, commit, dirty=False, changed=False):
    return {"kit_seq": seq, "kit_date": day, "kit_commit": commit * 40, "kit_dirty": dirty, "kit_changed": changed}


def write(path, rows):
    schema = b_run.load_schema()
    with open(path, "wb") as handle:
        for row in rows:
            if isinstance(row, dict):
                b_run.stats_check(row, schema)
                row = json.dumps(row).encode()
            handle.write(row + b"\n")
PY
# sum_store: write the claude and pi stores of the summary HOME from the Python on stdin.
sum_store() {
  rm -rf "$sum_home"
  mkdir -p "$sum_claude" "$sum_pi"
  { printf 'exec(open(%s).read())\npi_store = %s\n' "'$work/summary_lines.py'" "'$sum_pi/run-stats.jsonl'" && cat; } \
    | store_py "$sum_claude/run-stats.jsonl" || fail "writing the synthetic stores"
}
# summary [ARGS...]: the summary from repoS over the summary HOME, in $out.
summary() { out=$(HOME="$sum_home" stats "$repoS" --summary "$@") || fail "stats --summary $* failed: $out"; }
# has JQ MESSAGE: the last summary satisfies the filter.
has() { jq -e "$1" <<<"$out" >/dev/null || fail "$2: $(jq -c . <<<"$out" | head -c 3000)"; }
# tree_of DIR: every entry with its type, mode, size, time and content, to show that nothing changed.
tree_of() {
  python3 -I -B - "$1" <<'PY'
import hashlib, os, stat, sys

for folder, folders, files in os.walk(sys.argv[1]):
    folders.sort()
    for name in sorted(folders + files):
        path = os.path.join(folder, name)
        info = os.lstat(path)
        content = ""
        if stat.S_ISREG(info.st_mode) and info.st_mode & 0o400:
            content = hashlib.sha256(open(path, "rb").read()).hexdigest()
        print(path, oct(info.st_mode), info.st_size, info.st_mtime_ns, content)
PY
}

# Totals, quantiles, histograms and keyed sums over both stores, broken down three ways in three outputs (AC-1).
sum_store <<'PY'
write(store, [
    line(1, review={"rounds": 1, "by_gate": {"codex": 1}, "low_risk": False, "verdict": "READY FOR PR"},
         **kit(10, "2026-11-20", "a")),
    line(2, total_s=200, steps=5, dur_s={"implement": 150, "review": 50}, size="quick", end="qa", commits=0,
         review={"rounds": 1, "by_gate": {}, "low_risk": True}, **kit(10, "2026-11-20", "a", changed=True)),
    line(3, total_s=300, dur_s={"implement": 200, "verify": 100}, fix_rounds=2, checks_total=20, checks_failed=3,
         review={"rounds": 2, "by_gate": {"codex": 1, "reviewer": 1}, "low_risk": False, "verdict": "NEEDS FIXES"},
         ac={"pass": 3, "fail": 1}, blockers={"review": 2, "qa": 1, "by_class": {"data-integrity loss": 3}},
         escaped_from={"plan": 2, "spec": 1}, **kit(11, "2026-11-22", "b", dirty=True)),
])
write(pi_store, [
    line(4, runtime="pi", repo="2" * 16, total_s=400, dur_s={"review": 400},
         review={"rounds": 12, "by_gate": {"reviewer": 12}, "low_risk": False, "verdict": "READY FOR PR"},
         **kit(7, "2026-11-21", "c")),
])
PY
summary
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "the summary must be one compact line"
has '.ok and .since == null and (.repo | test("^[0-9a-f]{16}$")) and .before_since == 0' "the summary's header"
has '(keys | sort) == ["all","before_since","by_runtime","ok","repo","since","stores"]' "the summary's top-level keys"
has '.stores.claude == {status: "read", disabled: false, truncated: false, lines: 3, counted: 3, malformed: 0, unknown_version: 0, duplicates: 0}' "the claude store entry"
has '.stores.pi.status == "read" and .stores.pi.counted == 1' "the pi store entry"
has '.all.runs == 4 and .all.counts.review_rounds == {n: 4, sum: 16, min: 1, p50: 1, p90: 12, max: 12, values: {"1": 2, "2": 1, "10+": 1}}' "review rounds"
has '.all.counts | (keys | length) == 14 and all(.n == 4)' "every stored count has a value per run"
has '[.all.counts | .steps, .criteria, .scope_paths, .worker_steps, .parallel_steps, .qa_rounds, .fix_rounds, .blocked_count, .checks_total, .checks_failed, .commits, .review_blockers, .qa_blockers | .sum] == [14,8,16,0,0,4,2,0,35,3,3,2,1]' "count sums"
has '.all.counts.checks_total == {n: 4, sum: 35, min: 5, p50: 5, p90: 20, max: 20, values: {"5": 3, "10+": 1}}' "checks histogram"
has '.all.seconds.total == {n: 4, sum: 1050, min: 150, p50: 200, p90: 400, max: 400}' "total seconds"
has '.all.seconds.implement == {n: 3, sum: 450, min: 100, p50: 150, p90: 200, max: 200}' "a phase counts only the runs that were in it"
has '.all.seconds.review == {n: 3, sum: 500, min: 50, p50: 50, p90: 400, max: 400} and .all.seconds.fix == {n: 0, sum: 0}' "a phase no run was in has no quantile"
has '.all.sums == {size: {full: 3, quick: 1}, end: {commit: 3, qa: 1}, review_gate: {codex: 2, reviewer: 13},
  review_verdict: {"NEEDS FIXES": 1, "READY FOR PR": 2}, review_low_risk: {"false": 3, "true": 1}, qa_verdict: {"QA PASS": 4},
  ac: {fail: 1, pass: 9}, blockers_by_class: {"data-integrity loss": 3}, escaped_from: {plan: 2, spec: 1},
  kit_dirty: {"false": 3, "true": 1}, kit_changed: {"false": 3, "true": 1}}' "keyed sums"
has '.all.missing == {runtime: 0, kit: 0, kit_unchecked: 0, kit_changed: 0, review_verdict: 1, qa_verdict: 0, durations: 0}' "missing counts"
has '(.by_runtime | keys) == ["claude","pi"] and .by_runtime.claude.runs == 3 and .by_runtime.claude.counts.review_rounds.sum == 4 and .by_runtime.pi.counts.review_rounds.sum == 12' "by runtime"
header=$(jq -cS '{ok, since, repo, stores, before_since}' <<<"$out")
pi_block=$(jq -c .by_runtime.pi <<<"$out")
summary --section repo
has '(keys | sort) == ["before_since","by_repo","ok","repo","since","stores"]' "the repository section's keys"
[ "$(jq -cS '{ok, since, repo, stores, before_since}' <<<"$out")" = "$header" ] || fail "the repository section has the same header"
has '[.by_repo.groups[] | [.repo, .runs]] == [["1111111111111111", 3], ["2222222222222222", 1]] and .by_repo.omitted_groups == 0 and .by_repo.omitted_runs == 0' "by repository"
has "(.by_repo.groups[1] | del(.repo)) == $pi_block" "a group's block holds exactly its runs"
summary --section kit
has '(keys | sort) == ["before_since","by_kit","ok","repo","since","stores"]' "the kit section's keys"
[ "$(jq -cS '{ok, since, repo, stores, before_since}' <<<"$out")" = "$header" ] || fail "the kit section has the same header"
has '[.by_kit.groups[] | [.runtime, .kit_seq, .kit_date, .kit_commit[:1], .runs]] == [["claude",11,"2026-11-22","b",1],["pi",7,"2026-11-21","c",1],["claude",10,"2026-11-20","a",2]]' "by kit version, newest first"
has '.by_kit.without_kit.runs == 0 and .by_kit.omitted_groups == 0 and .by_kit.groups[2].seconds.total.sum == 350' "kit groups hold their own numbers"

# Lines that cannot be counted are counted per store and reach no block (AC-2).
sum_store <<'PY'
other = line(9, v=2)
other["new_field"] = "x"
write(store, [
    line(1, steps=1), b"not json", b'{"v":1}', b"[" * 100000, b'"text"',
    json.dumps(other).encode(), json.dumps({"v": 0}).encode(), line(1, steps=100), line(2, steps=2),
])
write(pi_store, [line(2, runtime="pi", steps=100), line(3, runtime="pi", steps=4)])
PY
summary
has '.stores.claude | .lines == 9 and .counted == 2 and .malformed == 4 and .unknown_version == 2 and .duplicates == 1' "the claude store's left-out lines"
has '.stores.pi | .lines == 2 and .counted == 1 and .malformed == 0 and .duplicates == 1' "a key repeated across stores counts once, claude first"
has '.all.runs == 3 and .all.counts.steps.sum == 7 and .by_runtime.claude.runs == 2 and .by_runtime.pi.runs == 1' "only the first line of a key is used"

# A value a line does not have is counted as missing, never read as zero or guessed (AC-3).
sum_store <<'PY'
legacy = line(1, runtime=None, history_complete=False, dur_s={"implement": 999, "fix": 999}, total_s=999,
              review={"rounds": 1, "by_gate": {}, "low_risk": True}, qa={"rounds": 1},
              blockers={"review": 2, "qa": 0, "by_class": {"unclassified": 2}}, escaped_from={"unclassified": 2})
both_dirty = kit(10, "2026-11-20", "a", dirty=True)
del both_dirty["kit_changed"]
write(store, [legacy, line(2, **both_dirty)])
write(pi_store, [])
PY
summary
has '.all.runs == 2 and .by_runtime.unknown.runs == 1 and .by_runtime.claude.runs == 1' "a line without a runtime is not given the store's"
has '.all.missing == {runtime: 1, kit: 1, kit_unchecked: 0, kit_changed: 2, review_verdict: 1, qa_verdict: 1, durations: 1}' "every gap is counted"
has '.all.seconds.total == {n: 1, sum: 150, min: 150, p50: 150, p90: 150, max: 150} and .all.seconds.fix == {n: 0, sum: 0} and .all.seconds.implement.sum == 100' "an incomplete history gives no seconds"
has '.all.sums.blockers_by_class == {unclassified: 2} and .all.sums.escaped_from == {unclassified: 2} and .all.sums.kit_changed == {} and .all.sums.kit_dirty == {"true": 1}' "unclassified stays its own key"
summary --section kit
has '.by_kit.without_kit.runs == 1 and (.by_kit.groups | length) == 1' "a line without a kit version is grouped apart"

# An older artifacts.yaml kept beside newer helpers: kit fields are set aside, the line still counts (AC-4).
sum_store <<'PY'
write(store, [line(1, **kit(10, "2026-11-20", "a")), line(2)])
write(pi_store, [])
PY
jq 'del(.run_stats.fields.kit_seq, .run_stats.fields.kit_date, .run_stats.fields.kit_commit, .run_stats.fields.kit_dirty, .run_stats.fields.kit_changed)' \
  "$work/kit-schema" >"$kit_claude/references/artifacts.yaml"
out=$(cd "$repoS" && HOME="$sum_home" python3 -I -B "$kit_claude/bin/b_run.py" stats --summary) || fail "the summary under an older schema failed"
has '.stores.claude.malformed == 0 and .stores.claude.counted == 2 and .all.runs == 2' "an older schema must not drop a line"
has '.all.missing.kit_unchecked == 1 and .all.missing.kit == 2 and .all.sums.kit_dirty == {}' "set-aside kit fields are counted and unused"
out=$(cd "$repoS" && HOME="$sum_home" python3 -I -B "$kit_claude/bin/b_run.py" stats --summary --section kit) || fail "the kit section under an older schema failed"
cp "$work/kit-schema" "$kit_claude/references/artifacts.yaml"
has '.by_kit.groups == [] and .by_kit.without_kit.runs == 2 and .by_kit.without_kit.missing.kit_unchecked == 1' "set-aside kit fields make no kit group"

# Every store state is reported, nothing is waited on or written, and no run folder is read (AC-5).
sum_state() { # STATE EXPECTED_STATUS: put the claude store into STATE and summarize it.
  local store="$sum_claude/run-stats.jsonl" before
  sum_store <<'PY'
write(store, [line(1)])
write(pi_store, [line(2, runtime="pi")])
PY
  case $1 in
    plain) ;;
    no-home) rm -rf "$sum_home/.claude" ;;
    no-store) rm -f "$store" ;;
    disabled) : >"$sum_claude/run-stats.off" ;;
    symlink) mv "$store" "$sum_claude/linked" && ln -s linked "$store" ;;
    directory) rm -f "$store" && mkdir "$store" ;;
    fifo) rm -f "$store" && mkfifo "$store" ;;
    linked-home) mv "$sum_claude" "$sum_home/.claude/real" && ln -s real "$sum_claude" ;;
    unreadable) chmod 000 "$store" ;;
    oversized) python3 -I -B -c 'import sys; open(sys.argv[1], "ab").write(b"x" * int(sys.argv[2]))' "$store" "$(jq .run_stats.max_file "$root/references/artifacts.yaml")" ;;
  esac
  before=$(tree_of "$sum_home")
  summary
  [ "$(tree_of "$sum_home")" = "$before" ] || fail "the summary must change nothing under HOME ($1)"
  has ".stores.claude.status == \"$2\" and .stores.pi.counted == 1" "the store state ($1)"
}
sum_state plain read
has '.stores.claude.disabled == false and .all.runs == 2' "a plain store"
sum_state no-home absent
sum_state no-store absent
has '.stores.claude.lines == 0 and .all.runs == 1 and .all.seconds.total.n == 1' "an absent store adds nothing"
sum_state disabled read
has '.stores.claude.disabled and .stores.claude.counted == 1' "the off flag is reported and the stored lines are read"
sum_state symlink not-regular
sum_state directory not-regular
sum_state fifo not-regular
sum_state linked-home unreadable
if [ "$(id -u)" != 0 ]; then sum_state unreadable unreadable; fi
sum_state oversized read
has '.stores.claude | .truncated and .counted == 1 and .malformed == 1' "an oversized store is cut at max_file"
# A failure after the open: the summary reports that store unreadable and keeps the other; plain stats still fails.
# faulty CALL ARGS...: stats from repoS with os.CALL failing on the claude store only; $out, and stderr in sum-err.
faulty() {
  out=$(cd "$repoS" && HOME="$sum_home" python3 -I -B - "$root/claude/bin/b_run.py" "$sum_claude/run-stats.jsonl" "$@" 2>"$work/sum-err" <<'PY'
import errno
import importlib.util
import os
import sys

cli, store, call, args = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
spec = importlib.util.spec_from_file_location("b_run", cli)
b_run = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b_run)
target = (os.stat(store).st_dev, os.stat(store).st_ino)
real_fstat, real_call = os.fstat, getattr(os, call)


def failing(fd, *rest):
    info = real_fstat(fd)
    if (info.st_dev, info.st_ino) == target:
        raise OSError(errno.EIO, "injected read failure")
    return real_call(fd, *rest)


setattr(os, call, failing)
sys.exit(b_run.main(["stats", *args]))
PY
  )
}
sum_state disabled read
for call in fstat pread; do
  faulty "$call" --summary || fail "a failing $call must not stop the summary: $(cat "$work/sum-err")"
  has '.stores.claude == {status: "unreadable", disabled: true, truncated: false, lines: 0, counted: 0, malformed: 0, unknown_version: 0, duplicates: 0} and .stores.pi.counted == 1 and .all.runs == 1' "a failing $call makes one store unreadable"
  rc=0
  faulty "$call" || rc=$?
  if [ "$rc" -ne 2 ] || [ -n "$out" ] || ! grep -qF 'injected read failure' "$work/sum-err"; then
    fail "plain stats must still fail on a failing $call: rc=$rc $(cat "$work/sum-err")"
  fi
done
sum_state plain read
first=$out
make_repo "$work/repoSum"
printf 'x\n' >"$work/repoSum/b.txt"
git -C "$work/repoSum" add b.txt
git -C "$work/repoSum" commit -qm second --amend
mkdir -p "$work/repoSum/.b-agentic"
printf 'not a folder\n' >"$work/repoSum/.b-agentic/runs"
out=$(HOME="$sum_home" stats "$work/repoSum" --summary) || fail "the summary must not read run folders"
[ "$(jq -cS 'del(.repo)' <<<"$out")" = "$(jq -cS 'del(.repo)' <<<"$first")" ] || fail "two repositories must differ only in repo"
[ "$(jq -r .repo <<<"$out")" != "$(jq -r .repo <<<"$first")" ] || fail "the second repository has its own key"

# --since keeps the runs dated on or after the day, old lines included, and invalid use is refused (AC-6).
sum_store <<'PY'
write(store, [line(1, date="2026-11-10", runtime=None), line(2, date="2026-11-20"), line(3, date="2026-11-25")])
write(pi_store, [line(4, date="2026-11-19", runtime="pi")])
PY
summary --since 2026-11-20
has '.since == "2026-11-20" and .all.runs == 2 and .before_since == 2 and .stores.claude.counted == 2 and .stores.pi.counted == 0 and (.by_runtime | keys) == ["claude"]' "--since"
summary --since 2026-11-20 --section repo
has '.since == "2026-11-20" and .before_since == 2 and ([.by_repo.groups[].runs] | add) == 2' "--since with the repository section"
summary --section kit --since 2026-11-20
has '.since == "2026-11-20" and .before_since == 2 and .by_kit.without_kit.runs == 2' "--since with the kit section"
summary --since 2026-12-01
has '.all.runs == 0 and .before_since == 4 and .by_runtime == {} and .all.counts.steps == {n: 0, sum: 0, values: {}}' "an empty summary"
summary --since 2026-12-01 --section repo
has '.by_repo == {groups: [], omitted_groups: 0, omitted_runs: 0}' "an empty repository section"
summary --since 2026-12-01 --section kit
has '.by_kit.groups == [] and .by_kit.without_kit.runs == 0' "an empty kit section"
summary
has '.since == null and .all.runs == 4' "no --since keeps every line"
# bad_use ARGS...: exit 2 with exactly one line on stderr and nothing on stdout.
bad_use() {
  local rc=0
  out=$(HOME="$sum_home" stats "$repoS" "$@" 2>"$work/sum-err") || rc=$?
  [ "$rc" -eq 2 ] && [ -z "$out" ] && [ "$(lines_of "$work/sum-err")" = 1 ] || fail "invalid use must exit 2 with one line ($*): rc=$rc $(cat "$work/sum-err")"
}
for since in 2026-02-30 20261120 2026-11-2 '' '2026-11-20 ' ２０２６-11-20 yesterday; do
  bad_use --summary --since "$since"
done
bad_use --since 2026-11-01
bad_use --since 2026-11-01 --record
bad_use --summary --record
bad_use --summary --run 20260101-x
bad_use --summary --run ''
bad_use --summary --apply
for section in all runtime Repo ''; do
  bad_use --summary --section "$section"
done
bad_use --summary --section
bad_use --section repo
bad_use --section kit --record
bad_use --summary --section kit --record
python3 -I -B "$root/claude/bin/b_run.py" --help | grep -qF 'stats --summary [--since YYYY-MM-DD] [--section repo|kit]' || fail "help must name the summary and its sections"

# Each output is bounded, under what an agent's shell tool shows, whatever the store holds (AC-7).
# sum_big ROUNDS: every bucket, key and verdict, over 8 repositories and 18 kit versions, and as many lines with
# neither a runtime nor a kit version, ROUNDS times.
sum_big() {
  sum_store <<PY
schema = b_run.load_schema()
fields = schema["run_stats"]["fields"]
classes = [*schema["enums"]["blocker_class"], "unclassified"]
stages = [*schema["enums"]["escape_stage"], "unclassified"]
rows, number = {"claude": [], "pi": []}, 0
for _ in range($1):
    for index in range(396):
        number += 1
        runtime = "pi" if index % 2 else "claude"
        # kit_seq and kit_date repeat across versions, so the order needs both.
        version = index % 9
        value = index % 11 if index % 11 < 10 else 10**9
        counts = {name: value for name in (
            "steps", "criteria", "scope_paths", "worker_steps", "parallel_steps", "fix_rounds", "blocked_count",
            "checks_total", "checks_failed", "commits")}
        rows[runtime].append(line(
            number, runtime=runtime, repo=f"{index % 8:016x}", size=("quick", "full")[index % 2],
            end=("commit", "qa")[index % 2], dur_s={phase: 10**9 for phase in fields["dur_s"]["keys"]}, total_s=10**9,
            review={"rounds": value, "by_gate": {"codex": 10**9, "reviewer": 10**9}, "low_risk": bool(index % 2),
                    "verdict": fields["review"]["fields"]["verdict"]["values"][index % 3]},
            qa={"rounds": value, "verdict": fields["qa"]["fields"]["verdict"]["values"][index % 3]},
            ac={name: 10**9 for name in fields["ac"]["keys"]},
            blockers={"review": value, "qa": value, "by_class": {name: 10**9 for name in classes}},
            escaped_from={name: 10**9 for name in stages},
            **counts, **kit(10**9 - version % 3, f"2026-11-{10 + version // 3:02d}", "abcdef012"[version], dirty=bool(index % 2), changed=bool(index % 4)),
        ))
        number += 1
        bare = {name: v for name, v in rows[runtime][-1].items() if not name.startswith("kit_") and name != "runtime"}
        rows[runtime].append({**bare, "run": f"{number:016x}"})
write(store, rows["claude"])
write(pi_store, rows["pi"])
PY
}
# bounded NAME: the last output stays under the bound.
bounded() {
  local size
  size=$(printf '%s' "$out" | wc -c | tr -d ' ')
  [ "$size" -lt 30000 ] || fail "$1 must stay under 30000 bytes: $size bytes"
}
for rounds in 1 2; do
  sum_big "$rounds"
  summary
  bounded "the default output ($rounds)"
  has ".all.runs == 792 * $rounds" "the big summary counts every run ($rounds)"
  has '(.all.counts.steps.values | keys) == ["0","1","10+","2","3","4","5","6","7","8","9"]' "every histogram bucket is used ($rounds)"
  has "(.by_runtime | keys) == [\"claude\",\"pi\",\"unknown\"] and .by_runtime.unknown.runs == 396 * $rounds" "three runtime blocks ($rounds)"
  summary --section repo
  bounded "the repository section ($rounds)"
  has "[.by_repo.groups[] | [.repo[-1:], .runs]] == [[\"0\", 100 * $rounds], [\"1\", 100 * $rounds], [\"2\", 100 * $rounds], [\"3\", 100 * $rounds], [\"4\", 98 * $rounds]]" "five repositories, most runs first ($rounds)"
  has ".by_repo.omitted_groups == 3 and .by_repo.omitted_runs == 294 * $rounds" "the repositories left out are counted ($rounds)"
  summary --section kit
  bounded "the kit section ($rounds)"
  has '[.by_kit.groups[] | [.runtime, .kit_seq, .kit_date, .kit_commit[:1]]] == [["pi",1000000000,"2026-11-12","0"],["claude",1000000000,"2026-11-12","0"],["pi",999999999,"2026-11-12","1"],["claude",999999999,"2026-11-12","1"]]' "four newest kit versions ($rounds)"
  has ".by_kit.without_kit.runs == 396 * $rounds" "lines without a kit version are grouped apart ($rounds)"
  has ".by_kit.omitted_groups == 14 and .by_kit.omitted_runs == 396 * $rounds - ([.by_kit.groups[].runs] | add)" "the kit versions left out are counted ($rounds)"
done

# --- the evidence (ADR-035): the blocker text of this repository's finished runs, read live from synthetic folders ----
ev_repo="$work/repoE"
ev_home="$work/ev-home"
cat >"$work/evidence_runs.py" <<'PY'
import json
from pathlib import Path


def blocker(number, **over):
    item = {
        "id": f"R1-{number}", "source": "review", "kind": "blocker", "disposition": "fixed",
        "blocker_class": "correctness regression", "escaped_from": "implement",
        "summary": f"summary {number}", "reason": f"reason {number}", "sweep": f"sweep {number}",
    }
    item.update(over)
    return {name: value for name, value in item.items() if value is not None}


def folder(repo, run_id, items=None, phase="done", state_id=None, valid=True, started=None):
    """A run folder as the helpers write it; valid=False skips the check that the fixture itself is sound."""
    path = Path(repo) / ".b-agentic" / "runs" / run_id
    path.mkdir(parents=True)
    state = {"run_id": state_id or run_id, "phase": phase}
    if started:
        state["history"] = [{"op": "init", "at": started}]
    (path / "state.json").write_text(json.dumps(state), encoding="utf-8")
    if items is not None:
        data = {"items": items}
        body = b_run.render("followups", data)
        (path / "followups.md").write_bytes(body.encode())
        entry = {"sha256": b_run.sha(body), "data": data, "rev": 1}
        recorded = {"schema": 1, "artifacts": {"followups": entry}}
        (path / "artifacts.json").write_text(json.dumps(recorded), encoding="utf-8")
        if valid:
            problems = b_run.validate_run(path, b_run.load_schema())[1]
            assert not problems, f"{run_id}: {problems}"
    return path
PY
# ev_fixture: a new repoE and an empty HOME, then the Python on stdin writes the run folders.
ev_fixture() {
  rm -rf "$ev_repo" "$ev_home"
  make_repo "$ev_repo"
  mkdir -p "$ev_home"
  { printf 'exec(open(%s).read())\nrepo = %s\n' "'$work/evidence_runs.py'" "'$ev_repo'" && cat; } |
    store_py unused || fail "writing the evidence run folders"
}
# evidence [ARGS...]: one page from repoE, in $out, checked to be one line of printable ASCII.
evidence() {
  out=$(HOME="$ev_home" stats "$ev_repo" --evidence "$@") || fail "stats --evidence $* failed: $out"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "a page must be one compact line ($*)"
  if printf '%s' "$out" | LC_ALL=C grep -q '[^ -~]'; then fail "a page must be printable ASCII ($*)"; fi
}
# ev_absent TEXT MESSAGE: the last page does not hold the text.
ev_absent() {
  if grep -qF "$1" <<<"$out"; then fail "$2"; fi
}
# ev_pages TOTAL: follow next_skip from the first page; every page is bounded and holds something, and the pages
# together hold TOTAL different blockers, listed in order in ev-ids.
ev_pages() {
  local skip=0 next size
  : >"$work/ev-ids"
  ev_page_count=0
  while :; do
    evidence --skip "$skip"
    size=$(printf '%s\n' "$out" | wc -c | tr -d ' ')
    [ "$size" -lt 30000 ] || fail "every page must stay under 30000 bytes (skip $skip): $size bytes"
    has ".total == $1 and .skip == $skip and .shown >= 1 and .shown == (.blockers | length)" "a page holds at least one blocker (skip $skip)"
    jq -r '.blockers[] | "\(.run) \(.id)"' <<<"$out" >>"$work/ev-ids"
    ev_page_count=$((ev_page_count + 1))
    next=$(jq -r .next_skip <<<"$out")
    if [ "$next" = null ]; then break; fi
    [ "$next" -gt "$skip" ] || fail "next_skip must move forward (skip $skip): $next"
    skip=$next
  done
  [ "$(lines_of "$work/ev-ids")" = "$1" ] || fail "paging must print $1 blockers: $(lines_of "$work/ev-ids")"
  [ "$(sort -u "$work/ev-ids" | wc -l | tr -d ' ')" = "$1" ] || fail "paging must print every blocker once"
}

# Content and order: the newest run first, a run's blockers as recorded, nine keys, null for what is absent (AC-1, AC-2).
ev_fixture <<'PY'
folder(repo, "20261101-a", [blocker(1, blocker_class=None, escaped_from=None)])
folder(repo, "20261103-b", [
    blocker(1, id="R2-1", summary="tóm \x85 tắt ‮ \U0001F680"),
    blocker(1, id="Q1-1", source="qa", escaped_from="review", disposition="rejected", sweep=None),
    {"id": "R1-9", "source": "review", "disposition": "deferred", "summary": "plain follow-up", "reason": "later"},
])
folder(repo, "20261105-c")
PY
evidence
has 'keys_unsorted == ["ok","folders","runs_read","skipped","total","oversized","skip","shown","next_skip","blockers"]' "the evidence header keys"
has '.ok and .folders == 3 and .runs_read == 3 and .skipped == {"not-a-run": 0, "bad-state": 0, "not-done": 0, invalid: 0}' "every done folder is read"
has '.total == 3 and .oversized == 0 and .skip == 0 and .shown == 3 and .next_skip == null' "one page holds them all"
has '[.blockers[] | [.run, .id]] == [["20261103-b","R2-1"],["20261103-b","Q1-1"],["20261101-a","R1-1"]]' "newest run first, recorded order inside a run"
has 'all(.blockers[]; keys_unsorted == ["run","id","source","disposition","blocker_class","escaped_from","summary","reason","sweep"])' "each blocker holds the nine keys"
has '.blockers[1] == {run: "20261103-b", id: "Q1-1", source: "qa", disposition: "rejected", blocker_class: "correctness regression", escaped_from: "review", summary: "summary 1", reason: "reason 1", sweep: null}' "a blocker's values"
has '.blockers[0].summary == "tóm \u0085 tắt ‮ 🚀"' "escaped text decodes to the recorded text"
has '.blockers[2] == {run: "20261101-a", id: "R1-1", source: "review", disposition: "fixed", blocker_class: null, escaped_from: null, summary: "summary 1", reason: "reason 1", sweep: "sweep 1"}' "an old blocker without a class or stage is printed with null"
ev_absent 'plain follow-up' "a follow-up that is not a blocker must not be printed"

# The bound and the pages, with the characters that escape longest (AC-3).
ev_fixture <<'PY'
wide = "\U0001D518" * 300
for run_id in ("20261101-x", "20261102-y"):
    folder(repo, run_id, [blocker(n, summary=wide, reason=wide, sweep=wide) for n in range(1, 31)])
PY
evidence
has '.shown == 2 and .next_skip == 2 and .total == 60' "two of the widest blockers fill a page"
ev_pages 60
[ "$ev_page_count" = 30 ] || fail "the widest blockers take 30 pages: $ev_page_count"
for run_id in 20261102-y 20261101-x; do
  for ((n = 1; n <= 30; n++)); do printf '%s R1-%s\n' "$run_id" "$n"; done
done >"$work/ev-want"
cmp -s "$work/ev-want" "$work/ev-ids" || fail "paging keeps the order"
ev_fixture <<'PY'
quotes, slashes, accents = '"' * 300, "\\" * 300, "é" * 300
folder(repo, "20261101-x", [blocker(n, summary=quotes, reason=slashes, sweep=accents) for n in range(1, 51)])
folder(repo, "20261102-y", [blocker(n) for n in range(1, 51)])
PY
evidence
size=$(printf '%s\n' "$out" | wc -c | tr -d ' ')
[ "$size" -gt 20000 ] || fail "a page is filled, not cut to a few blockers: $size bytes"
ev_pages 100
evidence --skip 999999
has '.total == 100 and .skip == 999999 and .shown == 0 and .next_skip == null and .blockers == []' "a skip past the end is an empty page"

# An unfinished run is not read, and a blocker too large for a page is only counted (AC-5).
ev_fixture <<'PY'
folder(repo, "20261101-x", [
    blocker(1, id="R1-" + "1" * 12000, summary="leak-oversized"),
    blocker(2),
    blocker(3, id="R1-" + "3" * 11500),
])
folder(repo, "20261102-y", [blocker(4, summary="leak-unfinished")], phase="implement")
folder(repo, "20261103-z", [blocker(5, summary="leak-blocked")], phase="blocked")
PY
evidence
has '.total == 2 and .oversized == 1 and .runs_read == 1 and .skipped["not-done"] == 2 and [.blockers[].id[:4]] == ["R1-2", "R1-3"]' "unfinished runs and an oversized blocker are left out"
ev_absent 'leak-' "nothing of an unfinished run or an oversized blocker is printed"
ev_pages 2

# A folder that is not what the helpers wrote drops only itself, and none of its text is printed (AC-4).
ev_fixture <<'PY'
import os


def bad(run_id, **over):
    return folder(repo, run_id, [blocker(1, summary=f"leak-{run_id}")], **over)


for run_id in ("20261101-good", "20261120-good"):
    folder(repo, run_id, [blocker(1, summary="visible")])
with open(bad("20261102-edited-md") / "followups.md", "a", encoding="utf-8") as handle:
    handle.write("leak-added by hand\n")
path = bad("20261103-wrong-hash") / "artifacts.json"
recorded = json.loads(path.read_text(encoding="utf-8"))
recorded["artifacts"]["followups"]["sha256"] = "0" * 64
path.write_text(json.dumps(recorded), encoding="utf-8")
(bad("20261104-malformed") / "artifacts.json").write_text("{leak-malformed", encoding="utf-8")
(bad("20261105-deep") / "artifacts.json").write_text("[" * 100000, encoding="utf-8")
with open(bad("20261106-huge") / "artifacts.json", "a", encoding="utf-8") as handle:
    handle.write(" " * b_run.MAX_FILE)
path = bad("20261107-linked-file") / "artifacts.json"
path.rename(Path(repo) / "linked-artifacts")
path.symlink_to(Path(repo) / "linked-artifacts")
for run_id, name in (("20261108-fifo-artifacts", "artifacts.json"), ("20261109-fifo-markdown", "followups.md"), ("20261112-fifo-state", "state.json")):
    path = bad(run_id) / name
    path.unlink()
    os.mkfifo(path)
(bad("20261113-unknown-file") / "extra.txt").write_text("leak-extra\n", encoding="utf-8")
# A FIFO beside sound files, under names no check reads: an allowed one and a temporary one.
os.mkfifo(bad("20261117-fifo-mutex") / "mutex")
os.mkfifo(bad("20261118-fifo-temp") / "followups.md.1.0123456789abcdef.tmp")
folder(repo, "20261114-control", [blocker(1, summary="leak-control \x01 end")], valid=False)
(bad("20261115-bad-state") / "state.json").write_text("{leak-state", encoding="utf-8")
bad("20261116-other-run", state_id="20261101-good")
# A link to a folder that is sound in every way: only being a link leaves it out.
target = folder(os.path.join(repo, "elsewhere"), "20261110-linked", [blocker(1, summary="leak-linked")])
(Path(repo) / ".b-agentic" / "runs" / "20261110-linked").symlink_to(target)
(Path(repo) / ".b-agentic" / "runs" / "20261111-plain-file").write_text("leak-file\n", encoding="utf-8")
folder(repo, "notes", [blocker(1, summary="leak-notes")])
PY
evidence
has '.folders == 20 and .runs_read == 2 and .skipped == {"not-a-run": 3, "bad-state": 3, "not-done": 0, invalid: 12}' "each bad folder is counted under its reason"
has '.total == 2 and [.blockers[] | [.run, .summary]] == [["20261120-good","visible"],["20261101-good","visible"]]' "the sound folders are still printed"
ev_absent 'leak' "no text of a folder that was left out is printed"

# Reading changes nothing in the repository or under HOME (AC-6).
before=$(tree_of "$ev_repo" && tree_of "$ev_home")
evidence
evidence --skip 1
[ "$(tree_of "$ev_repo" && tree_of "$ev_home")" = "$before" ] || fail "the evidence must change nothing in the repository or under HOME"
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$ev_repo/.b-agentic/runs/20261101-good"
  evidence
  chmod 755 "$ev_repo/.b-agentic/runs/20261101-good"
  has '.runs_read == 1 and .skipped["bad-state"] == 4 and [.blockers[].run] == ["20261120-good"]' "an unreadable folder drops only itself"
fi
# A name swapped for a link while the evidence is read cannot bring another tree's text in (AC-4).
# ev_swap WHEN PATH: run the evidence in-process and, at the first call of WHEN, replace repoE/PATH with a link to
# the same path in another tree: listdir swaps right after the runs are listed, read_state right before the first read.
ev_swap() {
  ev_fixture <<'PY'
folder(repo, "20261101-x", [blocker(1, summary="inside")])
folder(repo + "/outside", "20261101-x", [blocker(1, summary="leak-outside")])
PY
  out=$(cd "$ev_repo" && HOME="$ev_home" python3 -I -B - "$root/claude/bin/b_run.py" "$ev_repo" "$1" "$2" <<'PY'
import importlib.util
import os
import sys

cli, repo, when, swapped = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("b_run", cli)
b_run = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b_run)
module = os if when == "listdir" else b_run
real = getattr(module, when)
done = []


def swap():
    if not done:
        done.append(True)
        path = os.path.join(repo, swapped)
        os.rename(path, path + ".aside")
        os.symlink(os.path.join(repo, "outside", swapped), path)


def hooked(*args):
    if when == "read_state":
        swap()
    value = real(*args)
    swap()
    return value


setattr(module, when, hooked)
code = b_run.main(["stats", "--evidence"])
if not done:
    sys.exit("the swap never happened")
sys.exit(code)
PY
  ) || fail "the evidence during a swap failed ($1 $2)"
  ev_absent 'leak-outside' "a swapped name must not bring another tree's text in ($1 $2)"
}
for swapped in .b-agentic .b-agentic/runs .b-agentic/runs/20261101-x; do
  ev_swap read_state "$swapped"
  has '.runs_read == 1 and [.blockers[].summary] == ["inside"]' "the folder that was opened is the one read ($swapped)"
done
ev_swap listdir .b-agentic/runs
has '.runs_read == 1 and [.blockers[].summary] == ["inside"]' "the runs folder that was opened is the one read"
ev_swap listdir .b-agentic/runs/20261101-x
has '.runs_read == 0 and .skipped["not-a-run"] == 1 and .total == 0' "a folder swapped before it is opened is not followed"
ev_fixture <<'PY'
PY
evidence
has '.folders == 0 and .runs_read == 0 and .total == 0 and .shown == 0 and .next_skip == null' "a repository without runs"
ev_fixture <<'PY'
folder(repo + "/elsewhere", "20261101-x", [blocker(1, summary="leak-linked-base")])
(Path(repo) / ".b-agentic").symlink_to(Path(repo) / "elsewhere" / ".b-agentic")
PY
evidence
has '.folders == 0 and .total == 0' "a linked run folder base is not read"

# Only the checkout around the working directory is read, whatever the environment or git config names (AC-4).
ev_other="$work/ev-other"
ev_linked="$work/ev-linked"
ev_fixture <<PY
folder(repo, "20261101-x", [blocker(1, summary="inside")])
folder("$ev_other/inner", "20261101-x", [blocker(1, summary="leak-inner")])
folder("$ev_other", "20261101-x", [blocker(1, summary="leak-outer")])
PY
make_repo "$ev_other/inner"
make_repo "$ev_other/elsewhere"
GIT_WORK_TREE="$ev_other" evidence
has '[.blockers[].summary] == ["inside"]' "an inherited GIT_WORK_TREE is ignored"
GIT_DIR="$ev_other/elsewhere/.git" GIT_WORK_TREE="$ev_other" evidence
has '[.blockers[].summary] == ["inside"]' "an inherited GIT_DIR is ignored"
mkdir -p "$ev_repo/sub/deeper"
out=$(HOME="$ev_home" stats "$ev_repo/sub/deeper" --evidence) || fail "the evidence from a subfolder failed: $out"
has '[.blockers[].summary] == ["inside"]' "a subfolder reads its own checkout"
git -C "$ev_repo" worktree add -q "$ev_linked" || fail "adding a linked worktree"
out=$(HOME="$ev_home" stats "$ev_linked" --evidence) || fail "the evidence from a linked worktree failed: $out"
has '.folders == 0 and .total == 0' "a linked worktree reads its own run folders"
# ev_refused DIR: git points away from the checkout around DIR: exit 3, one line on stderr, nothing printed.
ev_refused() {
  local rc=0
  out=$(HOME="$ev_home" stats "$1" --evidence 2>"$work/sum-err") || rc=$?
  if [ "$rc" -ne 3 ] || [ -n "$out" ] || [ "$(lines_of "$work/sum-err")" != 1 ]; then
    fail "a redirected worktree must be refused ($1): rc=$rc $out $(cat "$work/sum-err")"
  fi
}
# A config pointing elsewhere, and one pointing at a folder above, which still holds the working directory.
git -C "$ev_repo" config core.worktree "$ev_other"
ev_refused "$ev_repo"
git -C "$ev_other/inner" config core.worktree "$ev_other"
ev_refused "$ev_other/inner"
rm -rf "$ev_other" "$ev_linked"

# --- the repository registry (ADR-037) ---------------------------------------------------------------------------------
# Every repository-key lookup uses a hardened git: nothing inherited steers it, and it cannot hang.
rg_key_repo="$work/rg-key"
make_repo "$rg_key_repo"
rg_log="$work/rg-git-log"
mkdir -p "$work/rg-fake-git" "$work/rg-slow-git"
printf '#!/bin/sh\n{ printf "args %%s\\n" "$*"; env | grep "^GIT_" | sort; } >>"%s"\nexec "%s" "$@"\n' "$rg_log" "$(command -v git)" >"$work/rg-fake-git/git"
printf '#!/bin/sh\nexec sleep 30\n' >"$work/rg-slow-git/git"
chmod +x "$work/rg-fake-git/git" "$work/rg-slow-git/git"
rg_want=$(git -C "$rg_key_repo" rev-list --max-parents=0 HEAD | python3 -I -B -c 'import hashlib, sys; print(hashlib.sha256(("b-agentic-run-stats:v1:" + "\n".join(sorted(sys.stdin.read().split()))).encode()).hexdigest()[:16])')
: >"$rg_log"
out=$(cd "$rg_key_repo" && printf '%s\n' 'from pathlib import Path' 'print(b_run.stats_repo_key(Path.cwd()))' |
  GIT_DIR="$work/rg-nowhere" GIT_CONFIG_PARAMETERS="'core.bare'='true'" GIT_TRACE="$work/rg-trace" PATH="$work/rg-fake-git:$PATH" store_py unused) ||
  fail "the hardened key lookup failed"
[ "$out" = "$rg_want" ] || fail "a full clone keeps its key under the hardened lookup: $out != $rg_want"
[ ! -e "$work/rg-trace" ] || fail "an inherited GIT_ variable must not reach git"
[ "$(grep -c '^args -c core.fsmonitor=false ' "$rg_log")" = 2 ] || fail "both lookups must turn the filesystem monitor off: $(cat "$rg_log")"
[ "$(grep '^GIT_' "$rg_log" | sort -u | tr '\n' ' ')" = "GIT_NO_LAZY_FETCH=1 GIT_OPTIONAL_LOCKS=0 " ] || fail "git gets only the two set GIT_ variables: $(cat "$rg_log")"
(cd "$rg_key_repo" && PATH="$work/rg-slow-git:$PATH" store_py unused <<'PY') || fail "a slow git must give no key instead of a hang"
import time
from pathlib import Path

b_run.KEY_GIT_SECONDS = 0.5
start = time.monotonic()
assert b_run.stats_repo_key(Path.cwd()) is None
assert time.monotonic() - start < 10, time.monotonic() - start
PY
# The two git runs of one key lookup share one limit: each of these is under it, and together they are over it.
mkdir -p "$work/rg-lagging-git"
printf '#!/bin/sh\nsleep 1.2\nexec "%s" "$@"\n' "$(command -v git)" >"$work/rg-lagging-git/git"
chmod +x "$work/rg-lagging-git/git"
(cd "$rg_key_repo" && PATH="$work/rg-lagging-git:$PATH" RG_WANT="$rg_want" store_py unused <<'PY') || fail "one key lookup must have one time limit"
from pathlib import Path

assert b_run.stats_repo_key(Path.cwd()) == os.environ["RG_WANT"]
b_run.KEY_GIT_SECONDS = 2.0
assert b_run.stats_repo_key(Path.cwd()) is None
PY
# Finding git counts against that limit too.
(cd "$rg_key_repo" && RG_WANT="$rg_want" store_py unused <<'PY') || fail "a slow search for git must count against the limit"
import shutil
import time
from pathlib import Path

real_which = shutil.which


def slow_which(*args, **options):
    time.sleep(1.2)
    return real_which(*args, **options)


shutil.which = slow_which
assert b_run.stats_repo_key(Path.cwd()) == os.environ["RG_WANT"]
b_run.KEY_GIT_SECONDS = 2.0
assert b_run.stats_repo_key(Path.cwd()) is None
PY
# A relative or empty search-path entry would run a program, or load a library, from the folder git is asked about.
mkdir -p "$rg_key_repo/bin"
rg_marker="$work/rg-planted-ran"
printf '#!/bin/sh\n: >"%s"\nexit 1\n' "$rg_marker" >"$rg_key_repo/git"
cp "$rg_key_repo/git" "$rg_key_repo/bin/git"
chmod +x "$rg_key_repo/git" "$rg_key_repo/bin/git"
(cd "$rg_key_repo" && RG_WANT="$rg_want" store_py unused <<'PY') || fail "only a git from an absolute PATH entry may run"
import subprocess
from pathlib import Path

real_path = os.environ["PATH"]
real_run = subprocess.run
seen = []


def spy(command, **options):
    seen.append((command, options["env"]))
    return real_run(command, **options)


subprocess.run = spy
os.environ.update(
    PATH=os.pathsep.join(["", ".", "bin", real_path]),
    LD_LIBRARY_PATH=":lib;also:/rg-absolute-lib;rg-after-semicolon:;/rg-second-lib",
    GCONV_PATH="gconv:/rg-absolute-gconv",
    DYLD_LIBRARY_PATH=os.pathsep.join(["lib", "."]),
    DYLD_FALLBACK_LIBRARY_PATH="lib",
    LD_PRELOAD="./planted.so",
    LD_AUDIT="./planted.so",
)
assert b_run.stats_repo_key(Path.cwd()) == os.environ["RG_WANT"]
assert seen, "git was not run"
for command, env in seen:
    assert os.path.isabs(command[0]), command
    assert all(os.path.isabs(entry) for entry in env["PATH"].split(os.pathsep)), env["PATH"]
    assert env.get("LD_LIBRARY_PATH") == "/rg-absolute-lib:/rg-second-lib", env.get("LD_LIBRARY_PATH")
    assert env.get("GCONV_PATH") == "/rg-absolute-gconv", env.get("GCONV_PATH")
    assert not {"DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT"} & set(env), sorted(env)
count = len(seen)
os.environ["PATH"] = os.pathsep.join(["", ".", "bin"])
assert b_run.stats_repo_key(Path.cwd()) is None
assert len(seen) == count, "no program may start without an absolute PATH entry"
PY
[ ! -e "$rg_marker" ] || fail "a git inside the folder must never run"
rm -rf "${rg_key_repo:?}/git" "${rg_key_repo:?}/bin"

# Recording stats remembers the checkout, once per key and path, and says so when the registry is created.
rg_home="$work/rg-home"
rg_claude="$rg_home/.claude/b-agentic"
rg_pi="$rg_home/.pi/agent/b-agentic"
rg_file="$rg_claude/run-stats-repos.jsonl"
rg_store="$rg_claude/run-stats.jsonl"
mkdir -p "$rg_claude"
chmod 700 "$rg_claude"
make_repo "$work/rg-a"
rg_a=$(cd "$work/rg-a" && pwd -P)
rg_saved_home=$HOME
export HOME="$rg_home"
finish_run "$rg_a" first
export HOME="$rg_saved_home"
jq -e '.run_stats == "written" and (.notice | contains("run-stats.jsonl") and contains("~/.claude/b-agentic/run-stats-repos.jsonl") and contains("checkout paths") and contains("run-stats.off"))' <<<"$out" >/dev/null ||
  fail "the first finished run must create the registry and name it in the notice: $out"
[ "$(mode_of "$rg_file")" = 600 ] || fail "the registry must be 0600"
rg_key=$(jq -r .repo "$rg_store")
jq -e -s --arg key "$rg_key" --arg path "$rg_a" '. == [{v: 1, repo: $key, path: $path}]' "$rg_file" >/dev/null || fail "the registry holds one line for the checkout: $(cat "$rg_file")"
if grep -qF "$work" "$rg_store"; then fail "no path may enter the store"; fi
# record_in DIR: stats --record there with the registry HOME, in $out.
record_in() {
  out=$(HOME="$rg_home" stats "$1" --record) || fail "stats --record failed ($1): $out"
}
record_in "$rg_a"
has '.appended == 0 and .already == 1 and .registry == "already" and (has("notice") | not)' "a checkout is registered once"
[ "$(lines_of "$rg_file")" = 1 ] || fail "a second record must add no registry line"
rm "$rg_file"
record_in "$rg_a"
has '.created == false and .registry == "written" and (.notice | contains("run-stats-repos.jsonl")) and (.notice | contains("numbers only") | not)' "a new registry beside an old store is announced alone"
# The path is the checkout around the working directory, also from a subfolder.
mkdir -p "$rg_a/sub/deeper"
record_in "$rg_a/sub/deeper"
has '.registry == "already"' "a subfolder registers its checkout"

# Nothing about the registry changes what recording the store returns.
# broken_registry WHAT EXPECTED: with the registry broken, a fresh store still takes the run and the reason is reported.
broken_registry() {
  rm -f "$rg_store"
  record_in "$rg_a"
  has ".appended == 1 and .already == 0 and .skipped == {} and .registry == \"$2\"" "a $1 registry must not touch the store result"
  [ "$(lines_of "$rg_store")" = 1 ] || fail "the store line must be written beside a $1 registry"
}
rm -f "$rg_file"
printf 'untouched\n' >"$work/rg-target"
chmod 600 "$work/rg-target"
ln -s "$work/rg-target" "$rg_file"
broken_registry "linked" "skipped:registry-unopenable"
[ "$(cat "$work/rg-target")" = untouched ] || fail "nothing may be written through a linked registry"
rm "$rg_file"
ln "$work/rg-target" "$rg_file"
broken_registry "hard-linked" "skipped:registry-not-plain"
[ "$(cat "$work/rg-target")" = untouched ] || fail "nothing may be written through a hard-linked registry"
rm "$rg_file"
mkfifo "$rg_file"
broken_registry "FIFO" "skipped:registry-not-plain"
rm "$rg_file"
mkdir "$rg_file"
broken_registry "folder" "skipped:registry-unopenable"
rmdir "$rg_file"
: >"$rg_file"
chmod 640 "$rg_file"
broken_registry "loose-mode" "skipped:registry-loose-mode"
[ ! -s "$rg_file" ] || fail "a loose registry must take no line"
chmod 600 "$rg_file"
python3 -I -B -c 'import sys; open(sys.argv[1], "wb").write(b"\n" * (1 << 20))' "$rg_file"
broken_registry "full" "skipped:registry-full"
printf 'not json\n{"torn' >"$rg_file"
broken_registry "torn" "written"
[ "$(tail -n 1 "$rg_file" | jq -r .path)" = "$rg_a" ] || fail "a torn tail must be ended before the new line"
[ "$(lines_of "$rg_file")" = 3 ] || fail "the earlier bytes stay and one line is added: $(cat "$rg_file")"
# A line the readers reject does not count as listed, or the checkout could never be registered again.
python3 -I -B -c '
import json, os, sys
target, key, path = sys.argv[1:4]
entry = {"v": 1, "repo": key, "path": path}
rejected = [json.dumps({**entry, "v": 2}), json.dumps({**entry, "extra": 1}), json.dumps(entry) + " " * 5000]
with open(target, "w") as handle:
    handle.write("".join(line + "\n" for line in rejected))
' "$rg_file" "$(jq -r .repo "$rg_store")" "$rg_a" || fail "writing a rejected registry"
record_in "$rg_a"
has '.registry == "written"' "a rejected line for this checkout must not hide it"
record_in "$rg_a"
has '.registry == "already"' "the sound line added beside the rejected ones is believed"
[ "$(lines_of "$rg_file")" = 4 ] || fail "one sound line is added to the three rejected ones: $(cat "$rg_file")"
rm -f "$rg_file" "$rg_store"
: >"$rg_claude/run-stats.off"
record_in "$rg_a"
has '.appended == 0 and .skipped == {disabled: 1} and .registry == "skipped:disabled" and (has("notice") | not)' "the off file stops both files"
[ ! -e "$rg_file" ] && [ ! -e "$rg_store" ] || fail "the off file must stop the registry from being created"
rm "$rg_claude/run-stats.off"
chmod 707 "$rg_claude"
record_in "$rg_a"
has '.registry == "skipped:home-not-private"' "a home others can write takes no registry"
chmod 700 "$rg_claude"
mkdir -p "$work/rg-empty-home"
out=$(HOME="$work/rg-empty-home" stats "$rg_a" --record) || fail "stats --record without a home failed: $out"
has '.registry == "skipped:no-install-home"' "no install home, no registry"
[ -z "$(ls -A "$work/rg-empty-home")" ] || fail "the registry must never create the install home"
git clone -q --depth 1 "file://$rg_a" "$work/rg-shallow" || fail "making a shallow clone"
record_in "$work/rg-shallow"
has '.registry == "skipped:no-repo-key"' "a shallow clone is not registered"
[ ! -e "$rg_file" ] || fail "no registry may be created for a clone without a key"
make_repo "$work/rg-redirect"
GIT_WORK_TREE="$work/rg-redirect" record_in "$rg_a"
has '.registry == "skipped:other-worktree"' "a redirected worktree is not registered"
[ ! -e "$rg_file" ] || fail "a redirected worktree must leave no path behind"
(cd "$rg_a" && HOME="$rg_home" store_py unused <<'PY') || fail "a busy or failing registry must only be a reason"
import fcntl

off = block["off"]
key = b_run.stats_repo_key(b_run.repo_root())
assert b_run._register_checkout("claude", off, key, b_run.repo_root())[0] == "written"
fd = os.open(b_run.stats_dir("claude") / b_run.REGISTRY, os.O_RDWR)
fcntl.flock(fd, fcntl.LOCK_EX)
assert b_run._register_checkout("claude", off, key, b_run.repo_root()) == ("skipped:registry-busy", False)
os.close(fd)


def boom(*_args):
    raise RuntimeError("boom")


b_run._locked_append = boom
assert b_run._register_checkout("claude", off, key, b_run.repo_root()) == ("failed", False)
PY
# The live record's caller waits 10 s in all, so registering adds no git run, and a late record no lock wait.
rm -f "$rg_file"
(cd "$rg_a" && HOME="$rg_home" store_py unused <<'PY') || fail "registration must not run into the caller's deadline"
import fcntl
import subprocess
import time

root = b_run.repo_root()
key = b_run.stats_repo_key(root)
real_run = subprocess.run


def no_program(*_args, **_options):
    raise AssertionError("registration must run no program")


subprocess.run = no_program
assert b_run._register_checkout("claude", block["off"], key, root) == ("written", True)
subprocess.run = real_run
waits = []
real_register = b_run._register_checkout


def noting(*args):
    waits.append(args[4])
    return real_register(*args)


b_run._register_checkout = noting
schema = b_run.load_schema()
assert b_run.cmd_stats(schema, {"record": True})["registry"] == "already"
b_run.REGISTRY_QUICK_SECONDS = 0.0
assert b_run.cmd_stats(schema, {"record": True})["registry"] == "already"
assert waits == [b_run.STATS_LOCK_SECONDS, 0.0], waits
fd = os.open(b_run.stats_dir("claude") / b_run.REGISTRY, os.O_RDWR)
fcntl.flock(fd, fcntl.LOCK_EX)
start = time.monotonic()
assert real_register("claude", block["off"], key, root, 0.0) == ("skipped:registry-busy", False)
assert time.monotonic() - start < b_run.STATS_LOCK_SECONDS / 2, time.monotonic() - start
os.close(fd)
PY
# Each runtime writes its own registry.
mkdir -p "$rg_pi"
chmod 700 "$rg_pi"
rm -f "$rg_file"
B_AGENTIC_HELPER_DIR="$pi_dir" record_in "$rg_a"
has '.registry == "written" and (.notice | contains("~/.pi/agent/b-agentic/run-stats-repos.jsonl"))' "Pi writes its own registry"
[ -f "$rg_pi/run-stats-repos.jsonl" ] && [ ! -e "$rg_file" ] || fail "Pi must not write the Claude Code registry"

# --repos: both registries, the most recently registered first, bounded, and the only output with paths.
# repos: stats --repos with the registry HOME, in $out, checked to be one bounded line of printable ASCII. It is
# run outside any repository: it reads only the registries.
repos() {
  mkdir -p "$work/rg-outside"
  out=$(HOME="$rg_home" stats "$work/rg-outside" --repos) || fail "stats --repos failed: $out"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "--repos must be one compact line"
  if printf '%s' "$out" | LC_ALL=C grep -q '[^ -~]'; then fail "--repos must be printable ASCII"; fi
  [ "$(printf '%s\n' "$out" | wc -c | tr -d ' ')" -lt 28001 ] || fail "--repos must stay under 28000 bytes"
}
# registry_file FILE: write the Python on stdin's `lines` (a list of bytes or of (key, path) pairs) as a registry.
registry_file() {
  { cat && printf '%s\n' 'out = b"".join(x + b"\n" if isinstance(x, bytes) else (json.dumps({"v": 1, "repo": x[0], "path": x[1]}) + "\n").encode() for x in lines)' \
    'fd = os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)' 'os.write(fd, out)' 'os.fchmod(fd, 0o600)'; } |
    { printf 'import json\n' && cat; } | store_py "$1" || fail "writing a registry: $1"
}
rm -f "$rg_file" "$rg_pi/run-stats-repos.jsonl"
repos
has '. == {ok: true, registries: {claude: {status: "absent", disabled: false, truncated: false, lines: 0, malformed: 0}, pi: {status: "absent", disabled: false, truncated: false, lines: 0, malformed: 0}}, repos: [], omitted_repos: 0}' "no registry, no repository"
registry_file "$rg_file" <<'PY'
a, b = "a" * 16, "b" * 16
lines = [(a, "/one"), (b, "/other"), b"not json", b"[1]", (a, "/two"), (a, "/one"),
    json.dumps({"v": 2, "repo": a, "path": "/v2"}).encode(), json.dumps({"v": True, "repo": a, "path": "/bool"}).encode(),
    json.dumps({"v": 1, "repo": a, "path": "/extra", "more": 1}).encode(), ("A" * 16, "/upper"), (a, "relative"),
    (a, "/not/../normal"), (a, "/con\ntrol"), (a, "/" + "p" * 1100), json.dumps({"v": 1, "repo": a, "path": 5}).encode(),
    (a, "/lone\udcff"), json.dumps({"v": 1, "repo": a, "path": "/long-line"}).encode() + b" " * 5000]
PY
registry_file "$rg_pi/run-stats-repos.jsonl" <<'PY'
lines = [("c" * 16, "/pi-only"), ("a" * 16, "/one"), ("a" * 16, "/tabé"), ("a" * 16, "/four"), ("a" * 16, "/five")]
PY
: >"$rg_claude/run-stats.off"
repos
rm "$rg_claude/run-stats.off"
has '.registries.claude == {status: "read", disabled: true, truncated: false, lines: 17, malformed: 13} and .registries.pi == {status: "read", disabled: false, truncated: false, lines: 5, malformed: 0}' "each registry's state and malformed lines"
has '[.repos[].repo] == ["aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb", "cccccccccccccccc"] and .omitted_repos == 0' "Claude Code first, newest first"
has '.repos[0] == {repo: "aaaaaaaaaaaaaaaa", paths: ["/one", "/two", "/five", "/four"], omitted_paths: 1}' "four paths a key, each once, newest first"
chmod 640 "$rg_file"
repos
has '.registries.claude.status == "loose-mode" and .registries.claude.lines == 0 and [.repos[].repo] == ["aaaaaaaaaaaaaaaa", "cccccccccccccccc"]' "a loose registry gives no entry"
chmod 600 "$rg_file"
mv "$rg_file" "$work/rg-real"
ln -s "$work/rg-real" "$rg_file"
repos
has '.registries.claude.status == "not-plain"' "a linked registry gives no entry"
rm "$rg_file"
ln "$work/rg-real" "$rg_file"
repos
has '.registries.claude.status == "not-plain"' "a hard-linked registry gives no entry"
rm "$rg_file"
mkfifo "$rg_file"
repos
has '.registries.claude.status == "not-plain"' "a FIFO registry gives no entry and does not hang"
rm "$rg_file"
chmod 707 "$rg_claude"
repos
has '.registries.claude.status == "home-not-private"' "a home others can write gives no entry"
chmod 700 "$rg_claude"
# The bound, with paths that escape longest, and a file past the size cap.
registry_file "$rg_file" <<'PY'
wide = "/" + ("\U0001D518" * 50 + "/") * 5
lines = [(f"{n:016x}", f"{wide}{n}-{m}") for n in range(40) for m in range(5)]
PY
repos
has '.registries.claude.truncated == false and .omitted_repos > 0 and (.repos | length) >= 2 and (.repos | length) + .omitted_repos == 42 and all(.repos[]; (.paths | length) <= 4)' "keys stop before the bound and the rest are counted"
[ "$(printf '%s\n' "$out" | wc -c | tr -d ' ')" -gt 15000 ] || fail "--repos is filled up to its bound"
python3 -I -B -c 'import sys; open(sys.argv[1], "ab").write(b"\n" * (1 << 20))' "$rg_file"
repos
has '.registries.claude.truncated and .registries.claude.status == "read"' "an oversized registry is read to its cap and said so"
for option in --record --summary --evidence "--skip 1" "--repo aaaaaaaaaaaaaaaa" "--since 2026-11-01" "--section repo" --apply "--run 20261101-x"; do
  # shellcheck disable=SC2086 # the option and its value are two words on purpose.
  bad_use --repos $option
done
python3 -I -B "$root/claude/bin/b_run.py" --help | grep -qF 'printed paths reach the model provider' || fail "help must warn where printed paths go"

# --evidence --repo: only the user's own whole checkouts that still have the key are read, and no path leaves.
rv_work=$(cd "$work" && pwd -P)
rv="$rv_work/rv"
rm -rf "$rv" "$rg_home"
mkdir -p "$rv" "$rg_claude" "$rg_pi" "$work/rg-outside"
chmod 700 "$rg_claude" "$rg_pi"
# other_repo DIR: a repository with a root commit of its own (two make_repo of one second share theirs, and a key).
other_repo() {
  make_repo "$1"
  git -C "$1" checkout -q --orphan other
  git -C "$1" commit -qm "root of $(basename "$1")"
}
make_repo "$rv/good"
git clone -q "file://$rv/good" "$rv/clone" || fail "cloning the good checkout"
git clone -q "file://$rv/good" "$rv/second" || fail "cloning the good checkout again"
git clone -q --depth 1 "file://$rv/good" "$rv/shallow" || fail "a shallow clone of the good checkout"
git clone -q "file://$rv/good" "$rv/partial" || fail "a clone to mark partial"
git -C "$rv/partial" config remote.origin.promisor true
git clone -q "file://$rv/good" "$rv/redirected" || fail "a clone to redirect"
git -C "$rv/redirected" config core.worktree "$rv/good"
other_repo "$rv/other"
mkdir -p "$rv/good/sub" "$rv/plain"
ln -s "$rv/good" "$rv/linked"
ln -s "$rv" "$rv_work/rv-alias"
{
  printf 'exec(open(%s).read())\nrv = %s\n' "'$work/evidence_runs.py'" "'$rv'"
  cat <<'PY'
folder(rv + "/good", "20261105-both", [blocker(1, summary="visible both from good")])
folder(rv + "/good", "20261101-good", [blocker(2, summary="visible good")])
folder(rv + "/good", "20261103-fix", [blocker(3, summary="leak-unfinished copy")], phase="implement")
folder(rv + "/clone", "20261105-both", [blocker(1, summary="leak-repeat from clone")])
folder(rv + "/clone", "20261104-clone", [blocker(4, summary="visible clone")])
folder(rv + "/clone", "20261103-fix", [blocker(3, summary="visible finished copy")])
for name in ("shallow", "partial", "redirected", "other", "plain", "good/sub"):
    folder(rv + "/" + name, "20261101-x", [blocker(1, summary=f"leak-{name}")])
PY
} | store_py unused || fail "writing the checkout run folders"
rv_key=$(cd "$rv/good" && printf '%s\n' 'from pathlib import Path' 'print(b_run.stats_repo_key(Path.cwd()))' | store_py unused)
# register FILE KEY PATH...: a registry of FILE whose newest entry is the first PATH.
register() {
  python3 -I -B -c '
import json, os, sys
target, key, paths = sys.argv[1], sys.argv[2], sys.argv[3:]
fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, "".join(json.dumps({"v": 1, "repo": key, "path": path}) + "\n" for path in reversed(paths)).encode())
os.fchmod(fd, 0o600)
' "$@" || fail "writing a registry: $1"
}
# rv_run ARGS...: stats from outside any repository with the registry HOME; sets $out, $rc and $work/rv-err.
rv_run() {
  rc=0
  out=$(HOME="$rg_home" stats "$work/rg-outside" "$@" 2>"$work/rv-err") || rc=$?
  if printf '%s' "$out" | grep -qF "$rv_work"; then fail "no path may be printed ($*): $out"; fi
  if grep -qF "$rv_work" "$work/rv-err"; then fail "no path may reach stderr ($*): $(cat "$work/rv-err")"; fi
}
# rv_read WHAT: --evidence --repo for the good key succeeds.
rv_read() {
  rv_run --evidence --repo "$rv_key"
  [ "$rc" -eq 0 ] || fail "$1: rc=$rc $(cat "$work/rv-err")"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "$1: one compact line"
  if grep -qF 'leak' <<<"$out"; then fail "$1: nothing of a checkout or folder left out may be printed: $out"; fi
}
# rv_refused WHAT TEXT: exit 3, one line on stderr holding TEXT, nothing on stdout.
rv_refused() {
  rv_run --evidence --repo "$rv_key"
  if [ "$rc" -ne 3 ] || [ -n "$out" ] || [ "$(lines_of "$work/rv-err")" != 1 ] || ! grep -qF "$2" "$work/rv-err"; then
    fail "$1: rc=$rc $out $(cat "$work/rv-err")"
  fi
}
rv_file="$rg_claude/run-stats-repos.jsonl"
rv_refused "a key that is not registered" "is not registered"
register "$rv_file" "$rv_key" "$rv/missing" "$rv/linked" "$rv/plain" "$rv/good"
rv_read "gone, linked and plain folders beside a good one"
has '.checkouts == {registered: 4, read: 1, skipped: {gone: 2, "not-owned": 0, "not-a-checkout": 1, partial: 0, "no-key": 0, "other-key": 0, "same-folder": 0, "not-tried": 0}, duplicate_runs: 0}' "each bad checkout is counted"
has 'keys_unsorted == ["ok","folders","runs_read","skipped","checkouts","total","oversized","skip","shown","next_skip","blockers"] and [.blockers[].summary] == ["visible both from good", "visible good"] and .skipped["not-done"] == 1' "the good checkout is read"
register "$rv_file" "$rv_key" "$rv/good/sub" "$rv/redirected" "$rv/partial" "$rv/good"
rv_read "a subfolder, a redirected worktree and a partial clone"
has '.checkouts.read == 1 and .checkouts.skipped["not-a-checkout"] == 2 and .checkouts.skipped.partial == 1 and .total == 2' "only the checkout's own top level, whole, is read"
register "$rv_file" "$rv_key" "$rv/shallow" "$rv/other" "$rv/good" "$rv/missing" "$rv/clone" "$rv/second"
rv_read "a shallow clone and another repository at a registered path"
has '.checkouts.registered == 6 and .checkouts.read == 1 and .checkouts.skipped == {gone: 1, "not-owned": 0, "not-a-checkout": 0, partial: 0, "no-key": 1, "other-key": 1, "same-folder": 0, "not-tried": 2}' "four paths are tried and the rest counted"
register "$rv_file" "$rv_key" "$rv/shallow" "$rv/other" "$rv/missing"
rv_refused "no checkout passes" "(gone 1, no-key 1, other-key 1)"
(cd "$work/rg-outside" && HOME="$rg_home" store_py "$rv/good" <<PY) || fail "another owner's folder must be left out"
real = os.getuid
os.getuid = lambda: real() + 1
assert b_run._open_checkout(store, "$rv_key", set()) == ("not-owned", -1)
PY
# A path swapped after its checkout was checked cannot bring another tree in: the runs are read from the held folder.
register "$rv_file" "$rv_key" "$rv/good"
cp -R "$rv/good" "$rv/good-copy"
out=$(cd "$work/rg-outside" && HOME="$rg_home" python3 -I -B - "$root/claude/bin/b_run.py" "$rv/good" "$rv/other" "$rv_key" <<'PY'
import importlib.util
import os
import sys

cli, good, other, key = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("b_run", cli)
b_run = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b_run)
real = b_run.stats_repo_key


def swapping(root):
    found = real(root)
    os.rename(good, good + ".aside")
    os.symlink(other, good)
    return found


b_run.stats_repo_key = swapping
code = b_run.main(["stats", "--evidence", "--repo", key])
os.unlink(good)
os.rename(good + ".aside", good)
sys.exit(code)
PY
) || fail "reading during a checkout swap failed: $out"
has '[.blockers[].summary] == ["visible both from good", "visible good"]' "the held checkout is the one read"
rm -rf "$rv/good-copy"
# Several checkouts across both registries: merged newest run first, a folder and a run id read once.
register "$rv_file" "$rv_key" "$rv/good" "$rv_work/rv-alias/good"
register "$rg_pi/run-stats-repos.jsonl" "$rv_key" "$rv/clone" "$rv/good"
rv_before=$(tree_of "$rv" && tree_of "$rg_home")
rv_read "two clones, one of them reached by two paths"
has '.checkouts == {registered: 3, read: 2, skipped: {gone: 0, "not-owned": 0, "not-a-checkout": 0, partial: 0, "no-key": 0, "other-key": 0, "same-folder": 1, "not-tried": 0}, duplicate_runs: 1}' "one folder is read once and a repeated run is counted"
has '[.blockers[] | [.run, .summary]] == [["20261105-both","visible both from good"],["20261104-clone","visible clone"],["20261103-fix","visible finished copy"],["20261101-good","visible good"]]' "runs merge newest first, the first sound copy wins"
has '.folders == 6 and .runs_read == 4 and .skipped == {"not-a-run": 0, "bad-state": 0, "not-done": 1, invalid: 0} and .total == 4' "the header counts over both checkouts"
rv_run --evidence --repo "$rv_key" --skip 3
has '.skip == 3 and .shown == 1 and .next_skip == null and .blockers[0].run == "20261101-good"' "--skip pages the merged runs"
rg_before_current=$(cd "$rv/good" && HOME="$rg_home" stats "$rv/good" --evidence) || fail "plain evidence in the good checkout"
jq -e 'has("checkouts") | not' <<<"$rg_before_current" >/dev/null || fail "plain evidence has no checkouts field"
[ "$(tree_of "$rv" && tree_of "$rg_home")" = "$rv_before" ] || fail "--repos and --evidence --repo must change nothing"
# Paging a merged set larger than a page prints every blocker once.
{
  printf 'exec(open(%s).read())\nrv = %s\n' "'$work/evidence_runs.py'" "'$rv'"
  cat <<'PY'
wide = "\U0001D518" * 300
for checkout, run_id in (("good", "20261201-g"), ("clone", "20261202-c")):
    folder(rv + "/" + checkout, run_id, [blocker(n, summary=wide, reason=wide, sweep=wide) for n in range(1, 6)])
PY
} | store_py unused || fail "writing wide runs in two checkouts"
rv_skip=0
: >"$work/rv-ids"
while :; do
  rv_run --evidence --repo "$rv_key" --skip "$rv_skip"
  [ "$(printf '%s\n' "$out" | wc -c | tr -d ' ')" -lt 30000 ] || fail "every merged page stays under 30000 bytes"
  has '.total == 14 and .shown >= 1' "a merged page holds something"
  jq -r '.blockers[] | "\(.run) \(.id)"' <<<"$out" >>"$work/rv-ids"
  rv_skip=$(jq -r .next_skip <<<"$out")
  [ "$rv_skip" != null ] || break
done
[ "$(lines_of "$work/rv-ids")" = 14 ] && [ "$(sort -u "$work/rv-ids" | wc -l | tr -d ' ')" = 14 ] || fail "paging prints every merged blocker once: $(cat "$work/rv-ids")"
# Two clones can use one folder name for two runs: their start times tell them apart, as in the summary.
{
  printf 'exec(open(%s).read())\nrv = %s\n' "'$work/evidence_runs.py'" "'$rv'"
  cat <<'PY'
folder(rv + "/good", "20261102-same", [blocker(1, summary="visible same earlier")], started="2026-11-02T01:00:00.000Z")
folder(rv + "/clone", "20261102-same", [blocker(1, summary="visible same later")], started="2026-11-02T02:00:00.000Z")
PY
} | store_py unused || fail "writing two runs with one folder name"
rv_run --evidence --repo "$rv_key" --skip 13
has '.total == 16 and [.blockers[].summary] == ["visible same later", "visible same earlier", "visible good"] and .folders == 10 and .runs_read == 8 and .checkouts.duplicate_runs == 1' "two runs with one folder name both print and a copy does not"
# A copy of a run already read is known from its state alone: its artifacts are not read and checked again.
(cd "$work/rg-outside" && HOME="$rg_home" store_py unused <<PY) || fail "a copy must not be read in full"
checked = []
real_validate = b_run.validate_run


def noting(folder, schema):
    checked.append(folder)
    return real_validate(folder, schema)


b_run.validate_run = noting
out = b_run.cmd_stats(b_run.load_schema(), {"evidence": True, "repo": "$rv_key"})
assert (out["runs_read"], out["checkouts"]["duplicate_runs"], len(checked)) == (8, 1, 8), (out["runs_read"], len(checked))
PY
# A damaged start time costs no blocker: plain evidence never needed it.
make_repo "$work/rg-damaged"
{
  printf 'exec(open(%s).read())\ndamaged = %s\n' "'$work/evidence_runs.py'" "'$work/rg-damaged'"
  cat <<'PY'
path = folder(damaged, "20261110-damaged", [blocker(1, summary="visible despite a damaged start")])
state = json.loads((path / "state.json").read_text(encoding="utf-8"))
(path / "state.json").write_text(json.dumps({**state, "started_at": None}), encoding="utf-8")
PY
} | store_py unused || fail "writing a run with a damaged start time"
out=$(HOME="$rg_home" stats "$work/rg-damaged" --evidence) || fail "plain evidence with a damaged start time: $out"
has '[.blockers[].summary] == ["visible despite a damaged start"] and .runs_read == 1 and .skipped.invalid == 0' "a damaged start time drops no blocker"
# Refused uses of --repo.
for key in abc "${rv_key}0" ABCDEF0123456789 'aaaaaaaaaaaaaaa ' '' "$rv/good"; do
  bad_use --evidence --repo "$key"
done
bad_use --repo "$rv_key"
bad_use --summary --repo "$rv_key"
bad_use --record --repo "$rv_key"
bad_use --evidence --repo
python3 -I -B "$root/claude/bin/b_run.py" --help | grep -qF -- '--repo KEY reads another registered' || fail "help must name --repo"
python3 -I -B "$root/claude/bin/b_run.py" --help | grep -qF 'share root commits share one KEY and are read together' || fail "help must say that forks share a key"

# Refused uses of --evidence and --skip, and the help line (AC-7).
bad_use --evidence --record
bad_use --evidence --run 20261101-x
bad_use --evidence --summary
bad_use --evidence --since 2026-11-01
bad_use --evidence --section repo
bad_use --evidence --apply
bad_use --skip 0
bad_use --summary --skip 0
bad_use --record --skip 1
bad_use --evidence --skip
for count in -1 '' 1.5 1234567 ' 1' abc １; do
  bad_use --evidence --skip "$count"
done
python3 -I -B "$root/claude/bin/b_run.py" --help | grep -qF 'stats --evidence [--skip N]' || fail "help must name the evidence"
python3 -I -B "$root/claude/bin/b_run.py" --help | grep -qF "in front of its model provider" || fail "help must say where printed evidence goes"
python3 -I -B "$root/claude/bin/b_run.py" --help | grep -qF "printed as written" || fail "help must say that the text itself can hold paths"

# --- invalid use -------------------------------------------------------------------------------------------------------------------
if stats "$repoS" --run "20260101-x" 2>/dev/null; then fail "--run without --record must be refused"; fi
if stats "$repoS" --apply 2>/dev/null; then fail "stats must refuse --apply"; fi
