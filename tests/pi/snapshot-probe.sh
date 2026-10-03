#!/usr/bin/env bash
# Exercise pi/extensions/b-candidate-snapshot.ts against a scripted local model
# and throwaway git repositories. Needs only the installed Pi CLI, git, and jq:
# no npm packages, credentials, or network.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
if [ -z "${SNAPSHOT_PROBE_KEEP:-}" ]; then trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT; else echo "kept: $work" >&2; fi
export PI_CODING_AGENT_DIR="$work/home" PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
# Keep git from discovering an enclosing repository above the throwaway work dir.
export GIT_CEILING_DIRECTORIES="$work"
mkdir -p "$work/home"

fail() { echo "snapshot probe failed: $*" >&2; exit 1; }

# Canonical fallback flags; must match SNAPSHOT_DIFF_FLAGS in the extension.
flags=(--no-ext-diff --no-textconv --no-color --no-renames --ignore-submodules=none --submodule=short --binary)

make_repo() {
  local dir=$1
  mkdir -p "$dir/sub"
  git -C "$dir" init -q .
  git -C "$dir" config user.email probe@example.invalid
  git -C "$dir" config user.name probe
  printf 'a\n' >"$dir/a.txt"
  printf 'b\n' >"$dir/b.txt"
  printf 's\n' >"$dir/sub/s.txt"
  git -C "$dir" add .
  git -C "$dir" commit -qm init
}

# run <cwd> <scenario> <out>: one `pi` run whose stub model calls the tool.
run() {
  ( cd "$1" && pi -ne -e "$root/tests/pi/gate-stub-provider.ts" \
      -e "$root/pi/extensions/b-candidate-snapshot.ts" --model gate-stub/gate-1 \
      --mode json --no-session "$2" >"$3" )
}

# The structuredContent of each tool result, one JSON per line.
snapshots() {
  jq -c 'select(.type == "tool_execution_end" and .toolName == "b_candidate_snapshot")
         | .result.structuredContent' "$1"
}
is_error() {
  jq -r 'select(.type == "tool_execution_end" and .toolName == "b_candidate_snapshot") | .isError' "$1"
}

# --- clean candidate: determinism, manual equivalence, scope, read-only -------
clean="$work/clean"
make_repo "$clean"
printf 'a2\n' >>"$clean/a.txt"
git -C "$clean" add a.txt
printf 'b2\n' >>"$clean/b.txt"
printf 'new\n' >"$clean/new.txt"
head -c 256 /dev/urandom >"$clean/bin.dat"
ln -s a.txt "$clean/link"
index_before=$(sha256sum "$clean/.git/index" | cut -d' ' -f1)

run "$clean" snap-twice "$work/clean.jsonl"
[ "$(snapshots "$work/clean.jsonl" | wc -l | tr -d ' ')" = 2 ] || fail "expected two tool results"
first=$(snapshots "$work/clean.jsonl" | sed -n 1p)
[ "$first" = "$(snapshots "$work/clean.jsonl" | sed -n 2p)" ] || fail "repeated calls disagree"
[ "$(jq -r .complete <<<"$first")" = true ] || fail "clean candidate should be complete"
[ "$(jq -r .ignored_included <<<"$first")" = false ] || fail "ignored files must be excluded by default"
[ "$(jq -r '.ignored | length' <<<"$first")" = 0 ] || fail "no ignored files may be listed by default"
[ "$(jq -r .head <<<"$first")" = "$(git -C "$clean" rev-parse HEAD)" ] || fail "head mismatch"

want_staged=$(git -C "$clean" diff "${flags[@]}" --cached -- . | sha256sum | cut -d' ' -f1)
want_unstaged=$(git -C "$clean" diff "${flags[@]}" -- . | sha256sum | cut -d' ' -f1)
[ "$(jq -r .staged_diff_sha256 <<<"$first")" = "$want_staged" ] || fail "staged digest differs from manual"
[ "$(jq -r .unstaged_diff_sha256 <<<"$first")" = "$want_unstaged" ] || fail "unstaged digest differs from manual"
[ "$(jq -r '.changed_paths | join(",")' <<<"$first")" = "a.txt,b.txt" ] || fail "changed paths wrong"
[ "$(jq -r '[.untracked[].path] | join(",")' <<<"$first")" = "bin.dat,link,new.txt" ] || fail "untracked paths wrong"
[ "$(jq -r '.untracked[] | select(.path == "bin.dat") | .sha256' <<<"$first")" = "$(sha256sum "$clean/bin.dat" | cut -d' ' -f1)" ] || fail "binary digest wrong"
[ "$(jq -r '.untracked[] | select(.path == "link") | .type' <<<"$first")" = symlink ] || fail "symlink not typed"
[ "$(jq -r '.untracked[] | select(.path == "link") | .sha256' <<<"$first")" = "$(printf 'a.txt' | sha256sum | cut -d' ' -f1)" ] || fail "symlink digest wrong"

