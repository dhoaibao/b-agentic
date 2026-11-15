#!/usr/bin/env bash
# Compare the snapshot CLI at a baseline git ref with the working tree on a set of
# fixture repositories: stdout, stderr, and exit code must be byte-identical, so a
# speed-up of the CLI cannot change a fingerprint. Needs only node and git (and bun, when installed, for the bun comparison).
# Set BASE_REF to the commit to compare against; without it the probe is skipped
# (a baseline is only meaningful while the CLI differs from some earlier ref).
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
if [ -z "${BASE_REF:-}" ]; then
  echo "snapshot parity probe skipped: set BASE_REF to a baseline commit"
  exit 0
fi
work=$(mktemp -d)
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_CEILING_DIRECTORIES="$work"

fail() { echo "snapshot parity probe failed: $*" >&2; exit 1; }

# The baseline CLI and every module it imports, exactly as committed at BASE_REF.
mkdir -p "$work/base"
git -C "$root" archive "$BASE_REF" claude/bin | tar -x -C "$work/base" || fail "cannot read $BASE_REF"
base_cli="$work/base/claude/bin/b-candidate-snapshot.mjs"
new_cli="$root/claude/bin/b-candidate-snapshot.mjs"
[ -f "$base_cli" ] || fail "no snapshot CLI at $BASE_REF"

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

# The baseline always runs under node (the CLI stays runnable under node); the changed CLI runs under node and,
# when it is installed, under bun with the hardening flags the installer writes (ADR-018).
runtimes=("node")
if command -v bun >/dev/null 2>&1; then runtimes+=("bun --no-env-file --config=/dev/null"); fi

# compare NAME REPO [cli args...]: run the baseline and the changed CLI in REPO and require identical results.
compare() {
  local name=$1 repo=$2 old_rc=0 new_rc runtime
  shift 2
  (cd "$repo" && node "$base_cli" "$@" >"$work/old.out" 2>"$work/old.err") || old_rc=$?
  for runtime in "${runtimes[@]}"; do
    new_rc=0
    # shellcheck disable=SC2086 # The runtime entry is a command with its flags.
    (cd "$repo" && $runtime "$new_cli" "$@" >"$work/new.out" 2>"$work/new.err") || new_rc=$?
    [ "$old_rc" = "$new_rc" ] || fail "$name ($runtime): exit code $old_rc at $BASE_REF, $new_rc now"
    cmp -s "$work/old.out" "$work/new.out" || fail "$name ($runtime): stdout differs"
    cmp -s "$work/old.err" "$work/new.err" || fail "$name ($runtime): stderr differs"
  done
  echo "snapshot parity probe passed: $name (exit $new_rc)"
}

clean="$work/clean"
make_repo "$clean"
compare "unchanged tree" "$clean"

printf 'a2\n' >>"$clean/a.txt"
git -C "$clean" add a.txt
printf 'b2\n' >>"$clean/b.txt"
printf 'new\n' >"$clean/new.txt"
head -c 256 /dev/urandom >"$clean/bin.dat"
ln -s a.txt "$clean/link"
compare "staged, unstaged, untracked, binary, symlink" "$clean"
compare "from a subdirectory" "$clean/sub"
compare "--fingerprint" "$clean" --fingerprint

mkdir -p "$clean/out"
printf 'artifact\n' >"$clean/out/artifact.txt"
printf 'out/\n' >"$clean/.gitignore"
compare "ignored artifact included" "$clean" --include-ignored out/artifact.txt
compare "ignored path that matches nothing" "$clean" --include-ignored missing.txt

prot="$work/protected"
make_repo "$prot"
printf 'S=1\n' >"$prot/.env"
printf 'k\n' >"$prot/secrets.json"
git -C "$prot" add secrets.json
printf 'e\n' >"$prot/.env.example"
compare "protected untracked and tracked paths" "$prot"
compare "--check-protected" "$prot" --check-protected

del="$work/deleted"
make_repo "$del"
printf 'k\n' >"$del/prod.env"
mkdir -p "$del/d.env"
printf 'x\n' >"$del/d.env/inner.txt"
git -C "$del" add .
git -C "$del" commit -qm more
git -C "$del" rm -q -f prod.env b.txt
git -C "$del" rm -q -r -f d.env
printf 'file now\n' >"$del/d.env"
git -C "$del" add d.env
git -C "$del" mv a.txt moved.txt
compare "staged deletions, a protected deletion, and a directory turned file" "$del"

flag="$work/flags"
make_repo "$flag"
git -C "$flag" update-index --assume-unchanged a.txt
printf 'hidden edit\n' >>"$flag/a.txt"
compare "assume-unchanged tracked file" "$flag"

odd="$work/odd"
make_repo "$odd"
printf 'x\n' >"$odd/$(printf 'bad\377name.txt')"
compare "non-UTF-8 untracked name" "$odd"

filt="$work/filter"
make_repo "$filt"
git -C "$filt" config filter.x.clean cat
printf 'a.txt filter=x\n' >"$filt/.gitattributes"
git -C "$filt" add .gitattributes
compare "executable clean filter is refused" "$filt"

plain="$work/plain"
mkdir -p "$plain"
compare "not a repository" "$plain"

nohead="$work/nohead"
mkdir -p "$nohead"
git -C "$nohead" init -q .
printf 'n\n' >"$nohead/n.txt"
compare "repository without a commit" "$nohead"

echo "snapshot parity probe passed"
