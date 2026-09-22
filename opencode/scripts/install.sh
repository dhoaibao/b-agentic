# Sourced by install.sh — do not run directly.
# shellcheck shell=bash
# shellcheck disable=SC2034 # Variables are consumed by shared sourced installer helpers.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by install.sh" >&2
  exit 1
fi

RUNTIME_NAME="OpenCode"
RUNTIME_UNINSTALL_LABEL="OpenCode personal config"
RUNTIME_PRESERVE_LABEL="OpenCode"
OPENCODE_CONFIG_DIR="${B_AGENTIC_OPENCODE_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}"
METADATA_DIR="$OPENCODE_CONFIG_DIR/b-agentic"
BACKUPS_DIR="$METADATA_DIR/backups"
SKILLS_DST="$OPENCODE_CONFIG_DIR/skills"
SKILLS_SNAPSHOT_DST="$METADATA_DIR/skills"
AGENTS_DST="$OPENCODE_CONFIG_DIR/agents"
AGENTS_SNAPSHOT_DST="$METADATA_DIR/agents"
COMMANDS_DST="$OPENCODE_CONFIG_DIR/commands"
COMMANDS_SNAPSHOT_DST="$METADATA_DIR/commands"
KERNEL_DST="$OPENCODE_CONFIG_DIR/AGENTS.md"
KERNEL_SNAPSHOT_DST="$METADATA_DIR/AGENTS.md"
REFERENCES_DST="$METADATA_DIR/references"
CAPABILITIES_SRC="$SOURCE_DIR/references/capabilities.yaml"
TEMPLATES_DST="$METADATA_DIR/templates"
MANIFEST_DST="$METADATA_DIR/install.json"
if [ -z "${B_AGENTIC_OPENCODE_CONFIG:-}" ] && [ ! -e "$OPENCODE_CONFIG_DIR/opencode.json" ] && [ -e "$OPENCODE_CONFIG_DIR/opencode.jsonc" ]; then
  OPENCODE_CONFIG_DST="$OPENCODE_CONFIG_DIR/opencode.jsonc"
else
  OPENCODE_CONFIG_DST="${B_AGENTIC_OPENCODE_CONFIG:-$OPENCODE_CONFIG_DIR/opencode.json}"
fi
OPENCODE_TEMPLATE_SRC="$SOURCE_DIR/opencode/configs/opencode.user.template.json"
AGENT_NAMES=(b-planner b-researcher b-debugger b-reviewer)
INSTALL_AGENTS_ACTION="skip"
INSTALL_AGENTS_STATE="none"
INSTALL_COMMANDS_ACTION="skip"
INSTALL_COMMANDS_STATE="none"
INSTALL_CONFIG_ACTION="skip"
INSTALL_CONFIG_STATE="none"
INSTALL_CONFIG_BACKUP="none"
PRESERVE_METADATA_DIR=0
OPENCODE_CLI_INSTALL_STATUS="not-run"
INSTALL_MISSING_TOOLS=()

runtime_upgrade_cli() {
  if command -v opencode >/dev/null 2>&1; then
    if dry_run_enabled; then
      OPENCODE_CLI_INSTALL_STATUS="planned"
      printf '[dry-run] opencode upgrade\n' >&2
      return 0
    fi
    log "Upgrading OpenCode CLI with 'opencode upgrade'"
    if opencode upgrade; then
      OPENCODE_CLI_INSTALL_STATUS="installed"
    else
      OPENCODE_CLI_INSTALL_STATUS="failed"
      warn "OpenCode CLI upgrade failed; upgrade it manually, then rerun with --update"
    fi
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    OPENCODE_CLI_INSTALL_STATUS="skipped"
    warn "curl is required to install the current OpenCode CLI; skipping OpenCode installation"
    return 0
  fi
  if dry_run_enabled; then
    OPENCODE_CLI_INSTALL_STATUS="planned"
    printf '[dry-run] curl -fsSL https://opencode.ai/v2/install | bash\n' >&2
    return 0
  fi
  log "Installing current OpenCode CLI with the OpenCode installer"
  if curl -fsSL https://opencode.ai/v2/install | bash; then
    OPENCODE_CLI_INSTALL_STATUS="installed"
    if ! command -v opencode >/dev/null 2>&1; then
      OPENCODE_CLI_INSTALL_STATUS="installed-not-on-path"
      warn "OpenCode CLI installed but 'opencode' is not on PATH; add its install directory to your shell profile."
    fi
  else
    OPENCODE_CLI_INSTALL_STATUS="failed"
    warn "OpenCode CLI installation failed; install it manually, then rerun with --update"
  fi
  return 0
}

