#!/usr/bin/env bash
# install.sh — bootstrap, refresh, or remove the native Pi b-agentic setup.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash
#   ~/.b-agentic/install.sh --sync
#   ~/.b-agentic/install.sh --update
#   ~/.b-agentic/install.sh --uninstall

set -euo pipefail
# shellcheck disable=SC2034 # Variables are consumed by the sourced runtime installer.

REPO_URL="${B_AGENTIC_REPO:-https://github.com/dhoaibao/b-agentic.git}"
LOCAL_REPO="${B_AGENTIC_DIR:-$HOME/.b-agentic}"
REF="${B_AGENTIC_REF:-}"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"
DRY_RUN_VALUE="${B_AGENTIC_DRY_RUN:-N}"
FORCE_VALUE="${B_AGENTIC_FORCE:-N}"
REPLACE_MEMORY_VALUE="${B_AGENTIC_REPLACE_MEMORY:-N}"
UNINSTALL_VALUE="${B_AGENTIC_UNINSTALL:-N}"
OPERATION=install
SOURCE_DIR="$LOCAL_REPO"
SKILLS_SRC=""
REFERENCES_SRC=""
TEMPLATES_SRC=""
KERNEL_SRC=""
INSTALL_STAGE_CURRENT=0
INSTALL_STAGE_TOTAL=0

# Output helpers: colors are empty unless stdout is a TTY and NO_COLOR is unset,
# so piped/CI output stays plain (bun/Homebrew pattern).
C_RESET='' C_BOLD='' C_DIM='' C_BLUE='' C_GREEN='' C_YELLOW='' C_RED=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET="$(printf '\033[0m')" C_BOLD="$(printf '\033[1m')" C_DIM="$(printf '\033[2m')"
  C_BLUE="$(printf '\033[34m')" C_GREEN="$(printf '\033[32m')"
  C_YELLOW="$(printf '\033[33m')" C_RED="$(printf '\033[31m')"
fi

log() { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$C_BLUE$C_BOLD" "$C_RESET" "$*"; }
success() { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
note_noninteractive() {
  if [ ! -t 0 ] || [ -n "${CI:-}" ]; then
    log "${C_DIM}Running non-interactively; output is reduced and no prompts are shown.${C_RESET}"
  fi
}
yes_value() { case "${1:-}" in y|Y|yes|YES|Yes|true|TRUE|1) return 0;; *) return 1;; esac; }
dry_run_enabled() { yes_value "$DRY_RUN_VALUE"; }
force_enabled() { yes_value "$FORCE_VALUE"; }
replace_memory_enabled() { yes_value "$REPLACE_MEMORY_VALUE"; }
uninstall_enabled() { yes_value "$UNINSTALL_VALUE"; }
run_cmd() { if dry_run_enabled; then printf '[dry-run] %s\n' "$*" >&2; else "$@"; fi; }

set_source_dir() {
  SOURCE_DIR="$1"
  SKILLS_SRC="$SOURCE_DIR/skills"
  REFERENCES_SRC="$SOURCE_DIR/references"
  TEMPLATES_SRC="$SOURCE_DIR/pi/configs"
  KERNEL_SRC="$SOURCE_DIR/references/kernel.template.md"
}

validate_bootstrap_inputs() {
  if [ -n "$REF" ] && ! [[ "$REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]; then
    die 'invalid --ref or B_AGENTIC_REF; use a tag, branch, or commit-like name'
  fi
  case "$REPO_URL" in
    https://*|http://*|ssh://*|git@*|/*|./*|../*) ;;
    *) die 'invalid B_AGENTIC_REPO; use an https, ssh, or local-path repository URL' ;;
  esac
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN_VALUE=Y ;;
      --force) FORCE_VALUE=Y ;;
      --replace-memory) REPLACE_MEMORY_VALUE=Y ;;
      --preserve-memory) REPLACE_MEMORY_VALUE=N ;;
      --uninstall) UNINSTALL_VALUE=Y ;;
      --sync|--update)
        [ "$OPERATION" = install ] || die '--sync and --update cannot be combined'
        OPERATION="${1#--}"
        ;;
      --ref=*) REF="${1#--ref=}"; [ -n "$REF" ] || die 'invalid empty --ref' ;;
      *) die "unknown argument: $1" ;;
    esac
    shift
  done
  if uninstall_enabled && [ "$OPERATION" != install ]; then die '--uninstall cannot be combined with --sync or --update'; fi
  validate_bootstrap_inputs
}