# A subdirectory cwd must not narrow the candidate.
run "$clean/sub" snap-once "$work/clean-sub.jsonl"
[ "$(snapshots "$work/clean-sub.jsonl")" = "$first" ] || fail "subdirectory cwd changed the snapshot"

[ "$(sha256sum "$clean/.git/index" | cut -d' ' -f1)" = "$index_before" ] || fail "tool modified .git/index"

fingerprint=$(jq -r .fingerprint <<<"$first")
printf 'more\n' >>"$clean/new.txt"
run "$clean" snap-once "$work/changed.jsonl"
[ "$(snapshots "$work/changed.jsonl" | jq -r .fingerprint)" != "$fingerprint" ] || fail "edit did not change fingerprint"
echo "snapshot probe passed: clean"

# --- ignored artifacts: excluded by default, covered only when named ----------
ign="$work/ign"
make_repo "$ign"
printf 'dist/\n.env\n' >"$ign/.gitignore"
git -C "$ign" add .gitignore
git -C "$ign" commit -qm ignore
mkdir -p "$ign/dist/sub"
printf 'out1\n' >"$ign/dist/out.js"
printf 'deep\n' >"$ign/dist/sub/deep.js"
printf 'TOPSECRET=1\n' >"$ign/.env"
run "$ign" snap-ignored "$work/ign.jsonl"
[ "$(snapshots "$work/ign.jsonl" | wc -l | tr -d ' ')" = 2 ] || fail "expected two ignored-scenario results"
plain=$(snapshots "$work/ign.jsonl" | sed -n 1p)
named=$(snapshots "$work/ign.jsonl" | sed -n 2p)
[ "$(jq -r .ignored_included <<<"$plain")" = false ] || fail "default call must report ignored files uncovered"
[ "$(jq -r .ignored_included <<<"$named")" = true ] || fail "named call must report ignored coverage"
[ "$(jq -r .complete <<<"$named")" = true ] || fail "named ignored artifacts should leave a complete snapshot"
[ "$(jq -r '[.ignored[].path] | join(",")' <<<"$named")" = "dist/out.js,dist/sub/deep.js" ] || fail "ignored paths wrong: $(jq -c '[.ignored[].path]' <<<"$named")"
[ "$(jq -r '.ignored[] | select(.path == "dist/out.js") | .sha256' <<<"$named")" = "$(sha256sum "$ign/dist/out.js" | cut -d' ' -f1)" ] || fail "ignored digest wrong"
[ "$(jq -r '[.untracked[].path] | join(",")' <<<"$named")" = "" ] || fail "ignored files leaked into untracked"
[ "$(jq -r .fingerprint <<<"$plain")" != "$(jq -r .fingerprint <<<"$named")" ] || fail "naming ignored paths did not change the fingerprint"
named_fp=$(jq -r .fingerprint <<<"$named")
printf 'out2\n' >"$ign/dist/out.js"
run "$ign" snap-ignored "$work/ign2.jsonl"
[ "$(snapshots "$work/ign2.jsonl" | sed -n 1p | jq -r .fingerprint)" = "$(jq -r .fingerprint <<<"$plain")" ] || fail "default fingerprint must not see an ignored edit"
[ "$(snapshots "$work/ign2.jsonl" | sed -n 2p | jq -r .fingerprint)" != "$named_fp" ] || fail "ignored edit did not change the named fingerprint"
run "$ign" snap-ignored-glob "$work/ign-glob.jsonl"
[ "$(is_error "$work/ign-glob.jsonl")" = true ] || fail "a glob must not expand include_ignored"
run "$ign" snap-ignored-missing "$work/ign-missing.jsonl"
[ "$(is_error "$work/ign-missing.jsonl")" = true ] || fail "an include_ignored path with no ignored file must be refused"
run "$ign" snap-ignored-outside "$work/ign-outside.jsonl"
[ "$(is_error "$work/ign-outside.jsonl")" = true ] || fail "an include_ignored path outside the repository must be refused"
SNAPSHOT_PROBE_ABSOLUTE="$ign/dist/out.js" run "$ign" snap-ignored-absolute "$work/ign-abs.jsonl"
[ "$(is_error "$work/ign-abs.jsonl")" = true ] || fail "an absolute include_ignored path must be refused"
# A replacement-character sibling must not satisfy a lone-surrogate lookalike.
printf 'sibling\n' >"$ign/dist/$(printf '\357\277\275').js"
run "$ign" snap-ignored-surrogate "$work/ign-surrogate.jsonl"
# jq cannot parse a lone-surrogate escape, so inspect the raw event line.
grep '"type":"tool_execution_end"' "$work/ign-surrogate.jsonl" | grep -F '"toolName":"b_candidate_snapshot"' | grep -Fq '"isError":true' \
  || fail "a lone surrogate selected a U+FFFD sibling"