managed_file_set() {
  local source_root="$1" destination_root="$2" snapshot_root="$3" marker="$4" label="$5"
  local src name dst snapshot action="skip" state="active"
  for src in "$source_root"/*.md; do
    [ -f "$src" ] || continue
    name="$(basename "$src")"
    dst="$destination_root/$name"
    snapshot="$snapshot_root/$name"
    if dry_run_enabled; then
      printf '[dry-run] install %s %s -> %s\n' "$label" "$src" "$dst" >&2
      [ "$action" = "preserve" ] || action="write"
      continue
    fi
    ensure_dir "$destination_root"
    ensure_dir "$snapshot_root"
    if [ -L "$dst" ]; then
      warn "preserving symlinked $label: $dst"
      action="preserve"
      state="preserved"
    elif [ ! -e "$dst" ]; then
      copy_file "$src" "$dst"
      copy_file "$src" "$snapshot"
      [ "$action" = "preserve" ] || action="write"
    elif cmp -s "$src" "$dst"; then
      copy_file "$src" "$snapshot"
    elif [ -f "$snapshot" ] && cmp -s "$dst" "$snapshot"; then
      copy_file "$src" "$dst"
      copy_file "$src" "$snapshot"
      [ "$action" = "preserve" ] || action="replace"
    elif grep -Fq "$marker" "$dst" 2>/dev/null; then
      warn "preserving modified $label: $dst"
      action="preserve"
      state="preserved"
    else
      warn "preserving user-owned $label: $dst"
      action="preserve"
      state="preserved"
    fi
  done
  printf '%s\n%s\nnone' "$action" "$state"
}

install_agents() {
  managed_file_set "$SOURCE_DIR/opencode/agents" "$AGENTS_DST" "$AGENTS_SNAPSHOT_DST" \
    "Managed by b-agentic" "OpenCode subagent"
}

install_commands() {
  managed_file_set "$SOURCE_DIR/opencode/commands" "$COMMANDS_DST" "$COMMANDS_SNAPSHOT_DST" \
    "Generated from skills/registry.yaml" "OpenCode command"
}

install_opencode_config() {
  if [ ! -f "$OPENCODE_TEMPLATE_SRC" ]; then
    die "missing OpenCode configuration template: $OPENCODE_TEMPLATE_SRC"
  fi
  merge_json_file "$OPENCODE_TEMPLATE_SRC" "$OPENCODE_CONFIG_DST" "opencode" "opencodeConfig"
}

runtime_install_configs() {
  run_install_triplet_stage "Installing OpenCode subagents" install_agents "skip" "none" "none" \
    INSTALL_AGENTS_ACTION INSTALL_AGENTS_STATE _unused_agents_backup || return $?
  run_install_triplet_stage "Installing OpenCode commands" install_commands "skip" "none" "none" \
    INSTALL_COMMANDS_ACTION INSTALL_COMMANDS_STATE _unused_commands_backup || return $?
  run_install_triplet_stage "Merging OpenCode config" install_opencode_config "skip" "none" "none" \
    INSTALL_CONFIG_ACTION INSTALL_CONFIG_STATE INSTALL_CONFIG_BACKUP || return $?
}

runtime_write_manifest() {
  local skills_string="${INSTALL_SKILL_NAMES[*]}"
  local agents_string="${AGENT_NAMES[*]}"
  local commands_string
  commands_string="$(cd "$SOURCE_DIR/opencode/commands" && printf '%s ' b-*.md)"

  if dry_run_enabled; then
    printf '[dry-run] write manifest %s\n' "$MANIFEST_DST" >&2
    return 0
  fi
  ensure_dir "$METADATA_DIR"
  local source_commit="" source_ref=""
  if [ -d "$SOURCE_DIR/.git" ]; then
    source_commit="$(git -C "$SOURCE_DIR" rev-parse HEAD 2>/dev/null || printf '')"
    source_ref="$(git -C "$SOURCE_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '')"
  fi
  env \
    MANIFEST_DST="$MANIFEST_DST" TIMESTAMP="$TIMESTAMP" SOURCE_COMMIT="$source_commit" SOURCE_REF="$source_ref" \
    OPENCODE_CONFIG_DIR="$OPENCODE_CONFIG_DIR" OPENCODE_CONFIG_DST="$OPENCODE_CONFIG_DST" \
    AGENTS_DST="$AGENTS_DST" COMMANDS_DST="$COMMANDS_DST" SKILLS_DST="$SKILLS_DST" \
    REFERENCES_DST="$REFERENCES_DST" TEMPLATES_DST="$TEMPLATES_DST" KERNEL_DST="$KERNEL_DST" \
    CONFIG_ACTION="$INSTALL_CONFIG_ACTION" CONFIG_STATE="$INSTALL_CONFIG_STATE" CONFIG_BACKUP="$INSTALL_CONFIG_BACKUP" \
    AGENTS_ACTION="$INSTALL_AGENTS_ACTION" AGENTS_STATE="$INSTALL_AGENTS_STATE" \
    COMMANDS_ACTION="$INSTALL_COMMANDS_ACTION" COMMANDS_STATE="$INSTALL_COMMANDS_STATE" \
    SKILLS="$skills_string" AGENTS="$agents_string" COMMANDS="$commands_string" \
    python3 - <<'PY'
import json
import os
from pathlib import Path

items = lambda name: [item for item in os.environ.get(name, '').split() if item]
manifest = {
    'suite': 'b-agentic',
    'runtime': 'opencode',
    'installedAt': os.environ['TIMESTAMP'],
    'sourceCommit': os.environ.get('SOURCE_COMMIT', ''),
    'sourceRef': os.environ.get('SOURCE_REF', ''),
    'activationState': 'active',
    'mcpAction': os.environ['CONFIG_ACTION'],
    'mcpState': os.environ['CONFIG_STATE'],
    'agentsAction': os.environ['AGENTS_ACTION'],
    'agentsState': os.environ['AGENTS_STATE'],
    'commandsAction': os.environ['COMMANDS_ACTION'],
    'commandsState': os.environ['COMMANDS_STATE'],
    'opencodeConfigAction': os.environ['CONFIG_ACTION'],
    'paths': {
        'opencodeConfigDir': os.environ['OPENCODE_CONFIG_DIR'],
        'opencodeConfig': os.environ['OPENCODE_CONFIG_DST'],
        'agents': os.environ['AGENTS_DST'],
        'commands': os.environ['COMMANDS_DST'],
        'kernel': os.environ['KERNEL_DST'],
        'skills': os.environ['SKILLS_DST'],
        'references': os.environ['REFERENCES_DST'],
        'capabilityContract': str(Path(os.environ['REFERENCES_DST']) / 'capabilities.yaml'),
        'templates': os.environ['TEMPLATES_DST'],
    },
    'skills': items('SKILLS'),
    'agents': items('AGENTS'),
    'commands': [Path(item).stem for item in items('COMMANDS')],
    'backups': {'opencodeConfig': os.environ['CONFIG_BACKUP']},
}
Path(os.environ['MANIFEST_DST']).write_text(json.dumps(manifest, indent=2) + '\n')
PY
}

runtime_print_install_report() {
  local summary_label="Installed"
  dry_run_enabled && summary_label="Planned"
  success "b-agentic install complete for OpenCode"
  installer_summary_log "$summary_label: ${#INSTALL_SKILL_NAMES[@]} skills; agents $INSTALL_AGENTS_ACTION; config $INSTALL_CONFIG_ACTION"
  if dry_run_enabled; then
    installer_summary_log "Manifest: not written (dry-run)"
  else
    installer_summary_log "Manifest: $MANIFEST_DST"
  fi
  step 'Next steps:'
  installer_summary_log "  - Start a new OpenCode session; use /b-plan, /b-research, /b-debug, or /b-review for explicit specialist routing."
  if [ "$OPENCODE_CLI_INSTALL_STATUS" = "installed-not-on-path" ]; then
    installer_summary_log "  - Add the OpenCode CLI install directory to your shell profile, then restart your shell."
  fi
  if [ "${#INSTALL_MISSING_TOOLS[@]}" -gt 0 ]; then
    installer_summary_log "  - Optional tools not found: ${INSTALL_MISSING_TOOLS[*]}. Install them to enable the affected workflows."
  fi
}

manifest_agent_names() {
  manifest_array_values agents || printf '%s\n' "${AGENT_NAMES[@]}"
}

remove_managed_profiles() {
  local root="$1" snapshot_root="$2" manifest_key="$3" label="$4" name path snapshot
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! managed_asset_name_is_safe "$name"; then
      warn "preserving $label with unsafe manifest name"
      PRESERVE_METADATA_DIR=1
      continue
    fi
    path="$root/$name.md"
    snapshot="$snapshot_root/$name.md"
    if [ -L "$path" ]; then
      warn "preserving symlinked $label: $path"
      PRESERVE_METADATA_DIR=1
    elif [ -f "$path" ] && [ -f "$snapshot" ] && cmp -s "$path" "$snapshot"; then
      run_cmd rm -f "$path"
    elif [ -e "$path" ]; then
      warn "preserving modified $label: $path"
      PRESERVE_METADATA_DIR=1
    fi
  done < <(manifest_array_values "$manifest_key")
}

runtime_uninstall_configs() {
  local config_path
  remove_managed_profiles "$AGENTS_DST" "$AGENTS_SNAPSHOT_DST" agents "OpenCode subagent"
  remove_managed_profiles "$COMMANDS_DST" "$COMMANDS_SNAPSHOT_DST" commands "OpenCode command"
  config_path="$(manifest_path_value opencodeConfig "$OPENCODE_CONFIG_DST")"
  remove_merged_config "$config_path" "$TEMPLATES_DST/opencode.user.template.json" "opencode.json" "opencodeConfig" "opencodeConfigAction"
}

opencode_install() { runtime_install_common; }
opencode_sync() { runtime_sync_common; }
opencode_update() {
  runtime_upgrade_cli
  case "$OPENCODE_CLI_INSTALL_STATUS" in
    skipped) log 'b-agentic update skipped: curl unavailable.' ;;
    failed) log 'b-agentic update skipped: OpenCode CLI upgrade failed.' ;;
    planned) log 'b-agentic update planned: upgrade not run in dry-run.' ;;
    *) log 'b-agentic update complete for OpenCode.' ;;
  esac
}
opencode_uninstall() { runtime_uninstall_common; }
