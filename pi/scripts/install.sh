# Sourced by install.sh — do not run directly.
# shellcheck shell=bash
# shellcheck disable=SC2034 # Shared installer helpers consume these variables.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo 'error: this script is sourced by install.sh' >&2
  exit 1
fi

RUNTIME_NAME=Pi
RUNTIME_UNINSTALL_LABEL='Pi agent directory'
RUNTIME_PRESERVE_LABEL=Pi
PI_CONFIG_DIR="${B_AGENTIC_PI_DIR:-${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}}"
METADATA_DIR="$PI_CONFIG_DIR/b-agentic"
BACKUPS_DIR="$METADATA_DIR/backups"
SKILLS_DST="$PI_CONFIG_DIR/skills"
SKILLS_SNAPSHOT_DST="$METADATA_DIR/skills"
AGENTS_DST="$PI_CONFIG_DIR/agents"
AGENTS_SNAPSHOT_DST="$METADATA_DIR/agents"
COMMANDS_DST="$PI_CONFIG_DIR/prompts"
COMMANDS_SNAPSHOT_DST="$METADATA_DIR/prompts"
KERNEL_DST="$PI_CONFIG_DIR/AGENTS.md"
KERNEL_SNAPSHOT_DST="$METADATA_DIR/AGENTS.md"
REFERENCES_DST="$METADATA_DIR/references"
TEMPLATES_DST="$METADATA_DIR/templates"
MANIFEST_DST="$METADATA_DIR/install.json"
PI_SETTINGS_DST="$PI_CONFIG_DIR/settings.json"
PI_SUBAGENTS_DST="$PI_CONFIG_DIR/subagents.json"
MAGIC_CONTEXT_DST="${XDG_CONFIG_HOME:-$HOME/.config}/cortexkit/magic-context.jsonc"
PI_THEME_DST="$PI_CONFIG_DIR/themes/dracula.json"
PI_THEME_SNAPSHOT_DST="$METADATA_DIR/themes/dracula.json"
PI_THEME_LICENSE_DST="$METADATA_DIR/themes/LICENSE"
PI_THEME_LICENSE_SNAPSHOT_DST="$METADATA_DIR/themes/LICENSE.snapshot"
PI_MCP_DST="$PI_CONFIG_DIR/mcp.json"
PI_PERMISSION_DST="$PI_CONFIG_DIR/extensions/pi-permission-system/config.json"
AGENT_NAMES=(b-planner b-researcher b-debugger b-reviewer)
INSTALL_AGENTS_ACTION=skip
INSTALL_COMMANDS_ACTION=skip
INSTALL_THEME_ACTION=skip
PRESERVE_METADATA_DIR=0
PI_CLI_INSTALL_STATUS=not-run
INSTALL_MISSING_TOOLS=()

runtime_upgrade_cli() {
  if ! command -v pi >/dev/null 2>&1; then
    command -v npm >/dev/null 2>&1 || die 'npm is required to install Pi'
    if dry_run_enabled; then
      PI_CLI_INSTALL_STATUS=planned
      printf '[dry-run] npm install -g @earendil-works/pi-coding-agent\n' >&2
    else
      npm install -g @earendil-works/pi-coding-agent || die 'Pi CLI installation failed'
      PI_CLI_INSTALL_STATUS=installed
    fi
  elif dry_run_enabled; then
    PI_CLI_INSTALL_STATUS=planned
    printf '[dry-run] pi update --self\n' >&2
  else
    PI_CODING_AGENT_DIR="$PI_CONFIG_DIR" pi update --self || die 'Pi CLI update failed'
    PI_CLI_INSTALL_STATUS=installed
  fi
}