rm -f "$ign/dist/$(printf '\357\277\275').js"
run "$ign" snap-ignored-secret "$work/ign-secret.jsonl"
[ "$(is_error "$work/ign-secret.jsonl")" = false ] || fail "an ignored protected path must return an incomplete snapshot"
secret=$(snapshots "$work/ign-secret.jsonl")
[ "$(jq -r .complete <<<"$secret")" = false ] || fail "an ignored protected path must be incomplete"
[ "$(jq -r '[.protected[] | select(.where | index("ignored"))] | length' <<<"$secret")" = 1 ] || fail "ignored protected path not listed"
grep -Fq TOPSECRET "$work/ign-secret.jsonl" && fail "ignored protected content reached the output"
echo "snapshot probe passed: ignored"

# --- protected paths: listed, never compared or read ---------------------------
guarded="$work/guarded"
make_repo "$guarded"
printf 'token: old\n' >"$guarded/secrets.yaml"
printf 'token: old\n' >"$guarded/hex:secrets.yaml"
mkdir "$guarded/secrets.store"
printf 'k\n' >"$guarded/secrets.store/a.txt"
git -C "$guarded" add .
git -C "$guarded" commit -qm secrets
# Same-size edits make git want to compare content; with mode 000 that comparison
# would fail loudly if git ever opened the file.
printf 'token: NEW\n' >"$guarded/secrets.yaml"
printf 'token: NEW\n' >"$guarded/hex:secrets.yaml"
printf 'v\n' >"$guarded/secrets.store/a.txt"
printf 'TOPSECRET=1\n' >"$guarded/.env"
printf 'b2\n' >>"$guarded/b.txt"
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$guarded/secrets.yaml" "$guarded/hex:secrets.yaml"
  if git -C "$guarded" diff --binary >/dev/null 2>"$work/control.err" || ! grep -q 'Permission denied' "$work/control.err"; then
    # A content diff over an unreadable same-size edit must fail; otherwise the
    # mode-000 trick proves nothing about reads.
    fail "negative control: plain git diff did not try to read the protected file"
  fi
  unreadable=1
else
  unreadable=0
fi
run "$guarded" snap-once "$work/guarded.jsonl"
[ "$(is_error "$work/guarded.jsonl")" = false ] || fail "protected candidate must return a snapshot, not an error"
guard=$(snapshots "$work/guarded.jsonl")
[ "$(jq -r .complete <<<"$guard")" = false ] || fail "protected candidate must be incomplete"
[ "$(jq -r '[.protected[].path] | sort | join(",")' <<<"$guard")" = ".env,hex:secrets.yaml,secrets.store/a.txt,secrets.yaml" ] || fail "protected paths wrong: $(jq -c '[.protected[].path]' <<<"$guard")"
# Even with a repo-relative path from a parent directory beneath the subtree cwd.
run "$guarded/secrets.store" snap-once "$work/guarded-sub.jsonl"
[ "$(snapshots "$work/guarded-sub.jsonl" | jq -r '[.protected[].path] | index("secrets.store/a.txt") != null')" = true ] || fail "subtree cwd hid a protected parent directory"
[ "$(jq -r '[.untracked[].path] | index(".env")' <<<"$guard")" = null ] || fail ".env must not be hashed"
want_guard=$(git -C "$guarded" diff "${flags[@]}" -- . ':(exclude,literal)secrets.yaml' ':(exclude,literal)hex:secrets.yaml' ':(exclude,literal)secrets.store/a.txt' 2>/dev/null | sha256sum | cut -d' ' -f1) || true
if [ "$unreadable" = 0 ]; then
  [ "$(jq -r .unstaged_diff_sha256 <<<"$guard")" = "$want_guard" ] || fail "protected change leaked into diff digest"
