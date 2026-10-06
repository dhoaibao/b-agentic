#!/usr/bin/env bash
# install.sh - bootstrap, refresh, or remove the Claude Code b-agentic setup.
#
# Usage:
#   ./install.sh [--dry-run] [--force] [--with-clickup]   install or sync from this checkout
#   ./install.sh --update                                 fast-forward the checkout, then sync
#   ./install.sh --uninstall                              remove what the manifest recorded
#   curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash
#
# From a checkout the script installs that checkout. When piped, it clones the
# source to B_AGENTIC_DIR (default ~/.b-agentic-claude, never ~/.b-agentic) first.
# --dry-run changes nothing, including the clone and the fetch. The script never
# runs vendor installers and never writes under ~/.pi; only ~/.claude is supported.

set -euo pipefail

REPO_URL="${B_AGENTIC_REPO:-https://github.com/dhoaibao/b-agentic.git}"
CLONE_DIR="${B_AGENTIC_DIR:-$HOME/.b-agentic-claude}"
REF="${B_AGENTIC_REF:-}"
UPDATE=0
DRY_RUN=0
UNINSTALL=0
PASSTHROUGH=()

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --update) UPDATE=1 ;;
    --dry-run) DRY_RUN=1; PASSTHROUGH+=("$1") ;;
    --uninstall) UNINSTALL=1; PASSTHROUGH+=("$1") ;;
    --force|--with-clickup|--without-clickup) PASSTHROUGH+=("$1") ;;
    --ref=*) REF="${1#--ref=}"; [ -n "$REF" ] || die 'invalid empty --ref' ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

if [ -n "$REF" ] && ! [[ "$REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]; then
  die 'invalid --ref or B_AGENTIC_REF; use a tag, branch, or commit-like name'
fi
case "$REPO_URL" in
  https://*|http://*|ssh://*|git@*|/*|./*|../*) ;;
  *) die 'invalid B_AGENTIC_REPO; use an https, ssh, or local-path repository URL' ;;
esac
command -v python3 >/dev/null 2>&1 || die 'python3 is required'

# refuse_protected_dir <dir>: the clone/update destination must not be the home
# directory or sit under the frozen Pi runtime, resolving symlinks first.
refuse_protected_dir() {
  python3 - "$1" <<'PY' || die "refusing to use $1 as the source directory (home directory, or under ~/.pi)"
import os
import sys

home = os.path.expanduser("~")
dest = os.path.realpath(sys.argv[1])
pi_roots = {os.path.join(home, ".pi"), os.path.realpath(os.path.join(home, ".pi"))}
if dest in {os.path.realpath(home), "/"}:
    raise SystemExit(1)
if any(dest == root or dest.startswith(root + os.sep) for root in pi_roots):
    raise SystemExit(1)
PY
}

# sgit <args>: git with every destination override cleared, so the operation can only
# touch the checkout it is pointed at (GIT_DIR and friends would redirect writes).
sgit() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
    -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_NAMESPACE git "$@"
}

# verify_checkout <dir>: the worktree, git directory, and common directory that git
# would actually write to must all be outside the protected locations, and the
# worktree must be the checkout itself (not a repository above it).
verify_checkout() {
  local dir=$1 toplevel gitdir common
  toplevel="$(sgit -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || die "$dir is not a usable git checkout"
  gitdir="$(sgit -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)" || die "$dir is not a usable git checkout"
  common="$(cd "$dir" && sgit rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || die "$dir is not a usable git checkout"
  [ "$(cd "$toplevel" && pwd -P)" = "$(cd "$dir" && pwd -P)" ] || die "$dir is not the root of its git worktree"
  refuse_protected_dir "$toplevel"
  refuse_protected_dir "$gitdir"
  refuse_protected_dir "$common"
}

SELF_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/skills/registry.yaml" ] && [ -d "$SELF_DIR/claude" ]; then
  SOURCE_DIR="$SELF_DIR"
else
  SOURCE_DIR="$CLONE_DIR"
  command -v git >/dev/null 2>&1 || die 'git is required to prepare the b-agentic source'
  refuse_protected_dir "$SOURCE_DIR"
  if [ ! -e "$SOURCE_DIR/.git" ]; then
    if [ "$DRY_RUN" -eq 1 ] || [ "$UNINSTALL" -eq 1 ]; then
      die "no b-agentic source checkout at $SOURCE_DIR; --dry-run and --uninstall do not clone"
    fi
    log "Cloning source: $REPO_URL -> $SOURCE_DIR"
    mkdir -p "$(dirname "$SOURCE_DIR")"
    sgit clone --quiet -- "$REPO_URL" "$SOURCE_DIR"
    verify_checkout "$SOURCE_DIR"
    if [ -n "$REF" ]; then sgit -C "$SOURCE_DIR" checkout --quiet "$REF" --; fi
  else
    UPDATE=1
  fi
fi

refuse_protected_dir "$SOURCE_DIR"

if [ -e "$SOURCE_DIR/.git" ] && [ "$UNINSTALL" -eq 0 ]; then
  if [ "$UPDATE" -eq 1 ] || { [ -n "$REF" ] && [ "$SOURCE_DIR" = "$CLONE_DIR" ]; }; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log "[dry-run] would update the source checkout: $SOURCE_DIR${REF:+ to $REF}"
    else
      log "Updating source: $SOURCE_DIR"
      verify_checkout "$SOURCE_DIR"
      sgit -C "$SOURCE_DIR" fetch --quiet --tags --prune
      if [ -n "$REF" ]; then
        sgit -C "$SOURCE_DIR" checkout --quiet "$REF" --
      elif sgit -C "$SOURCE_DIR" symbolic-ref -q HEAD >/dev/null 2>&1; then
        sgit -C "$SOURCE_DIR" pull --ff-only --quiet
      else
        die "detached HEAD checkout at $SOURCE_DIR cannot be updated automatically; pass --ref=<branch>"
      fi
    fi
  fi
fi

exec python3 "$SOURCE_DIR/tooling/install/claude_install.py" --source "$SOURCE_DIR" ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
