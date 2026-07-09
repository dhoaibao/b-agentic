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
#   curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --ref=<tag-or-sha>

set -euo pipefail

readonly REPO_URL="${B_AGENTIC_REPO:-https://github.com/dhoaibao/b-agentic.git}"
readonly LOCAL_REPO="${B_AGENTIC_DIR:-$HOME/.b-agentic}"
REF="${B_AGENTIC_REF:-}"
readonly TIMESTAMP="$(date +%Y%m%d%H%M%S)"

DRY_RUN_VALUE="${B_AGENTIC_DRY_RUN:-N}"
REPLACE_MEMORY_VALUE="${B_AGENTIC_REPLACE_MEMORY:-}"
UNINSTALL_VALUE="${B_AGENTIC_UNINSTALL:-N}"
PROMPT_API_KEYS_VALUE="${B_AGENTIC_PROMPT_API_KEYS:-auto}"
RUNTIME="${B_AGENTIC_RUNTIME:-codex}"
INSTALL_RTK_VALUE="${B_AGENTIC_INSTALL_RTK:-auto}"
B_AGENTIC_RTK_REF="${B_AGENTIC_RTK_REF:-v0.43.0}"
INSTALL_SHELL_TOOLS_VALUE="${B_AGENTIC_INSTALL_SHELL_TOOLS:-auto}"
INSTALL_RUNTIME_CLI_VALUE="${B_AGENTIC_INSTALL_RUNTIME_CLI:-auto}"
INSTALL_SERENA_VALUE="${B_AGENTIC_INSTALL_SERENA:-auto}"
INSTALL_CODEGRAPH_VALUE="${B_AGENTIC_INSTALL_CODEGRAPH:-auto}"

SOURCE_DIR="$LOCAL_REPO"
SKILLS_SRC="$SOURCE_DIR/skills"
REFERENCES_SRC="$SOURCE_DIR/references"
TEMPLATES_SRC="$SOURCE_DIR/runtimes/$RUNTIME/configs"
KERNEL_SRC="$SOURCE_DIR/runtimes/$RUNTIME/kernel.md"
DRY_RUN_SOURCE_DIR=""
UI_ENABLED=1
INSTALL_RUNTIME_CLI_DECISION=""

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
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

install_runtime_cli_enabled() {
  case "${INSTALL_RUNTIME_CLI_DECISION:-}" in
    Y) return 0 ;;
    N) return 1 ;;
  esac

  case "${INSTALL_RUNTIME_CLI_VALUE:-auto}" in
    n|N|no|NO|No|false|FALSE|0)
      INSTALL_RUNTIME_CLI_DECISION="N"
      ;;
    y|Y|yes|YES|Yes|true|TRUE|1)
      INSTALL_RUNTIME_CLI_DECISION="Y"
      ;;
    auto|AUTO|Auto)
      if runtime_cli_installed && prompt_yes_no "Upgrade the installed $RUNTIME CLI now? [y/N]" N; then
        INSTALL_RUNTIME_CLI_DECISION="Y"
      elif ! runtime_cli_installed && prompt_yes_no "Install the $RUNTIME CLI now? [y/N]" N; then
        INSTALL_RUNTIME_CLI_DECISION="Y"
      else
        INSTALL_RUNTIME_CLI_DECISION="N"
      fi
      ;;
    *) die "invalid B_AGENTIC_INSTALL_RUNTIME_CLI value: $INSTALL_RUNTIME_CLI_VALUE" ;;
  esac

  [ "$INSTALL_RUNTIME_CLI_DECISION" = "Y" ]
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
    printf '[dry-run] %s\n' "$*" >&2
    return 0
  fi
  "$@"
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || die "required binary not found: $1"
}

require_python_311() {
  python3 - <<'PY' >/dev/null 2>&1 || die "Python 3.11+ is required."
import sys
sys.exit(0 if sys.version_info >= (3, 11) else 1)
PY
}

