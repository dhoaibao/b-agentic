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

SOURCE_DIR="$LOCAL_REPO"
SKILLS_SRC="$SOURCE_DIR/skills"
REFERENCES_SRC="$SOURCE_DIR/references"
TEMPLATES_SRC="$SOURCE_DIR/runtimes/$RUNTIME/configs"
KERNEL_SRC="$SOURCE_DIR/runtimes/$RUNTIME/kernel.md"
DRY_RUN_SOURCE_DIR=""
UI_MODE="${B_AGENTIC_UI:-auto}"
UI_ENABLED=0
UI_SPINNER_ACTIVE=0
UI_SPINNER_LABEL=""
UI_SPINNER_PID=""
UI_COLOR_DIM=""
UI_COLOR_ACCENT=""
UI_COLOR_SUCCESS=""
UI_COLOR_WARN=""
UI_COLOR_ERROR=""
UI_COLOR_RESET=""

ui_clear_ephemeral_line() {
  [ "${UI_SPINNER_ACTIVE:-0}" -eq 1 ] || return 0
  printf '\r\033[2K' >&2
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
    marker="${UI_COLOR_SUCCESS}[ok]${UI_COLOR_RESET}"
  else
    marker="${UI_COLOR_ERROR}[!!]${UI_COLOR_RESET}"
  fi
  printf '%b %s\n' "$marker" "$label" >&2
}

log() {
  ui_clear_ephemeral_line
  printf '%s\n' "$*"
}

warn() {
  ui_clear_ephemeral_line
  printf '%bwarning:%b %s\n' "$UI_COLOR_WARN" "$UI_COLOR_RESET" "$*" >&2
}

die() {
  if [ "${UI_SPINNER_ACTIVE:-0}" -eq 1 ]; then
    ui_stop_spinner 1 "$UI_SPINNER_LABEL"
  else
    ui_clear_ephemeral_line
  fi
  printf '%berror:%b %s\n' "$UI_COLOR_ERROR" "$UI_COLOR_RESET" "$*" >&2
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
    UI_COLOR_DIM=$'\033[2m'
    UI_COLOR_ACCENT=$'\033[36m'
    UI_COLOR_SUCCESS=$'\033[32m'
    UI_COLOR_WARN=$'\033[33m'
    UI_COLOR_ERROR=$'\033[31m'
    UI_COLOR_RESET=$'\033[0m'
  fi
}

ui_spinner_loop() {
  local label="$1"
  local -a frames=('-' '\' '|' '/')
  local index=0

  while :; do
    printf '\r\033[2K%b[%s]%b %s' "$UI_COLOR_ACCENT" "${frames[$index]}" "$UI_COLOR_RESET" "$label" >&2
    index=$(((index + 1) % ${#frames[@]}))
    sleep 0.1
  done
}

ui_start_spinner() {
  local label="$1"
  [ "${UI_ENABLED:-0}" -eq 1 ] || return 0
  ui_clear_ephemeral_line
  UI_SPINNER_ACTIVE=1
  UI_SPINNER_LABEL="$label"
  ui_spinner_loop "$label" &
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

  printf '\n%b==%b b-agentic installer\n' \
    "$UI_COLOR_ACCENT" "$UI_COLOR_RESET" >&2
  printf '%b::%b mode %s | runtime %s\n' \
    "$UI_COLOR_DIM" "$UI_COLOR_RESET" "$action" "$target" >&2
}

ui_print_runtime_banner() {
  local runtime_label="$1" activation_state="$2"
  [ "${UI_ENABLED:-0}" -eq 1 ] || return 0

  printf '\n%b==%b %s %b::%b activation %s\n' \
    "$UI_COLOR_ACCENT" "$UI_COLOR_RESET" "$runtime_label" "$UI_COLOR_DIM" "$UI_COLOR_RESET" "$activation_state" >&2
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
      git clone "$REPO_URL" "$DRY_RUN_SOURCE_DIR"
      if [ -n "$REF" ]; then
        git -C "$DRY_RUN_SOURCE_DIR" checkout "$REF"
      fi
      set_source_dir "$DRY_RUN_SOURCE_DIR"
    fi
  elif [ -d "$LOCAL_REPO/.git" ]; then
    log "Updating source: $LOCAL_REPO"
    git -C "$LOCAL_REPO" fetch --all --tags --prune
    if [ -n "$REF" ]; then
      git -C "$LOCAL_REPO" checkout "$REF"
    else
      git -C "$LOCAL_REPO" pull --ff-only
    fi
    set_source_dir "$LOCAL_REPO"
  else
    log "Cloning source: $REPO_URL -> $LOCAL_REPO"
    mkdir -p "$(dirname "$LOCAL_REPO")"
    git clone "$REPO_URL" "$LOCAL_REPO"
    if [ -n "$REF" ]; then
      git -C "$LOCAL_REPO" checkout "$REF"
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

manifest_path_for_runtime() {
  case "$1" in
    claude-code) printf '%s/.claude/b-agentic/install.json' "$HOME" ;;
    opencode) printf '%s/.config/opencode/b-agentic/install.json' "$HOME" ;;
    codex-cli) printf '%s/.codex/b-agentic/install.json' "$HOME" ;;
    *) return 1 ;;
  esac
}

manifest_only_runtime_names() {
  printf '%s\n' claude-code opencode codex-cli
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
  run_cmd python3 - "$manifest_path" <<'PY'
import json
import shutil
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1]).expanduser()
home = Path.home().resolve()


