#!/usr/bin/env bash
# install.sh - Bootstrap or update b-agentic
# Bootstraps source sync, then delegates skills, shared references support sync,
# and runtimes/$RUNTIME/kernel.md installation to the shared installer core.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --dry-run
#   curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --runtime=all
#   curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --uninstall

set -euo pipefail

readonly REPO_URL="${B_AGENTIC_REPO:-https://github.com/dhoaibao/b-agentic.git}"
readonly LOCAL_REPO="${B_AGENTIC_DIR:-$HOME/.b-agentic}"
readonly REF="${B_AGENTIC_REF:-}"
readonly TIMESTAMP="$(date +%Y%m%d%H%M%S)"

DRY_RUN_VALUE="${B_AGENTIC_DRY_RUN:-N}"
REPLACE_MEMORY_VALUE="${B_AGENTIC_REPLACE_MEMORY:-}"
UNINSTALL_VALUE="${B_AGENTIC_UNINSTALL:-N}"
PROMPT_API_KEYS_VALUE="${B_AGENTIC_PROMPT_API_KEYS:-auto}"
RUNTIME="${B_AGENTIC_RUNTIME:-claude-code}"
STRICT_VALUE="${B_AGENTIC_STRICT_INSTALL:-N}"

SOURCE_DIR="$LOCAL_REPO"
SKILLS_SRC="$SOURCE_DIR/skills"
REFERENCES_SRC="$SOURCE_DIR/references"
TEMPLATES_SRC="$SOURCE_DIR/runtimes/$RUNTIME/configs"
KERNEL_SRC="$SOURCE_DIR/runtimes/$RUNTIME/kernel.md"
DRY_RUN_SOURCE_DIR=""
UI_MODE="${B_AGENTIC_UI:-auto}"
UI_ANIMATE_MODE="${B_AGENTIC_ANIMATE:-auto}"
UI_ENABLED=0
UI_ANIMATION_ENABLED=0
UI_SPINNER_ACTIVE=0
UI_SPINNER_LABEL=""
UI_SPINNER_PID=""
UI_DONE_PRINTED=0
UI_COLOR_BOLD=""
UI_COLOR_DIM=""
UI_COLOR_ACCENT=""
UI_COLOR_LOGO_ALT=""
UI_COLOR_SUCCESS=""
UI_COLOR_WARN=""
UI_COLOR_ERROR=""
UI_COLOR_RESET=""

readonly UI_ICON_RUNNING="●"
readonly UI_ICON_SUCCESS="✓"
readonly UI_ICON_WARNING="▲"
readonly UI_ICON_ERROR="✕"

ui_clear_ephemeral_line() {
  [ "${UI_SPINNER_ACTIVE:-0}" -eq 1 ] || return 0
  printf '\r\033[2K' >&2
}

ui_timeline_pulse() {
  local message="$1" frame
  [ "${UI_ANIMATION_ENABLED:-0}" -eq 1 ] || return 0

  # Pure ANSI cursor control: redraw one ephemeral timeline row before
  # printing the final state row. No external animation helper is needed.
  for frame in '·' '∙' '•' '●'; do
    printf '\r\033[2K  %b│%b %b%s%b  %s' \
      "$UI_COLOR_ACCENT" "$UI_COLOR_RESET" \
      "$UI_COLOR_LOGO_ALT" "$frame" "$UI_COLOR_RESET" "$message" >&2
    sleep 0.04
  done
  printf '\r\033[2K' >&2
}

print_logo() {
  [ "${UI_ENABLED:-0}" -eq 1 ] || return 0

  printf '\n' >&2
  printf '  %b██████╗        █████╗  ██████╗ ███████╗███╗   ██╗████████╗██╗ ██████╗%b\n' "$UI_COLOR_ACCENT" "$UI_COLOR_RESET" >&2
  printf '  %b██╔══██╗      ██╔══██╗██╔════╝ ██╔════╝████╗  ██║╚══██╔══╝██║██╔════╝%b\n' "$UI_COLOR_ACCENT" "$UI_COLOR_RESET" >&2
  printf '  %b██████╔╝█████╗███████║██║  ███╗█████╗  ██╔██╗ ██║   ██║   ██║██║     %b\n' "$UI_COLOR_LOGO_ALT" "$UI_COLOR_RESET" >&2
  printf '  %b██╔══██╗╚════╝██╔══██║██║   ██║██╔══╝  ██║╚██╗██║   ██║   ██║██║     %b\n' "$UI_COLOR_LOGO_ALT" "$UI_COLOR_RESET" >&2
  printf '  %b██████╔╝      ██║  ██║╚██████╔╝███████╗██║ ╚████║   ██║   ██║╚██████╗%b\n' "$UI_COLOR_LOGO_ALT" "$UI_COLOR_RESET" >&2
  printf '  %b╚═════╝       ╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝  ╚═══╝   ╚═╝   ╚═╝ ╚═════╝%b\n' "$UI_COLOR_LOGO_ALT" "$UI_COLOR_RESET" >&2
  printf '\n' >&2
}

