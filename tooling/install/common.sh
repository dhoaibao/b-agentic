# Shared native Pi installer helpers. Sourced by install.sh.
# shellcheck shell=bash
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by install.sh" >&2
  exit 1
fi

ensure_dir() { run_cmd mkdir -p "$1"; }
installer_summary_log() { log "$@"; }
set_install_stage_total() { INSTALL_STAGE_CURRENT=0; INSTALL_STAGE_TOTAL="${1:-0}"; }

run_stage() {
  local label="$1"
  shift
  INSTALL_STAGE_CURRENT=$((INSTALL_STAGE_CURRENT + 1))
  step "[$INSTALL_STAGE_CURRENT/${INSTALL_STAGE_TOTAL:-?}] $label"
  "$@"
}

capture_output_stage() {
  local label="$1" output_var="$2" captured
  shift 2
  INSTALL_STAGE_CURRENT=$((INSTALL_STAGE_CURRENT + 1))
  step "[$INSTALL_STAGE_CURRENT/${INSTALL_STAGE_TOTAL:-?}] $label"
  captured="$("$@")" || return $?
  printf -v "$output_var" '%s' "$captured"
}

read_install_triplet() {
  local output="$1" default_action="$2" default_state="$3" default_backup="$4"
  local action_var="$5" state_var="$6" backup_var="$7"
  local action="$default_action" state="$default_state" backup="$default_backup"
  local line=0 value
  while IFS= read -r value; do
    line=$((line + 1))
    case "$line" in
      1) [ -n "$value" ] && action="$value" ;;
      2) [ -n "$value" ] && state="$value" ;;
      3) [ -n "$value" ] && backup="$value" ;;
    esac
  done <<<"$output"
  printf -v "$action_var" '%s' "$action"
  printf -v "$state_var" '%s' "$state"
  printf -v "$backup_var" '%s' "$backup"
}

run_install_triplet_stage() {
  local label="$1" command_name="$2" default_action="$3" default_state="$4" default_backup="$5"
  local action_var="$6" state_var="$7" backup_var="$8" output
  capture_output_stage "$label" output "$command_name"
  read_install_triplet "$output" "$default_action" "$default_state" "$default_backup" \
    "$action_var" "$state_var" "$backup_var"
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
    printf '[dry-run] cp -R %s %s\n' "$src" "$dst" >&2
    return 0
  fi
  rm -rf "$dst"
  cp -R "$src" "$dst"
}

backup_file() {
  local path="$1" backup suffix=1
  [ -f "$path" ] || return 0
  ensure_dir "$BACKUPS_DIR"
  backup="$BACKUPS_DIR/$(basename "$path").bak-$TIMESTAMP"
  while [ -e "$backup" ]; do
    backup="$BACKUPS_DIR/$(basename "$path").bak-$TIMESTAMP-$suffix"
    suffix=$((suffix + 1))
  done
  copy_file "$path" "$backup"
  printf '%s' "$backup"
}

managed_asset_name_is_safe() {
  case "$1" in b-[a-z]* ) ;; *) return 1 ;; esac
  case "$1" in *[!a-z0-9-]*|*-) return 1 ;; esac
  return 0
}

skill_names() {
  python3 - "$SKILLS_SRC" <<'PY'
from pathlib import Path
import sys
for path in sorted(Path(sys.argv[1]).glob('*/SKILL.md')):
    print(path.parent.name)
PY
}

skill_dir_matches_snapshot() {
  python3 - "$1" "$2" <<'PY'
from pathlib import Path
import sys

def same(left, right):
    if left.is_symlink() or right.is_symlink(): return False
    if left.is_dir() and right.is_dir():
        a = {item.name: item for item in left.iterdir()}
        b = {item.name: item for item in right.iterdir()}
        return a.keys() == b.keys() and all(same(a[name], b[name]) for name in a)
    return left.is_file() and right.is_file() and left.read_bytes() == right.read_bytes()
sys.exit(0 if same(Path(sys.argv[1]), Path(sys.argv[2])) else 1)
PY
}

install_skills() {
  local name src dst snapshot
  INSTALL_SKILL_NAMES=()
  ensure_dir "$SKILLS_DST"
  ensure_dir "$SKILLS_SNAPSHOT_DST"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    src="$SKILLS_SRC/$name"; dst="$SKILLS_DST/$name"; snapshot="$SKILLS_SNAPSHOT_DST/$name"
    if [ -L "$dst" ]; then
      warn "preserving symlinked skill: $dst"
      continue
    fi
    if [ -e "$dst" ] && { ! grep -Fq 'Generated from skills/registry.yaml' "$dst/SKILL.md" 2>/dev/null || ! skill_dir_matches_snapshot "$dst" "$snapshot"; }; then
      warn "preserving user-owned or modified skill: $dst"
      continue
    fi
    copy_dir_replace "$src" "$dst"
    run_cmd rm -f "$dst/prompt.md"
    copy_dir_replace "$dst" "$snapshot"
    INSTALL_SKILL_NAMES+=("$name")
  done < <(skill_names)
}

