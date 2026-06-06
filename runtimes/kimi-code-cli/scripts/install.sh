# Sourced by install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by install.sh" >&2
  exit 1
fi

readonly RUNTIME_UNINSTALL_LABEL="Kimi Code CLI personal config"
readonly RUNTIME_PRESERVE_LABEL="Kimi Code CLI"
readonly KIMI_DIR="${B_AGENTIC_KIMI_CODE_DIR:-${KIMI_CODE_HOME:-$HOME/.kimi-code}}"
readonly METADATA_DIR="$KIMI_DIR/b-agentic"
readonly BACKUPS_DIR="$METADATA_DIR/backups"
readonly SKILLS_DST="$KIMI_DIR/skills"
readonly KERNEL_DST="$KIMI_DIR/AGENTS.md"
readonly KERNEL_SNAPSHOT_DST="$METADATA_DIR/AGENTS.md"
readonly REFERENCES_DST="$METADATA_DIR/references"
readonly TEMPLATES_DST="$METADATA_DIR/templates"
readonly MANIFEST_DST="$METADATA_DIR/install.json"
readonly RUNTIME_PRE_ACTION_ENFORCEMENT="advisory-only"
readonly KIMI_CONFIG_DST="${B_AGENTIC_KIMI_CONFIG:-$KIMI_DIR/config.toml}"
readonly MCP_CONFIG_DST="${B_AGENTIC_KIMI_MCP_CONFIG:-$KIMI_DIR/mcp.json}"
readonly MCP_ROOT_KEY="mcpServers"
readonly MCP_PLACEHOLDER_STYLE="claude"
readonly MCP_CONTEXT7_SECTION="headers"
readonly MCP_BRAVE_SECTION="env"
readonly MCP_FIRECRAWL_SECTION="env"
readonly MCP_BACKUP_KEY="kimiMcp"
readonly KIMI_CONFIG_BACKUP_KEY="kimiConfig"
readonly HOOK_CHECKER_DST="$METADATA_DIR/hooks/check-runtime.py"

readonly KIMI_MANAGED_BEGIN="# BEGIN b-agentic managed config"
readonly KIMI_MANAGED_END="# END b-agentic managed config"

CONTEXT7_API_KEY_INPUT=""
BRAVE_API_KEY_INPUT=""
FIRECRAWL_API_KEY_INPUT=""
FIRECRAWL_API_URL_INPUT=""
INSTALL_CONFIG_ACTION="skip"
INSTALL_CONFIG_STATE="none"
INSTALL_CONFIG_BACKUP="none"
INSTALL_MCP_ACTION="skip"
INSTALL_MCP_STATE="none"
INSTALL_MCP_BACKUP="none"

runtime_require_tomllib() {
  python3 - <<'PY' >/dev/null 2>&1 || die "Kimi Code CLI install requires Python 3.11+ (stdlib tomllib)."
import tomllib
PY
}

runtime_warn_missing_cli() {
  command -v kimi >/dev/null 2>&1 || warn "kimi CLI not found; files will still be installed for Kimi Code CLI to discover later."
}

runtime_install_config_stage_count() {
  printf '2'
}

