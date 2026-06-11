# Sourced by install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by install.sh" >&2
  exit 1
fi

readonly RUNTIME_UNINSTALL_LABEL="Kilo Code personal config"
readonly RUNTIME_PRESERVE_LABEL="Kilo Code"
readonly KILO_DIR="${B_AGENTIC_KILO_DIR:-$HOME/.config/kilo}"
readonly METADATA_DIR="$KILO_DIR/b-agentic"
readonly BACKUPS_DIR="$METADATA_DIR/backups"
readonly SKILLS_DST="${B_AGENTIC_SKILLS_DST:-$HOME/.config/kilo/skills}"
readonly AGENTS_SRC="$SOURCE_DIR/runtimes/$RUNTIME/agents"
readonly AGENTS_DST="${B_AGENTIC_KILO_AGENTS_DIR:-$HOME/.config/kilo/agents}"
readonly AGENTS_SNAPSHOT_DST="$METADATA_DIR/agents"
readonly KERNEL_DST="$KILO_DIR/AGENTS.md"
readonly KERNEL_SNAPSHOT_DST="$METADATA_DIR/AGENTS.md"
readonly REFERENCES_DST="$METADATA_DIR/references"
readonly TEMPLATES_DST="$METADATA_DIR/templates"
readonly MANIFEST_DST="$METADATA_DIR/install.json"
readonly RUNTIME_PRE_ACTION_ENFORCEMENT="advisory-only"
readonly KILO_JSONC_DST="${B_AGENTIC_KILO_JSONC:-$HOME/.config/kilo/kilo.jsonc}"
readonly MCP_CONFIG_DST="$KILO_JSONC_DST"
readonly MCP_ROOT_KEY="mcp"
readonly MCP_PLACEHOLDER_STYLE="kilo"
readonly MCP_CONTEXT7_SECTION="headers"
readonly MCP_BRAVE_SECTION="environment"
readonly MCP_FIRECRAWL_SECTION="environment"
readonly MCP_BACKUP_KEY="kiloJsonc"

CONTEXT7_API_KEY_INPUT=""
BRAVE_API_KEY_INPUT=""
FIRECRAWL_API_KEY_INPUT=""
FIRECRAWL_API_URL_INPUT=""

runtime_warn_missing_cli() {
  command -v kilo >/dev/null 2>&1 || warn "kilo CLI not found; files will still be installed for Kilo Code to discover later."
}

runtime_install_config_stage_count() {
  printf '1'
}

runtime_install_extra_assets() {
  install_managed_profiles "$AGENTS_SRC" "$AGENTS_DST" "$AGENTS_SNAPSHOT_DST" "md" "Kilo Code agent" INSTALL_AGENT_NAMES
}

runtime_install_configs() {
  run_install_triplet_stage "Merging MCP config" install_mcp_config "skip" "none" "none" \
    INSTALL_MCP_ACTION INSTALL_MCP_STATE INSTALL_MCP_BACKUP
}

runtime_write_manifest() {
  local skills_string="${INSTALL_SKILL_NAMES[*]}"
  local agents_string="${INSTALL_AGENT_NAMES[*]}"

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
    KILO_DIR="$KILO_DIR" \
    KILO_JSONC_DST="$KILO_JSONC_DST" \
    SKILLS_DST="$SKILLS_DST" \
    AGENTS_DST="$AGENTS_DST" \
    REFERENCES_DST="$REFERENCES_DST" \
    TEMPLATES_DST="$TEMPLATES_DST" \
    KERNEL_DST="$KERNEL_DST" \
    SKILLS="$skills_string" \
    AGENTS="$agents_string" \
    python3 - <<'PY'
import json
import os
from pathlib import Path

skills = [name for name in os.environ['SKILLS'].split() if name]
agents = [name for name in os.environ['AGENTS'].split() if name]
manifest = {
    'suite': 'b-agentic',
    'runtime': os.environ['RUNTIME'],
    'installedAt': os.environ['TIMESTAMP'],
    'activationState': os.environ['ACTIVATION_STATE'],
    'memoryAction': os.environ['MEMORY_ACTION'],
    'mcpAction': os.environ['MCP_ACTION'],
    'mcpState': os.environ['MCP_STATE'],
    'paths': {
        'kiloDir': os.environ['KILO_DIR'],
        'kiloJsonc': os.environ['KILO_JSONC_DST'],
        'kernel': os.environ['KERNEL_DST'],
        'skills': os.environ['SKILLS_DST'],
        'agents': os.environ['AGENTS_DST'],
        'references': os.environ['REFERENCES_DST'],
        'templates': os.environ['TEMPLATES_DST'],
    },
    'skills': skills,
    'agents': agents,
    'backups': {
        'agentsMd': os.environ['MEMORY_BACKUP'],
        'kiloJsonc': os.environ['MCP_BACKUP'],
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
  report_item "agents" "${#INSTALL_AGENT_NAMES[@]} synced -> $AGENTS_DST"
  report_item "kernel" "$INSTALL_MEMORY_ACTION -> $KERNEL_DST"
  report_item "mcp" "$INSTALL_MCP_ACTION -> $KILO_JSONC_DST"
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

runtime_uninstall_extra_assets() {
  local agents_path
  agents_path="$(manifest_path_value agents "$AGENTS_DST")"
  uninstall_managed_profiles agents "$agents_path" "$AGENTS_SNAPSHOT_DST" "md" "Kilo Code agent"
}

runtime_uninstall_configs() {
  local kilo_jsonc_path
  kilo_jsonc_path="$(manifest_path_value kiloJsonc "$KILO_JSONC_DST")"
  remove_merged_config "$kilo_jsonc_path" "$TEMPLATES_DST/mcp.user.template.json" "kilo.jsonc" "kiloJsonc" "mcpAction"
}

runtime_main() {
  runtime_install_common
}

runtime_uninstall() {
  runtime_uninstall_common
}