fi
grep -Fq TOPSECRET "$work/guarded.jsonl" && fail "protected content reached the output"
echo "snapshot probe passed: protected"

# --- non-UTF-8 names: classified on raw bytes ---------------------------------
raw="$work/raw"
make_repo "$raw"
if printf 'x\n' >"$raw/$(printf '\377.env')" 2>/dev/null; then
  run "$raw" snap-once "$work/raw.jsonl"
  snap=$(snapshots "$work/raw.jsonl")
  [ "$(jq -r '[.protected[].path_hex] | index("ff2e656e76") != null' <<<"$snap")" = true ] || fail "non-UTF-8 .env not classified as protected"
  [ "$(jq -r '[.untracked[].path_hex] | index("ff2e656e76")' <<<"$snap")" = null ] || fail "non-UTF-8 .env was hashed"
  [ "$(jq -r .complete <<<"$snap")" = false ] || fail "non-UTF-8 protected path must be incomplete"
  # Tracked and protected: cannot be excluded by pathspec, so the tool must refuse.
  git -C "$raw" add -- "$(printf '\377.env')"
  run "$raw" snap-once "$work/raw-tracked.jsonl"
  [ "$(is_error "$work/raw-tracked.jsonl")" = true ] || fail "tracked non-UTF-8 protected path must be refused"
  echo "snapshot probe passed: non-utf8"
else
  echo "snapshot probe skipped: non-utf8 (filesystem rejects raw bytes)"
fi

# --- submodules: never inspected, never complete ------------------------------
subsrc="$work/subsrc"
make_repo "$subsrc"
subrepo="$work/withsub"
make_repo "$subrepo"
git -C "$subrepo" -c protocol.file.allow=always submodule add -q "$subsrc" vendor >/dev/null 2>&1 \
  || fail "could not add a submodule fixture"
git -C "$subrepo" commit -qm submodule
printf 'dirty\n' >>"$subrepo/vendor/a.txt"
run "$subrepo" snap-once "$work/sub.jsonl"
[ "$(is_error "$work/sub.jsonl")" = false ] || fail "submodule candidate must return a snapshot"
snap=$(snapshots "$work/sub.jsonl")
[ "$(jq -r .complete <<<"$snap")" = false ] || fail "submodule candidate must be incomplete"
[ "$(jq -r '[.submodules[].path] | join(",")' <<<"$snap")" = vendor ] || fail "submodule not listed"
[ "$(jq -r '.submodules[0].index_oid' <<<"$snap")" = "$(git -C "$subrepo" rev-parse :vendor)" ] || fail "submodule index oid wrong"
echo "snapshot probe passed: submodule"

# --- repository filters: refused, never executed ------------------------------
filtered="$work/filtered"
make_repo "$filtered"
sentinel="$work/filter-ran"
printf '*.dat filter=evil\n' >"$filtered/.gitattributes"
printf 'one\n' >"$filtered/f.dat"
git -C "$filtered" add .
git -C "$filtered" commit -qm data
git -C "$filtered" config filter.evil.clean "touch '$sentinel'; cat"
printf 'two\n' >"$filtered/f.dat"
index_before=$(sha256sum "$filtered/.git/index" | cut -d' ' -f1)
run "$filtered" snap-once "$work/filter.jsonl"
[ "$(is_error "$work/filter.jsonl")" = true ] || fail "repository filter must be refused"
[ ! -e "$sentinel" ] || fail "the clean filter ran"
[ "$(sha256sum "$filtered/.git/index" | cut -d' ' -f1)" = "$index_before" ] || fail "refused snapshot modified .git/index"
# A configured filter that no path uses is harmless.
unused="$work/unused"
make_repo "$unused"
git -C "$unused" config filter.evil.clean "touch '$sentinel'; cat"
printf 'x\n' >>"$unused/a.txt"
run "$unused" snap-once "$work/unused.jsonl"
[ "$(is_error "$work/unused.jsonl")" = false ] || fail "unused filter driver must not refuse"
[ ! -e "$sentinel" ] || fail "an unused filter ran"
echo "snapshot probe passed: filters"