check_dependencies() {
  local dependency_label="curl, git, python3"

  if command -v curl >/dev/null 2>&1; then
    :
  else
    warn "curl not found; install with the documented curl command will not work on this machine"
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
  require_python_311
  log "Using $dependency_label"
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
      --no-install-rtk)
        INSTALL_RTK_VALUE=N
        ;;
      --no-install-shell-tools)
        INSTALL_SHELL_TOOLS_VALUE=N
        ;;
      --no-install-runtime-cli)
        INSTALL_RUNTIME_CLI_VALUE=N
        ;;
      --no-install-serena)
        INSTALL_SERENA_VALUE=N
        ;;
      --no-install-codegraph)
        INSTALL_CODEGRAPH_VALUE=N
        ;;
      --runtime=*)
        RUNTIME="${1#--runtime=}"
        case "$RUNTIME" in
          all) ;;
          *[^a-z0-9_-]*) die "invalid runtime name: $RUNTIME (use lowercase alphanumeric, dashes, underscores)" ;;
        esac
        ;;
      --ref=*)
        REF="${1#--ref=}"
        [ -n "$REF" ] || die "invalid ref: empty"
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
    shift
  done
}

validate_ref() {
  [ -n "$REF" ] || return 0
  case "$REF" in
    -*) die "invalid ref: $REF (must not start with -)" ;;
  esac
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
    log "Preparing uninstall source"
    prepare_source
    log "Uninstall source ready"
    return 0
  fi

  if [ -d "$LOCAL_REPO/.git" ] || [ -d "$LOCAL_REPO/skills" ]; then
    warn "b-agentic is already installed; running upgrade"
  else
    log "b-agentic is not installed; downloading installer source"
  fi

  prepare_source
  log "Installer source ready"
}

manifest_only_records() {
  python3 - <<'PY'
import json
import os
from pathlib import Path

home = Path.home()
candidates = []
candidates.extend(home.glob(".*/b-agentic/install.json"))
candidates.extend((home / ".config").glob("*/b-agentic/install.json"))
candidates.extend((home / ".local" / "share").glob("*/b-agentic/install.json"))
candidates.extend((home / "Library" / "Application Support").glob("*/b-agentic/install.json"))
candidates.extend((home / ".gemini").glob("*/b-agentic/install.json"))

allowed_roots = [home.resolve()]

seen = set()
for path in candidates:
    try:
        resolved = path.resolve()
        if not any(resolved.is_relative_to(root) for root in allowed_roots):
            continue
    except Exception:
        continue
    if resolved in seen or not path.is_file():
        continue
    seen.add(resolved)
    try:
        data = json.loads(path.read_text())
    except Exception:
        continue
    suite = data.get("suite")
    if suite is not None and suite != "b-agentic":
        continue
    runtime = data.get("runtime")
    if isinstance(runtime, str) and runtime:
        print(f"{runtime}\t{path}")
PY
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
    while IFS=$'\t' read -r runtime_name manifest_path; do
      [ -n "$runtime_name" ] || continue
      if [ -f "$manifest_path" ]; then
        manifest_only_uninstall_one "$runtime_name" "$manifest_path"
        installed_count=$((installed_count + 1))
      fi
    done < <(manifest_only_records)
    [ "$installed_count" -gt 0 ] || return 1
    return 0
  fi

  while IFS=$'\t' read -r runtime_name manifest_path; do
    [ "$runtime_name" = "$RUNTIME" ] || continue
    [ -f "$manifest_path" ] || continue
    manifest_only_uninstall_one "$RUNTIME" "$manifest_path"
    return $?
  done < <(manifest_only_records)
  return 1
}