validate_source_layout() {
  [ -d "$SKILLS_SRC" ] || die "missing skills: $SKILLS_SRC"
  [ -f "$SKILLS_SRC/registry.yaml" ] || die "missing skill registry: $SKILLS_SRC/registry.yaml"
  [ -d "$REFERENCES_SRC" ] || die "missing references: $REFERENCES_SRC"
  [ -f "$REFERENCES_SRC/capabilities.yaml" ] || die "missing capability registry: $REFERENCES_SRC/capabilities.yaml"
  [ -f "$KERNEL_SRC" ] || die "missing kernel: $KERNEL_SRC"
  [ -d "$TEMPLATES_SRC" ] || die "missing Pi configs: $TEMPLATES_SRC"
  [ -f "$TEMPLATES_SRC/permission.user.template.json" ] || die 'missing generated Pi permission template'
  [ -f "$TEMPLATES_SRC/mcp.base.json" ] || die 'missing Pi MCP template'
  [ -f "$SOURCE_DIR/pi/themes/dracula.json" ] || die 'missing Dracula theme'
  [ -f "$SOURCE_DIR/pi/themes/LICENSE" ] || die 'missing Dracula theme license'
  [ -f "$SOURCE_DIR/pi/scripts/install.sh" ] || die 'missing Pi runtime installer'
  [ -f "$SOURCE_DIR/tooling/install/common.sh" ] || die "missing installer core"
}

resolve_default_branch() {
  local target=""
  target="$(git -C "$LOCAL_REPO" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -n "$target" ]; then
    echo "${target#origin/}"
    return 0
  fi
  if git -C "$LOCAL_REPO" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null 2>&1 || \
     git -C "$LOCAL_REPO" show-ref --verify --quiet refs/heads/main; then
    echo "main"
    return 0
  fi
  if git -C "$LOCAL_REPO" rev-parse --verify --quiet refs/remotes/origin/master >/dev/null 2>&1 || \
     git -C "$LOCAL_REPO" show-ref --verify --quiet refs/heads/master; then
    echo "master"
    return 0
  fi
  return 1
}

prepare_source() {
  if [ -d "$LOCAL_REPO/.git" ]; then
    if [ "$OPERATION" = sync ] && [ -z "$REF" ] && ! force_enabled; then
      log "Using installed source: $LOCAL_REPO"
    elif [ "$OPERATION" = update ]; then
      log "Using installed source without fetching: $LOCAL_REPO"
    elif ! uninstall_enabled; then
      if dry_run_enabled; then
        log "[dry-run] git -C $LOCAL_REPO fetch --tags --prune"
        if [ -n "$REF" ]; then
          log "[dry-run] git -C $LOCAL_REPO checkout $REF --"
        else
          if ! git -C "$LOCAL_REPO" symbolic-ref -q HEAD >/dev/null 2>&1; then
            local branch
            branch="$(resolve_default_branch 2>/dev/null)" || die "detached HEAD checkout at $LOCAL_REPO cannot be updated automatically; pass --ref=<branch>"
            log "[dry-run] git -C $LOCAL_REPO checkout $branch --"
          fi
          log "[dry-run] git -C $LOCAL_REPO pull --ff-only"
        fi
      else
        log "Updating source: $LOCAL_REPO"
        git -C "$LOCAL_REPO" fetch --quiet --tags --prune
        if [ -n "$REF" ]; then
          git -C "$LOCAL_REPO" checkout --quiet "$REF" --
        else
          if ! git -C "$LOCAL_REPO" symbolic-ref -q HEAD >/dev/null 2>&1; then
            local branch
            branch="$(resolve_default_branch 2>/dev/null)" || die "detached HEAD checkout at $LOCAL_REPO cannot be updated automatically; pass --ref=<branch>"
            log "Detached checkout at $LOCAL_REPO; switching to default branch: $branch"
            if git -C "$LOCAL_REPO" show-ref --verify --quiet "refs/heads/$branch"; then
              git -C "$LOCAL_REPO" checkout --quiet "$branch" --
            elif git -C "$LOCAL_REPO" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null 2>&1; then
              git -C "$LOCAL_REPO" checkout --quiet -b "$branch" "origin/$branch" --
            else
              die "detached HEAD checkout at $LOCAL_REPO cannot be updated automatically; branch '$branch' not found; pass --ref=<branch>"
            fi
          fi
          git -C "$LOCAL_REPO" pull --ff-only --quiet
        fi
      fi
    fi
  elif [ -d "$LOCAL_REPO/skills" ]; then
    log "Using source directory: $LOCAL_REPO"
  elif uninstall_enabled; then
    die "b-agentic source is unavailable at $LOCAL_REPO; restore it or use the installed manifest helper."
  elif dry_run_enabled; then
    die 'dry-run requires an existing B_AGENTIC_DIR source checkout'
  else
    log "Cloning source: $REPO_URL -> $LOCAL_REPO"
    mkdir -p "$(dirname "$LOCAL_REPO")"
    git clone --quiet -- "$REPO_URL" "$LOCAL_REPO"
    [ -z "$REF" ] || git -C "$LOCAL_REPO" checkout --quiet "$REF" --
  fi
  set_source_dir "$LOCAL_REPO"
  validate_source_layout
}