print_header() {
  local title="$1"
  [ "${UI_ENABLED:-0}" -eq 1 ] || return 0

  printf '  %b%s%b\n' "$UI_COLOR_BOLD" "$title" "$UI_COLOR_RESET" >&2
}

print_step() {
  local state="$1" message="$2" color="$UI_COLOR_DIM" icon=" "
  [ "${UI_ENABLED:-0}" -eq 1 ] || return 1

  case "$state" in
    running)
      color="$UI_COLOR_LOGO_ALT"
      icon="$UI_ICON_RUNNING"
      ;;
    success)
      color="$UI_COLOR_SUCCESS"
      icon="$UI_ICON_SUCCESS"
      ;;
    warning)
      color="$UI_COLOR_WARN"
      icon="$UI_ICON_WARNING"
      ;;
    error)
      color="$UI_COLOR_ERROR"
      icon="$UI_ICON_ERROR"
      ;;
  esac

  case "$state" in
    success|warning|error) ui_timeline_pulse "$message" ;;
  esac

  printf '  %b│%b\n' "$UI_COLOR_ACCENT" "$UI_COLOR_RESET" >&2
  printf '  %b%s%b  %s\n' "$color" "$icon" "$UI_COLOR_RESET" "$message" >&2
}

ui_stop_spinner() {
  local rc="${1:-0}" label="${2:-$UI_SPINNER_LABEL}" marker=""
  [ "${UI_ENABLED:-0}" -eq 1 ] || return 0

  if [ -n "${UI_SPINNER_PID:-}" ]; then
    kill "$UI_SPINNER_PID" >/dev/null 2>&1 || true
    wait "$UI_SPINNER_PID" 2>/dev/null || true
  fi

  printf '\r\033[2K' >&2
  UI_SPINNER_ACTIVE=0
  UI_SPINNER_LABEL=""
  UI_SPINNER_PID=""

  if [ "$rc" -eq 0 ]; then
    marker="${UI_COLOR_SUCCESS}${UI_ICON_SUCCESS}${UI_COLOR_RESET}"
  else
    marker="${UI_COLOR_ERROR}${UI_ICON_ERROR}${UI_COLOR_RESET}"
  fi
  printf '  %b│%b\n' "$UI_COLOR_ACCENT" "$UI_COLOR_RESET" >&2
  printf '  %b  %s\n' "$marker" "$label" >&2
}

log() {
  local message="$*"

  ui_clear_ephemeral_line
  if [ "${UI_ENABLED:-0}" -eq 1 ]; then
    [ -n "$message" ] || return 0
    case "$message" in
      "==> "*)
        print_step success "${message#==> }"
        ;;
      "b-agentic "*complete*)
        print_step success "$message"
        ;;
      "Uninstall complete."*)
        print_step success "$message"
        ;;
      "  activation:"*|"  launch:"*|"  activate:"*|"  apply:"*)
        printf '     %s\n' "${message#"  "}" >&2
        ;;
    esac
    return 0
  fi
  printf '%s\n' "$message"
}

warn() {
  ui_clear_ephemeral_line
  if [ "${UI_ENABLED:-0}" -eq 1 ]; then
    print_step warning "$*"
    return 0
  fi
  printf '%bwarning:%b %s\n' "$UI_COLOR_WARN" "$UI_COLOR_RESET" "$*" >&2
}

