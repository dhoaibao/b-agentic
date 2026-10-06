#!/usr/bin/env bash
# Exercise claude/bin/b-candidate-snapshot.mjs against throwaway git
# repositories. Needs only node, git, and jq: no npm packages, credentials, or
# network. Exit code contract: 0 complete, 3 incomplete, 2 refused or failed.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cli="$root/claude/bin/b-candidate-snapshot.mjs"
work=$(mktemp -d)
if [ -z "${SNAPSHOT_PROBE_KEEP:-}" ]; then trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT; else echo "kept: $work" >&2; fi
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
# Keep git from discovering an enclosing repository above the throwaway work dir.
export GIT_CEILING_DIRECTORIES="$work"

fail() { echo "snapshot probe failed: $*" >&2; exit 1; }

# Canonical diff flags; must match SNAPSHOT_DIFF_FLAGS in the CLI.
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

# snap <cwd> <out> [cli args...]: write stdout to <out>, stderr to <out>.err, and
# the exit code to <out>.rc without aborting the script.
snap() {
  local cwd=$1 out=$2
  shift 2
  local rc=0
  ( cd "$cwd" && node "$cli" "$@" >"$out" 2>"$out.err" ) || rc=$?
  printf '%s' "$rc" >"$out.rc"
}
rc_of() { cat "$1.rc"; }
expect_refused() { [ "$(rc_of "$1")" = 2 ] || fail "$2 (exit $(rc_of "$1"): $(head -c 200 "$1.err"))"; }

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

snap "$clean" "$work/c1.json"
snap "$clean" "$work/c2.json"
[ "$(rc_of "$work/c1.json")" = 0 ] || fail "clean candidate should exit 0"
cmp -s "$work/c1.json" "$work/c2.json" || fail "repeated calls disagree"
first=$(cat "$work/c1.json")
[ "$(jq -r .schema <<<"$first")" = "b-candidate-snapshot/3" ] || fail "schema changed"
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

# --fingerprint prints exactly the fingerprint of the JSON mode.
snap "$clean" "$work/c-fp.txt" --fingerprint
[ "$(cat "$work/c-fp.txt")" = "$(jq -r .fingerprint <<<"$first")" ] || fail "--fingerprint disagrees with the JSON fingerprint"

# A subdirectory cwd must not narrow the candidate.
snap "$clean/sub" "$work/c-sub.json"
cmp -s "$work/c1.json" "$work/c-sub.json" || fail "subdirectory cwd changed the snapshot"

[ "$(sha256sum "$clean/.git/index" | cut -d' ' -f1)" = "$index_before" ] || fail "CLI modified .git/index"