def warn(message: str) -> None:
    print(f"warning: {message}", file=sys.stderr)


def under_home(path: Path) -> bool:
    try:
        path.resolve().relative_to(home)
        return True
    except Exception:
        return False


def safe_name(name: object) -> bool:
    if not isinstance(name, str) or not name.startswith("b-"):
        return False
    return all(ch.islower() or ch.isdigit() or ch == "-" for ch in name) and not name.endswith("-")


def remove_tree(path: Path) -> None:
    if path.exists() and under_home(path):
        shutil.rmtree(path)


def remove_file(path: Path) -> None:
    if path.exists() and under_home(path):
        path.unlink()


def files_equal(left: Path, right: Path) -> bool:
    try:
        return left.read_bytes() == right.read_bytes()
    except Exception:
        return False


def remove_snapshot_profiles(names: list, dst_root: Path, snapshot_root: Path, extension: str, label: str) -> None:
    for name in names:
        if not safe_name(name):
            warn(f"preserving {label} with unsafe manifest name")
            continue
        dst = dst_root / f"{name}.{extension}"
        snapshot = snapshot_root / f"{name}.{extension}"
        if not dst.exists():
            continue
        if snapshot.exists() and files_equal(dst, snapshot):
            remove_file(dst)
        else:
            warn(f"preserving modified {label}: {dst}")


def remove_config_if_template(path_value: str | None, template: Path, label: str) -> None:
    if not isinstance(path_value, str):
        return
    path = Path(path_value).expanduser()
    if path.exists() and template.exists() and files_equal(path, template):
        remove_file(path)
    elif path.exists():
        warn(f"preserving modified {label}: {path}")


def remove_codex_managed_block(path_value: str | None) -> None:
    if not isinstance(path_value, str):
        return
    path = Path(path_value).expanduser()
    if not path.exists():
        return
    begin = "# BEGIN b-agentic managed config"
    end = "# END b-agentic managed config"
    text = path.read_text()
    if begin not in text:
        return
    if end not in text:
        warn(f"preserving modified Codex config: {path}")
        return
    prefix, remainder = text.split(begin, 1)
    _managed, suffix = remainder.split(end, 1)
    cleaned = (prefix + suffix).strip()
    if cleaned:
        path.write_text(cleaned + "\n")
    else:
        remove_file(path)


data = json.loads(manifest_path.read_text())
runtime = data.get("runtime")
paths = data.get("paths", {})
metadata = manifest_path.parent