die() {
  if [ "${UI_SPINNER_ACTIVE:-0}" -eq 1 ]; then
    ui_stop_spinner 1 "$UI_SPINNER_LABEL"
  else
    ui_clear_ephemeral_line
  fi
  if [ "${UI_ENABLED:-0}" -eq 1 ]; then
    print_step error "$*"
  else
    printf '%berror:%b %s\n' "$UI_COLOR_ERROR" "$UI_COLOR_RESET" "$*" >&2
  fi
  exit 1
}

ui_init() {
  case "$UI_MODE" in
    auto|"")
      if [ -t 2 ] && [ "${TERM:-}" != "dumb" ]; then
        UI_ENABLED=1
      fi
      ;;
    always)
      UI_ENABLED=1
      ;;
    never)
      UI_ENABLED=0
      ;;
    *)
      printf 'error: invalid B_AGENTIC_UI value: %s\n' "$UI_MODE" >&2
      exit 1
      ;;
  esac

  if [ "$UI_ENABLED" -eq 1 ]; then
    UI_COLOR_BOLD=$'\033[1m'
    UI_COLOR_DIM=$'\033[2m'
    UI_COLOR_ACCENT=$'\033[38;5;68m'
    UI_COLOR_LOGO_ALT=$'\033[38;5;147m'
    UI_COLOR_SUCCESS=$'\033[38;5;82m'
    UI_COLOR_WARN=$'\033[38;5;220m'
    UI_COLOR_ERROR=$'\033[38;5;203m'
    UI_COLOR_RESET=$'\033[0m'
  fi

  case "$UI_ANIMATE_MODE" in
    auto|"")
      if [ "$UI_ENABLED" -eq 1 ] && [ -t 2 ]; then
        UI_ANIMATION_ENABLED=1
      fi
      ;;
    always)
      [ "$UI_ENABLED" -eq 1 ] && UI_ANIMATION_ENABLED=1
      ;;
    never)
      UI_ANIMATION_ENABLED=0
      ;;
    *)
      printf 'error: invalid B_AGENTIC_ANIMATE value: %s\n' "$UI_ANIMATE_MODE" >&2
      exit 1
      ;;
  esac
}

spinner() {
  local label="$1"
  local -a frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local index=0

  # Keep spinner output on a single ephemeral line so completed steps remain clean.
  while :; do
    printf '\r\033[2K  %b│%b %b%s%b  %s %b%s%b' \
      "$UI_COLOR_ACCENT" "$UI_COLOR_RESET" \
      "$UI_COLOR_LOGO_ALT" "$UI_ICON_RUNNING" "$UI_COLOR_RESET" \
      "$label" "$UI_COLOR_DIM" "${frames[$index]}" "$UI_COLOR_RESET" >&2
    index=$(((index + 1) % ${#frames[@]}))
    sleep 0.08
  done
}

ui_start_spinner() {
  local label="$1"
  [ "${UI_ENABLED:-0}" -eq 1 ] || return 0
  ui_clear_ephemeral_line
  UI_SPINNER_ACTIVE=1
  UI_SPINNER_LABEL="$label"
  spinner "$label" &
  UI_SPINNER_PID=$!
}

ui_print_intro() {
  local action="install"
  local target="$RUNTIME"
  [ "${UI_ENABLED:-0}" -eq 1 ] || return 0

  if uninstall_enabled; then
    action="uninstall"
  elif dry_run_enabled; then
    action="dry-run install"
  fi
  if [ "$RUNTIME" = "all" ]; then
    target="all runtimes"
  fi

  print_logo
  printf '  %bInstall / Upgrade%b  %b%s%b\n' \
    "$UI_COLOR_BOLD" "$UI_COLOR_RESET" "$UI_COLOR_LOGO_ALT$UI_COLOR_BOLD" "$target" "$UI_COLOR_RESET" >&2
  printf '  %b%s%b\n' "$UI_COLOR_DIM" "$action" "$UI_COLOR_RESET" >&2
}

ui_print_runtime_banner() {
  local runtime_label="$1" activation_state="$2"
  [ "${UI_ENABLED:-0}" -eq 1 ] || return 0

  print_step running "$runtime_label activation: $activation_state"
}

ui_print_done() {
  [ "${UI_DONE_PRINTED:-0}" -eq 0 ] || return 0
  UI_DONE_PRINTED=1

  if [ "${UI_ENABLED:-0}" -eq 1 ]; then
    printf '  %b│%b\n' "$UI_COLOR_ACCENT" "$UI_COLOR_RESET" >&2
    printf '  Done\n' >&2
  else
    printf 'Done\n' >&2
  fi
}

cleanup() {
  if [ "${UI_SPINNER_ACTIVE:-0}" -eq 1 ]; then
    ui_stop_spinner 1 "$UI_SPINNER_LABEL"
  fi
  if [ -n "$DRY_RUN_SOURCE_DIR" ]; then
    rm -rf "$DRY_RUN_SOURCE_DIR"
  fi
}

trap cleanup EXIT

yes_value() {
  case "${1:-}" in
    y|Y|yes|YES|Yes|true|TRUE|1) return 0 ;;
    *) return 1 ;;
  esac
}

dry_run_enabled() {
  yes_value "$DRY_RUN_VALUE"
}

replace_memory_enabled() {
  yes_value "$REPLACE_MEMORY_VALUE"
}

uninstall_enabled() {
  yes_value "$UNINSTALL_VALUE"
}

can_prompt_api_keys() {
  ! dry_run_enabled || return 1
  case "$PROMPT_API_KEYS_VALUE" in
    n|N|no|NO|No|false|FALSE|0) return 1 ;;
    auto|AUTO|Auto|y|Y|yes|YES|Yes|true|TRUE|1) ;;
    *) die "invalid B_AGENTIC_PROMPT_API_KEYS value: $PROMPT_API_KEYS_VALUE" ;;
  esac
  [ -r /dev/tty ] && [ -w /dev/tty ]
}