install_rtk() {
  case "${INSTALL_RTK_VALUE:-auto}" in
    n|N|no|NO|No|false|FALSE|0) return 0 ;;
    y|Y|yes|YES|Yes|true|TRUE|1) ;;
    auto|AUTO|Auto) ;;
    *) die "invalid B_AGENTIC_INSTALL_RTK value: $INSTALL_RTK_VALUE" ;;
  esac

  if command -v rtk >/dev/null 2>&1; then
    case "${INSTALL_RTK_VALUE:-auto}" in
      auto|AUTO|Auto)
        if ! prompt_yes_no 'RTK is already installed. Upgrade it now? [y/N]' N; then
          log "RTK already installed; skipping upgrade without explicit approval"
          return 0
        fi
        ;;
    esac
    if dry_run_enabled; then
      printf '[dry-run] curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/%s/install.sh | RTK_VERSION=%s sh\n' "$B_AGENTIC_RTK_REF" "$B_AGENTIC_RTK_REF" >&2
      return 0
    fi
    log "RTK already installed; upgrading"
    if curl -fsSL "https://raw.githubusercontent.com/rtk-ai/rtk/${B_AGENTIC_RTK_REF}/install.sh" | RTK_VERSION="${B_AGENTIC_RTK_REF}" sh; then
      log "RTK upgraded"
    else
      warn "RTK upgrade failed; continuing with existing RTK"
    fi
    return 0
  fi

  case "${INSTALL_RTK_VALUE:-auto}" in
    auto|AUTO|Auto)
      if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
        return 0
      fi
      local answer=""
      printf 'Install RTK (Rust Token Killer) to reduce shell command token usage? [y/N]: ' > /dev/tty
      IFS= read -r answer < /dev/tty || answer=""
      case "$answer" in
        y|Y|yes|YES|Yes|true|TRUE|1) ;;
        *) return 0 ;;
      esac
      ;;
  esac

  if dry_run_enabled; then
    printf '[dry-run] curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/%s/install.sh | RTK_VERSION=%s sh\n' "$B_AGENTIC_RTK_REF" "$B_AGENTIC_RTK_REF" >&2
    return 0
  fi

  log "Installing RTK"
  if curl -fsSL "https://raw.githubusercontent.com/rtk-ai/rtk/${B_AGENTIC_RTK_REF}/install.sh" | RTK_VERSION="${B_AGENTIC_RTK_REF}" sh; then
    log "RTK installed"
  else
    warn "RTK installation failed; continuing without RTK"
  fi
}

prompt_yes_no() {
  local prompt_text="$1" default_answer="${2:-N}"
  if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
    return 1
  fi
  local answer=""
  printf '%s: ' "$prompt_text" > /dev/tty
  IFS= read -r -t 30 answer < /dev/tty || answer=""
  [ -n "$answer" ] || answer="$default_answer"
  case "$answer" in
    y|Y|yes|YES|Yes|true|TRUE|1) return 0 ;;
    *) return 1 ;;
  esac
}

install_uv() {
  if command -v uv >/dev/null 2>&1; then
    log "uv already installed"
    return 0
  fi

  if dry_run_enabled; then
    printf '[dry-run] curl -LsSf https://astral.sh/uv/install.sh | sh\n' >&2
    return 0
  fi

  if ! prompt_yes_no 'uv is required but not installed. Install uv now? [y/N]' N; then
    warn "uv not installed; skipping Serena installation"
    return 1
  fi

  log "Installing uv"
  if ! curl -LsSf https://astral.sh/uv/install.sh | sh; then
    warn "uv installation failed; skipping Serena installation"
    return 1
  fi

  if command -v uv >/dev/null 2>&1; then
    log "uv installed"
    return 0
  fi

  if [ -x "$HOME/.cargo/bin/uv" ]; then
    export PATH="$HOME/.cargo/bin:$PATH"
    log "uv installed"
    return 0
  fi

  if [ -x "$HOME/.local/bin/uv" ]; then
    export PATH="$HOME/.local/bin:$PATH"
    log "uv installed"
    return 0
  fi

  warn "uv installed but not found on PATH; skipping Serena installation"
  return 1
}

