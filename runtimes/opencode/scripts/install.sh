# Sourced by install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by install.sh" >&2
  exit 1
fi

readonly RUNTIME_UNINSTALL_LABEL="OpenCode personal config"
readonly RUNTIME_PRESERVE_LABEL="OpenCode"
readonly OPENCODE_DIR="${B_AGENTIC_OPENCODE_DIR:-$HOME/.config/opencode}"
readonly METADATA_DIR="$OPENCODE_DIR/b-agentic"
readonly BACKUPS_DIR="$METADATA_DIR/backups"
readonly SKILLS_DST="${B_AGENTIC_SKILLS_DST:-$HOME/.config/opencode/skills}"
readonly COMMANDS_SRC="$SOURCE_DIR/runtimes/$RUNTIME/commands"
readonly COMMANDS_DST="${B_AGENTIC_OPENCODE_COMMANDS_DIR:-$HOME/.config/opencode/commands}"
readonly COMMANDS_SNAPSHOT_DST="$METADATA_DIR/commands"
readonly KERNEL_DST="$OPENCODE_DIR/AGENTS.md"
readonly KERNEL_SNAPSHOT_DST="$METADATA_DIR/AGENTS.md"
readonly REFERENCES_DST="$METADATA_DIR/references"
readonly TEMPLATES_DST="$METADATA_DIR/templates"
readonly MANIFEST_DST="$METADATA_DIR/install.json"
readonly OPENCODE_JSON_DST="${B_AGENTIC_OPENCODE_JSON:-$HOME/.config/opencode/opencode.json}"
readonly MCP_CONFIG_DST="$OPENCODE_JSON_DST"
readonly MCP_ROOT_KEY="mcp"
readonly MCP_PLACEHOLDER_STYLE="opencode"
readonly MCP_CONTEXT7_SECTION="headers"
readonly MCP_BRAVE_SECTION="environment"
readonly MCP_FIRECRAWL_SECTION="environment"
readonly MCP_BACKUP_KEY="opencodeJson"

CONTEXT7_API_KEY_INPUT=""
BRAVE_API_KEY_INPUT=""
FIRECRAWL_API_KEY_INPUT=""
FIRECRAWL_API_URL_INPUT=""

runtime_warn_missing_cli() {
  command -v codegraph >/dev/null 2>&1 || warn "codegraph CLI not found; CodeGraph MCP will not start until CodeGraph is installed."
}

runtime_upgrade_cli() {
  if command -v opencode >/dev/null 2>&1; then
    log "OpenCode CLI already installed; upgrading"
    if run_cmd opencode upgrade; then
      log "OpenCode CLI upgraded"
    else
      warn "OpenCode CLI upgrade failed; continuing with existing CLI"
    fi
    return 0
  fi

  log "OpenCode CLI not found; installing"
  if dry_run_enabled; then
    printf '[dry-run] curl -fsSL https://opencode.ai/install | bash\n' >&2
  elif curl -fsSL https://opencode.ai/install | bash; then
    log "OpenCode CLI installed"
  else
    warn "OpenCode CLI install failed; files will still be installed for OpenCode to discover later"
  fi
}

runtime_install_config_stage_count() {
  printf '2'
}

command_names() {
  python3 - "$COMMANDS_SRC" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
for path in sorted(root.glob('*.md')):
    print(path.stem)
PY
}

command_name_is_current() {
  local target="$1" name
  while IFS= read -r name; do
    [ "$name" = "$target" ] && return 0
  done < <(command_names)
  return 1
}

command_skill_was_installed() {
  local target="$1" name
  for name in "${INSTALL_SKILL_NAMES[@]}"; do
    [ "$name" = "$target" ] && return 0
  done
  return 1
}

prune_stale_commands() {
  [ -f "$MANIFEST_DST" ] || return 0

  local name command_path command_snapshot
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! managed_asset_name_is_safe "$name"; then
      warn "preserving stale OpenCode command with unsafe manifest name"
      continue
    fi
    command_name_is_current "$name" && continue

    command_path="$COMMANDS_DST/$name.md"
    command_snapshot="$COMMANDS_SNAPSHOT_DST/$name.md"
    [ -f "$command_path" ] || continue

    if [ -f "$command_snapshot" ] && cmp -s "$command_path" "$command_snapshot"; then
      run_cmd rm -f "$command_path"
    else
      warn "preserving stale OpenCode command wrapper without matching managed snapshot: $command_path"
    fi
  done < <(manifest_array_values commands)
}