install_references_and_templates() {
  copy_dir_replace "$REFERENCES_SRC" "$REFERENCES_DST"
  copy_dir_replace "$TEMPLATES_SRC" "$TEMPLATES_DST"
}

install_kernel() {
  ensure_dir "$METADATA_DIR"
  if [ -L "$KERNEL_DST" ]; then
    warn "preserving symlinked kernel: $KERNEL_DST"
    printf 'preserve\npending\nnone'
  elif [ ! -e "$KERNEL_DST" ]; then
    copy_file "$KERNEL_SRC" "$KERNEL_DST"
    copy_file "$KERNEL_SRC" "$KERNEL_SNAPSHOT_DST"
    printf 'write\nactive\nnone'
  elif [ -f "$KERNEL_SNAPSHOT_DST" ] && cmp -s "$KERNEL_DST" "$KERNEL_SNAPSHOT_DST"; then
    copy_file "$KERNEL_SRC" "$KERNEL_DST"
    copy_file "$KERNEL_SRC" "$KERNEL_SNAPSHOT_DST"
    printf 'replace\nactive\nnone'
  elif replace_memory_enabled; then
    local backup
    backup="$(backup_file "$KERNEL_DST")"
    copy_file "$KERNEL_SRC" "$KERNEL_DST"
    copy_file "$KERNEL_SRC" "$KERNEL_SNAPSHOT_DST"
    printf 'replace\nactive\n%s' "${backup:-none}"
  else
    printf 'preserve\npending\nnone'
  fi
}

remove_managed_kernel() {
  if [ -L "$KERNEL_DST" ]; then
    warn "preserving symlinked kernel: $KERNEL_DST"
    PRESERVE_METADATA_DIR=1
    return 0
  fi
  [ -f "$KERNEL_DST" ] || return 0
  if grep -Fq '<!-- b-agentic-managed -->' "$KERNEL_DST" && [ -f "$KERNEL_SNAPSHOT_DST" ] && cmp -s "$KERNEL_DST" "$KERNEL_SNAPSHOT_DST"; then
    local original
    original="$(manifest_backup_value kernel none)"
    if [ "$original" != none ]; then
      if [ -f "$original" ] && [ ! -L "$original" ]; then
        run_cmd cp "$original" "$KERNEL_DST"
        if [ -f "$MANIFEST_DST" ] && python3 - "$MANIFEST_DST" <<'PY'
import json, sys
from pathlib import Path
raise SystemExit(0 if json.loads(Path(sys.argv[1]).read_text()).get('kernelPriorBackups') else 1)
PY
        then
          warn "preserving earlier user kernel backups in $BACKUPS_DIR"
          PRESERVE_METADATA_DIR=1
        fi
      else
        warn "preserving managed kernel: original backup is missing: $original"
        PRESERVE_METADATA_DIR=1
      fi
    else
      run_cmd rm -f "$KERNEL_DST"
    fi
  else
    warn "preserving modified or user-owned kernel: $KERNEL_DST"
    PRESERVE_METADATA_DIR=1
  fi
}

manifest_backup_value() {
  local key="$1" fallback="$2"
  [ -f "$MANIFEST_DST" ] || { printf '%s' "$fallback"; return 0; }
  python3 - "$MANIFEST_DST" "$key" "$fallback" <<'PY'
import json, sys
from pathlib import Path
try:
    print(json.loads(Path(sys.argv[1]).read_text()).get('backups', {}).get(sys.argv[2], sys.argv[3]))
except Exception:
    print(sys.argv[3])
PY
}

manifest_action_value() {
  local key="$1" fallback="$2"
  [ -f "$MANIFEST_DST" ] || { printf '%s' "$fallback"; return 0; }
  python3 - "$MANIFEST_DST" "$key" "$fallback" <<'PY'
import json, sys
from pathlib import Path
try:
    print(json.loads(Path(sys.argv[1]).read_text()).get(sys.argv[2], sys.argv[3]))
except Exception:
    print(sys.argv[3])
PY
}

manifest_array_values() {
  [ -f "$MANIFEST_DST" ] || return 1
  python3 - "$MANIFEST_DST" "$1" <<'PY'
import json, sys
from pathlib import Path
try:
    for value in json.loads(Path(sys.argv[1]).read_text()).get(sys.argv[2], []):
        if isinstance(value, str): print(value)
except Exception:
    pass
PY
}

