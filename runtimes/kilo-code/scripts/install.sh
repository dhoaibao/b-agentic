# Sourced by install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by install.sh" >&2
  exit 1
fi

readonly RUNTIME_UNINSTALL_LABEL="Kilo Code personal config"
readonly RUNTIME_PRESERVE_LABEL="Kilo Code"
readonly KILO_HOME="${B_AGENTIC_KILO_HOME:-$HOME/.kilo}"
readonly KILO_CONFIG_DIR="${B_AGENTIC_KILO_CONFIG_DIR:-$HOME/.config/kilo}"
readonly METADATA_DIR="$KILO_HOME/b-agentic"
readonly BACKUPS_DIR="$METADATA_DIR/backups"
readonly SKILLS_DST="${B_AGENTIC_SKILLS_DST:-$KILO_HOME/skills}"
readonly KERNEL_DST="${B_AGENTIC_KILO_KERNEL:-$KILO_CONFIG_DIR/AGENTS.md}"
readonly KERNEL_SNAPSHOT_DST="$METADATA_DIR/AGENTS.md"
readonly REFERENCES_DST="$METADATA_DIR/references"
readonly TEMPLATES_DST="$METADATA_DIR/templates"
readonly MANIFEST_DST="$METADATA_DIR/install.json"
readonly KILO_CONFIG_DST="${B_AGENTIC_KILO_CONFIG:-$KILO_CONFIG_DIR/kilo.jsonc}"
readonly MCP_CONFIG_DST="$KILO_CONFIG_DST"
readonly MCP_ROOT_KEY="mcp"
readonly MCP_PLACEHOLDER_STYLE="opencode"
readonly MCP_CONTEXT7_SECTION="headers"
readonly MCP_BRAVE_SECTION="environment"
readonly MCP_FIRECRAWL_SECTION="environment"
readonly MCP_BACKUP_KEY="kiloConfig"

CONTEXT7_API_KEY_INPUT=""
BRAVE_API_KEY_INPUT=""
FIRECRAWL_API_KEY_INPUT=""
FIRECRAWL_API_URL_INPUT=""

runtime_warn_missing_cli() {
  command -v codegraph >/dev/null 2>&1 || warn "codegraph CLI not found; CodeGraph MCP will not start until CodeGraph is installed."
  command -v pnpm >/dev/null 2>&1 || warn "pnpm not found; MCP servers that use 'pnpm dlx' (Brave, Firecrawl, Playwright) will not start until pnpm is installed."
}

runtime_upgrade_cli() {
  if command -v kilo >/dev/null 2>&1; then
    log "Kilo Code CLI already installed; upgrading"
    if run_cmd kilo upgrade; then
      log "Kilo Code CLI upgraded"
    else
      warn "Kilo Code CLI upgrade failed; continuing with existing CLI"
    fi
    return 0
  fi

  log "Kilo Code CLI not found; installing"
  if dry_run_enabled; then
    printf '[dry-run] curl -fsSL https://kilo.ai/cli/install | bash\n' >&2
  elif curl -fsSL https://kilo.ai/cli/install | bash; then
    log "Kilo Code CLI installed"
  else
    warn "Kilo Code CLI install failed; files will still be installed for Kilo Code to discover later"
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
    KILO_HOME="$KILO_HOME" \
    KILO_CONFIG_DIR="$KILO_CONFIG_DIR" \
    KILO_CONFIG_DST="$KILO_CONFIG_DST" \
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
        'kiloHome': os.environ['KILO_HOME'],
        'kiloConfigDir': os.environ['KILO_CONFIG_DIR'],
        'kiloConfig': os.environ['KILO_CONFIG_DST'],
        'kernel': os.environ['KERNEL_DST'],
        'skills': os.environ['SKILLS_DST'],
        'references': os.environ['REFERENCES_DST'],
        'templates': os.environ['TEMPLATES_DST'],
    },
    'skills': skills,
    'backups': {
        'kiloConfig': os.environ['MCP_BACKUP'],
    },
}
Path(os.environ['MANIFEST_DST']).write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
PY
}

runtime_print_install_report() {
  print_install_report_header "Kilo Code"
  report_section "Summary"
  report_item "activation" "$INSTALL_ACTIVATION_STATE"
  report_item "skills" "${#INSTALL_SKILL_NAMES[@]} synced -> $SKILLS_DST"
  report_item "kernel" "$INSTALL_MEMORY_ACTION -> $KERNEL_DST"
  report_item "mcp" "$INSTALL_MCP_ACTION -> $KILO_CONFIG_DST"
  report_item "references" "sync -> $REFERENCES_DST"
  report_item "templates" "sync -> $TEMPLATES_DST"
  report_item "manifest" "write -> $MANIFEST_DST"
  report_section "Backups"
  report_item "kernel" "$INSTALL_MEMORY_BACKUP"
  report_item "mcp" "$INSTALL_MCP_BACKUP"
  print_install_report_readiness
  print_shell_tool_recommendations
  print_install_report_next_steps "Kilo Code"
}

runtime_uninstall_configs() {
  local kilo_config_path
  kilo_config_path="$(manifest_path_value kiloConfig "$KILO_CONFIG_DST")"
  remove_merged_config "$kilo_config_path" "$TEMPLATES_DST/mcp.user.template.json" "kilo.jsonc" "kiloConfig" "mcpAction"
}

runtime_uninstall_extra_assets() { :; }

runtime_main() {
  runtime_install_common
}

runtime_uninstall() {
  runtime_uninstall_common
}