install_serena() {
  case "${INSTALL_SERENA_VALUE:-auto}" in
    n|N|no|NO|No|false|FALSE|0) return 0 ;;
    y|Y|yes|YES|Yes|true|TRUE|1) ;;
    auto|AUTO|Auto) ;;
    *) die "invalid B_AGENTIC_INSTALL_SERENA value: $INSTALL_SERENA_VALUE" ;;
  esac

  if command -v serena >/dev/null 2>&1; then
    case "${INSTALL_SERENA_VALUE:-auto}" in
      auto|AUTO|Auto)
        if ! prompt_yes_no 'Serena is already installed. Upgrade it now? [y/N]' N; then
          log "Serena already installed; skipping upgrade without explicit approval"
          return 0
        fi
        ;;
    esac
    if dry_run_enabled; then
      printf '[dry-run] uv tool upgrade serena-agent\n' >&2
      return 0
    fi
    if ! command -v uv >/dev/null 2>&1; then
      warn "uv not installed; skipping Serena upgrade"
      return 0
    fi
    log "Serena already installed; upgrading"
    if uv tool upgrade serena-agent; then
      log "Serena upgraded"
    else
      warn "Serena upgrade failed; continuing with existing Serena"
    fi
    return 0
  fi

  case "${INSTALL_SERENA_VALUE:-auto}" in
    auto|AUTO|Auto)
      if ! prompt_yes_no 'Install Serena MCP agent (requires uv)? [y/N]' N; then
        return 0
      fi
      ;;
  esac

  install_uv || return 0

  if dry_run_enabled; then
    printf '[dry-run] uv tool install -p 3.13 serena-agent\n' >&2
    return 0
  fi

  log "Installing Serena"
  if uv tool install -p 3.13 serena-agent; then
    log "Serena installed"
  else
    warn "Serena installation failed; continuing without Serena"
  fi
}

install_codegraph() {
  case "${INSTALL_CODEGRAPH_VALUE:-auto}" in
    n|N|no|NO|No|false|FALSE|0) return 0 ;;
    y|Y|yes|YES|Yes|true|TRUE|1) ;;
    auto|AUTO|Auto) ;;
    *) die "invalid B_AGENTIC_INSTALL_CODEGRAPH value: $INSTALL_CODEGRAPH_VALUE" ;;
  esac

  if command -v codegraph >/dev/null 2>&1; then
    case "${INSTALL_CODEGRAPH_VALUE:-auto}" in
      auto|AUTO|Auto)
        if ! prompt_yes_no 'CodeGraph is already installed. Upgrade it now? [y/N]' N; then
          log "CodeGraph already installed; skipping upgrade without explicit approval"
          return 0
        fi
        ;;
    esac
    if dry_run_enabled; then
      printf '[dry-run] codegraph upgrade\n' >&2
      return 0
    fi
    log "CodeGraph already installed; upgrading"
    if codegraph upgrade; then
      log "CodeGraph upgraded"
    else
      warn "CodeGraph upgrade failed; continuing with existing CodeGraph"
    fi
    return 0
  fi

  case "${INSTALL_CODEGRAPH_VALUE:-auto}" in
    auto|AUTO|Auto)
      if ! prompt_yes_no 'Install CodeGraph MCP agent? [y/N]' N; then
        return 0
      fi
      ;;
  esac

  if dry_run_enabled; then
    printf '[dry-run] curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh | sh\n' >&2
    return 0
  fi

  log "Installing CodeGraph"
  if curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh | sh; then
    log "CodeGraph installed"
  else
    warn "CodeGraph installation failed; continuing without CodeGraph"
  fi
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
  validate_ref

  if try_manifest_only_uninstall; then
    return 0
  fi

  check_dependencies
  install_app

  source_installer_core

  if ! uninstall_enabled; then
    install_rtk
    install_shell_tools
    install_serena
    install_codegraph
  fi

  if [ "$RUNTIME" = "all" ]; then
    set +e
    ( set -e; run_all_runtimes )
    rc=$?
    set -e
    return "$rc"
  fi

  runtime_registered "$RUNTIME" || die "unknown runtime: $RUNTIME"
  validate_runtime_source_layout

  load_runtime_driver

  if uninstall_enabled; then
    set +e
    ( set -e; runtime_uninstall )
    rc=$?
    set -e
    return "$rc"
  fi

  set +e
  ( set -e; runtime_main )
  rc=$?
  set -e
  return "$rc"
}

main "$@"
