#!/usr/bin/env bash
# install.sh - Bootstrap or update b-agentic for Claude Code
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --dry-run
#   curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --uninstall

set -euo pipefail

readonly REPO_URL="${B_AGENTIC_REPO:-https://github.com/dhoaibao/b-agentic.git}"
readonly LOCAL_REPO="${B_AGENTIC_DIR:-$HOME/.b-agentic}"
readonly REF="${B_AGENTIC_REF:-}"
readonly CLAUDE_DIR="${B_AGENTIC_CLAUDE_DIR:-$HOME/.claude}"
readonly METADATA_DIR="$CLAUDE_DIR/b-agentic"
readonly BACKUPS_DIR="$METADATA_DIR/backups"
readonly SKILLS_DST="$CLAUDE_DIR/skills"
readonly KERNEL_DST="$CLAUDE_DIR/CLAUDE.md"
readonly KERNEL_SNAPSHOT_DST="$METADATA_DIR/CLAUDE.md"
readonly REFERENCES_DST="$METADATA_DIR/references"
readonly TEMPLATES_DST="$METADATA_DIR/templates"
readonly MANIFEST_DST="$METADATA_DIR/install.json"
readonly SETTINGS_DST="$CLAUDE_DIR/settings.json"
readonly CLAUDE_JSON_DST="${B_AGENTIC_CLAUDE_JSON:-$HOME/.claude.json}"
readonly TIMESTAMP="$(date +%Y%m%d%H%M%S)"

DRY_RUN_VALUE="${B_AGENTIC_DRY_RUN:-N}"
REPLACE_MEMORY_VALUE="${B_AGENTIC_REPLACE_MEMORY:-}"
UNINSTALL_VALUE="${B_AGENTIC_UNINSTALL:-N}"

SOURCE_DIR="$LOCAL_REPO"
SKILLS_SRC="$SOURCE_DIR/skills"
REFERENCES_SRC="$SOURCE_DIR/references"
TEMPLATES_SRC="$SOURCE_DIR/claude"
KERNEL_SRC="$SOURCE_DIR/global/CLAUDE.md"
DRY_RUN_SOURCE_DIR=""

log() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

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

run_cmd() {
  if dry_run_enabled; then
    printf '[dry-run] %s\n' "$*" >&2
    return 0
  fi
  "$@"
}

ensure_dir() {
  local dir_path="$1"
  run_cmd mkdir -p "$dir_path"
}

copy_file() {
  local src="$1" dst="$2"
  ensure_dir "$(dirname "$dst")"
  run_cmd cp "$src" "$dst"
}

copy_dir_replace() {
  local src="$1" dst="$2"
  ensure_dir "$(dirname "$dst")"
  if dry_run_enabled; then
    printf '[dry-run] rm -rf %s\n' "$dst" >&2
    printf '[dry-run] cp -R %s %s\n' "$src" "$dst" >&2
    return 0
  fi
  rm -rf "$dst"
  cp -R "$src" "$dst"
}

backup_file() {
  local path="$1"
  [ -f "$path" ] || return 0
  ensure_dir "$BACKUPS_DIR"
  local backup="$BACKUPS_DIR/$(basename "$path").bak-$TIMESTAMP"
  copy_file "$path" "$backup"
  printf '%s' "$backup"
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
  TEMPLATES_SRC="$SOURCE_DIR/claude"
  KERNEL_SRC="$SOURCE_DIR/global/CLAUDE.md"
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

  [ -d "$SKILLS_SRC" ] || die "missing source directory: $SKILLS_SRC"
  [ -d "$REFERENCES_SRC" ] || die "missing source directory: $REFERENCES_SRC"
  [ -d "$TEMPLATES_SRC" ] || die "missing source directory: $TEMPLATES_SRC"
  [ -f "$KERNEL_SRC" ] || die "missing kernel source: $KERNEL_SRC"
}

skill_names() {
  python3 - "$SKILLS_SRC" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for path in sorted(root.glob('*/SKILL.md')):
    print(path.parent.name)
PY
}

