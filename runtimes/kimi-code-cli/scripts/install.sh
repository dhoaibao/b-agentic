# Sourced by install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by install.sh" >&2
  exit 1
fi

readonly RUNTIME_UNINSTALL_LABEL="Kimi Code CLI personal config"
readonly RUNTIME_PRESERVE_LABEL="Kimi Code CLI"
readonly KIMI_DIR="${B_AGENTIC_KIMI_CODE_HOME:-${KIMI_CODE_HOME:-$HOME/.kimi-code}}"
readonly METADATA_DIR="$KIMI_DIR/b-agentic"
readonly BACKUPS_DIR="$METADATA_DIR/backups"
readonly SKILLS_DST="${B_AGENTIC_SKILLS_DST:-$KIMI_DIR/skills}"
readonly KERNEL_DST="$KIMI_DIR/b-agentic-kernel.md"
readonly KERNEL_SNAPSHOT_DST="$METADATA_DIR/b-agentic-kernel.md"
readonly REFERENCES_DST="$METADATA_DIR/references"
readonly TEMPLATES_DST="$METADATA_DIR/templates"
readonly MANIFEST_DST="$METADATA_DIR/install.json"
readonly KIMI_CONFIG_DST="${B_AGENTIC_KIMI_CONFIG:-$KIMI_DIR/config.toml}"
readonly KIMI_CONFIG_BACKUP_KEY="kimiConfig"
readonly KIMI_HOOK_SRC="$SOURCE_DIR/runtimes/$RUNTIME/hooks/inject-kernel.py"
readonly KIMI_HOOK_DST="$METADATA_DIR/hooks/inject-kernel.py"

readonly MCP_CONFIG_DST="${B_AGENTIC_KIMI_MCP_JSON:-$KIMI_DIR/mcp.json}"
readonly MCP_ROOT_KEY="mcpServers"
readonly MCP_PLACEHOLDER_STYLE="claude"
readonly MCP_CONTEXT7_SECTION="headers"
readonly MCP_BRAVE_SECTION="env"
readonly MCP_FIRECRAWL_SECTION="env"
readonly MCP_BACKUP_KEY="kimiMcpJson"

readonly KIMI_MANAGED_BEGIN="# BEGIN b-agentic managed config"
readonly KIMI_MANAGED_END="# END b-agentic managed config"

CONTEXT7_API_KEY_INPUT=""
BRAVE_API_KEY_INPUT=""
FIRECRAWL_API_KEY_INPUT=""
INSTALL_CONFIG_ACTION="skip"
INSTALL_CONFIG_STATE="none"
INSTALL_CONFIG_BACKUP="none"
INSTALL_MCP_ACTION="skip"
INSTALL_MCP_STATE="none"
INSTALL_MCP_BACKUP="none"

runtime_warn_missing_cli() {
  command -v kimi >/dev/null 2>&1 || warn "kimi CLI not found; files will still be installed for Kimi Code CLI to discover later."
}

runtime_install_config_stage_count() {
  printf '2'
}

runtime_require_tomllib() {
  python3 - <<'PY' >/dev/null 2>&1 || die "Kimi Code CLI install requires Python 3.11+ (stdlib tomllib)."
import tomllib
PY
}

install_kimi_hook_script() {
  [ -f "$KIMI_HOOK_SRC" ] || die "missing Kimi hook source: $KIMI_HOOK_SRC"
  copy_file "$KIMI_HOOK_SRC" "$KIMI_HOOK_DST"
}

