# Sourced by install.sh - do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by install.sh" >&2
  exit 1
fi

readonly RUNTIME_UNINSTALL_LABEL="Cursor personal config"
readonly RUNTIME_PRESERVE_LABEL="Cursor"
readonly CURSOR_CONFIG_DIR="${B_AGENTIC_CURSOR_CONFIG_DIR:-$HOME/.cursor}"
readonly METADATA_DIR="${B_AGENTIC_CURSOR_METADATA:-$HOME/.cursor/b-agentic}"
readonly BACKUPS_DIR="$METADATA_DIR/backups"
readonly SKILLS_DST="${B_AGENTIC_SKILLS_DST:-$HOME/.cursor/skills}"
readonly KERNEL_DST="${B_AGENTIC_CURSOR_MEMORY:-$HOME/.cursor/AGENTS.md}"
readonly KERNEL_SNAPSHOT_DST="$METADATA_DIR/AGENTS.md"
readonly REFERENCES_DST="$METADATA_DIR/references"
readonly TEMPLATES_DST="$METADATA_DIR/templates"
readonly MANIFEST_DST="$METADATA_DIR/install.json"
readonly MCP_CONFIG_DST="${B_AGENTIC_CURSOR_MCP:-$HOME/.cursor/mcp.json}"
readonly MCP_TEMPLATE_SRC="$TEMPLATES_SRC/mcp.user.template.json"
readonly MCP_ROOT_KEY="mcpServers"
readonly MCP_PLACEHOLDER_STYLE="gemini"
readonly MCP_CONTEXT7_SECTION="headers"
readonly MCP_BRAVE_SECTION="env"
readonly MCP_FIRECRAWL_SECTION="env"
readonly MCP_BACKUP_KEY="cursorMcp"

CONTEXT7_API_KEY_INPUT=""
BRAVE_API_KEY_INPUT=""
FIRECRAWL_API_KEY_INPUT=""

runtime_warn_missing_cli() {
  command -v cursor >/dev/null 2>&1 || warn "Cursor not found; files will still be installed for Cursor to discover later."
}

runtime_install_config_stage_count() {
  printf '1'
}

runtime_install_extra_assets() {
  :
}

runtime_install_configs() {
  run_install_triplet_stage "Merging Cursor MCP config" install_mcp_config "skip" "none" "none" \
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
    MCP_ACTION="$INSTALL_MCP_ACTION" \
    MCP_STATE="$INSTALL_MCP_STATE" \
    MCP_BACKUP="$INSTALL_MCP_BACKUP" \
    CURSOR_CONFIG_DIR="$CURSOR_CONFIG_DIR" \
    MCP_CONFIG_DST="$MCP_CONFIG_DST" \
    SKILLS_DST="$SKILLS_DST" \
    REFERENCES_DST="$REFERENCES_DST" \
    TEMPLATES_DST="$TEMPLATES_DST" \
    KERNEL_DST="$KERNEL_DST" \
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
    'mcpAction': os.environ['MCP_ACTION'],
    'mcpState': os.environ['MCP_STATE'],
    'paths': {
        'cursorConfigDir': os.environ['CURSOR_CONFIG_DIR'],
        'cursorMcp': os.environ['MCP_CONFIG_DST'],
        'kernel': os.environ['KERNEL_DST'],
        'skills': os.environ['SKILLS_DST'],
        'references': os.environ['REFERENCES_DST'],
        'templates': os.environ['TEMPLATES_DST'],
    },
    'skills': skills,
    'commands': [],
    'backups': {
        'agentsMd': os.environ['MEMORY_BACKUP'],
        'cursorMcp': os.environ['MCP_BACKUP'],
    },
}
Path(os.environ['MANIFEST_DST']).write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
PY
}

runtime_print_install_report() {
  print_install_report_header "Cursor"
  report_section "Summary"
  report_item "activation" "$INSTALL_ACTIVATION_STATE"
  report_item "skills" "${#INSTALL_SKILL_NAMES[@]} synced -> $SKILLS_DST"
  report_item "commands" "native slash command from installed skills"
  report_item "kernel" "$INSTALL_MEMORY_ACTION -> $KERNEL_DST"
  report_item "mcp" "$INSTALL_MCP_ACTION -> $MCP_CONFIG_DST"
  report_item "references" "sync -> $REFERENCES_DST"
  report_item "templates" "sync -> $TEMPLATES_DST"
  report_item "manifest" "write -> $MANIFEST_DST"
  report_section "Backups"
  report_item "kernel" "$INSTALL_MEMORY_BACKUP"
  report_item "mcp" "$INSTALL_MCP_BACKUP"
  print_install_report_readiness
  if [ "$INSTALL_ACTIVATION_STATE" = "active" ]; then
    warn "AGENTS.md not auto-loaded: if Cursor does not read ~/.cursor/AGENTS.md automatically, add the kernel content via Cursor Settings -> Rules."
  fi
  print_shell_tool_recommendations
  print_install_report_next_steps "Cursor"
}

runtime_uninstall_extra_assets() {
  :
}

runtime_uninstall_configs() {
  local mcp_path
  mcp_path="$(manifest_path_value cursorMcp "$MCP_CONFIG_DST")"
  remove_merged_config "$mcp_path" "$TEMPLATES_DST/mcp.user.template.json" "cursor-mcp.json" "cursorMcp" "mcpAction"
}

runtime_main() {
  runtime_install_common
}

runtime_uninstall() {
  runtime_uninstall_common
}
