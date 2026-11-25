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

# finish_run REPO SLUG: a quick run through QA to done, then commit its change so the next run starts clean.
finish_run() {
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
  ok "$repo" s1 advance "done"
  git -C "$repo" commit -qam "run $slug"
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

# --- invalid use -------------------------------------------------------------------------------------------------------------------
if stats "$repoS" --run "20260101-x" 2>/dev/null; then fail "--run without --record must be refused"; fi
if stats "$repoS" --apply 2>/dev/null; then fail "stats must refuse --apply"; fi