# An empty `filter=` value on an earlier path must not hide a later dotted driver.
emptyattr="$work/emptyattr"
make_repo "$emptyattr"
printf 'a.txt filter=\nb.txt filter=evil.name\n' >"$emptyattr/.gitattributes"
git -C "$emptyattr" add .
git -C "$emptyattr" commit -qm attrs
git -C "$emptyattr" config filter.evil.name.clean "touch '$sentinel'; cat"
printf 'a2\n' >>"$emptyattr/a.txt"
printf 'b2\n' >>"$emptyattr/b.txt"
run "$emptyattr" snap-once "$work/emptyattr.jsonl"
[ "$(is_error "$work/emptyattr.jsonl")" = true ] || fail "empty filter value hid an executable driver"
[ ! -e "$sentinel" ] || fail "the dotted-name clean filter ran"
echo "snapshot probe passed: empty-attribute"

# --- inherited git environment must not disable the protected exclusions -------
for var in GIT_LITERAL_PATHSPECS GIT_GLOB_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS; do
  ( export "$var=1"; run "$guarded" snap-once "$work/env-$var.jsonl" )
  [ "$(is_error "$work/env-$var.jsonl")" = false ] || fail "$var made a protected candidate fail or read it"
  [ "$(snapshots "$work/env-$var.jsonl" | jq -c 'del(.fingerprint)')" = "$(jq -c 'del(.fingerprint)' <<<"$guard")" ] || fail "$var changed the snapshot"
done
echo "snapshot probe passed: git-environment"

# --- partial clones: refused, no fetch, no object writes ----------------------
origin="$work/origin"
make_repo "$origin"
git -C "$origin" config uploadpack.allowFilter true
git -C "$origin" config uploadpack.allowAnySHA1InWant true
partial="$work/partial"
if git clone -q --no-local --filter=blob:none "file://$origin" "$partial" 2>/dev/null; then
  printf 'edit\n' >>"$partial/a.txt"
  objects_before=$(find "$partial/.git/objects" -type f | sort | sha256sum | cut -d' ' -f1)
  run "$partial" snap-once "$work/partial.jsonl"
  [ "$(is_error "$work/partial.jsonl")" = true ] || fail "partial clone must be refused"
  [ "$(find "$partial/.git/objects" -type f | sort | sha256sum | cut -d' ' -f1)" = "$objects_before" ] || fail "partial clone object store changed"
  echo "snapshot probe passed: partial-clone"
else
  echo "snapshot probe skipped: partial-clone (git cannot create a filtered clone here)"
fi

# --- repository names ending in whitespace ------------------------------------
mkdir -p "$work/ws"
make_repo "$work/ws/root"
make_repo "$work/ws/root "
printf 'only here\n' >"$work/ws/root /marker.txt"
git -C "$work/ws/root " add marker.txt
git -C "$work/ws/root " commit -qm marker
run "$work/ws/root " snap-once "$work/ws.jsonl"
[ "$(snapshots "$work/ws.jsonl" | jq -r .head)" = "$(git -C "$work/ws/root " rev-parse HEAD)" ] || fail "whitespace-suffixed repository resolved to a sibling"
echo "snapshot probe passed: whitespace-root"

# --- a non-UTF-8 repository root must be refused, not decoded lossily -----------
mkdir -p "$work/rawroot"
rawdir="$work/rawroot/root$(printf '\377')"
if mkdir "$rawdir" 2>/dev/null; then
  make_repo "$rawdir"
  make_repo "$work/rawroot/root$(printf '\357\277\275')"
  printf 'sibling\n' >"$work/rawroot/root$(printf '\357\277\275')/marker.txt"
  git -C "$work/rawroot/root$(printf '\357\277\275')" add marker.txt
  git -C "$work/rawroot/root$(printf '\357\277\275')" commit -qm sibling
  ln -s "$rawdir" "$work/rawroot/link"
  run "$work/rawroot/link" snap-once "$work/rawroot.jsonl"
  [ "$(is_error "$work/rawroot.jsonl")" = true ] || fail "non-UTF-8 repository root must be refused"
  echo "snapshot probe passed: non-utf8-root"
else
  echo "snapshot probe skipped: non-utf8-root (filesystem rejects raw bytes)"
fi

# --- not a repository: a failed tool result, never a bogus snapshot ------------
mkdir -p "$work/plain"
run "$work/plain" snap-once "$work/plain.jsonl"
[ "$(is_error "$work/plain.jsonl")" = true ] || fail "non-repository should error"
echo "snapshot probe passed: non-repository"