toml_string() {
  python3 - "$1" <<'PY'
import json
import sys
print(json.dumps(sys.argv[1]))
PY
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
    KIMI_HOOK_DST="$KIMI_HOOK_DST" \
    KERNEL_DST="$KERNEL_DST" \
    JSON_TMP="$tmp" \
    python3 - <<'PY'
import json
import os
import tomllib
from pathlib import Path


def split_managed_block(text: str, begin: str, end: str) -> str:
    if begin not in text:
        return text
    if end not in text:
        raise SystemExit("invalid Kimi config: missing managed block terminator")
    prefix, remainder = text.split(begin, 1)
    _managed, suffix = remainder.split(end, 1)
    return prefix + suffix


def validate_toml(text: str, label: str) -> None:
    if not text.strip():
        return
    try:
        tomllib.loads(text)
    except tomllib.TOMLDecodeError as exc:
        raise SystemExit(f"invalid Kimi config {label}: {exc}")


path = Path(os.environ["KIMI_CONFIG_DST"])
begin = os.environ["KIMI_MANAGED_BEGIN"]
end = os.environ["KIMI_MANAGED_END"]
hook = os.environ["KIMI_HOOK_DST"]
kernel = os.environ["KERNEL_DST"]
tmp = Path(os.environ["JSON_TMP"])

current_text = path.read_text() if path.exists() else ""
base_text = split_managed_block(current_text, begin, end)
validate_toml(base_text, "user-owned portion")

command = f"python3 {json.dumps(hook)} {json.dumps(kernel)}"
managed = "\n".join([
    begin,
    "# Managed by b-agentic for Kimi Code CLI.",
    "# Remove by rerunning install.sh --runtime=kimi-code-cli --uninstall.",
    "",
    "[[hooks]]",
    'event = "UserPromptSubmit"',
    'matcher = ".*"',
    f"command = {json.dumps(command)}",
    "timeout = 5",
    "",
    "[[permission.rules]]",
    'decision = "deny"',
    'pattern = "Bash(rm -rf*)" ',
    'reason = "b-agentic blocks obviously destructive shell commands"',
    "",
    "[[permission.rules]]",
    'decision = "deny"',
    'pattern = "Bash(git reset --hard*)" ',
    'reason = "b-agentic blocks destructive git history/worktree resets"',
    "",
    end,
])

parts = [base_text.strip(), managed]
next_text = "\n\n".join(part for part in parts if part).strip() + "\n"
validate_toml(next_text, "with managed block")
tmp.write_text(next_text)
PY
  then
    rc=0
  else
    rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    die "failed to merge Kimi config: $KIMI_CONFIG_DST"
  fi

  if [ "$existed" -eq 1 ]; then
    backup="$(backup_file "$KIMI_CONFIG_DST")"
  fi
  run_cmd mv "$tmp" "$KIMI_CONFIG_DST"
  printf '%s\nactive\n%s' "$action" "${backup:-none}"
}

runtime_install_extra_assets() {
  install_kimi_hook_script
}

runtime_install_configs() {
  run_install_triplet_stage "Merging MCP config" install_mcp_config "skip" "none" "none" \
    INSTALL_MCP_ACTION INSTALL_MCP_STATE INSTALL_MCP_BACKUP
  run_install_triplet_stage "Merging Kimi config" install_kimi_config "skip" "none" "none" \
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
    KIMI_MCP_DST="$MCP_CONFIG_DST" \
    KIMI_HOOK_DST="$KIMI_HOOK_DST" \
    KERNEL_DST="$KERNEL_DST" \
    SKILLS_DST="$SKILLS_DST" \
    REFERENCES_DST="$REFERENCES_DST" \
    TEMPLATES_DST="$TEMPLATES_DST" \
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
    'paths': {
        'kimiDir': os.environ['KIMI_DIR'],
        'kimiConfig': os.environ['KIMI_CONFIG_DST'],
        'kimiMcpJson': os.environ['KIMI_MCP_DST'],
        'kernel': os.environ['KERNEL_DST'],
        'kernelHook': os.environ['KIMI_HOOK_DST'],
        'skills': os.environ['SKILLS_DST'],
        'references': os.environ['REFERENCES_DST'],
        'templates': os.environ['TEMPLATES_DST'],
    },
    'skills': skills,
    'hooks': ['inject-kernel'],
    'backups': {
        'bAgenticKernel': os.environ['MEMORY_BACKUP'],
        'kimiMcpJson': os.environ['MCP_BACKUP'],
        'kimiConfig': os.environ['CONFIG_BACKUP'],
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
  report_item "kernel-hook" "$INSTALL_CONFIG_STATE -> $KIMI_CONFIG_DST"
  report_item "mcp" "$INSTALL_MCP_ACTION -> $MCP_CONFIG_DST"
  report_item "references" "sync -> $REFERENCES_DST"
  report_item "templates" "sync -> $TEMPLATES_DST"
  report_item "manifest" "write -> $MANIFEST_DST"
  report_section "Backups"
  report_item "kernel" "$INSTALL_MEMORY_BACKUP"
  report_item "mcp" "$INSTALL_MCP_BACKUP"
  report_item "config" "$INSTALL_CONFIG_BACKUP"
  print_install_report_readiness
  report_item "kimi-hooks" "UserPromptSubmit is fail-open; restart Kimi and verify the kernel hook if activation matters"
  print_shell_tool_recommendations
  print_install_report_next_steps "Kimi Code CLI"
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

runtime_uninstall_configs() {
  local kimi_config_path kimi_mcp_path
  kimi_config_path="$(manifest_path_value kimiConfig "$KIMI_CONFIG_DST")"
  kimi_mcp_path="$(manifest_path_value kimiMcpJson "$MCP_CONFIG_DST")"
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