install_kimi_config() {
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
    KIMI_MANAGED_BEGIN="$KIMI_MANAGED_BEGIN" \
    KIMI_MANAGED_END="$KIMI_MANAGED_END" \
    HOOK_CHECKER_DST="$HOOK_CHECKER_DST" \
    SOURCE_DIR="$SOURCE_DIR" \
    JSON_TMP="$tmp" \
    python3 - <<'PY'
import json
import os
import tomllib
from pathlib import Path


def load_toml(text: str, label: str):
    if not text.strip():
        return {}
    try:
        return tomllib.loads(text)
    except tomllib.TOMLDecodeError as exc:
        raise SystemExit(f"invalid Kimi config {label}: {exc}")


def split_managed_block(text: str, begin: str, end: str) -> tuple[str, str]:
    if begin not in text:
        return text, ""
    if end not in text:
        raise SystemExit("invalid Kimi config: missing managed block terminator")
    prefix, remainder = text.split(begin, 1)
    managed_body, suffix = remainder.split(end, 1)
    return prefix + suffix, begin + managed_body + end


path = Path(os.environ["KIMI_CONFIG_DST"])
begin = os.environ["KIMI_MANAGED_BEGIN"]
end = os.environ["KIMI_MANAGED_END"]
hook_checker = os.environ["HOOK_CHECKER_DST"]
source_dir = os.environ["SOURCE_DIR"]
current_text = path.read_text() if path.exists() else ""
base_text, _managed_text = split_managed_block(current_text, begin, end)
load_toml(base_text, "user-owned portion")

hook_check_command = f"python3 {json.dumps(hook_checker)} --client kimi-code-cli --event stop --source {json.dumps(source_dir)}"
lines = [
    begin,
    "# Managed by b-agentic for Kimi Code CLI.",
    "# Remove by rerunning install.sh --runtime=kimi-code-cli --uninstall.",
    "",
    "[[hooks]]",
    'event = "Stop"',
    f"command = {json.dumps(hook_check_command)}",
    'matcher = ""',
    "timeout = 30",
    "",
]

while lines and lines[-1] == "":
    lines.pop()
lines.append(end)

managed_block = "\n".join(lines)
base_stripped = base_text.strip()
final_text = managed_block if not base_stripped else base_stripped + "\n\n" + managed_block
final_text += "\n"

load_toml(final_text, "rendered output")
if final_text == current_text:
    raise SystemExit(2)

Path(os.environ["JSON_TMP"]).write_text(final_text)
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

runtime_install_extra_assets() {
  install_hook_checker
}

runtime_install_configs() {
  run_install_triplet_stage "Merging Kimi MCP config" install_mcp_config "skip" "none" "none" \
    INSTALL_MCP_ACTION INSTALL_MCP_STATE INSTALL_MCP_BACKUP
  run_install_triplet_stage "Updating Kimi config" install_kimi_config "skip" "none" "none" \
    INSTALL_CONFIG_ACTION INSTALL_CONFIG_STATE INSTALL_CONFIG_BACKUP
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
    KIMI_DIR="$KIMI_DIR" \
    KIMI_CONFIG_DST="$KIMI_CONFIG_DST" \
    MCP_CONFIG_DST="$MCP_CONFIG_DST" \
    SKILLS_DST="$SKILLS_DST" \
    REFERENCES_DST="$REFERENCES_DST" \
    TEMPLATES_DST="$TEMPLATES_DST" \
    HOOK_CHECKER_DST="$HOOK_CHECKER_DST" \
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
    'configAction': os.environ['CONFIG_ACTION'],
    'configState': os.environ['CONFIG_STATE'],
    'hooksState': os.environ['CONFIG_STATE'],
    'paths': {
        'kimiDir': os.environ['KIMI_DIR'],
        'kimiConfig': os.environ['KIMI_CONFIG_DST'],
        'kimiMcp': os.environ['MCP_CONFIG_DST'],
        'kernel': os.environ['KERNEL_DST'],
        'skills': os.environ['SKILLS_DST'],
        'references': os.environ['REFERENCES_DST'],
        'templates': os.environ['TEMPLATES_DST'],
        'hookChecker': os.environ['HOOK_CHECKER_DST'],
    },
    'skills': skills,
    'backups': {
        'agentsMd': os.environ['MEMORY_BACKUP'],
        'kimiConfig': os.environ['CONFIG_BACKUP'],
        'kimiMcp': os.environ['MCP_BACKUP'],
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
  report_item "mcp" "$INSTALL_MCP_ACTION -> $MCP_CONFIG_DST"
  report_item "config" "$INSTALL_CONFIG_ACTION -> $KIMI_CONFIG_DST"
  report_item "hooks" "$INSTALL_CONFIG_STATE; Kimi hooks are fail-open"
  report_item "references" "sync -> $REFERENCES_DST"
  report_item "templates" "sync -> $TEMPLATES_DST"
  report_item "manifest" "write -> $MANIFEST_DST"
  report_section "Backups"
  report_item "kernel" "$INSTALL_MEMORY_BACKUP"
  report_item "mcp" "$INSTALL_MCP_BACKUP"
  report_item "config" "$INSTALL_CONFIG_BACKUP"
  print_install_report_readiness
  report_item "kimi-hooks" "fail-open by design; use Kimi permission mode/manual approval for high-risk operations"
  print_shell_tool_recommendations
  print_install_report_next_steps "Kimi Code CLI"
}

runtime_uninstall_configs() {
  local kimi_config_path kimi_mcp_path
  kimi_config_path="$(manifest_path_value kimiConfig "$KIMI_CONFIG_DST")"
  kimi_mcp_path="$(manifest_path_value kimiMcp "$MCP_CONFIG_DST")"
  remove_kimi_config_block "$kimi_config_path"
  remove_merged_config "$kimi_mcp_path" "$TEMPLATES_DST/mcp.user.template.json" "mcp" "$MCP_BACKUP_KEY" "mcpAction"
}

runtime_main() {
  runtime_require_tomllib
  runtime_install_common
}

runtime_uninstall() {
  runtime_uninstall_common
}
