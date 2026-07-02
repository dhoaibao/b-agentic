# Sourced by install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by install.sh" >&2
  exit 1
fi

readonly RUNTIME_UNINSTALL_LABEL="GitHub Copilot CLI personal config"
readonly RUNTIME_PRESERVE_LABEL="GitHub Copilot CLI"
readonly COPILOT_DIR="${B_AGENTIC_COPILOT_DIR:-$HOME/.copilot}"
readonly METADATA_DIR="$COPILOT_DIR/b-agentic"
readonly BACKUPS_DIR="$METADATA_DIR/backups"
readonly SKILLS_DST="$COPILOT_DIR/skills"
readonly KERNEL_DST="$COPILOT_DIR/copilot-instructions.md"
readonly KERNEL_SNAPSHOT_DST="$METADATA_DIR/copilot-instructions.md"
readonly REFERENCES_DST="$METADATA_DIR/references"
readonly TEMPLATES_DST="$METADATA_DIR/templates"
readonly MANIFEST_DST="$METADATA_DIR/install.json"
readonly MCP_CONFIG_DST="$COPILOT_DIR/mcp-config.json"
readonly MCP_ROOT_KEY="mcpServers"
readonly MCP_PLACEHOLDER_STYLE="claude"
readonly MCP_CONTEXT7_SECTION="headers"
readonly MCP_BRAVE_SECTION="env"
readonly MCP_FIRECRAWL_SECTION="env"
readonly MCP_BACKUP_KEY="mcpConfig"

CONTEXT7_API_KEY_INPUT=""
BRAVE_API_KEY_INPUT=""
FIRECRAWL_API_KEY_INPUT=""
FIRECRAWL_API_URL_INPUT=""

runtime_warn_missing_cli() {
  command -v copilot >/dev/null 2>&1 || warn "copilot CLI not found; files will still be installed for GitHub Copilot CLI to discover later."
  command -v codegraph >/dev/null 2>&1 || warn "codegraph CLI not found; CodeGraph MCP will not start until CodeGraph is installed."
  command -v pnpm >/dev/null 2>&1 || warn "pnpm not found; MCP servers that use 'pnpm dlx' (Brave, Firecrawl, Playwright) will not start until pnpm is installed."
}

runtime_cli_installed() {
  command -v copilot >/dev/null 2>&1
}

readonly COPILOT_INSTALL_URL="${B_AGENTIC_COPILOT_INSTALL_URL:-https://gh.io/copilot-install}"

runtime_upgrade_cli() {
  if command -v copilot >/dev/null 2>&1; then
    log "GitHub Copilot CLI already installed; upgrading"
  else
    log "GitHub Copilot CLI not found; installing"
  fi
  if dry_run_enabled; then
    printf '[dry-run] curl -fsSL %s | bash\n' "$COPILOT_INSTALL_URL" >&2
    return 0
  fi
  if curl -fsSL "$COPILOT_INSTALL_URL" | bash; then
    log "GitHub Copilot CLI install/upgrade completed"
  else
    warn "GitHub Copilot CLI install/upgrade failed; files will still be installed for GitHub Copilot CLI to discover later"
  fi
}

runtime_install_config_stage_count() {
  printf '2'
}

runtime_install_extra_assets() {
  :
}

runtime_install_configs() {
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
    MCP_ACTION="$INSTALL_MCP_ACTION" \
    MCP_STATE="$INSTALL_MCP_STATE" \
    MCP_BACKUP="$INSTALL_MCP_BACKUP" \
    COPILOT_DIR="$COPILOT_DIR" \
    SKILLS_DST="$SKILLS_DST" \
    REFERENCES_DST="$REFERENCES_DST" \
    TEMPLATES_DST="$TEMPLATES_DST" \
    KERNEL_DST="$KERNEL_DST" \
    MCP_CONFIG_DST="$MCP_CONFIG_DST" \
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
        'copilotDir': os.environ['COPILOT_DIR'],
        'kernel': os.environ['KERNEL_DST'],
        'skills': os.environ['SKILLS_DST'],
        'references': os.environ['REFERENCES_DST'],
        'templates': os.environ['TEMPLATES_DST'],
        'mcpConfig': os.environ['MCP_CONFIG_DST'],
    },
    'skills': skills,
    'backups': {
        'copilotInstructionsMd': os.environ['MEMORY_BACKUP'],
        'mcpConfig': os.environ['MCP_BACKUP'],
    },
}
Path(os.environ['MANIFEST_DST']).write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
PY
}

runtime_print_install_report() {
  print_install_report_header "GitHub Copilot CLI"
  report_section "Summary"
  report_item "activation" "$INSTALL_ACTIVATION_STATE"
  report_item "skills" "${#INSTALL_SKILL_NAMES[@]} synced -> $SKILLS_DST"
  report_item "kernel" "$INSTALL_MEMORY_ACTION -> $KERNEL_DST"
  report_item "mcp" "$INSTALL_MCP_ACTION -> $MCP_CONFIG_DST"
  report_item "references" "sync -> $REFERENCES_DST"
  report_item "templates" "sync -> $TEMPLATES_DST"
  report_item "manifest" "write -> $MANIFEST_DST"
  report_section "Backups"
  report_item "kernel" "$INSTALL_MEMORY_BACKUP"
  report_item "mcp" "$INSTALL_MCP_BACKUP"
  print_install_report_readiness
  print_shell_tool_recommendations
  print_install_report_next_steps "GitHub Copilot CLI"
}

runtime_uninstall_configs() {
  local mcp_config_path
  mcp_config_path="$(manifest_path_value mcpConfig "$MCP_CONFIG_DST")"
  remove_merged_config "$mcp_config_path" "$TEMPLATES_DST/mcp.user.template.json" "mcp-config.json" "mcpConfig" "mcpAction"
}

runtime_uninstall_extra_assets() { :; }

runtime_main() {
  runtime_install_common
}

runtime_uninstall() {
  runtime_uninstall_common
}