sync_references_into_skill() {
  local skill_dir="$1"
  local support_dir="$skill_dir/references/b-agentic"
  ensure_dir "$support_dir"
  if dry_run_enabled; then
    printf '[dry-run] cp %s/*.md %s/\n' "$REFERENCES_SRC" "$support_dir" >&2
    return 0
  fi
  cp "$REFERENCES_SRC"/*.md "$support_dir"/
}

install_skills() {
  ensure_dir "$SKILLS_DST"
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    copy_dir_replace "$SKILLS_SRC/$name" "$SKILLS_DST/$name"
    sync_references_into_skill "$SKILLS_DST/$name"
  done < <(skill_names)
}

print_install_report() {
  local activation_state="$1" skill_count="$2" memory_action="$3" memory_backup="$4" settings_action="$5" settings_backup="$6" mcp_action="$7" mcp_backup="$8"

  log ""
  log "b-agentic Claude Code install complete"
  log "skillsSynced: $skill_count -> $SKILLS_DST"
  log "kernel: $memory_action -> $KERNEL_DST"
  log "settings: $settings_action -> $SETTINGS_DST"
  log "mcp: $mcp_action -> $CLAUDE_JSON_DST"
  log "references: sync -> $REFERENCES_DST"
  log "templates: sync -> $TEMPLATES_DST"
  log "manifest: write -> $MANIFEST_DST"
  log "backups:"
  log "  kernel: $memory_backup"
  log "  settings: $settings_backup"
  log "  mcp: $mcp_backup"
  log "activationState: $activation_state"
}

install_references_and_templates() {
  copy_dir_replace "$REFERENCES_SRC" "$REFERENCES_DST"
  copy_dir_replace "$TEMPLATES_SRC" "$TEMPLATES_DST"
}

install_kernel() {
  ensure_dir "$METADATA_DIR"
  copy_file "$KERNEL_SRC" "$KERNEL_SNAPSHOT_DST"

  if [ ! -e "$KERNEL_DST" ]; then
    copy_file "$KERNEL_SRC" "$KERNEL_DST"
    printf 'replace\nactive\nnone'
    return 0
  fi

  if grep -Fq '<!-- b-agentic-managed -->' "$KERNEL_DST"; then
    local backup
    backup="$(backup_file "$KERNEL_DST")"
    copy_file "$KERNEL_SRC" "$KERNEL_DST"
    printf 'replace\nactive\n%s' "${backup:-none}"
    return 0
  fi

  if replace_memory_enabled; then
    local backup
    backup="$(backup_file "$KERNEL_DST")"
    copy_file "$KERNEL_SRC" "$KERNEL_DST"
    printf 'replace\nactive\n%s' "${backup:-none}"
    return 0
  fi

  printf 'preserve\npending\nnone'
}

merge_json_file() {
  local src="$1" dst="$2" label="$3" backup_key="$4"
  if [ ! -e "$dst" ]; then
    copy_file "$src" "$dst"
    printf 'write\nactive\nnone'
    return 0
  fi

  if dry_run_enabled; then
    printf '[dry-run] merge %s %s into %s\n' "$label" "$src" "$dst" >&2
    printf 'merge\nactive\n%s' "$(manifest_backup_value "$backup_key" none)"
    return 0
  fi

  local tmp rc
  tmp="$(mktemp "${TMPDIR:-/tmp}/b-agentic-${label}.XXXXXX")"
  if env JSON_SRC="$src" JSON_DST="$dst" JSON_TMP="$tmp" JSON_LABEL="$label" python3 - <<'PY'
import json
import os
from pathlib import Path

src = Path(os.environ['JSON_SRC'])
dst = Path(os.environ['JSON_DST'])
tmp = Path(os.environ['JSON_TMP'])
label = os.environ['JSON_LABEL']
recommended = json.loads(src.read_text())
current = json.loads(dst.read_text())

def merge(existing, incoming):
    if isinstance(existing, dict) and isinstance(incoming, dict):
        merged = dict(existing)
        for key, value in incoming.items():
            if key not in merged:
                merged[key] = value
            else:
                merged[key] = merge(merged[key], value)
        return merged
    if isinstance(existing, list) and isinstance(incoming, list):
        merged = list(existing)
        for item in incoming:
            if item not in merged:
                merged.append(item)
        return merged
    return existing

if not isinstance(current, dict):
    raise SystemExit(f'{label} merge requires existing target to be a JSON object')

merged = merge(current, recommended)
if merged == current:
    raise SystemExit(2)
tmp.write_text(json.dumps(merged, indent=2, sort_keys=True) + '\n')
PY
  then
    rc=0
  else
    rc=$?
  fi

  if [ "$rc" -eq 2 ]; then
    rm -f "$tmp"
    printf 'merge\nactive\n%s' "$(manifest_backup_value "$backup_key" none)"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    die "failed to merge $label config: $dst"
  fi

  local backup
  backup="$(backup_file "$dst")"
  run_cmd mv "$tmp" "$dst"
  printf 'merge\nactive\n%s' "${backup:-none}"
}

install_settings_config() {
  merge_json_file "$TEMPLATES_SRC/settings.recommended.json" "$SETTINGS_DST" "settings" "settings"
}

install_mcp_config() {
  merge_json_file "$TEMPLATES_SRC/mcp.user.template.json" "$CLAUDE_JSON_DST" "mcp" "claudeJson"
}

write_manifest() {
  local memory_action="$1" activation_state="$2" memory_backup="$3" settings_action="$4" settings_state="$5" settings_backup="$6" mcp_action="$7" mcp_state="$8" mcp_backup="$9"
  shift 9
  local skills=("$@")

  if dry_run_enabled; then
    printf '[dry-run] write manifest %s\n' "$MANIFEST_DST" >&2
    return 0
  fi

  ensure_dir "$METADATA_DIR"
  env \
    MANIFEST_DST="$MANIFEST_DST" \
    TIMESTAMP="$TIMESTAMP" \
    MEMORY_ACTION="$memory_action" \
    ACTIVATION_STATE="$activation_state" \
    MEMORY_BACKUP="$memory_backup" \
    SETTINGS_ACTION="$settings_action" \
    SETTINGS_STATE="$settings_state" \
    SETTINGS_BACKUP="$settings_backup" \
    MCP_ACTION="$mcp_action" \
    MCP_STATE="$mcp_state" \
    MCP_BACKUP="$mcp_backup" \
    CLAUDE_DIR="$CLAUDE_DIR" \
    CLAUDE_JSON_DST="$CLAUDE_JSON_DST" \
    SKILLS_DST="$SKILLS_DST" \
    REFERENCES_DST="$REFERENCES_DST" \
    TEMPLATES_DST="$TEMPLATES_DST" \
    KERNEL_DST="$KERNEL_DST" \
    SETTINGS_DST="$SETTINGS_DST" \
    SKILLS="${skills[*]}" \
    python3 - <<'PY'
import json
import os
from pathlib import Path

skills = [name for name in os.environ['SKILLS'].split() if name]
manifest = {
    'suite': 'b-agentic',
    'runtime': 'claude-code',
    'installedAt': os.environ['TIMESTAMP'],
    'activationState': os.environ['ACTIVATION_STATE'],
    'memoryAction': os.environ['MEMORY_ACTION'],
    'settingsAction': os.environ['SETTINGS_ACTION'],
    'settingsState': os.environ['SETTINGS_STATE'],
    'mcpAction': os.environ['MCP_ACTION'],
    'mcpState': os.environ['MCP_STATE'],
    'paths': {
        'claudeDir': os.environ['CLAUDE_DIR'],
        'claudeJson': os.environ['CLAUDE_JSON_DST'],
        'kernel': os.environ['KERNEL_DST'],
        'skills': os.environ['SKILLS_DST'],
        'references': os.environ['REFERENCES_DST'],
        'templates': os.environ['TEMPLATES_DST'],
        'settings': os.environ['SETTINGS_DST'],
    },
    'skills': skills,
    'backups': {
        'claudeMd': os.environ['MEMORY_BACKUP'],
        'settings': os.environ['SETTINGS_BACKUP'],
        'claudeJson': os.environ['MCP_BACKUP'],
    },
}
Path(os.environ['MANIFEST_DST']).write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
PY
}

remove_managed_kernel() {
  if [ -f "$KERNEL_DST" ] && grep -Fq '<!-- b-agentic-managed -->' "$KERNEL_DST"; then
    if [ -f "$KERNEL_SNAPSHOT_DST" ] && cmp -s "$KERNEL_DST" "$KERNEL_SNAPSHOT_DST"; then
      run_cmd rm -f "$KERNEL_DST"
    else
      warn "preserving modified managed CLAUDE.md: $KERNEL_DST"
    fi
  fi
}

manifest_path_value() {
  local key="$1" fallback="$2"
  if [ ! -f "$MANIFEST_DST" ]; then
    printf '%s' "$fallback"
    return 0
  fi
  python3 - "$MANIFEST_DST" "$key" "$fallback" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
key = sys.argv[2]
fallback = sys.argv[3]
try:
    data = json.loads(path.read_text())
    print(data.get('paths', {}).get(key, fallback))
except Exception:
    print(fallback)
PY
}

manifest_backup_value() {
  local key="$1" fallback="$2"
  if [ ! -f "$MANIFEST_DST" ]; then
    printf '%s' "$fallback"
    return 0
  fi
  python3 - "$MANIFEST_DST" "$key" "$fallback" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
key = sys.argv[2]
fallback = sys.argv[3]
try:
    data = json.loads(path.read_text())
    print(data.get('backups', {}).get(key, fallback))
except Exception:
    print(fallback)
PY
}

manifest_action_value() {
  local key="$1" fallback="$2"
  if [ ! -f "$MANIFEST_DST" ]; then
    printf '%s' "$fallback"
    return 0
  fi
  python3 - "$MANIFEST_DST" "$key" "$fallback" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
key = sys.argv[2]
fallback = sys.argv[3]
try:
    data = json.loads(path.read_text())
    print(data.get(key, fallback))
except Exception:
    print(fallback)
PY
}

remove_managed_config() {
  local path="$1" template="$2" label="$3"
  [ -f "$path" ] || return 0
  if [ -f "$template" ] && cmp -s "$path" "$template"; then
    run_cmd rm -f "$path"
  else
    warn "preserving modified $label: $path"
  fi
}

remove_merged_config() {
  local path="$1" template="$2" label="$3" backup_key="$4" action_key="$5"
  [ -f "$path" ] || return 0
  if [ -f "$template" ] && cmp -s "$path" "$template"; then
    run_cmd rm -f "$path"
    return 0
  fi

  local original
  original="$(manifest_backup_value "$backup_key" "")"
  if [ ! -f "$original" ] && [ "$(manifest_action_value "$action_key" "")" = "write" ]; then
    original="empty"
  fi
  if [ "$original" != "empty" ] && [ ! -f "$original" ]; then
    warn "preserving modified $label: $path"
    return 0
  fi
  if dry_run_enabled; then
    printf '[dry-run] remove managed %s entries from %s\n' "$label" "$path" >&2
    return 0
  fi

  local tmp rc
  tmp="$(mktemp "${TMPDIR:-/tmp}/b-agentic-uninstall-${label}.XXXXXX")"
  if env JSON_CURRENT="$path" JSON_TEMPLATE="$template" JSON_ORIGINAL="$original" JSON_TMP="$tmp" JSON_LABEL="$label" python3 - <<'PY'
import json
import os
from pathlib import Path

current_path = Path(os.environ['JSON_CURRENT'])
template_path = Path(os.environ['JSON_TEMPLATE'])
original_path = Path(os.environ['JSON_ORIGINAL'])
tmp_path = Path(os.environ['JSON_TMP'])
label = os.environ['JSON_LABEL']

current = json.loads(current_path.read_text())
incoming = json.loads(template_path.read_text())
original = {} if str(original_path) == 'empty' else json.loads(original_path.read_text())

MISSING = object()

def cleanup(current_value, incoming_value, original_value):
    if isinstance(current_value, dict) and isinstance(incoming_value, dict):
        original_dict = original_value if isinstance(original_value, dict) else {}
        result = dict(current_value)
        for key, incoming_child in incoming_value.items():
            if key not in result:
                continue
            original_child = original_dict.get(key, MISSING)
            current_child = result[key]
            if original_child is MISSING:
                if current_child == incoming_child:
                    result.pop(key)
                elif isinstance(current_child, (dict, list)) and isinstance(incoming_child, type(current_child)):
                    empty_original = {} if isinstance(current_child, dict) else []
                    cleaned = cleanup(current_child, incoming_child, empty_original)
                    if cleaned in ({}, []):
                        result.pop(key)
                    else:
                        result[key] = cleaned
            else:
                result[key] = cleanup(current_child, incoming_child, original_child)
        return result

    if isinstance(current_value, list) and isinstance(incoming_value, list):
        original_list = original_value if isinstance(original_value, list) else []
        result = list(current_value)
        for item in incoming_value:
            if item not in original_list and item in result:
                result.remove(item)
        return result

    return current_value

if not isinstance(current, dict) or not isinstance(incoming, dict) or not isinstance(original, dict):
    raise SystemExit(f'{label} cleanup requires JSON object inputs')

cleaned = cleanup(current, incoming, original)
if cleaned == current:
    raise SystemExit(2)
tmp_path.write_text(json.dumps(cleaned, indent=2, sort_keys=True) + '\n')
PY
  then
    rc=0
  else
    rc=$?
  fi

  if [ "$rc" -eq 2 ]; then
    rm -f "$tmp"
    warn "preserving modified $label: $path"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    warn "preserving modified $label: $path"
    return 0
  fi

  mv "$tmp" "$path"
}

uninstall() {
  log "Uninstalling b-agentic from Claude Code personal config"
  local name
  if [ -f "$MANIFEST_DST" ]; then
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      run_cmd rm -rf "$SKILLS_DST/$name"
    done < <(python3 - "$MANIFEST_DST" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text())
except Exception:
    data = {}
for name in data.get('skills', []):
    print(name)
PY
)
  else
    for name in b-orchestrate b-spec b-plan b-research b-implement b-refactor b-debug b-test b-browser b-review b-audit; do
      run_cmd rm -rf "$SKILLS_DST/$name"
    done
  fi

  remove_managed_kernel
  local settings_path claude_json_path
  settings_path="$(manifest_path_value settings "$SETTINGS_DST")"
  claude_json_path="$(manifest_path_value claudeJson "$CLAUDE_JSON_DST")"
  remove_merged_config "$settings_path" "$TEMPLATES_DST/settings.recommended.json" "settings.json" "settings" "settingsAction"
  remove_merged_config "$claude_json_path" "$TEMPLATES_DST/mcp.user.template.json" ".claude.json" "claudeJson" "mcpAction"
  run_cmd rm -rf "$METADATA_DIR"
  log "Uninstall complete. User-owned Claude Code files were preserved."
}

main() {
  parse_args "$@"

  if uninstall_enabled; then
    require_bin python3
    uninstall
    return 0
  fi

  sync_source
  command -v claude >/dev/null 2>&1 || warn "claude CLI not found; files will still be installed for Claude Code to discover later."

  local skill
  local installed_skills=()
  while IFS= read -r skill; do
    [ -n "$skill" ] || continue
    installed_skills+=("$skill")
  done < <(skill_names)
  install_skills

  install_references_and_templates

  local kernel_result memory_action activation_state memory_backup
  local -a kernel_lines
  kernel_result="$(install_kernel)"
  readarray -t kernel_lines <<< "$kernel_result"
  memory_action="${kernel_lines[0]:-preserve}"
  activation_state="${kernel_lines[1]:-pending}"
  memory_backup="${kernel_lines[2]:-none}"

  local settings_result settings_action settings_state settings_backup
  local -a settings_lines
  settings_result="$(install_settings_config)"
  readarray -t settings_lines <<< "$settings_result"
  settings_action="${settings_lines[0]:-skip}"
  settings_state="${settings_lines[1]:-none}"
  settings_backup="${settings_lines[2]:-none}"

  local mcp_result mcp_action mcp_state mcp_backup
  local -a mcp_lines
  mcp_result="$(install_mcp_config)"
  readarray -t mcp_lines <<< "$mcp_result"
  mcp_action="${mcp_lines[0]:-skip}"
  mcp_state="${mcp_lines[1]:-none}"
  mcp_backup="${mcp_lines[2]:-none}"

  write_manifest "$memory_action" "$activation_state" "$memory_backup" "$settings_action" "$settings_state" "$settings_backup" "$mcp_action" "$mcp_state" "$mcp_backup" "${installed_skills[@]}"

  print_install_report "$activation_state" "${#installed_skills[@]}" "$memory_action" "$memory_backup" "$settings_action" "$settings_backup" "$mcp_action" "$mcp_backup"
  if [ "$activation_state" = "pending" ]; then
    log "Existing $KERNEL_DST was preserved. Review $KERNEL_SNAPSHOT_DST and rerun with --replace-memory to activate the kernel."
    return 2
  fi
}

main "$@"
