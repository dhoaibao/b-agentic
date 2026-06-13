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
FIRECRAWL_API_URL_INPUT=""

runtime_warn_missing_cli() {
  command -v codegraph >/dev/null 2>&1 || warn "codegraph CLI not found; CodeGraph MCP will not start until CodeGraph is installed."
  command -v pnpm >/dev/null 2>&1 || warn "pnpm not found; MCP servers that use 'pnpm dlx' (Brave, Firecrawl, Playwright) will not start until pnpm is installed."
}

runtime_upgrade_cli() {
  if command -v claude >/dev/null 2>&1; then
    log "Claude Code CLI already installed; upgrading"
    if run_cmd claude upgrade; then
      log "Claude Code CLI upgraded"
    else
      warn "Claude Code CLI upgrade failed; continuing with existing CLI"
    fi
    return 0
  fi

  log "Claude Code CLI not found; installing"
  if dry_run_enabled; then
    printf '[dry-run] curl -fsSL https://claude.ai/install.sh | bash\n' >&2
  elif curl -fsSL https://claude.ai/install.sh | bash; then
    log "Claude Code CLI installed"
  else
    warn "Claude Code CLI install failed; files will still be installed for Claude Code to discover later"
  fi
}

runtime_install_config_stage_count() {
  printf '2'
}

install_settings_config() {
  local template_src="$TEMPLATES_SRC/settings.template.json"
  local rendered_template
  rendered_template="$(mktemp "${TMPDIR:-/tmp}/b-agentic-claude-settings.XXXXXX")"

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

  merge_json_file "$rendered_template" "$SETTINGS_DST" "settings" "settings"
  rm -f "$rendered_template"
}

runtime_install_extra_assets() {
  :
}

runtime_install_configs() {
  run_install_triplet_stage "Merging Claude settings" install_settings_config "skip" "none" "none" \
    INSTALL_SETTINGS_ACTION INSTALL_SETTINGS_STATE INSTALL_SETTINGS_BACKUP
  run_install_triplet_stage "Merging MCP config" install_mcp_config "skip" "none" "none" \
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
  print_install_report_header "Claude Code"
  report_section "Summary"
  report_item "activation" "$INSTALL_ACTIVATION_STATE"
  report_item "skills" "${#INSTALL_SKILL_NAMES[@]} synced -> $SKILLS_DST"
  report_item "kernel" "$INSTALL_MEMORY_ACTION -> $KERNEL_DST"
  report_item "settings" "$INSTALL_SETTINGS_ACTION -> $SETTINGS_DST"
  report_item "mcp" "$INSTALL_MCP_ACTION -> $CLAUDE_JSON_DST"
  report_item "references" "sync -> $REFERENCES_DST"
  report_item "templates" "sync -> $TEMPLATES_DST"
  report_item "manifest" "write -> $MANIFEST_DST"
  report_section "Backups"
  report_item "kernel" "$INSTALL_MEMORY_BACKUP"
  report_item "settings" "$INSTALL_SETTINGS_BACKUP"
  report_item "mcp" "$INSTALL_MCP_BACKUP"
  print_install_report_readiness
  print_shell_tool_recommendations
  print_install_report_next_steps "Claude Code"
}

runtime_uninstall_configs() {
  local settings_path claude_json_path
  settings_path="$(manifest_path_value settings "$SETTINGS_DST")"
  claude_json_path="$(manifest_path_value claudeJson "$CLAUDE_JSON_DST")"
  remove_merged_config "$settings_path" "$TEMPLATES_DST/settings.template.json" "settings.json" "settings" "settingsAction"
  remove_merged_config "$claude_json_path" "$TEMPLATES_DST/mcp.user.template.json" ".claude.json" "claudeJson" "mcpAction"
}

runtime_uninstall_extra_assets() { :; }

runtime_main() {
  runtime_install_common
}

runtime_uninstall() {
  runtime_uninstall_common
}
