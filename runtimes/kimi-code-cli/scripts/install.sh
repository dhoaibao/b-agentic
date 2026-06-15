# Sourced by install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by install.sh" >&2
  exit 1
fi

readonly RUNTIME_UNINSTALL_LABEL="Kimi Code CLI personal config"
readonly RUNTIME_PRESERVE_LABEL="Kimi Code CLI"
readonly KIMI_CODE_DIR="${B_AGENTIC_KIMI_CODE_DIR:-${KIMI_CODE_HOME:-$HOME/.kimi-code}}"
readonly METADATA_DIR="$KIMI_CODE_DIR/b-agentic"
readonly BACKUPS_DIR="$METADATA_DIR/backups"
readonly SKILLS_DST="${B_AGENTIC_SKILLS_DST:-$KIMI_CODE_DIR/skills}"
readonly KERNEL_DST="$KIMI_CODE_DIR/AGENTS.md"
readonly KERNEL_SNAPSHOT_DST="$METADATA_DIR/AGENTS.md"
readonly REFERENCES_DST="$METADATA_DIR/references"
readonly TEMPLATES_DST="$METADATA_DIR/templates"
readonly MANIFEST_DST="$METADATA_DIR/install.json"
readonly KIMI_CONFIG_DST="${B_AGENTIC_KIMI_CONFIG:-$KIMI_CODE_DIR/config.toml}"
readonly KIMI_MCP_JSON_DST="${B_AGENTIC_KIMI_MCP_JSON:-$KIMI_CODE_DIR/mcp.json}"
readonly MCP_CONFIG_DST="$KIMI_MCP_JSON_DST"
readonly MCP_ROOT_KEY="mcpServers"
readonly MCP_PLACEHOLDER_STYLE="kimi"
readonly MCP_CONTEXT7_SECTION="headers"
readonly MCP_BRAVE_SECTION="env"
readonly MCP_FIRECRAWL_SECTION="env"
readonly MCP_BACKUP_KEY="kimiMcpJson"
readonly KIMI_CONFIG_BACKUP_KEY="kimiConfig"
readonly KIMI_MANAGED_BEGIN="# BEGIN b-agentic managed config"
readonly KIMI_MANAGED_END="# END b-agentic managed config"

CONTEXT7_API_KEY_INPUT=""
BRAVE_API_KEY_INPUT=""
FIRECRAWL_API_KEY_INPUT=""
FIRECRAWL_API_URL_INPUT=""

runtime_warn_missing_cli() {
  command -v kimi >/dev/null 2>&1 || warn "kimi CLI not found; files will still be installed for Kimi Code CLI to discover later."
  command -v codegraph >/dev/null 2>&1 || warn "codegraph CLI not found; CodeGraph MCP will not start until CodeGraph is installed."
  command -v pnpm >/dev/null 2>&1 || warn "pnpm not found; MCP servers that use 'pnpm dlx' (Brave, Firecrawl, Playwright) will not start until pnpm is installed."
}

runtime_upgrade_cli() {
  if command -v kimi >/dev/null 2>&1; then
    log "Kimi Code CLI already installed; upgrading"
    if run_cmd kimi upgrade; then
      log "Kimi Code CLI upgraded"
    else
      warn "Kimi Code CLI upgrade failed; continuing with existing CLI"
    fi
    return 0
  fi

  log "Kimi Code CLI not found; installing"
  if dry_run_enabled; then
    printf '[dry-run] curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash\n' >&2
  elif curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash; then
    log "Kimi Code CLI installed"
  else
    warn "Kimi Code CLI install failed; files will still be installed for Kimi Code CLI to discover later"
  fi
}

runtime_install_config_stage_count() {
  printf '2'
}

