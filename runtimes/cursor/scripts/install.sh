# Sourced by install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by install.sh" >&2
  exit 1
fi

readonly RUNTIME_UNINSTALL_LABEL="Cursor personal config"
readonly RUNTIME_PRESERVE_LABEL="Cursor"
readonly CURSOR_DIR="${B_AGENTIC_CURSOR_DIR:-$HOME/.cursor}"
readonly METADATA_DIR="$CURSOR_DIR/b-agentic"
readonly BACKUPS_DIR="$METADATA_DIR/backups"
readonly SKILLS_DST="$CURSOR_DIR/skills"
readonly KERNEL_DST="$CURSOR_DIR/AGENTS.md"
readonly KERNEL_SNAPSHOT_DST="$METADATA_DIR/AGENTS.md"
readonly REFERENCES_DST="$METADATA_DIR/references"
readonly TEMPLATES_DST="$METADATA_DIR/templates"
readonly MANIFEST_DST="$METADATA_DIR/install.json"
readonly CURSOR_JSON_DST="${B_AGENTIC_CURSOR_JSON:-$HOME/.cursor/mcp.json}"
readonly MCP_CONFIG_DST="$CURSOR_JSON_DST"
readonly SETTINGS_DST="$CURSOR_DIR/cli-config.json"
readonly MCP_ROOT_KEY="mcpServers"
readonly MCP_PLACEHOLDER_STYLE="claude"
readonly MCP_CONTEXT7_SECTION="headers"
readonly MCP_BRAVE_SECTION="env"
readonly MCP_FIRECRAWL_SECTION="env"
readonly MCP_BACKUP_KEY="cursorJson"
readonly SETTINGS_BACKUP_KEY="settings"

CONTEXT7_API_KEY_INPUT=""
BRAVE_API_KEY_INPUT=""
FIRECRAWL_API_KEY_INPUT=""
FIRECRAWL_API_URL_INPUT=""

runtime_warn_missing_cli() {
  command -v agent >/dev/null 2>&1 || warn "Cursor Agent CLI 'agent' not found; active acceptance will not work."
  command -v codegraph >/dev/null 2>&1 || warn "codegraph CLI not found; CodeGraph MCP will not start until CodeGraph is installed."
  command -v pnpm >/dev/null 2>&1 || warn "pnpm not found; MCP servers that use 'pnpm dlx' (Brave, Firecrawl, Playwright) will not start until pnpm is installed."
}

runtime_cli_installed() {
  command -v agent >/dev/null 2>&1
}

runtime_upgrade_cli() {
  if command -v agent >/dev/null 2>&1; then
    log "Cursor Agent CLI already installed; upgrading"
  else
    log "Cursor Agent CLI not found; installing from https://cursor.com/install"
  fi
  if dry_run_enabled; then
    printf '[dry-run] curl https://cursor.com/install -fsSL | bash\n' >&2
    return 0
  fi
  if curl https://cursor.com/install -fsSL | bash; then
    log "Cursor Agent CLI install/upgrade completed"
  else
    warn "Cursor Agent CLI install/upgrade failed; continuing"
  fi
  return 0
}

runtime_install_config_stage_count() {
  printf '3'
}

install_settings_config() {
  local template_src="$TEMPLATES_SRC/settings.template.json"
  local rendered_template
  rendered_template="$(mktemp "${TMPDIR:-/tmp}/b-agentic-cursor-settings.XXXXXX")"

  env \
    TEMPLATE_SRC="$template_src" \
    TEMPLATE_DST="$rendered_template" \
    python3 - <<'PY'
import json
import os
from pathlib import Path

src = Path(os.environ["TEMPLATE_SRC"])
dst = Path(os.environ["TEMPLATE_DST"])
text = src.read_text()
data = json.loads(text)
dst.write_text(json.dumps(data, indent=2, sort_keys=False) + "\n")
PY

  if ! dry_run_enabled; then
    copy_file "$rendered_template" "$TEMPLATES_DST/settings.template.json"
  fi

  merge_json_file "$rendered_template" "$SETTINGS_DST" "settings" "$SETTINGS_BACKUP_KEY"
  rm -f "$rendered_template"
}

runtime_install_extra_assets() {
  :
}

runtime_install_configs() {
  run_install_triplet_stage "Merging Cursor settings" install_settings_config "skip" "none" "none" \
    INSTALL_SETTINGS_ACTION INSTALL_SETTINGS_STATE INSTALL_SETTINGS_BACKUP
  run_install_triplet_stage "Merging MCP config" install_mcp_config "skip" "none" "none" \
    INSTALL_MCP_ACTION INSTALL_MCP_STATE INSTALL_MCP_BACKUP
  apply_prompted_mcp_keys_stage INSTALL_MCP_ACTION INSTALL_MCP_BACKUP
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
    CURSOR_DIR="$CURSOR_DIR" \
    MCP_CONFIG_DST="$MCP_CONFIG_DST" \
    SETTINGS_DST="$SETTINGS_DST" \
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
    'settingsAction': os.environ['SETTINGS_ACTION'],
    'settingsState': os.environ['SETTINGS_STATE'],
    'mcpAction': os.environ['MCP_ACTION'],
    'mcpState': os.environ['MCP_STATE'],
    'paths': {
        'cursorDir': os.environ['CURSOR_DIR'],
        'mcpConfig': os.environ['MCP_CONFIG_DST'],
        'settings': os.environ['SETTINGS_DST'],
        'kernel': os.environ['KERNEL_DST'],
        'skills': os.environ['SKILLS_DST'],
        'references': os.environ['REFERENCES_DST'],
        'templates': os.environ['TEMPLATES_DST'],
    },
    'skills': skills,
    'backups': {
        'agentsMd': os.environ['MEMORY_BACKUP'],
        'settings': os.environ['SETTINGS_BACKUP'],
        'mcpConfig': os.environ['MCP_BACKUP'],
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
  report_item "kernel" "$INSTALL_MEMORY_ACTION -> $KERNEL_DST"
  report_item "settings" "$INSTALL_SETTINGS_ACTION -> $SETTINGS_DST"
  report_item "mcp" "$INSTALL_MCP_ACTION -> $MCP_CONFIG_DST"
  report_item "references" "sync -> $REFERENCES_DST"
  report_item "templates" "sync -> $TEMPLATES_DST"
  report_item "manifest" "write -> $MANIFEST_DST"
  report_section "Backups"
  report_item "kernel" "$INSTALL_MEMORY_BACKUP"
  report_item "settings" "$INSTALL_SETTINGS_BACKUP"
  report_item "mcp" "$INSTALL_MCP_BACKUP"
  print_install_report_readiness
  print_shell_tool_recommendations
  print_install_report_next_steps "Cursor"
}

runtime_uninstall_configs() {
  local mcp_config_path settings_path
  mcp_config_path="$(manifest_path_value mcpConfig "$MCP_CONFIG_DST")"
  settings_path="$(manifest_path_value settings "$SETTINGS_DST")"
  remove_merged_config "$settings_path" "$TEMPLATES_DST/settings.template.json" "cli-config.json" "settings" "settingsAction"
  remove_merged_config "$mcp_config_path" "$TEMPLATES_DST/mcp.user.template.json" "mcp.json" "mcpConfig" "mcpAction"
}

runtime_uninstall_extra_assets() { :; }

runtime_main() {
  runtime_install_common
}

runtime_uninstall() {
  runtime_uninstall_common
}