fingerprint=$(jq -r .fingerprint <<<"$first")
printf 'more\n' >>"$clean/new.txt"
snap "$clean" "$work/c-changed.json"
[ "$(jq -r .fingerprint "$work/c-changed.json")" != "$fingerprint" ] || fail "edit did not change fingerprint"
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
snap "$ign" "$work/i-plain.json"
snap "$ign" "$work/i-named.json" --include-ignored dist
plain=$(cat "$work/i-plain.json")
named=$(cat "$work/i-named.json")
[ "$(rc_of "$work/i-named.json")" = 0 ] || fail "named ignored artifacts should leave a complete snapshot"
[ "$(jq -r .ignored_included <<<"$plain")" = false ] || fail "default call must report ignored files uncovered"
[ "$(jq -r .ignored_included <<<"$named")" = true ] || fail "named call must report ignored coverage"
[ "$(jq -r '[.ignored[].path] | join(",")' <<<"$named")" = "dist/out.js,dist/sub/deep.js" ] || fail "ignored paths wrong: $(jq -c '[.ignored[].path]' <<<"$named")"
[ "$(jq -r '.ignored[] | select(.path == "dist/out.js") | .sha256' <<<"$named")" = "$(sha256sum "$ign/dist/out.js" | cut -d' ' -f1)" ] || fail "ignored digest wrong"
[ "$(jq -r '[.untracked[].path] | join(",")' <<<"$named")" = "" ] || fail "ignored files leaked into untracked"
[ "$(jq -r .fingerprint <<<"$plain")" != "$(jq -r .fingerprint <<<"$named")" ] || fail "naming ignored paths did not change the fingerprint"
named_fp=$(jq -r .fingerprint <<<"$named")
printf 'out2\n' >"$ign/dist/out.js"
snap "$ign" "$work/i-plain2.json"
snap "$ign" "$work/i-named2.json" --include-ignored dist
[ "$(jq -r .fingerprint "$work/i-plain2.json")" = "$(jq -r .fingerprint <<<"$plain")" ] || fail "default fingerprint must not see an ignored edit"
[ "$(jq -r .fingerprint "$work/i-named2.json")" != "$named_fp" ] || fail "ignored edit did not change the named fingerprint"
snap "$ign" "$work/i-glob.json" --include-ignored 'dist/*.js'
expect_refused "$work/i-glob.json" "a glob must not expand --include-ignored"
snap "$ign" "$work/i-missing.json" --include-ignored nothing-here
expect_refused "$work/i-missing.json" "an --include-ignored path with no ignored file must be refused"
snap "$ign" "$work/i-outside.json" --include-ignored ../clean/new.txt
expect_refused "$work/i-outside.json" "an --include-ignored path outside the repository must be refused"
snap "$ign" "$work/i-abs.json" --include-ignored "$ign/dist/out.js"
expect_refused "$work/i-abs.json" "an absolute --include-ignored path must be refused"
snap "$ign" "$work/i-nopath.json" --include-ignored
expect_refused "$work/i-nopath.json" "--include-ignored without a path must be refused"
snap "$ign" "$work/i-fffd.json" --include-ignored "dist/$(printf '\357\277\275').js"
expect_refused "$work/i-fffd.json" "a U+FFFD path must be refused"
snap "$ign" "$work/i-secret.json" --include-ignored .env
[ "$(rc_of "$work/i-secret.json")" = 3 ] || fail "an ignored protected path must return an incomplete snapshot (exit 3)"
secret=$(cat "$work/i-secret.json")
[ "$(jq -r .complete <<<"$secret")" = false ] || fail "an ignored protected path must be incomplete"
[ "$(jq -r '[.protected[] | select(.where | index("ignored"))] | length' <<<"$secret")" = 1 ] || fail "ignored protected path not listed"
grep -Fq TOPSECRET "$work/i-secret.json" && fail "ignored protected content reached the output"
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
snap "$guarded" "$work/g.json"
[ "$(rc_of "$work/g.json")" = 3 ] || fail "protected candidate must return an incomplete snapshot (exit 3), not an error"
guard=$(cat "$work/g.json")
[ "$(jq -r .complete <<<"$guard")" = false ] || fail "protected candidate must be incomplete"
[ "$(jq -r '[.protected[].path] | sort | join(",")' <<<"$guard")" = ".env,hex:secrets.yaml,secrets.store/a.txt,secrets.yaml" ] || fail "protected paths wrong: $(jq -c '[.protected[].path]' <<<"$guard")"
# Even from a subtree cwd beneath a protected parent directory.
snap "$guarded/secrets.store" "$work/g-sub.json"
[ "$(jq -r '[.protected[].path] | index("secrets.store/a.txt") != null' "$work/g-sub.json")" = true ] || fail "subtree cwd hid a protected parent directory"
[ "$(jq -r '[.untracked[].path] | index(".env")' <<<"$guard")" = null ] || fail ".env must not be hashed"
want_guard=$(git -C "$guarded" diff "${flags[@]}" -- . ':(exclude,literal)secrets.yaml' ':(exclude,literal)hex:secrets.yaml' ':(exclude,literal)secrets.store/a.txt' 2>/dev/null | sha256sum | cut -d' ' -f1) || true
if [ "$unreadable" = 0 ]; then
  [ "$(jq -r .unstaged_diff_sha256 <<<"$guard")" = "$want_guard" ] || fail "protected change leaked into diff digest"
fi
grep -Fq TOPSECRET "$work/g.json" && fail "protected content reached the output"