install_kimi_config() {
  local template_src="$TEMPLATES_SRC/config.template.toml"
  local existed action backup="none"
  existed=0
  action="write"
  if [ -e "$KIMI_CONFIG_DST" ]; then
    existed=1
    action="merge"
  fi

  if dry_run_enabled; then
    printf '[dry-run] manage Kimi config %s\n' "$KIMI_CONFIG_DST" >&2
    printf '%s\nactive\n%s' "$action" "$(manifest_backup_value "$KIMI_CONFIG_BACKUP_KEY" none)"
    return 0
  fi

  ensure_dir "$(dirname "$KIMI_CONFIG_DST")"

  local tmp rc
  tmp="$(mktemp "${TMPDIR:-/tmp}/b-agentic-kimi-config.XXXXXX")"
  if env \
    KIMI_CONFIG_DST="$KIMI_CONFIG_DST" \
    KIMI_CONFIG_TEMPLATE="$template_src" \
    KIMI_MANAGED_BEGIN="$KIMI_MANAGED_BEGIN" \
    KIMI_MANAGED_END="$KIMI_MANAGED_END" \
    JSON_TMP="$tmp" \
    python3 - <<'PY'
import os
import tomllib
from pathlib import Path

path = Path(os.environ["KIMI_CONFIG_DST"])
template = Path(os.environ["KIMI_CONFIG_TEMPLATE"])
begin = os.environ["KIMI_MANAGED_BEGIN"]
end = os.environ["KIMI_MANAGED_END"]
tmp = Path(os.environ["JSON_TMP"])

def split_managed_block(text: str) -> str:
    if begin not in text:
        return text
    if end not in text:
        raise SystemExit("invalid Kimi config: missing managed block terminator")
    prefix, remainder = text.split(begin, 1)
    _managed_body, suffix = remainder.split(end, 1)
    return prefix + suffix

current_text = path.read_text() if path.exists() else ""
base_text = split_managed_block(current_text)
managed_body = template.read_text().strip()
managed_block = "\n".join([
    begin,
    "# Managed by b-agentic for Kimi Code CLI.",
    "# Remove by rerunning install.sh --runtime=kimi-code-cli --uninstall.",
    "",
    managed_body,
    end,
])
base_stripped = base_text.strip()
final_text = managed_block if not base_stripped else base_stripped + "\n\n" + managed_block
final_text += "\n"

tomllib.loads(final_text)
if final_text == current_text:
    raise SystemExit(2)

tmp.write_text(final_text)
PY
  then
    rc=0
  else
    rc=$?
  fi

  if [ "$rc" -eq 2 ]; then
    rm -f "$tmp"
    printf '%s\nactive\n%s' "$action" "$(manifest_backup_value "$KIMI_CONFIG_BACKUP_KEY" none)"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    die "failed to write Kimi config: $KIMI_CONFIG_DST"
  fi

  if [ "$existed" -eq 1 ]; then
    backup="$(backup_file "$KIMI_CONFIG_DST")"
  fi
  run_cmd mv "$tmp" "$KIMI_CONFIG_DST"
  printf '%s\nactive\n%s' "$action" "${backup:-none}"
}

runtime_install_configs() {
  run_install_triplet_stage "Updating Kimi config" install_kimi_config "skip" "none" "none" \
    INSTALL_CONFIG_ACTION INSTALL_CONFIG_STATE INSTALL_CONFIG_BACKUP
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
    MCP_ACTION="$INSTALL_MCP_ACTION" \
    MCP_STATE="$INSTALL_MCP_STATE" \
    MCP_BACKUP="$INSTALL_MCP_BACKUP" \
    CONFIG_ACTION="$INSTALL_CONFIG_ACTION" \
    CONFIG_STATE="$INSTALL_CONFIG_STATE" \
    CONFIG_BACKUP="$INSTALL_CONFIG_BACKUP" \
    KIMI_CODE_DIR="$KIMI_CODE_DIR" \
    KIMI_CONFIG_DST="$KIMI_CONFIG_DST" \
    KIMI_MCP_JSON_DST="$KIMI_MCP_JSON_DST" \
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
    'configAction': os.environ['CONFIG_ACTION'],
    'configState': os.environ['CONFIG_STATE'],
    'mcpAction': os.environ['MCP_ACTION'],
    'mcpState': os.environ['MCP_STATE'],
    'paths': {
        'kimiCodeDir': os.environ['KIMI_CODE_DIR'],
        'kimiConfig': os.environ['KIMI_CONFIG_DST'],
        'kimiMcpJson': os.environ['KIMI_MCP_JSON_DST'],
        'kernel': os.environ['KERNEL_DST'],
        'skills': os.environ['SKILLS_DST'],
        'references': os.environ['REFERENCES_DST'],
        'templates': os.environ['TEMPLATES_DST'],
    },
    'skills': skills,
    'backups': {
        'kimiConfig': os.environ['CONFIG_BACKUP'],
        'kimiMcpJson': os.environ['MCP_BACKUP'],
    },
}
Path(os.environ['MANIFEST_DST']).write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
PY
}