run_cmd() {
  if dry_run_enabled; then
    ui_clear_ephemeral_line
    printf '[dry-run] %s\n' "$*" >&2
    return 0
  fi
  "$@"
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || die "required binary not found: $1"
}

check_dependencies() {
  local dependency_label="curl, git, python3"

  if command -v curl >/dev/null 2>&1; then
    :
  else
    print_step warning "curl not found; install with the documented curl command will not work on this machine" || true
    dependency_label="git, python3"
  fi

  # git is needed only when the installer must fetch or update its source checkout.
  if uninstall_enabled && { [ -d "$LOCAL_REPO/.git" ] || [ -d "$LOCAL_REPO/skills" ]; }; then
    dependency_label="${dependency_label}, local source"
  else
    require_bin git
  fi

  # Runtime installers use Python for structured config and manifest updates.
  require_bin python3
  print_step success "Using $dependency_label" || true
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run)
        DRY_RUN_VALUE=Y
        ;;
      --replace-memory)
        REPLACE_MEMORY_VALUE=Y
        ;;
      --preserve-memory)
        REPLACE_MEMORY_VALUE=N
        ;;
      --uninstall)
        UNINSTALL_VALUE=Y
        ;;
      --prompt-api-keys)
        PROMPT_API_KEYS_VALUE=Y
        ;;
      --no-prompt-api-keys)
        PROMPT_API_KEYS_VALUE=N
        ;;
      --strict)
        STRICT_VALUE=Y
        ;;
      --runtime=*)
        RUNTIME="${1#--runtime=}"
        case "$RUNTIME" in
          all) ;;
          *[^a-z0-9_-]*) die "invalid runtime name: $RUNTIME (use lowercase alphanumeric, dashes, underscores)" ;;
        esac
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
    shift
  done
}

set_source_dir() {
  SOURCE_DIR="$1"
  SKILLS_SRC="$SOURCE_DIR/skills"
  REFERENCES_SRC="$SOURCE_DIR/references"
  TEMPLATES_SRC="$SOURCE_DIR/runtimes/$RUNTIME/configs"
  KERNEL_SRC="$SOURCE_DIR/runtimes/$RUNTIME/kernel.md"
}

validate_shared_source_layout() {
  [ -d "$SKILLS_SRC" ] || die "missing source directory: $SKILLS_SRC"
  [ -d "$REFERENCES_SRC" ] || die "missing source directory: $REFERENCES_SRC"
  [ -f "$SOURCE_DIR/tooling/install/common.sh" ] || die "missing installer core: $SOURCE_DIR/tooling/install/common.sh"
  [ -f "$SOURCE_DIR/runtimes/registry.yaml" ] || die "missing runtime registry: $SOURCE_DIR/runtimes/registry.yaml"
}

validate_runtime_source_layout() {
  [ -d "$TEMPLATES_SRC" ] || die "missing source directory: $TEMPLATES_SRC"
  [ -f "$KERNEL_SRC" ] || die "missing kernel source: $KERNEL_SRC"
}