# --check-protected: metadata-only guard for the Codex review gate.
snap "$guarded" "$work/gp.json" --check-protected
[ "$(rc_of "$work/gp.json")" = 3 ] || fail "--check-protected must block when protected paths are tracked or untracked"
[ "$(jq -r '.blocking | sort | join(",")' "$work/gp.json")" = ".env,hex:secrets.yaml,secrets.store/a.txt,secrets.yaml" ] || fail "blocking list wrong: $(jq -c .blocking "$work/gp.json")"
[ "$(jq -r .ok "$work/gp.json")" = false ] || fail "--check-protected ok must be false"
grep -Fq TOPSECRET "$work/gp.json" && fail "--check-protected exposed content"
# Ignored-only protected files are warnings, not blockers (accepted residual risk).
snap "$ign" "$work/ip.json" --check-protected
[ "$(rc_of "$work/ip.json")" = 0 ] || fail "ignored-only protected files must not block"
[ "$(jq -r '[.protected[] | select(.where | index("ignored"))] | length' "$work/ip.json")" = 1 ] || fail "ignored protected path not reported by --check-protected"
[ "$(jq -r '.blocking | length' "$work/ip.json")" = 0 ] || fail "ignored-only protected file reported as blocking"
snap "$clean" "$work/cp.json" --check-protected
[ "$(rc_of "$work/cp.json")" = 0 ] || fail "a repository with no protected paths must pass --check-protected"
echo "snapshot probe passed: protected"

# --- non-UTF-8 names: classified on raw bytes ---------------------------------
raw="$work/raw"
make_repo "$raw"
if printf 'x\n' >"$raw/$(printf '\377.env')" 2>/dev/null; then
  snap "$raw" "$work/raw.json"
  [ "$(jq -r '[.protected[].path_hex] | index("ff2e656e76") != null' "$work/raw.json")" = true ] || fail "non-UTF-8 .env not classified as protected"
  [ "$(jq -r '[.untracked[].path_hex] | index("ff2e656e76")' "$work/raw.json")" = null ] || fail "non-UTF-8 .env was hashed"
  [ "$(jq -r .complete "$work/raw.json")" = false ] || fail "non-UTF-8 protected path must be incomplete"
  # Tracked and protected: cannot be excluded by pathspec, so the CLI must refuse.
  git -C "$raw" add -- "$(printf '\377.env')"
  snap "$raw" "$work/raw-tracked.json"
  expect_refused "$work/raw-tracked.json" "tracked non-UTF-8 protected path must be refused"
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
snap "$subrepo" "$work/sub.json"
[ "$(rc_of "$work/sub.json")" = 3 ] || fail "submodule candidate must return an incomplete snapshot (exit 3)"
snapjson=$(cat "$work/sub.json")
[ "$(jq -r .complete <<<"$snapjson")" = false ] || fail "submodule candidate must be incomplete"
[ "$(jq -r '[.submodules[].path] | join(",")' <<<"$snapjson")" = vendor ] || fail "submodule not listed"
[ "$(jq -r '.submodules[0].index_oid' <<<"$snapjson")" = "$(git -C "$subrepo" rev-parse :vendor)" ] || fail "submodule index oid wrong"
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
snap "$filtered" "$work/filter.json"
expect_refused "$work/filter.json" "repository filter must be refused"
[ ! -e "$sentinel" ] || fail "the clean filter ran"
[ "$(sha256sum "$filtered/.git/index" | cut -d' ' -f1)" = "$index_before" ] || fail "refused snapshot modified .git/index"
# A configured filter that no path uses is harmless.
unused="$work/unused"
make_repo "$unused"
git -C "$unused" config filter.evil.clean "touch '$sentinel'; cat"
printf 'x\n' >>"$unused/a.txt"
snap "$unused" "$work/unused.json"
[ "$(rc_of "$work/unused.json")" = 0 ] || fail "unused filter driver must not refuse"
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
snap "$emptyattr" "$work/emptyattr.json"
expect_refused "$work/emptyattr.json" "empty filter value hid an executable driver"
[ ! -e "$sentinel" ] || fail "the dotted-name clean filter ran"
echo "snapshot probe passed: empty-attribute"