managed_file_set() {
  local source_root="$1" destination_root="$2" snapshot_root="$3" label="$4"
  local src name dst snapshot action=skip state=active
  for src in "$source_root"/*.md; do
    [ -f "$src" ] || continue
    name="$(basename "$src")"
    dst="$destination_root/$name"
    snapshot="$snapshot_root/$name"
    if dry_run_enabled; then
      printf '[dry-run] install %s %s -> %s\n' "$label" "$src" "$dst" >&2
      action='write'
      continue
    fi
    ensure_dir "$destination_root"
    ensure_dir "$snapshot_root"
    if [ -L "$dst" ]; then
      warn "preserving symlinked $label: $dst"
      action=preserve; state=preserved
    elif [ ! -e "$dst" ]; then
      copy_file "$src" "$dst"
      copy_file "$src" "$snapshot"
      [ "$action" = preserve ] || action='write'
    elif cmp -s "$src" "$dst"; then
      copy_file "$src" "$snapshot"
    elif [ -f "$snapshot" ] && cmp -s "$dst" "$snapshot"; then
      copy_file "$src" "$dst"
      copy_file "$src" "$snapshot"
      [ "$action" = preserve ] || action=replace
    else
      warn "preserving modified or user-owned $label: $dst"
      action=preserve; state=preserved
    fi
  done
  printf '%s\n%s\nnone' "$action" "$state"
}

install_agents() {
  managed_file_set "$SOURCE_DIR/pi/agents" "$AGENTS_DST" "$AGENTS_SNAPSHOT_DST" 'Pi specialist'
}

install_commands() {
  managed_file_set "$SOURCE_DIR/pi/prompts" "$COMMANDS_DST" "$COMMANDS_SNAPSHOT_DST" 'Pi prompt'
}

install_theme() {
  local src="$SOURCE_DIR/pi/themes/dracula.json"
  if dry_run_enabled; then
    printf '[dry-run] install Pi theme %s -> %s\n' "$src" "$PI_THEME_DST" >&2
    printf 'write\nactive\nnone'
  elif [ -L "$(dirname "$PI_THEME_SNAPSHOT_DST")" ] || [ -L "$PI_THEME_SNAPSHOT_DST" ] ||
       [ -L "$PI_THEME_LICENSE_DST" ] || [ -L "$PI_THEME_LICENSE_SNAPSHOT_DST" ]; then
    die "symlinked Pi theme snapshot or license: $METADATA_DIR/themes"
  elif [ -e "$PI_THEME_LICENSE_DST" ] &&
       { [ ! -f "$PI_THEME_LICENSE_SNAPSHOT_DST" ] || ! cmp -s "$PI_THEME_LICENSE_DST" "$PI_THEME_LICENSE_SNAPSHOT_DST"; }; then
    die "preserving modified Pi theme license: $PI_THEME_LICENSE_DST"
  elif [ -L "$(dirname "$PI_THEME_DST")" ] || [ -L "$PI_THEME_DST" ]; then
    warn "preserving symlinked Pi theme: $PI_THEME_DST"
    printf 'preserve\npreserved\nnone'
  elif [ ! -e "$PI_THEME_DST" ]; then
    copy_file "$src" "$PI_THEME_DST"
    copy_file "$src" "$PI_THEME_SNAPSHOT_DST"
    copy_file "$SOURCE_DIR/pi/themes/LICENSE" "$PI_THEME_LICENSE_DST"
    copy_file "$SOURCE_DIR/pi/themes/LICENSE" "$PI_THEME_LICENSE_SNAPSHOT_DST"
    printf 'write\nactive\nnone'
  elif [ -f "$PI_THEME_SNAPSHOT_DST" ] && cmp -s "$PI_THEME_DST" "$PI_THEME_SNAPSHOT_DST"; then
    copy_file "$src" "$PI_THEME_DST"
    copy_file "$src" "$PI_THEME_SNAPSHOT_DST"
    copy_file "$SOURCE_DIR/pi/themes/LICENSE" "$PI_THEME_LICENSE_DST"
    copy_file "$SOURCE_DIR/pi/themes/LICENSE" "$PI_THEME_LICENSE_SNAPSHOT_DST"
    printf 'replace\nactive\nnone'
  else
    warn "preserving modified or user-owned Pi theme: $PI_THEME_DST"
    printf 'preserve\npreserved\nnone'
  fi
}

remember_theme_baseline() {
  local prior
  [ "$INSTALL_THEME_ACTION" = preserve ] && [ -f "$PI_THEME_SNAPSHOT_DST" ] || return 0
  prior="$(manifest_action_value themeAction skip)"
  case "$prior" in write|replace) INSTALL_THEME_ACTION="$prior" ;; esac
}

install_settings() { merge_json_file "$TEMPLATES_SRC/settings.base.json" "$PI_SETTINGS_DST" settings settings; }
install_subagents() { merge_json_file "$TEMPLATES_SRC/subagents.base.json" "$PI_SUBAGENTS_DST" subagents subagents; }
safe_magic_context_path() {
  # The CortexKit config is shared across harnesses. Do not follow a symlinked
  # directory or manage a path outside the user's home.
  python3 - "$1" <<'PY'
from pathlib import Path
import sys
home = Path.home().resolve()
path = Path(sys.argv[1])
raise SystemExit(0 if path.is_absolute() and path.resolve().is_relative_to(home) and
                 not any(parent.is_symlink() for parent in path.parents if parent != home) else 1)
PY
}
preflight_magic_context() {
  safe_magic_context_path "$MAGIC_CONTEXT_DST" || die "Magic Context config must be a non-symlinked path under HOME: $MAGIC_CONTEXT_DST"
  [ ! -L "$MAGIC_CONTEXT_DST" ] || die "preserving symlinked Magic Context config: $MAGIC_CONTEXT_DST"
  if [ -e "$MANIFEST_DST" ] || [ -L "$MANIFEST_DST" ]; then
    [ ! -L "$MANIFEST_DST" ] || die "symlinked Pi install manifest: $MANIFEST_DST"
    if ! python3 - "$MANIFEST_DST" <<'PY'
import json, sys
from pathlib import Path
manifest = json.loads(Path(sys.argv[1]).read_text())
raise SystemExit(0 if isinstance(manifest, dict) and manifest.get('runtime') == 'pi' else 1)
PY
    then
      die "unreadable Pi install manifest: $MANIFEST_DST"
    fi
  fi
}
install_magic_context() {
  preflight_magic_context
  merge_json_file "$TEMPLATES_SRC/magic-context.base.json" "$MAGIC_CONTEXT_DST" magic-context magicContext
}
install_mcp() { merge_json_file "$TEMPLATES_SRC/mcp.base.json" "$PI_MCP_DST" mcp mcp; }
install_permission() {
  merge_json_file "$TEMPLATES_SRC/permission.user.template.json" "$PI_PERMISSION_DST" permission permission
}

remember_config_baseline() {
  local key="$1" path="$2" action_var="$3" backup_var="$4" prior_path prior_action
  [ -f "$MANIFEST_DST" ] || return 0
  prior_path="$(manifest_path_value "$key" '')"
  [ "$prior_path" = "$path" ] || return 0
  prior_action="$(manifest_action_value "${key}Action" '')"
  [ -n "$prior_action" ] || return 0
  printf -v "$action_var" '%s' "$prior_action"
  printf -v "$backup_var" '%s' "$(manifest_backup_value "$key" none)"
}

install_packages() {
  local package name listed update_existing=0
  if dry_run_enabled; then
    printf '[dry-run] install missing or update existing Pi extensions in %s\n' "$PI_CONFIG_DIR" >&2
    return 0
  fi
  command -v pi >/dev/null 2>&1 || die 'Pi CLI not on PATH; cannot install extensions'
  listed="$( cd "$PI_CONFIG_DIR" && PI_CODING_AGENT_DIR="$PI_CONFIG_DIR" pi list --no-approve )" \
    || die 'failed to list Pi extensions'
  while IFS= read -r package; do
    [ -n "$package" ] || continue
    name="${package#npm:}"
    # pi list also shows declared packages whose cache has not been installed yet.
    if [ "$package" != "${PRIOR_FAILED_PACKAGE:-}" ] &&
       { printf '%s\n' "$listed" | grep -Fqx "  $package" ||
         printf '%s\n' "$listed" | grep -Fqx "  $package (filtered)"; } &&
       [ -d "$PI_CONFIG_DIR/npm/node_modules/$name" ]; then
      update_existing=1
      continue
    fi
    # Record the attempted package before Pi touches its cache so an interrupted
    # install cannot be mistaken for a complete installation on the next run.
    env MANIFEST_DST="$MANIFEST_DST" FAILED_PACKAGE="$package" python3 - <<'PY'
import json, os
from pathlib import Path
path = Path(os.environ['MANIFEST_DST'])
data = json.loads(path.read_text())
data['packageState'] = 'partial'
data['failedPackage'] = os.environ['FAILED_PACKAGE']
path.write_text(json.dumps(data, indent=2) + '\n')
PY
    ( cd "$PI_CONFIG_DIR" && PI_CODING_AGENT_DIR="$PI_CONFIG_DIR" pi install "$package" --no-approve ) \
      || die "failed to install $package"
  done < <(python3 - "$TEMPLATES_SRC/settings.base.json" <<'PY'
import json, sys
for package in json.load(open(sys.argv[1]))['packages']:
    print(package)
PY
)
  if [ "$update_existing" -eq 1 ]; then
    ( cd "$PI_CONFIG_DIR" && PI_CODING_AGENT_DIR="$PI_CONFIG_DIR" pi update --extensions --no-approve ) \
      || die 'Pi extension update failed'
  fi
}

runtime_install_configs() {
  run_install_triplet_stage 'Syncing Pi specialists' install_agents skip none none \
    INSTALL_AGENTS_ACTION INSTALL_AGENTS_STATE INSTALL_AGENTS_BACKUP
  run_install_triplet_stage 'Syncing Pi prompts' install_commands skip none none \
    INSTALL_COMMANDS_ACTION INSTALL_COMMANDS_STATE INSTALL_COMMANDS_BACKUP
  run_install_triplet_stage 'Installing Dracula theme' install_theme skip none none \
    INSTALL_THEME_ACTION INSTALL_THEME_STATE INSTALL_THEME_BACKUP
  remember_theme_baseline
  run_install_triplet_stage 'Merging Pi settings' install_settings skip none none \
    INSTALL_SETTINGS_ACTION INSTALL_SETTINGS_STATE INSTALL_SETTINGS_BACKUP
  remember_config_baseline settings "$PI_SETTINGS_DST" INSTALL_SETTINGS_ACTION INSTALL_SETTINGS_BACKUP
  run_install_triplet_stage 'Configuring Pi specialists' install_subagents skip none none \
    INSTALL_SUBAGENTS_ACTION INSTALL_SUBAGENTS_STATE INSTALL_SUBAGENTS_BACKUP
  remember_config_baseline subagents "$PI_SUBAGENTS_DST" INSTALL_SUBAGENTS_ACTION INSTALL_SUBAGENTS_BACKUP
  if ! dry_run_enabled && env SOURCE_DIR="$SOURCE_DIR" PI_SETTINGS_DST="$PI_SETTINGS_DST" python3 - <<'PY'
import os, sys
from pathlib import Path
sys.path.insert(0, str(Path(os.environ['SOURCE_DIR']) / 'tooling' / 'install'))
from jsonc import loads
settings = loads(Path(os.environ['PI_SETTINGS_DST']).read_text())
raise SystemExit(0 if settings.get('compaction', {}).get('enabled') is True else 1)
PY
  then
    warn 'Pi native compaction remains enabled in user settings; disable it to let Magic Context manage context.'
  fi
  run_install_triplet_stage 'Merging Pi MCP servers' install_mcp skip none none \
    INSTALL_MCP_ACTION INSTALL_MCP_STATE INSTALL_MCP_BACKUP
  remember_config_baseline mcp "$PI_MCP_DST" INSTALL_MCP_ACTION INSTALL_MCP_BACKUP
  run_install_triplet_stage 'Merging Pi permission policy' install_permission skip none none \
    INSTALL_PERMISSION_ACTION INSTALL_PERMISSION_STATE INSTALL_PERMISSION_BACKUP
  remember_config_baseline permission "$PI_PERMISSION_DST" INSTALL_PERMISSION_ACTION INSTALL_PERMISSION_BACKUP
  # Keep this shared config last: later config merge failures must not leave it
  # changed before the ownership manifest is written.
  run_install_triplet_stage 'Configuring Magic Context' install_magic_context skip none none \
    INSTALL_MAGIC_CONTEXT_ACTION INSTALL_MAGIC_CONTEXT_STATE INSTALL_MAGIC_CONTEXT_BACKUP
  MAGIC_CONTEXT_STAGE_BACKUP="$INSTALL_MAGIC_CONTEXT_BACKUP"
  MAGIC_CONTEXT_STAGE_ACTION="$INSTALL_MAGIC_CONTEXT_ACTION"
  remember_config_baseline magicContext "$MAGIC_CONTEXT_DST" INSTALL_MAGIC_CONTEXT_ACTION INSTALL_MAGIC_CONTEXT_BACKUP
}

runtime_finish_packages() {
  run_stage 'Reconciling Pi extensions' install_packages
  if ! dry_run_enabled; then
    env MANIFEST_DST="$MANIFEST_DST" python3 - <<'PY'
import json, os
from pathlib import Path
path = Path(os.environ['MANIFEST_DST'])
data = json.loads(path.read_text())
data['packageState'] = 'ready'
data.pop('failedPackage', None)
path.write_text(json.dumps(data, indent=2) + '\n')
PY
  fi
}

remember_kernel_baseline() {
  local prior prior_action
  prior="$(manifest_backup_value kernel none)"
  if [ "$prior" != none ]; then
    if [ "$INSTALL_MEMORY_BACKUP" = none ]; then
      INSTALL_MEMORY_BACKUP="$prior"
    fi
    INSTALL_MEMORY_ACTION=replace
  else
    prior_action="$(manifest_action_value kernelAction '')"
    if [ "$prior_action" = write ] && [ "$INSTALL_MEMORY_BACKUP" = none ]; then
      INSTALL_MEMORY_ACTION='write'
      INSTALL_MEMORY_BACKUP=none
    fi
  fi
}

runtime_write_manifest() {
  if dry_run_enabled; then
    printf '[dry-run] write manifest %s\n' "$MANIFEST_DST" >&2
    return 0
  fi
  ensure_dir "$METADATA_DIR"
  env MANIFEST_DST="$MANIFEST_DST" TIMESTAMP="$TIMESTAMP" PI_CONFIG_DIR="$PI_CONFIG_DIR" \
    PI_SETTINGS_DST="$PI_SETTINGS_DST" PI_SUBAGENTS_DST="$PI_SUBAGENTS_DST" PI_MCP_DST="$PI_MCP_DST" PI_PERMISSION_DST="$PI_PERMISSION_DST" \
    MAGIC_CONTEXT_DST="$MAGIC_CONTEXT_DST" MAGIC_CONTEXT_ACTION="$INSTALL_MAGIC_CONTEXT_ACTION" \
    MAGIC_CONTEXT_BACKUP="$INSTALL_MAGIC_CONTEXT_BACKUP" \
    AGENTS_DST="$AGENTS_DST" COMMANDS_DST="$COMMANDS_DST" SKILLS_DST="$SKILLS_DST" \
    REFERENCES_DST="$REFERENCES_DST" TEMPLATES_DST="$TEMPLATES_DST" KERNEL_DST="$KERNEL_DST" \
    KERNEL_ACTION="$INSTALL_MEMORY_ACTION" KERNEL_BACKUP="$INSTALL_MEMORY_BACKUP" \
    SETTINGS_ACTION="$INSTALL_SETTINGS_ACTION" SETTINGS_BACKUP="$INSTALL_SETTINGS_BACKUP" \
    SUBAGENTS_ACTION="$INSTALL_SUBAGENTS_ACTION" SUBAGENTS_BACKUP="$INSTALL_SUBAGENTS_BACKUP" \
    MCP_ACTION="$INSTALL_MCP_ACTION" MCP_BACKUP="$INSTALL_MCP_BACKUP" \
    PERMISSION_ACTION="$INSTALL_PERMISSION_ACTION" PERMISSION_BACKUP="$INSTALL_PERMISSION_BACKUP" \
    AGENTS_ACTION="$INSTALL_AGENTS_ACTION" COMMANDS_ACTION="$INSTALL_COMMANDS_ACTION" \
    THEME_ACTION="$INSTALL_THEME_ACTION" \
    SKILLS="${INSTALL_SKILL_NAMES[*]}" AGENTS="${AGENT_NAMES[*]}" python3 - <<'PY'
import json, os
from pathlib import Path
root = Path(os.environ['COMMANDS_DST'])
manifest_path = Path(os.environ['MANIFEST_DST'])
previous = json.loads(manifest_path.read_text()) if manifest_path.is_file() else {}
prior_backups = previous.get('kernelPriorBackups', [])
if not isinstance(prior_backups, list):
    prior_backups = []
old_backup = previous.get('backups', {}).get('kernel', 'none')
new_backup = os.environ['KERNEL_BACKUP']
if old_backup not in ('none', new_backup) and old_backup not in prior_backups:
    prior_backups.append(old_backup)
manifest = {
    'suite': 'b-agentic', 'runtime': 'pi', 'installedAt': os.environ['TIMESTAMP'],
    'activationState': 'active', 'packageState': 'pending',
    'kernelAction': os.environ['KERNEL_ACTION'],
    'kernelPriorBackups': prior_backups,
    'agentsAction': os.environ['AGENTS_ACTION'], 'commandsAction': os.environ['COMMANDS_ACTION'],
    'themeAction': os.environ['THEME_ACTION'],
    'settingsAction': os.environ['SETTINGS_ACTION'], 'subagentsAction': os.environ['SUBAGENTS_ACTION'],
    'mcpAction': os.environ['MCP_ACTION'],
    'magicContextAction': os.environ['MAGIC_CONTEXT_ACTION'],
    'permissionAction': os.environ['PERMISSION_ACTION'],
    'paths': {
        'piConfigDir': os.environ['PI_CONFIG_DIR'], 'settings': os.environ['PI_SETTINGS_DST'],
        'subagents': os.environ['PI_SUBAGENTS_DST'],
        'mcp': os.environ['PI_MCP_DST'], 'permission': os.environ['PI_PERMISSION_DST'],
        'magicContext': os.environ['MAGIC_CONTEXT_DST'],
        'agents': os.environ['AGENTS_DST'], 'commands': os.environ['COMMANDS_DST'],
        'kernel': os.environ['KERNEL_DST'], 'skills': os.environ['SKILLS_DST'],
        'references': os.environ['REFERENCES_DST'],
        'capabilityContract': str(Path(os.environ['REFERENCES_DST']) / 'capabilities.yaml'),
        'templates': os.environ['TEMPLATES_DST'],
    },
    'skills': os.environ['SKILLS'].split(), 'agents': os.environ['AGENTS'].split(),
    'commands': [p.stem for p in sorted(root.glob('b-*.md'))
                 if p.name in {f'{name}.md' for name in os.environ['SKILLS'].split()}],
    'backups': {
        'kernel': os.environ['KERNEL_BACKUP'],
        'settings': os.environ['SETTINGS_BACKUP'], 'subagents': os.environ['SUBAGENTS_BACKUP'],
        'mcp': os.environ['MCP_BACKUP'],
        'magicContext': os.environ['MAGIC_CONTEXT_BACKUP'],
        'permission': os.environ['PERMISSION_BACKUP'],
    },
}
if previous.get('packageState') == 'partial' and previous.get('failedPackage'):
    manifest['packageState'] = 'partial'
    manifest['failedPackage'] = previous['failedPackage']
import tempfile
with tempfile.NamedTemporaryFile(mode='w', dir=manifest_path.parent, prefix='.install-', delete=False) as temp:
    temp.write(json.dumps(manifest, indent=2) + '\n')
try:
    os.replace(temp.name, manifest_path)
finally:
    if os.path.exists(temp.name):
        os.unlink(temp.name)
PY
}

rollback_magic_context() {
  # A manifest-write failure must not leave shared config without ownership.
  if dry_run_enabled; then return 0; fi
  if [ -f "${MAGIC_CONTEXT_STAGE_BACKUP:-}" ]; then
    cp "$MAGIC_CONTEXT_STAGE_BACKUP" "$MAGIC_CONTEXT_DST"
  elif [ "${MAGIC_CONTEXT_STAGE_ACTION:-}" = write ]; then
    rm -f "$MAGIC_CONTEXT_DST"
  else
    warn "cannot restore Magic Context config after manifest failure: $MAGIC_CONTEXT_DST"
  fi
}

runtime_print_install_report() {
  success 'b-agentic install complete for Pi'
  installer_summary_log "Installed: ${#INSTALL_SKILL_NAMES[@]} skills, four specialists, Dracula theme, seven unpinned extensions."
  installer_summary_log "Manifest: $MANIFEST_DST"
  step 'Next steps:'
  installer_summary_log '  - Start a new Pi session and invoke /b-plan or another explicit /b-* prompt.'
}

remove_managed_profiles() {
  local root="$1" snapshots="$2" key="$3" label="$4" name path snapshot
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! managed_asset_name_is_safe "$name"; then
      warn "preserving $label with unsafe manifest name"; PRESERVE_METADATA_DIR=1; continue
    fi
    path="$root/$name.md"; snapshot="$snapshots/$name.md"
    if [ -L "$path" ]; then
      warn "preserving symlinked $label: $path"; PRESERVE_METADATA_DIR=1
    elif [ -f "$path" ] && [ -f "$snapshot" ] && cmp -s "$path" "$snapshot"; then
      run_cmd rm -f "$path"
    elif [ -e "$path" ]; then
      warn "preserving modified $label: $path"; PRESERVE_METADATA_DIR=1
    fi
  done < <(manifest_array_values "$key")
}

remove_managed_theme() {
  case "$(manifest_action_value themeAction skip)" in write|replace) ;; *) return 0 ;; esac
  if [ -L "$PI_THEME_LICENSE_DST" ] || [ -L "$PI_THEME_LICENSE_SNAPSHOT_DST" ] ||
     { [ -e "$PI_THEME_LICENSE_DST" ] &&
       { [ ! -f "$PI_THEME_LICENSE_SNAPSHOT_DST" ] || ! cmp -s "$PI_THEME_LICENSE_DST" "$PI_THEME_LICENSE_SNAPSHOT_DST"; }; }; then
    warn "preserving modified Pi theme license: $PI_THEME_LICENSE_DST"
    PRESERVE_METADATA_DIR=1
  fi
  if [ -L "$(dirname "$PI_THEME_DST")" ] || [ -L "$PI_THEME_DST" ]; then
    warn "preserving symlinked Pi theme: $PI_THEME_DST"
    PRESERVE_METADATA_DIR=1
  elif [ -f "$PI_THEME_DST" ] && [ -f "$PI_THEME_SNAPSHOT_DST" ] && [ ! -L "$PI_THEME_SNAPSHOT_DST" ] && cmp -s "$PI_THEME_DST" "$PI_THEME_SNAPSHOT_DST"; then
    run_cmd rm -f "$PI_THEME_DST"
  elif [ -e "$PI_THEME_DST" ]; then
    warn "preserving modified Pi theme: $PI_THEME_DST"
    PRESERVE_METADATA_DIR=1
  fi
}

runtime_uninstall_configs() {
  remove_managed_theme
  remove_managed_profiles "$AGENTS_DST" "$AGENTS_SNAPSHOT_DST" agents 'Pi specialist'
  remove_managed_profiles "$COMMANDS_DST" "$COMMANDS_SNAPSHOT_DST" commands 'Pi prompt'
  if remove_managed_packages; then
    remove_merged_config "$PI_SETTINGS_DST" "$TEMPLATES_DST/settings.base.json" settings settings settingsAction
  else
    PRESERVE_METADATA_DIR=1
  fi
  if [ "$(manifest_action_value subagentsAction '')" != '' ]; then
    remove_merged_config "$PI_SUBAGENTS_DST" "$TEMPLATES_DST/subagents.base.json" subagents subagents subagentsAction
  fi
  if [ "$(manifest_action_value magicContextAction '')" != '' ]; then
    local magic_path
    magic_path="$(manifest_path_value magicContext "$MAGIC_CONTEXT_DST")"
    if safe_magic_context_path "$magic_path"; then
      remove_merged_config "$magic_path" \
        "$TEMPLATES_DST/magic-context.base.json" magic-context magicContext magicContextAction
    else
      warn "preserving unsafe Magic Context config path: $magic_path"
      PRESERVE_METADATA_DIR=1
    fi
  fi
  remove_merged_config "$PI_MCP_DST" "$TEMPLATES_DST/mcp.base.json" mcp mcp mcpAction
  remove_merged_config "$PI_PERMISSION_DST" "$TEMPLATES_DST/permission.user.template.json" permission permission permissionAction
}

remove_managed_packages() {
  local original package packages
  [ -f "$PI_SETTINGS_DST" ] || return 0
  [ ! -L "$PI_SETTINGS_DST" ] || return 0
  [ -f "$TEMPLATES_DST/settings.base.json" ] || return 0
  original="$(manifest_backup_value settings none)"
  if [ "$original" != none ] && [ ! -f "$original" ]; then
    warn 'preserving package cache: original settings backup is missing'
    return 1
  fi
  if ! packages="$(python3 - "$PI_SETTINGS_DST" "$TEMPLATES_DST/settings.base.json" "$original" "$SOURCE_DIR" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[4]) / 'tooling' / 'install'))
from jsonc import loads
try:
    current = loads(Path(sys.argv[1]).read_text()).get('packages', [])
    managed = json.loads(Path(sys.argv[2]).read_text())['packages']
    original = loads(Path(sys.argv[3]).read_text()).get('packages', []) if sys.argv[3] != 'none' else []
    for package in managed:
        if package in current and package not in original:
            print(package)
except (OSError, ValueError, AttributeError, TypeError):
    raise SystemExit('cannot establish package ownership from settings')
PY
)"; then
    warn 'preserving package cache: package ownership is uncertain'
    return 1
  fi
  [ -n "$packages" ] || return 0
  if ! dry_run_enabled && ! command -v pi >/dev/null 2>&1; then
    warn 'Pi CLI unavailable; managed package cache remains on disk'
    return 1
  fi
  local failed=0
  while IFS= read -r package; do
    [ -n "$package" ] || continue
    if dry_run_enabled; then
      printf '[dry-run] pi remove %s\n' "$package" >&2
    else
      ( cd "$PI_CONFIG_DIR" && PI_CODING_AGENT_DIR="$PI_CONFIG_DIR" pi remove "$package" --no-approve ) \
        || { warn "could not remove $package"; failed=1; }
    fi
  done <<<"$packages"
  return "$failed"
}

require_existing_config_path() {
  local key expected existing
  [ -f "$MANIFEST_DST" ] || return 0
  for key in settings subagents mcp permission magicContext; do
    case "$key" in
      settings) expected="$PI_SETTINGS_DST" ;;
      subagents) expected="$PI_SUBAGENTS_DST" ;;
      mcp) expected="$PI_MCP_DST" ;;
      permission) expected="$PI_PERMISSION_DST" ;;
      magicContext) expected="$MAGIC_CONTEXT_DST" ;;
    esac
    existing="$(manifest_path_value "$key" '')"
    [ -z "$existing" ] || [ "$existing" = "$expected" ] || die "Pi $key path changed; uninstall the existing installation first"
  done
}

pi_install() { require_existing_config_path; preflight_magic_context; runtime_install_common; }
pi_sync() { require_existing_config_path; preflight_magic_context; runtime_sync_common; }
pi_update() {
  runtime_upgrade_cli
  command -v pi >/dev/null 2>&1 || die 'Pi CLI not on PATH'
  if dry_run_enabled; then
    printf '[dry-run] pi update --extensions\n' >&2
  else
    ( cd "$PI_CONFIG_DIR" && PI_CODING_AGENT_DIR="$PI_CONFIG_DIR" pi update --extensions --no-approve ) \
      || die 'Pi extension update failed'
  fi
  log 'b-agentic update complete for Pi.'
}
pi_uninstall() { runtime_uninstall_common; }