runtime_defaults = {
    "claude-code": {
        "metadata": home / ".claude" / "b-agentic",
        "skills": home / ".claude" / "skills",
        "kernel": home / ".claude" / "CLAUDE.md",
        "agents": home / ".claude" / "agents",
        "settings": home / ".claude" / "settings.json",
        "claudeJson": home / ".claude.json",
    },
    "opencode": {
        "metadata": home / ".config" / "opencode" / "b-agentic",
        "skills": home / ".config" / "opencode" / "skills",
        "kernel": home / ".config" / "opencode" / "AGENTS.md",
        "agents": home / ".config" / "opencode" / "agents",
        "commands": home / ".config" / "opencode" / "commands",
        "opencodeJson": home / ".config" / "opencode" / "opencode.json",
    },
    "codex-cli": {
        "metadata": home / ".codex" / "b-agentic",
        "skills": home / ".codex" / "skills",
        "kernel": home / ".codex" / "AGENTS.md",
        "agents": home / ".codex" / "agents",
        "rules": home / ".codex" / "rules",
        "codexConfig": home / ".codex" / "config.toml",
    },
}

defaults = runtime_defaults.get(runtime)
if defaults is None:
    raise SystemExit(f"unsupported manifest runtime: {runtime!r}")
if metadata.resolve() != defaults["metadata"].resolve():
    raise SystemExit(f"manifest path does not match runtime metadata root: {manifest_path}")


def managed_skill_dir(path: Path) -> bool:
    skill_file = path / "SKILL.md"
    if not skill_file.exists():
        return False
    try:
        text = skill_file.read_text()
    except Exception:
        return False
    return "Generated from skills/registry.yaml" in text


skills_root = defaults["skills"]
for name in data.get("skills", []):
    if not safe_name(name):
        warn("preserving skill with unsafe manifest name")
        continue
    skill_dir = skills_root / name
    if managed_skill_dir(skill_dir):
        remove_tree(skill_dir)
    elif skill_dir.exists():
        warn(f"preserving skill without managed marker: {skill_dir}")

kernel_path = defaults["kernel"]
kernel_snapshot = metadata / kernel_path.name
if kernel_path.exists():
    try:
        kernel_text = kernel_path.read_text()
    except Exception:
        kernel_text = ""
    if "<!-- b-agentic-managed -->" in kernel_text and kernel_snapshot.exists() and files_equal(kernel_path, kernel_snapshot):
        remove_file(kernel_path)
    else:
        warn(f"preserving modified managed kernel: {kernel_path}")

if runtime == "claude-code":
    remove_snapshot_profiles(data.get("agents", []), defaults["agents"], metadata / "agents", "md", "Claude Code agent")
    remove_config_if_template(str(defaults["settings"]), metadata / "templates" / "settings.template.json", "settings.json")
    remove_config_if_template(str(defaults["claudeJson"]), metadata / "templates" / "mcp.user.template.json", ".claude.json")
elif runtime == "opencode":
    remove_snapshot_profiles(data.get("agents", []), defaults["agents"], metadata / "agents", "md", "OpenCode agent")
    remove_snapshot_profiles(data.get("commands", []), defaults["commands"], metadata / "commands", "md", "OpenCode command")
    remove_config_if_template(str(defaults["opencodeJson"]), metadata / "templates" / "mcp.user.template.json", "opencode.json")
elif runtime == "codex-cli":
    remove_snapshot_profiles(data.get("agents", []), defaults["agents"], metadata / "agents", "toml", "Codex agent")
    remove_snapshot_profiles(data.get("rules", []), defaults["rules"], metadata / "rules", "rules", "Codex rule")
    remove_codex_managed_block(str(defaults["codexConfig"]))
remove_tree(metadata)
print(f"Manifest-only uninstall complete for {runtime}. Source cache was not required.")
PY
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
  parse_args "$@"
  ui_init
  ui_print_intro
  if try_manifest_only_uninstall; then
    return 0
  fi
  prepare_source

  if [ "$RUNTIME" = "all" ]; then
    run_all_runtimes
    return $?
  fi

  runtime_registered "$RUNTIME" || die "unknown runtime: $RUNTIME"
  validate_runtime_source_layout

  source_installer_core
  load_runtime_driver

  if uninstall_enabled; then
    runtime_uninstall
    return 0
  fi

  runtime_main
}

main "$@"