manifest_path_value() {
  local key="$1" fallback="$2"
  [ -f "$MANIFEST_DST" ] || { printf '%s' "$fallback"; return 0; }
  python3 - "$MANIFEST_DST" "$key" "$fallback" <<'PY'
import json, sys
from pathlib import Path
try:
    print(json.loads(Path(sys.argv[1]).read_text()).get('paths', {}).get(sys.argv[2], sys.argv[3]))
except Exception:
    print(sys.argv[3])
PY
}

merge_json_file() {
  local src="$1" dst="$2" label="$3" backup_key="$4"
  [ ! -L "$dst" ] || die "preserving symlinked $label configuration: $dst"
  if [ ! -e "$dst" ]; then
    copy_file "$src" "$dst"
    printf 'write\nactive\nnone'
    return 0
  fi
  if dry_run_enabled; then
    printf '[dry-run] merge %s into %s\n' "$src" "$dst" >&2
    printf 'merge\nactive\n%s' "$(manifest_backup_value "$backup_key" none)"
    return 0
  fi
  local tmp backup
  tmp="$(mktemp "${TMPDIR:-/tmp}/b-agentic-${label}.XXXXXX")"
  if ! env JSON_SRC="$src" JSON_DST="$dst" JSON_TMP="$tmp" JSON_PREVIOUS_TEMPLATE="$TEMPLATES_DST/$(basename "$src")" SOURCE_DIR="$SOURCE_DIR" python3 - <<'PY'
import json, os, sys
from pathlib import Path
sys.path.insert(0, str(Path(os.environ['SOURCE_DIR']) / 'tooling' / 'install'))
from jsonc import loads
src, dst, tmp = map(Path, (os.environ['JSON_SRC'], os.environ['JSON_DST'], os.environ['JSON_TMP']))
incoming = json.loads(src.read_text())
current = loads(dst.read_text())
previous_path = Path(os.environ['JSON_PREVIOUS_TEMPLATE'])
previous = json.loads(previous_path.read_text()) if previous_path.is_file() else {}
if not isinstance(incoming, dict) or not isinstance(current, dict) or not isinstance(previous, dict):
    raise SystemExit('configuration roots must be objects')
def merge(existing, recommended, path=()):
    if isinstance(existing, dict) and isinstance(recommended, dict):
        merged = dict(existing)
        for key, value in recommended.items():
            if key == 'packages' and isinstance(merged.get(key), list) and isinstance(value, list):
                merged[key] = value + [item for item in merged[key] if item not in value]
            else:
                merged[key] = merge(merged[key], value, path + (key,)) if key in merged else value
        return merged
    if isinstance(existing, list) and isinstance(recommended, list):
        # Preserve user-owned command and other ordered arrays.
        return existing
    return existing
merged = merge(current, incoming)
tmp.write_text(json.dumps(merged, indent=2) + '\n')
PY
  then
    rm -f "$tmp"
    die "failed to merge $label configuration: $dst"
  fi
  backup="$(backup_file "$dst")"
  run_cmd mv "$tmp" "$dst"
  printf 'merge\nactive\n%s' "${backup:-none}"
}

remove_merged_config() {
  local path="$1" template="$2" label="$3" backup_key="$4" action_key="$5" backup original_arg tmp
  if [ -L "$path" ]; then
    warn "preserving symlinked $label: $path"
    PRESERVE_METADATA_DIR=1
    return 0
  fi
  [ -f "$path" ] || return 0
  backup="$(manifest_backup_value "$backup_key" none)"
  if [ "$backup" = "none" ] && [ "$(manifest_action_value "$action_key" '')" = "write" ]; then
    original_arg=""
  elif [ -f "$backup" ]; then
    original_arg="$backup"
  else
    warn "preserving modified $label: $path"
    PRESERVE_METADATA_DIR=1
    return 0
  fi
  if dry_run_enabled; then
    printf '[dry-run] remove managed %s values from %s\n' "$label" "$path" >&2
    return 0
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/b-agentic-uninstall-${label}.XXXXXX")"
  if ! env JSON_CURRENT="$path" JSON_TEMPLATE="$template" JSON_ORIGINAL="$original_arg" JSON_TMP="$tmp" SOURCE_DIR="$SOURCE_DIR" python3 - <<'PY'
import json, os, sys
from pathlib import Path
sys.path.insert(0, str(Path(os.environ['SOURCE_DIR']) / 'tooling' / 'install'))
from jsonc import loads
from json_cleanup import remove_managed_json_config
current = Path(os.environ['JSON_CURRENT'])
template = Path(os.environ['JSON_TEMPLATE'])
original = Path(os.environ['JSON_ORIGINAL']) if os.environ['JSON_ORIGINAL'] else None
cleaned = remove_managed_json_config(current, template, original, current.name)
Path(os.environ['JSON_TMP']).write_text(json.dumps(cleaned, indent=2) + '\n')
PY
  then
    rm -f "$tmp"
    warn "preserving modified $label: $path"
    PRESERVE_METADATA_DIR=1
    return 0
  fi
  if [ "$(cat "$tmp")" = "{}" ]; then
    if [ "$(manifest_action_value "$action_key" '')" = write ]; then
      run_cmd rm -f "$path"
      rm -f "$tmp"
    else
      run_cmd mv "$tmp" "$path"
    fi
  else
    run_cmd mv "$tmp" "$path"
  fi
}