install_commands() {
  local output_var="$1"
  ensure_dir "$COMMANDS_DST"
  eval "$output_var=()"

  local name src dst previous_snapshot next_snapshot
  next_snapshot="$(mktemp -d "${TMPDIR:-/tmp}/b-agentic-opencode-commands.XXXXXX")"
  while IFS= read -r name; do
    [ -n "$name" ] || continue

    src="$COMMANDS_SRC/$name.md"
    dst="$COMMANDS_DST/$name.md"
    previous_snapshot="$COMMANDS_SNAPSHOT_DST/$name.md"

    if ! command_skill_was_installed "$name"; then
      if [ -f "$dst" ] && [ -f "$previous_snapshot" ] && cmp -s "$dst" "$previous_snapshot"; then
        run_cmd rm -f "$dst"
      elif [ -f "$dst" ]; then
        warn "preserving OpenCode command for skipped skill: $dst"
      fi
      continue
    fi

    if [ -f "$dst" ]; then
      if [ -f "$previous_snapshot" ] && cmp -s "$dst" "$previous_snapshot"; then
        copy_file "$src" "$dst"
        copy_file "$src" "$next_snapshot/$name.md"
        eval "$output_var+=(\"$name\")"
        continue
      fi

      if cmp -s "$dst" "$src"; then
        if [ -f "$previous_snapshot" ]; then
          copy_file "$src" "$next_snapshot/$name.md"
          eval "$output_var+=(\"$name\")"
        else
          warn "preserving existing OpenCode command: $dst"
        fi
        continue
      fi

      if [ -f "$previous_snapshot" ]; then
        warn "preserving modified OpenCode command wrapper: $dst"
      else
        warn "preserving existing OpenCode command: $dst"
      fi
      continue
    fi

    copy_file "$src" "$dst"
    copy_file "$src" "$next_snapshot/$name.md"
    eval "$output_var+=(\"$name\")"
  done < <(command_names)

  prune_stale_commands
  copy_dir_replace "$next_snapshot" "$COMMANDS_SNAPSHOT_DST"
  rm -rf "$next_snapshot"
}

runtime_install_extra_assets() {
  [ -d "$COMMANDS_SRC" ] || die "missing command source directory: $COMMANDS_SRC"
  install_commands INSTALL_COMMAND_NAMES
}

runtime_install_configs() {
  run_install_triplet_stage "Merging MCP config" install_mcp_config "skip" "none" "none" \
    INSTALL_MCP_ACTION INSTALL_MCP_STATE INSTALL_MCP_BACKUP
  apply_prompted_mcp_keys_stage INSTALL_MCP_ACTION INSTALL_MCP_BACKUP
}

