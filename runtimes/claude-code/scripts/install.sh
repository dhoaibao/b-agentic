# Sourced by install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by install.sh" >&2
  exit 1
fi

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

CONTEXT7_API_KEY_INPUT=""
BRAVE_API_KEY_INPUT=""
FIRECRAWL_API_KEY_INPUT=""

mcp_secret_configured() {
  local server="$1" section="$2" key="$3"
  [ -f "$CLAUDE_JSON_DST" ] || return 1
  python3 - "$CLAUDE_JSON_DST" "$server" "$section" "$key" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
server, section, key = sys.argv[2:5]
try:
    data = json.loads(path.read_text())
except Exception:
    sys.exit(1)

value = (
    data.get('mcpServers', {})
    .get(server, {})
    .get(section, {})
    .get(key)
)
if isinstance(value, str) and value and not value.startswith('${'):
    sys.exit(0)
sys.exit(1)
PY
}

prompt_secret() {
  local label="$1" value=""
  printf '%s (leave blank to skip): ' "$label" > /dev/tty
  IFS= read -r -s value < /dev/tty || value=""
  printf '\n' > /dev/tty
  printf '%s' "$value"
}

collect_api_keys() {
  can_prompt_api_keys || return 0

  printf '\nOptional MCP API keys. Values are written to %s and never to tracked templates.\n' "$CLAUDE_JSON_DST" > /dev/tty
  if ! mcp_secret_configured context7 headers CONTEXT7_API_KEY; then
    CONTEXT7_API_KEY_INPUT="$(prompt_secret 'Context7 API key')"
  fi
  if ! mcp_secret_configured brave-search env BRAVE_API_KEY; then
    BRAVE_API_KEY_INPUT="$(prompt_secret 'Brave Search API key')"
  fi
  if ! mcp_secret_configured firecrawl env FIRECRAWL_API_KEY; then
    FIRECRAWL_API_KEY_INPUT="$(prompt_secret 'Firecrawl API key')"
  fi
}

print_install_report() {
  local activation_state="$1" skill_count="$2" memory_action="$3" memory_backup="$4" settings_action="$5" settings_backup="$6" mcp_action="$7" mcp_backup="$8"

  log ""
  log "b-agentic Claude Code install complete"
  log "skillsSynced: $skill_count -> $SKILLS_DST"
  log "kernel: $memory_action -> $KERNEL_DST"
  log "settings: $settings_action -> $SETTINGS_DST"
  log "mcp: $mcp_action -> $CLAUDE_JSON_DST"
  log "references: sync -> $REFERENCES_DST"
  log "templates: sync -> $TEMPLATES_DST"
  log "manifest: write -> $MANIFEST_DST"
  log "backups:"
  log "  kernel: $memory_backup"
  log "  settings: $settings_backup"
  log "  mcp: $mcp_backup"
  log "activationState: $activation_state"
}

install_settings_config() {
  merge_json_file "$TEMPLATES_SRC/settings.template.json" "$SETTINGS_DST" "settings" "settings"
}

install_mcp_config() {
  merge_json_file "$TEMPLATES_SRC/mcp.user.template.json" "$CLAUDE_JSON_DST" "mcp" "claudeJson"
}

apply_prompted_mcp_keys() {
  local action="$1" current_backup="$2"
  if [ -z "$CONTEXT7_API_KEY_INPUT" ] && [ -z "$BRAVE_API_KEY_INPUT" ] && [ -z "$FIRECRAWL_API_KEY_INPUT" ]; then
    printf 'none'
    return 0
  fi
  if dry_run_enabled; then
    printf 'none'
    return 0
  fi

  local tmp rc
  tmp="$(mktemp "${TMPDIR:-/tmp}/b-agentic-mcp-keys.XXXXXX")"
  chmod 600 "$tmp"
  if env \
    CLAUDE_JSON_DST="$CLAUDE_JSON_DST" \
    JSON_TMP="$tmp" \
    CONTEXT7_API_KEY_INPUT="$CONTEXT7_API_KEY_INPUT" \
    BRAVE_API_KEY_INPUT="$BRAVE_API_KEY_INPUT" \
    FIRECRAWL_API_KEY_INPUT="$FIRECRAWL_API_KEY_INPUT" \
    python3 - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ['CLAUDE_JSON_DST'])
tmp = Path(os.environ['JSON_TMP'])
data = json.loads(path.read_text())
servers = data.setdefault('mcpServers', {})

updates = {
    ('context7', 'headers', 'CONTEXT7_API_KEY'): os.environ.get('CONTEXT7_API_KEY_INPUT', ''),
    ('brave-search', 'env', 'BRAVE_API_KEY'): os.environ.get('BRAVE_API_KEY_INPUT', ''),
    ('firecrawl', 'env', 'FIRECRAWL_API_KEY'): os.environ.get('FIRECRAWL_API_KEY_INPUT', ''),
}

for (server_name, section_name, key_name), value in updates.items():
    if not value:
        continue
    server = servers.setdefault(server_name, {})
    section = server.setdefault(section_name, {})
    section[key_name] = value

if json.loads(path.read_text()) == data:
    raise SystemExit(2)
tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')
PY
  then
    rc=0
  else
    rc=$?
  fi

  if [ "$rc" -eq 2 ]; then
    rm -f "$tmp"
    printf 'none'
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    die "failed to write prompted MCP API keys: $CLAUDE_JSON_DST"
  fi

  local backup="$current_backup"
  if [ "$action" != "write" ] && [ "$backup" = "none" ]; then
    backup="$(backup_file "$CLAUDE_JSON_DST")"
  fi
  run_cmd mv "$tmp" "$CLAUDE_JSON_DST"
  printf '%s' "${backup:-none}"
}