install_uninstall_helper() {
  local destination="$METADATA_DIR/tooling/install"
  ensure_dir "$destination"
  copy_file "$SOURCE_DIR/tooling/install/manifest_uninstall.py" "$destination/manifest_uninstall.py"
  copy_file "$SOURCE_DIR/tooling/install/jsonc.py" "$destination/jsonc.py"
  copy_file "$SOURCE_DIR/tooling/install/json_cleanup.py" "$destination/json_cleanup.py"
}

runtime_sync_configs() {
  runtime_install_configs
}

runtime_sync_common() {
  set_install_stage_total 12
  run_stage 'Syncing skills' install_skills
  run_install_triplet_stage 'Syncing kernel' install_kernel preserve pending none INSTALL_MEMORY_ACTION INSTALL_ACTIVATION_STATE INSTALL_MEMORY_BACKUP
  remember_kernel_baseline
  runtime_sync_configs
  run_stage 'Syncing references and templates' install_references_and_templates
  run_stage 'Refreshing uninstall helper' install_uninstall_helper
  # shellcheck disable=SC2034 # Consumed by the sourced Pi runtime installer.
  PRIOR_PACKAGE_STATE="$(manifest_action_value packageState pending)"
  # shellcheck disable=SC2034 # Consumed by the sourced Pi runtime installer.
  PRIOR_FAILED_PACKAGE="$(manifest_action_value failedPackage '')"
  run_stage 'Writing install manifest' runtime_write_manifest
  runtime_finish_packages
}

runtime_install_common() {
  set_install_stage_total 13
  run_stage 'Preparing Pi CLI' runtime_upgrade_cli
  run_stage 'Syncing skills' install_skills
  run_install_triplet_stage 'Installing kernel' install_kernel preserve pending none INSTALL_MEMORY_ACTION INSTALL_ACTIVATION_STATE INSTALL_MEMORY_BACKUP
  remember_kernel_baseline
  runtime_install_configs
  run_stage 'Syncing references and templates' install_references_and_templates
  run_stage 'Installing uninstall helper' install_uninstall_helper
  # shellcheck disable=SC2034 # Consumed by the sourced Pi runtime installer.
  PRIOR_PACKAGE_STATE="$(manifest_action_value packageState pending)"
  # shellcheck disable=SC2034 # Consumed by the sourced Pi runtime installer.
  PRIOR_FAILED_PACKAGE="$(manifest_action_value failedPackage '')"
  run_stage 'Writing install manifest' runtime_write_manifest
  runtime_finish_packages
  runtime_print_install_report
}

manifest_skill_names() {
  manifest_array_values skills || skill_names
}

uninstall_installed_skills() {
  local name path snapshot
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! managed_asset_name_is_safe "$name"; then
      warn "preserving skill with unsafe manifest name"
      PRESERVE_METADATA_DIR=1
      continue
    fi
    path="$SKILLS_DST/$name"
    snapshot="$SKILLS_SNAPSHOT_DST/$name"
    if [ -L "$path" ]; then
      warn "preserving symlinked skill: $path"
      PRESERVE_METADATA_DIR=1
    elif [ -d "$path" ] && [ -d "$snapshot" ] && skill_dir_matches_snapshot "$path" "$snapshot"; then
      run_cmd rm -rf "$path"
    elif [ -e "$path" ]; then
      warn "preserving modified skill: $path"
      PRESERVE_METADATA_DIR=1
    fi
  done < <(manifest_skill_names)
}

runtime_uninstall_common() {
  set_install_stage_total 4
  run_stage 'Removing Pi config' runtime_uninstall_configs
  run_stage 'Removing managed skills' uninstall_installed_skills
  run_stage 'Removing managed kernel' remove_managed_kernel
  if [ "${PRESERVE_METADATA_DIR:-0}" -eq 0 ]; then
    run_stage 'Removing managed metadata' run_cmd rm -rf "$METADATA_DIR"
  else
    run_stage 'Preserving modified metadata' :
  fi
}
