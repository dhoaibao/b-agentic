# Sourced by install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by install.sh" >&2
  exit 1
fi

readonly RUNTIME_UNINSTALL_LABEL="Claude Code personal config"
readonly RUNTIME_PRESERVE_LABEL="Claude Code"
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
readonly MCP_CONFIG_DST="$CLAUDE_JSON_DST"
readonly MCP_ROOT_KEY="mcpServers"
readonly MCP_PLACEHOLDER_STYLE="claude"
readonly MCP_CONTEXT7_SECTION="headers"
readonly MCP_BRAVE_SECTION="env"
readonly MCP_FIRECRAWL_SECTION="env"
readonly MCP_BACKUP_KEY="claudeJson"

CONTEXT7_API_KEY_INPUT=""
BRAVE_API_KEY_INPUT=""
FIRECRAWL_API_KEY_INPUT=""

runtime_warn_missing_cli() {
  command -v claude >/dev/null 2>&1 || warn "claude CLI not found; files will still be installed for Claude Code to discover later."
}

install_settings_config() {
  merge_json_file "$TEMPLATES_SRC/settings.template.json" "$SETTINGS_DST" "settings" "settings"
}

runtime_install_configs() {
  local settings_result mcp_result
  settings_result="$(install_settings_config)"
  read_install_triplet "$settings_result" "skip" "none" "none" \
    INSTALL_SETTINGS_ACTION INSTALL_SETTINGS_STATE INSTALL_SETTINGS_BACKUP
  mcp_result="$(install_mcp_config)"
  read_install_triplet "$mcp_result" "skip" "none" "none" \
    INSTALL_MCP_ACTION INSTALL_MCP_STATE INSTALL_MCP_BACKUP
}

runtime_write_manifest() {
  local skills_string="${INSTALL_SKILL_NAMES[*]}"

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
    SETTINGS_ACTION="$INSTALL_SETTINGS_ACTION" \
    SETTINGS_STATE="$INSTALL_SETTINGS_STATE" \
    SETTINGS_BACKUP="$INSTALL_SETTINGS_BACKUP" \
    MCP_ACTION="$INSTALL_MCP_ACTION" \
    MCP_STATE="$INSTALL_MCP_STATE" \
    MCP_BACKUP="$INSTALL_MCP_BACKUP" \
    CLAUDE_DIR="$CLAUDE_DIR" \
    CLAUDE_JSON_DST="$CLAUDE_JSON_DST" \
    SKILLS_DST="$SKILLS_DST" \
    REFERENCES_DST="$REFERENCES_DST" \
    TEMPLATES_DST="$TEMPLATES_DST" \
    KERNEL_DST="$KERNEL_DST" \
    SETTINGS_DST="$SETTINGS_DST" \
    SKILLS="$skills_string" \
    python3 - <<'PY'
import json
import os
from pathlib import Path

skills = [name for name in os.environ['SKILLS'].split() if name]
manifest = {
    'suite': 'b-agentic',
    'runtime': os.environ['RUNTIME'],
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

runtime_print_install_report() {
  log ""
  log "b-agentic Claude Code install complete"
  log "skillsSynced: ${#INSTALL_SKILL_NAMES[@]} -> $SKILLS_DST"
  log "kernel: $INSTALL_MEMORY_ACTION -> $KERNEL_DST"
  log "settings: $INSTALL_SETTINGS_ACTION -> $SETTINGS_DST"
  log "mcp: $INSTALL_MCP_ACTION -> $CLAUDE_JSON_DST"
  log "references: sync -> $REFERENCES_DST"
  log "templates: sync -> $TEMPLATES_DST"
  log "manifest: write -> $MANIFEST_DST"
  log "backups:"
  log "  kernel: $INSTALL_MEMORY_BACKUP"
  log "  settings: $INSTALL_SETTINGS_BACKUP"
  log "  mcp: $INSTALL_MCP_BACKUP"
  log "activationState: $INSTALL_ACTIVATION_STATE"
  log "mcpReadiness:"
  log "  serena: install/init separately; installer never runs onboarding"
  log "  gitnexus: install/index separately if you want graph radar"
  log "  api-keys: Context7, Brave Search, and Firecrawl need user-scope keys"
}

runtime_uninstall_configs() {
  local settings_path claude_json_path
  settings_path="$(manifest_path_value settings "$SETTINGS_DST")"
  claude_json_path="$(manifest_path_value claudeJson "$CLAUDE_JSON_DST")"
  remove_merged_config "$settings_path" "$TEMPLATES_DST/settings.template.json" "settings.json" "settings" "settingsAction"
  remove_merged_config "$claude_json_path" "$TEMPLATES_DST/mcp.user.template.json" ".claude.json" "claudeJson" "mcpAction"
}

runtime_main() {
  runtime_install_common
}

runtime_uninstall() {
  runtime_uninstall_common
}