runtime_names() {
  require_bin python3
  python3 - "$SOURCE_DIR/runtimes/registry.yaml" <<'PY'
from pathlib import Path
import json
import sys

registry = json.loads(Path(sys.argv[1]).read_text())
for runtime in registry.get('runtimes', []):
    name = runtime.get('name')
    if isinstance(name, str) and name:
        print(name)
PY
}

runtime_names_for_all() {
  runtime_names
}

runtime_registered() {
  local target="$1"
  local runtime_name
  while IFS= read -r runtime_name; do
    [ -n "$runtime_name" ] || continue
    if [ "$runtime_name" = "$target" ]; then
      return 0
    fi
  done < <(runtime_names)
  return 1
}

sync_source() {
  require_bin git
  require_bin python3

  if dry_run_enabled; then
    if [ -d "$LOCAL_REPO/.git" ] || [ -d "$LOCAL_REPO/skills" ]; then
      log "Dry-run source: $LOCAL_REPO (no fetch/pull)"
      set_source_dir "$LOCAL_REPO"
    else
      DRY_RUN_SOURCE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/b-agentic-dry-run.XXXXXX")"
      log "Dry-run source clone: $REPO_URL -> $DRY_RUN_SOURCE_DIR"
      git clone --quiet "$REPO_URL" "$DRY_RUN_SOURCE_DIR"
      if [ -n "$REF" ]; then
        git -C "$DRY_RUN_SOURCE_DIR" checkout --quiet "$REF"
      fi
      set_source_dir "$DRY_RUN_SOURCE_DIR"
    fi
  elif [ -d "$LOCAL_REPO/.git" ]; then
    log "Updating source: $LOCAL_REPO"
    git -C "$LOCAL_REPO" fetch --all --tags --prune --quiet
    if [ -n "$REF" ]; then
      git -C "$LOCAL_REPO" checkout --quiet "$REF"
    else
      git -C "$LOCAL_REPO" pull --ff-only --quiet
    fi
    set_source_dir "$LOCAL_REPO"
  else
    log "Cloning source: $REPO_URL -> $LOCAL_REPO"
    mkdir -p "$(dirname "$LOCAL_REPO")"
    git clone --quiet "$REPO_URL" "$LOCAL_REPO"
    if [ -n "$REF" ]; then
      git -C "$LOCAL_REPO" checkout --quiet "$REF"
    fi
    set_source_dir "$LOCAL_REPO"
  fi

  validate_shared_source_layout
}

prepare_source() {
  if uninstall_enabled && { [ -d "$LOCAL_REPO/.git" ] || [ -d "$LOCAL_REPO/skills" ]; }; then
    set_source_dir "$LOCAL_REPO"
    validate_shared_source_layout
    return 0
  fi

  sync_source
}

install_app() {
  if uninstall_enabled; then
    print_step running "Preparing uninstall source" || true
    prepare_source
    print_step success "Uninstall source ready" || true
    return 0
  fi

  if [ -d "$LOCAL_REPO/.git" ] || [ -d "$LOCAL_REPO/skills" ]; then
    print_step warning "b-agentic is already installed; running upgrade" || true
  else
    print_step running "b-agentic is not installed; downloading installer source" || true
  fi

  prepare_source
  print_step success "Installer source ready" || true
}

manifest_path_for_runtime() {
  case "$1" in
    claude-code) printf '%s/.claude/b-agentic/install.json' "$HOME" ;;
    opencode) printf '%s/.config/opencode/b-agentic/install.json' "$HOME" ;;
    codex-cli) printf '%s/.codex/b-agentic/install.json' "$HOME" ;;
    kilo-code) printf '%s/.config/kilo/b-agentic/install.json' "$HOME" ;;
    *) return 1 ;;
  esac
}

manifest_only_runtime_names() {
  printf '%s\n' claude-code opencode codex-cli kilo-code
}