# --- inherited git environment must not disable the protected exclusions -------
for var in GIT_LITERAL_PATHSPECS GIT_GLOB_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS; do
  ( export "$var=1"; snap "$guarded" "$work/env-$var.json" )
  [ "$(rc_of "$work/env-$var.json")" = 3 ] || fail "$var made a protected candidate fail or read it"
  [ "$(jq -c 'del(.fingerprint)' "$work/env-$var.json")" = "$(jq -c 'del(.fingerprint)' <<<"$guard")" ] || fail "$var changed the snapshot"
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
  snap "$partial" "$work/partial.json"
  expect_refused "$work/partial.json" "partial clone must be refused"
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
snap "$work/ws/root " "$work/ws.json"
[ "$(jq -r .head "$work/ws.json")" = "$(git -C "$work/ws/root " rev-parse HEAD)" ] || fail "whitespace-suffixed repository resolved to a sibling"
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
  snap "$work/rawroot/link" "$work/rawroot.json"
  expect_refused "$work/rawroot.json" "non-UTF-8 repository root must be refused"
  # The secret guard must refuse the same lookalike instead of scanning the sibling.
  snap "$work/rawroot/link" "$work/rawroot-check.json" --check-protected
  expect_refused "$work/rawroot-check.json" "--check-protected must refuse a non-UTF-8 repository root"
  [ ! -s "$work/rawroot-check.json" ] || fail "--check-protected printed a result for a lookalike repository"
  # A non-UTF-8 subtree beneath a valid root is refused in both modes.
  make_repo "$work/validroot"
  mkdir "$work/validroot/sub$(printf '\377')"
  snap "$work/validroot/sub$(printf '\377')" "$work/rawsub.json"
  expect_refused "$work/rawsub.json" "non-UTF-8 subtree cwd must be refused"
  snap "$work/validroot/sub$(printf '\377')" "$work/rawsub-check.json" --check-protected
  expect_refused "$work/rawsub-check.json" "--check-protected must refuse a non-UTF-8 subtree cwd"
  echo "snapshot probe passed: non-utf8-root"
else
  echo "snapshot probe skipped: non-utf8-root (filesystem rejects raw bytes)"
fi

# --- guard boundaries: opaque repositories fail the guard closed ---------------
snap "$subrepo" "$work/gsub.json" --check-protected
[ "$(rc_of "$work/gsub.json")" = 3 ] || fail "--check-protected must block on a submodule gitlink (exit $(rc_of "$work/gsub.json"))"
[ "$(jq -r '[.opaque[] | select(.kind == "submodule") | .path] | join(",")' "$work/gsub.json")" = vendor ] || fail "submodule not reported as opaque"
[ "$(jq -r .ok "$work/gsub.json")" = false ] || fail "submodule guard ok must be false"

embedded="$work/embedded"
make_repo "$embedded"
git init -q "$embedded/nested.env"
git init -q "$embedded/tools"
snap "$embedded" "$work/gemb.json" --check-protected
[ "$(rc_of "$work/gemb.json")" = 3 ] || fail "--check-protected must block on embedded repositories (exit $(rc_of "$work/gemb.json"))"
[ "$(jq -r '[.opaque[] | select(.kind == "embedded-repository") | .path] | sort | join(",")' "$work/gemb.json")" = "nested.env,tools" ] || fail "embedded repositories not reported as opaque: $(jq -c .opaque "$work/gemb.json")"
[ "$(jq -r '.blocking | join(",")' "$work/gemb.json")" = "nested.env" ] || fail "embedded repository with a protected name was not blocking"

innocent="$work/innocent"
make_repo "$innocent"
git init -q "$innocent/tools"
snap "$innocent" "$work/ginn.json" --check-protected
[ "$(rc_of "$work/ginn.json")" = 3 ] || fail "an innocuously named embedded repository must still block the guard"
[ "$(jq -r '.blocking | length' "$work/ginn.json")" = 0 ] || fail "innocuous embedded repository must not be listed as a protected path"
echo "snapshot probe passed: guard-boundaries"

# --- symlinked launcher still runs the CLI --------------------------------------
ln -s "$cli" "$work/launcher.mjs"
( cd "$clean" && node "$work/launcher.mjs" --fingerprint >"$work/launcher.out" 2>"$work/launcher.err" ) || fail "symlinked launcher failed"
[ "$(cat "$work/launcher.out")" = "$(jq -r .fingerprint <(cd "$clean" && node "$cli"))" ] || fail "symlinked launcher printed no or a different fingerprint"
echo "snapshot probe passed: launcher"

# --- not a repository: a failure, never a bogus snapshot ----------------------
mkdir -p "$work/plain"
snap "$work/plain" "$work/plain.json"
expect_refused "$work/plain.json" "non-repository should fail"
snap "$work/plain" "$work/plain-check.json" --check-protected
expect_refused "$work/plain-check.json" "--check-protected outside a repository should fail"
[ ! -s "$work/plain.json" ] || fail "a failed snapshot printed output on stdout"
echo "snapshot probe passed: non-repository"

# --- usage errors ---------------------------------------------------------------
snap "$clean" "$work/usage.json" --bogus
expect_refused "$work/usage.json" "an unknown argument must be refused"
echo "snapshot probe passed: usage"