runtime_write_manifest() {
  local skills_string="${INSTALL_SKILL_NAMES[*]}"
  local commands_string="${INSTALL_COMMAND_NAMES[*]}"

  if dry_run_enabled; then
    printf '[dry-run] write manifest %s\n' "$MANIFEST_DST" >&2
    return 0
  fi

  ensure_dir "$METADATA_DIR"
  env \
    MANIFEST_DST="$MANIFEST_DST" \
    TIMESTAMP="$TIMESTAMP" \
    RUNTIME="$RUNTIME" \
    MEMORY_ACTION="$INSTALL_MEMORY_ACTION" \
    ACTIVATION_STATE="$INSTALL_ACTIVATION_STATE" \
    MEMORY_BACKUP="$INSTALL_MEMORY_BACKUP" \
    MCP_ACTION="$INSTALL_MCP_ACTION" \
    MCP_STATE="$INSTALL_MCP_STATE" \
    MCP_BACKUP="$INSTALL_MCP_BACKUP" \
    OPENCODE_DIR="$OPENCODE_DIR" \
    OPENCODE_JSON_DST="$OPENCODE_JSON_DST" \
    SKILLS_DST="$SKILLS_DST" \
    COMMANDS_DST="$COMMANDS_DST" \
    REFERENCES_DST="$REFERENCES_DST" \
    TEMPLATES_DST="$TEMPLATES_DST" \
    KERNEL_DST="$KERNEL_DST" \
    SKILLS="$skills_string" \
    COMMANDS="$commands_string" \
    python3 - <<'PY'
import json
import os
from pathlib import Path

skills = [name for name in os.environ['SKILLS'].split() if name]
commands = [name for name in os.environ['COMMANDS'].split() if name]
manifest = {
    'suite': 'b-agentic',
    'runtime': os.environ['RUNTIME'],
    'installedAt': os.environ['TIMESTAMP'],
    'activationState': os.environ['ACTIVATION_STATE'],
    'memoryAction': os.environ['MEMORY_ACTION'],
    'mcpAction': os.environ['MCP_ACTION'],
    'mcpState': os.environ['MCP_STATE'],
    'paths': {
        'opencodeDir': os.environ['OPENCODE_DIR'],
        'opencodeJson': os.environ['OPENCODE_JSON_DST'],
        'kernel': os.environ['KERNEL_DST'],
        'skills': os.environ['SKILLS_DST'],
        'commands': os.environ['COMMANDS_DST'],
        'references': os.environ['REFERENCES_DST'],
        'templates': os.environ['TEMPLATES_DST'],
    },
    'skills': skills,
    'commands': commands,
    'backups': {
        'opencodeJson': os.environ['MCP_BACKUP'],
    },
}
Path(os.environ['MANIFEST_DST']).write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
PY
}

runtime_print_install_report() {
  print_install_report_header "OpenCode"
  report_section "Summary"
  report_item "activation" "$INSTALL_ACTIVATION_STATE"
  report_item "skills" "${#INSTALL_SKILL_NAMES[@]} synced -> $SKILLS_DST"
  report_item "commands" "${#INSTALL_COMMAND_NAMES[@]} synced -> $COMMANDS_DST"
  report_item "kernel" "$INSTALL_MEMORY_ACTION -> $KERNEL_DST"
  report_item "mcp" "$INSTALL_MCP_ACTION -> $OPENCODE_JSON_DST"
  report_item "references" "sync -> $REFERENCES_DST"
  report_item "templates" "sync -> $TEMPLATES_DST"
  report_item "manifest" "write -> $MANIFEST_DST"
  report_section "Backups"
  report_item "kernel" "$INSTALL_MEMORY_BACKUP"
  report_item "mcp" "$INSTALL_MCP_BACKUP"
  print_install_report_readiness
  print_shell_tool_recommendations
  print_install_report_next_steps "OpenCode"
}

manifest_command_names() {
  if manifest_array_values commands; then
    return 0
  fi
  command_names
}

runtime_uninstall_extra_assets() {
  local name command_path command_snapshot
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! managed_asset_name_is_safe "$name"; then
      warn "preserving OpenCode command with unsafe manifest name"
      continue
    fi
    command_path="$COMMANDS_DST/$name.md"
    command_snapshot="$COMMANDS_SNAPSHOT_DST/$name.md"
    if [ ! -f "$command_path" ]; then
      continue
    fi
    if [ ! -f "$command_snapshot" ]; then
      warn "preserving OpenCode command with no managed snapshot: $command_path"
      continue
    fi
    if cmp -s "$command_path" "$command_snapshot"; then
      run_cmd rm -f "$command_path"
    else
      warn "preserving modified OpenCode command wrapper: $command_path"
    fi
  done < <(manifest_command_names)
}

runtime_uninstall_configs() {
  local opencode_json_path
  opencode_json_path="$(manifest_path_value opencodeJson "$OPENCODE_JSON_DST")"
  remove_merged_config "$opencode_json_path" "$TEMPLATES_DST/mcp.user.template.json" "opencode.json" "opencodeJson" "mcpAction"
}

runtime_main() {
  runtime_install_common
}

runtime_uninstall() {
  runtime_uninstall_common
}