write_manifest() {
  local memory_action="$1" activation_state="$2" memory_backup="$3" settings_action="$4" settings_state="$5" settings_backup="$6" mcp_action="$7" mcp_state="$8" mcp_backup="$9"
  shift 9
  local skills=("$@")

  if dry_run_enabled; then
    printf '[dry-run] write manifest %s\n' "$MANIFEST_DST" >&2
    return 0
  fi

  ensure_dir "$METADATA_DIR"
  env \
    MANIFEST_DST="$MANIFEST_DST" \
    TIMESTAMP="$TIMESTAMP" \
    RUNTIME="$RUNTIME" \
    MEMORY_ACTION="$memory_action" \
    ACTIVATION_STATE="$activation_state" \
    MEMORY_BACKUP="$memory_backup" \
    SETTINGS_ACTION="$settings_action" \
    SETTINGS_STATE="$settings_state" \
    SETTINGS_BACKUP="$settings_backup" \
    MCP_ACTION="$mcp_action" \
    MCP_STATE="$mcp_state" \
    MCP_BACKUP="$mcp_backup" \
    CLAUDE_DIR="$CLAUDE_DIR" \
    CLAUDE_JSON_DST="$CLAUDE_JSON_DST" \
    SKILLS_DST="$SKILLS_DST" \
    REFERENCES_DST="$REFERENCES_DST" \
    TEMPLATES_DST="$TEMPLATES_DST" \
    KERNEL_DST="$KERNEL_DST" \
    SETTINGS_DST="$SETTINGS_DST" \
    SKILLS="${skills[*]}" \
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

runtime_uninstall() {
  require_bin python3
  log "Uninstalling b-agentic from Claude Code personal config"
  local name
  if [ -f "$MANIFEST_DST" ]; then
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      run_cmd rm -rf "$SKILLS_DST/$name"
    done < <(python3 - "$MANIFEST_DST" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text())
except Exception:
    data = {}
for name in data.get('skills', []):
    print(name)
PY
)
  else
    for name in b-orchestrate b-plan b-research b-implement b-refactor b-debug b-test b-browser b-review b-audit b-ship; do
      run_cmd rm -rf "$SKILLS_DST/$name"
    done
  fi

  remove_managed_kernel
  local settings_path claude_json_path
  settings_path="$(manifest_path_value settings "$SETTINGS_DST")"
  claude_json_path="$(manifest_path_value claudeJson "$CLAUDE_JSON_DST")"
  remove_merged_config "$settings_path" "$TEMPLATES_DST/settings.template.json" "settings.json" "settings" "settingsAction"
  remove_merged_config "$claude_json_path" "$TEMPLATES_DST/mcp.user.template.json" ".claude.json" "claudeJson" "mcpAction"
  run_cmd rm -rf "$METADATA_DIR"
  log "Uninstall complete. User-owned Claude Code files were preserved."
}

runtime_main() {
  command -v claude >/dev/null 2>&1 || warn "claude CLI not found; files will still be installed for Claude Code to discover later."

  local skill
  local installed_skills=()
  while IFS= read -r skill; do
    [ -n "$skill" ] || continue
    installed_skills+=("$skill")
  done < <(skill_names)
  install_skills

  install_references_and_templates

  local kernel_result memory_action activation_state memory_backup
  local -a kernel_lines
  kernel_result="$(install_kernel)"
  readarray -t kernel_lines <<< "$kernel_result"
  memory_action="${kernel_lines[0]:-preserve}"
  activation_state="${kernel_lines[1]:-pending}"
  memory_backup="${kernel_lines[2]:-none}"

  local settings_result settings_action settings_state settings_backup
  local -a settings_lines
  settings_result="$(install_settings_config)"
  readarray -t settings_lines <<< "$settings_result"
  settings_action="${settings_lines[0]:-skip}"
  settings_state="${settings_lines[1]:-none}"
  settings_backup="${settings_lines[2]:-none}"

  local mcp_result mcp_action mcp_state mcp_backup
  local -a mcp_lines
  mcp_result="$(install_mcp_config)"
  readarray -t mcp_lines <<< "$mcp_result"
  mcp_action="${mcp_lines[0]:-skip}"
  mcp_state="${mcp_lines[1]:-none}"
  mcp_backup="${mcp_lines[2]:-none}"
  collect_api_keys
  prompted_mcp_backup="$(apply_prompted_mcp_keys "$mcp_action" "$mcp_backup")"
  if [ "$prompted_mcp_backup" != "none" ]; then
    mcp_backup="$prompted_mcp_backup"
  fi

  write_manifest "$memory_action" "$activation_state" "$memory_backup" "$settings_action" "$settings_state" "$settings_backup" "$mcp_action" "$mcp_state" "$mcp_backup" "${installed_skills[@]}"

  print_install_report "$activation_state" "${#installed_skills[@]}" "$memory_action" "$memory_backup" "$settings_action" "$settings_backup" "$mcp_action" "$mcp_backup"
  ensure_repo_gitignore_guard
  if [ "$activation_state" = "pending" ]; then
    log "Existing $KERNEL_DST was preserved. Review $KERNEL_SNAPSHOT_DST and rerun with --replace-memory to activate the kernel."
    return 2
  fi
}
