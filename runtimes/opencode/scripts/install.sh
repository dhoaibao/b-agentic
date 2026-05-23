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
readonly SKILLS_DST="${B_AGENTIC_SKILLS_DST:-$HOME/.claude/skills}"
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

runtime_warn_missing_cli() {
  command -v opencode >/dev/null 2>&1 || warn "opencode CLI not found; files will still be installed for OpenCode to discover later."
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

install_commands() {
  local -n installed_ref="$1"
  ensure_dir "$COMMANDS_DST"
  installed_ref=()

  local name src dst previous_snapshot next_snapshot
  next_snapshot="$(mktemp -d "${TMPDIR:-/tmp}/b-agentic-opencode-commands.XXXXXX")"
  while IFS= read -r name; do
    [ -n "$name" ] || continue

    src="$COMMANDS_SRC/$name.md"
    dst="$COMMANDS_DST/$name.md"
    previous_snapshot="$COMMANDS_SNAPSHOT_DST/$name.md"

    if [ -f "$dst" ]; then
      if [ -f "$previous_snapshot" ] && cmp -s "$dst" "$previous_snapshot"; then
        copy_file "$src" "$dst"
        copy_file "$src" "$next_snapshot/$name.md"
        installed_ref+=("$name")
        continue
      fi

      if cmp -s "$dst" "$src"; then
        if [ -f "$previous_snapshot" ]; then
          copy_file "$src" "$next_snapshot/$name.md"
          installed_ref+=("$name")
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
    installed_ref+=("$name")
  done < <(command_names)

  copy_dir_replace "$next_snapshot" "$COMMANDS_SNAPSHOT_DST"
  rm -rf "$next_snapshot"
}

runtime_install_extra_assets() {
  [ -d "$COMMANDS_SRC" ] || die "missing command source directory: $COMMANDS_SRC"
  install_commands INSTALL_COMMAND_NAMES
}

runtime_install_configs() {
  local mcp_result
  mcp_result="$(install_mcp_config)"
  read_install_triplet "$mcp_result" "skip" "none" "none" \
    INSTALL_MCP_ACTION INSTALL_MCP_STATE INSTALL_MCP_BACKUP
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
        'agentsMd': os.environ['MEMORY_BACKUP'],
        'opencodeJson': os.environ['MCP_BACKUP'],
    },
}
Path(os.environ['MANIFEST_DST']).write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
PY
}

runtime_print_install_report() {
  log ""
  log "b-agentic OpenCode install complete"
  log "skillsSynced: ${#INSTALL_SKILL_NAMES[@]} -> $SKILLS_DST"
  log "commandsSynced: ${#INSTALL_COMMAND_NAMES[@]} -> $COMMANDS_DST"
  log "kernel: $INSTALL_MEMORY_ACTION -> $KERNEL_DST"
  log "mcp: $INSTALL_MCP_ACTION -> $OPENCODE_JSON_DST"
  log "references: sync -> $REFERENCES_DST"
  log "templates: sync -> $TEMPLATES_DST"
  log "manifest: write -> $MANIFEST_DST"
  log "backups:"
  log "  kernel: $INSTALL_MEMORY_BACKUP"
  log "  mcp: $INSTALL_MCP_BACKUP"
  log "activationState: $INSTALL_ACTIVATION_STATE"
  log "mcpReadiness:"
  log "  serena: install/init separately; installer never runs onboarding"
  log "  gitnexus: install/index separately if you want graph radar"
  log "  api-keys: Context7, Brave Search, and Firecrawl need user-scope keys"
}

manifest_command_names() {
  if manifest_array_values commands; then
    return 0
  fi
  command_names
}

runtime_uninstall_extra_assets() {
  local name commands_path command_snapshot
  commands_path="$(manifest_path_value commands "$COMMANDS_DST")"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    command_snapshot="$COMMANDS_SNAPSHOT_DST/$name.md"
    if [ ! -f "$commands_path/$name.md" ]; then
      continue
    fi
    if [ ! -f "$command_snapshot" ]; then
      warn "preserving OpenCode command with no managed snapshot: $commands_path/$name.md"
      continue
    fi
    if cmp -s "$commands_path/$name.md" "$command_snapshot"; then
      run_cmd rm -f "$commands_path/$name.md"
    else
      warn "preserving modified OpenCode command wrapper: $commands_path/$name.md"
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
