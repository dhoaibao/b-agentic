#!/usr/bin/env bash
# install.sh - bootstrap, refresh, or remove the b-agentic setup for Claude Code, Pi, or all runtimes.
#
# Usage:
#   ./install.sh [--dry-run] [--force] [-y]               install or sync from this checkout
#   ./install.sh --with=excalidraw,drawio                 install optional components (datagrip, tablepro,
#                                                         excalidraw, drawio, notion); --without=ID removes them
#   ./install.sh --statusline-only                        install only the Claude Code status line (a later
#                                                         full install upgrades it; --uninstall removes it)
#   ./install.sh --update                                 fast-forward the checkout, then sync
#   ./install.sh --uninstall                              remove what the manifest recorded
#   ./install.sh --runtime=pi [--dry-run] [--force] [-y]  install, sync, or (--uninstall) remove the Pi runtime
#                                                         under ~/.pi/agent (ADR-030); npm packages stay Pi-managed
#   ./install.sh --runtime=all [--dry-run] [--force] [-y] install, sync, or (--uninstall) remove both Claude Code
#                                                         and Pi from a local checkout (preflights both first)
#   curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash
#
# From a checkout the script installs that checkout. When piped, it clones the
# source to B_AGENTIC_DIR (default ~/.b-agentic-claude, never ~/.b-agentic) first.
# --dry-run changes nothing, including the clone and the fetch. Unless you accept an interactive [y/N] prompt after
# sync (skipped under -y, --dry-run, --uninstall, --statusline-only, non-terminal stdout, or no /dev/tty), the script
# runs no vendor installers. A Claude Code sync touches only ~/.claude and ~/.claude.json, and never anything under
# ~/.pi or ~/.config/opencode (the OpenCode runtime was removed; see docs/decisions/ADR-020-claude-code-only-again.md).
# Post-sync Claude [y/N] prompts offer `curl -fsSL https://claude.ai/install.sh | bash`,
# `curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh`,
# `rtk init -g --hook-only --auto-patch`, and
# `curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh | sh` (approved vendor scripts
# install their own binaries outside ~/.claude, and `rtk init` adds the RTK hook to ~/.claude/settings.json).
# A Pi sync (--runtime=pi) writes only ~/.pi/agent and never touches ~/.claude or ~/.claude.json; post-sync Pi [y/N]
# prompts offer `curl -fsSL https://pi.dev/install.sh | sh` plus the `rtk` and `codegraph` curl scripts above (never
# `rtk init`, writing outside ~/.pi/agent).
# An all-runtimes sync (--runtime=all) preflights and plans both Claude Code and Pi before writing either, follows the
# --runtime=pi flag restrictions (local checkout only; no --statusline-only, --update, --ref, or piped clone), and on
# an interactive terminal offers each missing vendor tool once (`claude`, `pi`, `rtk`, `codegraph`, plus the RTK hook).
# Optional components are never installed without a choice: a terminal shows a checkbox list (nothing
# checked on a fresh install; installed ones are pre-checked), while -y, --dry-run, or no terminal keeps
# the recorded choice and otherwise installs none. --with/--without are additive and repeatable.
# On a terminal the installer shows a step timeline and asks before writing (via /dev/tty,
# so it works when piped); -y/--yes, --dry-run, --uninstall, or no terminal keeps the plain output.

set -euo pipefail

REPO_URL="${B_AGENTIC_REPO:-https://github.com/dhoaibao/b-agentic.git}"
CLONE_DIR="${B_AGENTIC_DIR:-$HOME/.b-agentic-claude}"
REF="${B_AGENTIC_REF:-}"
UPDATE=0
DRY_RUN=0
UNINSTALL=0
YES=0
RUNTIME=claude
STATUSLINE=0
NOTES=""
PASSTHROUGH=()