runtime_print_install_report() {
  print_install_report_header "Kimi Code CLI"
  report_section "Summary"
  report_item "activation" "$INSTALL_ACTIVATION_STATE"
  report_item "skills" "${#INSTALL_SKILL_NAMES[@]} synced -> $SKILLS_DST"
  report_item "kernel" "$INSTALL_MEMORY_ACTION -> $KERNEL_DST"
  report_item "config" "$INSTALL_CONFIG_ACTION -> $KIMI_CONFIG_DST"
  report_item "mcp" "$INSTALL_MCP_ACTION -> $KIMI_MCP_JSON_DST"
  report_item "references" "sync -> $REFERENCES_DST"
  report_item "templates" "sync -> $TEMPLATES_DST"
  report_item "manifest" "write -> $MANIFEST_DST"
  report_section "Backups"
  report_item "kernel" "$INSTALL_MEMORY_BACKUP"
  report_item "config" "$INSTALL_CONFIG_BACKUP"
  report_item "mcp" "$INSTALL_MCP_BACKUP"
  print_install_report_readiness
  print_shell_tool_recommendations
  print_install_report_next_steps "Kimi Code CLI"
}

runtime_uninstall_configs() {
  local kimi_config_path kimi_mcp_json_path
  kimi_config_path="$(manifest_path_value kimiConfig "$KIMI_CONFIG_DST")"
  kimi_mcp_json_path="$(manifest_path_value kimiMcpJson "$KIMI_MCP_JSON_DST")"
  remove_kimi_config_block "$kimi_config_path"
  remove_merged_config "$kimi_mcp_json_path" "$TEMPLATES_DST/mcp.user.template.json" "kimi mcp.json" "kimiMcpJson" "mcpAction"
}

remove_kimi_config_block() {
  local path="$1"
  [ -f "$path" ] || return 0

  if dry_run_enabled; then
    printf '[dry-run] remove managed Kimi config block from %s\n' "$path" >&2
    return 0
  fi

  local tmp rc
  tmp="$(mktemp "${TMPDIR:-/tmp}/b-agentic-kimi-uninstall.XXXXXX")"
  if env \
    KIMI_CONFIG_DST="$path" \
    KIMI_MANAGED_BEGIN="$KIMI_MANAGED_BEGIN" \
    KIMI_MANAGED_END="$KIMI_MANAGED_END" \
    JSON_TMP="$tmp" \
    python3 - <<'PY'
import os
from pathlib import Path

path = Path(os.environ['KIMI_CONFIG_DST'])
begin = os.environ['KIMI_MANAGED_BEGIN']
end = os.environ['KIMI_MANAGED_END']
tmp = Path(os.environ['JSON_TMP'])
text = path.read_text()

if begin not in text:
    raise SystemExit(2)
if end not in text:
    raise SystemExit('invalid Kimi config: missing managed block terminator')

prefix, remainder = text.split(begin, 1)
_managed_body, suffix = remainder.split(end, 1)
cleaned = (prefix + suffix).strip()
if not cleaned:
    raise SystemExit(3)
tmp.write_text(cleaned + '\n')
PY
  then
    rc=0
  else
    rc=$?
  fi

  if [ "$rc" -eq 2 ]; then
    rm -f "$tmp"
    return 0
  fi
  if [ "$rc" -eq 3 ]; then
    rm -f "$tmp"
    run_cmd rm -f "$path"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    warn "preserving modified Kimi config: $path"
    return 0
  fi

  run_cmd mv "$tmp" "$path"
}

runtime_install_extra_assets() { :; }

runtime_uninstall_extra_assets() { :; }

runtime_main() {
  runtime_install_common
}

runtime_uninstall() {
  runtime_uninstall_common
}