manifest_only_uninstall() {
  local config_dir="${B_AGENTIC_PI_DIR:-${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}}"
  local manifest="$config_dir/b-agentic/install.json"
  local helper="$config_dir/b-agentic/tooling/install/manifest_uninstall.py"
  uninstall_enabled && [ ! -d "$LOCAL_REPO/skills" ] && [ -f "$manifest" ] && [ -f "$helper" ] || return 1
  if dry_run_enabled; then
    python3 "$helper" "$manifest" --dry-run
  else
    python3 "$helper" "$manifest"
  fi
}

validate_pi_config_dir() {
  local config_dir="${B_AGENTIC_PI_DIR:-${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}}"
  python3 - "$config_dir" <<'PY' || die 'Pi agent directory must be an absolute path under the invoking user home'
from pathlib import Path
import sys
path = Path(sys.argv[1])
home = Path.home().resolve()
if not path.is_absolute() or path.resolve() == home or not path.resolve().is_relative_to(home):
    raise SystemExit(1)
PY
}

install_optional_runtime_tools() {
  command -v rtk >/dev/null 2>&1 || INSTALL_MISSING_TOOLS+=('rtk')
  command -v codegraph >/dev/null 2>&1 || INSTALL_MISSING_TOOLS+=('codegraph')
  command -v bunx >/dev/null 2>&1 || INSTALL_MISSING_TOOLS+=('bunx')
  # Install reports these in its Next steps block; other operations have no
  # summary, so surface them as a warning there.
  if [ "$OPERATION" != install ] && [ "${#INSTALL_MISSING_TOOLS[@]}" -gt 0 ]; then
    warn "optional tools not found: ${INSTALL_MISSING_TOOLS[*]}; install them to enable the affected workflows."
  fi
}

load_runtime() {
  # shellcheck disable=SC1090
  source "$SOURCE_DIR/tooling/install/common.sh"
  # shellcheck disable=SC1090
  source "$SOURCE_DIR/pi/scripts/install.sh"
}

main() {
  parse_args "$@"
  note_noninteractive
  command -v python3 >/dev/null 2>&1 || die 'python3 is required for configuration management'
  validate_pi_config_dir
  if manifest_only_uninstall; then return 0; fi
  command -v git >/dev/null 2>&1 || die 'git is required to prepare b-agentic source'
  prepare_source
  load_runtime
  if uninstall_enabled; then
    pi_uninstall
    success 'b-agentic uninstall complete for Pi.'
    return 0
  fi

  install_optional_runtime_tools
  case "$OPERATION" in
    install) pi_install ;;
    sync) pi_sync; success 'b-agentic sync complete for Pi.' ;;
    update) pi_update ;;
  esac
}

main "$@"