die() {
  [ -z "$NOTES" ] || printf '%s\n' "$NOTES"
  printf 'error: %s\n' "$*" >&2
  exit 1
}
log() { printf '%s\n' "$*"; }
# note <text>: a progress line. When the installer will draw its terminal UI it takes the notes over
# (B_AGENTIC_NOTES) and shows them as steps under its header; otherwise they print immediately.
note() {
  if [ "$FANCY" -eq 1 ]; then NOTES="${NOTES:+$NOTES$'\n'}$*"; else log "$*"; fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --update) UPDATE=1 ;;
    --dry-run) DRY_RUN=1; PASSTHROUGH+=("$1") ;;
    --uninstall) UNINSTALL=1; PASSTHROUGH+=("$1") ;;
    -y|--yes) YES=1; PASSTHROUGH+=("$1") ;;
    --force) PASSTHROUGH+=("$1") ;;
    --runtime=claude) RUNTIME=claude ;;
    --runtime=pi) RUNTIME=pi ;;
    --runtime=all) RUNTIME=all ;;
    --runtime=*) die "unsupported $1: only claude, pi, and all are supported (see docs/decisions/ADR-020-claude-code-only-again.md and docs/decisions/ADR-030-pi-runtime-rendered-at-install.md)" ;;
    --statusline-only) STATUSLINE=1; PASSTHROUGH+=("$1") ;;
    --with=*|--without=*)
      [[ "${1#*=}" =~ ^[a-z][a-z0-9-]*(,[a-z][a-z0-9-]*)*$ ]] || die "invalid ${1%%=*} value; use comma-separated component ids"
      PASSTHROUGH+=("$1") ;;
    --ref=*) REF="${1#--ref=}"; [ -n "$REF" ] || die 'invalid empty --ref' ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

if [ "$RUNTIME" = pi ] || [ "$RUNTIME" = all ]; then
  [ "$STATUSLINE" -eq 0 ] || die "--statusline-only is a Claude Code option and cannot be combined with --runtime=$RUNTIME"
  { [ "$UPDATE" -eq 0 ] && [ -z "$REF" ]; } || die "--update and --ref fetch over the network; --runtime=$RUNTIME installs only from a local checkout, so update the checkout yourself first"
fi

# Same condition as the installer's terminal UI: a terminal, and none of the plain-output modes.
FANCY=0
if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ "$DRY_RUN" -eq 0 ] && [ "$UNINSTALL" -eq 0 ] && [ "$YES" -eq 0 ]; then
  FANCY=1
fi

if [ -n "$REF" ] && ! [[ "$REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]; then
  die 'invalid --ref or B_AGENTIC_REF; use a tag, branch, or commit-like name'
fi
case "$REPO_URL" in
  https://*|http://*|ssh://*|git@*|/*|./*|../*) ;;
  *) die 'invalid B_AGENTIC_REPO; use an https, ssh, or local-path repository URL' ;;
esac
command -v python3 >/dev/null 2>&1 || die 'python3 is required'

# refuse_protected_dir <dir>: the clone/update destination must not be the home
# directory or sit under ~/.pi or ~/.config/opencode (the opt-in Pi runtime's tree and a removed runtime's, neither of which a source checkout may live in), resolving symlinks first.
refuse_protected_dir() {
  python3 - "$1" <<'PY' || die "refusing to use $1 as the source directory (home directory, or under ~/.pi or ~/.config/opencode)"
import os
import sys

home = os.path.expanduser("~")
dest = os.path.realpath(sys.argv[1])
pi_roots = {
    candidate
    for name in (".pi", os.path.join(".config", "opencode"))
    for candidate in (os.path.join(home, name), os.path.realpath(os.path.join(home, name)))
}
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
  if [ "$RUNTIME" = pi ] || [ "$RUNTIME" = all ]; then
    die "--runtime=$RUNTIME installs only from a local checkout and never clones; run ./install.sh from a b-agentic checkout"
  fi
  SOURCE_DIR="$CLONE_DIR"
  command -v git >/dev/null 2>&1 || die 'git is required to prepare the b-agentic source'
  refuse_protected_dir "$SOURCE_DIR"
  if [ ! -e "$SOURCE_DIR/.git" ]; then
    if [ "$DRY_RUN" -eq 1 ] || [ "$UNINSTALL" -eq 1 ]; then
      die "no b-agentic source checkout at $SOURCE_DIR; --dry-run and --uninstall do not clone"
    fi
    note "Cloning source: $REPO_URL -> $SOURCE_DIR"
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
      note "Updating source: $SOURCE_DIR"
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

export B_AGENTIC_NOTES="$NOTES"
case "$RUNTIME" in
  pi) INSTALLER="$SOURCE_DIR/tooling/install/pi_install.py" ;;
  all) INSTALLER="$SOURCE_DIR/tooling/install/all_install.py" ;;
  *) INSTALLER="$SOURCE_DIR/tooling/install/claude_install.py" ;;
esac
exec python3 "$INSTALLER" --source "$SOURCE_DIR" ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