manifest_only_uninstall_one() {
  local runtime_name="$1" manifest_path="$2"
  [ -f "$manifest_path" ] || return 1
  local installed_script="$(dirname "$manifest_path")/tooling/install/manifest_uninstall.py"
  if [ -f "$installed_script" ]; then
    run_cmd python3 "$installed_script" "$manifest_path"
    return $?
  fi
  if [ -n "${SOURCE_DIR:-}" ] && [ -f "$SOURCE_DIR/tooling/install/manifest_uninstall.py" ]; then
    run_cmd python3 "$SOURCE_DIR/tooling/install/manifest_uninstall.py" "$manifest_path"
    return $?
  fi
  die "manifest-only uninstall for $runtime_name requires $installed_script; reinstall once or restore the source checkout to uninstall safely"
}

try_manifest_only_uninstall() {
  uninstall_enabled || return 1
  { [ -d "$LOCAL_REPO/.git" ] || [ -d "$LOCAL_REPO/skills" ]; } && return 1

  local runtime_name manifest_path installed_count=0
  if [ "$RUNTIME" = "all" ]; then
    while IFS= read -r runtime_name; do
      [ -n "$runtime_name" ] || continue
      manifest_path="$(manifest_path_for_runtime "$runtime_name")" || continue
      if [ -f "$manifest_path" ]; then
        manifest_only_uninstall_one "$runtime_name" "$manifest_path"
        installed_count=$((installed_count + 1))
      fi
    done < <(manifest_only_runtime_names)
    [ "$installed_count" -gt 0 ] || return 1
    return 0
  fi

  manifest_path="$(manifest_path_for_runtime "$RUNTIME")" || return 1
  [ -f "$manifest_path" ] || return 1
  manifest_only_uninstall_one "$RUNTIME" "$manifest_path"
}

source_installer_core() {
  local common_src="$SOURCE_DIR/tooling/install/common.sh"
  [ -f "$common_src" ] || die "missing installer core: $common_src"
  # shellcheck disable=SC1090
  source "$common_src"
}

load_runtime_driver() {
  local runtime_script="$SOURCE_DIR/runtimes/$RUNTIME/scripts/install.sh"
  [ -f "$runtime_script" ] || die "missing runtime install script: $runtime_script"
  # shellcheck disable=SC1090
  source "$runtime_script"
}

run_runtime_action() {
  local runtime_name="$1"
  local rc=0

  set +e
  (
    RUNTIME="$runtime_name"
    STRICT_VALUE="$STRICT_VALUE"
    set_source_dir "$SOURCE_DIR"
    validate_runtime_source_layout
    source_installer_core
    load_runtime_driver
    if uninstall_enabled; then
      runtime_uninstall
    else
      runtime_main
    fi
  )
  rc=$?
  set -e

  return "$rc"
}

run_all_runtimes() {
  local runtime_name rc overall_rc=0 runtime_count=0
  local action_label="Installing"
  local target_label="all default runtimes"
  if uninstall_enabled; then
    action_label="Uninstalling"
    target_label="all registered runtimes"
  fi

  log "$action_label $target_label"

  while IFS= read -r runtime_name; do
    [ -n "$runtime_name" ] || continue
    runtime_count=$((runtime_count + 1))
    log ""
    log "==> $runtime_name"

    if run_runtime_action "$runtime_name"; then
      rc=0
    else
      rc=$?
    fi

    case "$rc" in
      0) ;;
      2)
        if [ "$overall_rc" -eq 0 ]; then
          overall_rc=2
        fi
        ;;
      *)
        return "$rc"
        ;;
    esac
  done < <(runtime_names_for_all)

  [ "$runtime_count" -gt 0 ] || die "no runtimes registered in $SOURCE_DIR/runtimes/registry.yaml"
  return "$overall_rc"
}

main() {
  local rc=0

  parse_args "$@"
  ui_init
  ui_print_intro

  if try_manifest_only_uninstall; then
    ui_print_done
    return 0
  fi

  check_dependencies
  install_app

  if [ "$RUNTIME" = "all" ]; then
    set +e
    ( set -e; run_all_runtimes )
    rc=$?
    set -e
    ui_print_done
    return "$rc"
  fi

  runtime_registered "$RUNTIME" || die "unknown runtime: $RUNTIME"
  validate_runtime_source_layout

  source_installer_core
  load_runtime_driver

  if uninstall_enabled; then
    set +e
    ( set -e; runtime_uninstall )
    rc=$?
    set -e
    ui_print_done
    return "$rc"
  fi

  set +e
  ( set -e; runtime_main )
  rc=$?
  set -e
  ui_print_done
  return "$rc"
}

main "$@"
