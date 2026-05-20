#!/usr/bin/env bash
# install.sh — Bootstrap or update b-agentic for OpenCode
# Usage:
#   First time / update:
#     curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash
#
# Optional environment overrides:
#   B_AGENTIC_REPO  — git URL to clone (default: https://github.com/dhoaibao/b-agentic.git)
#   B_AGENTIC_DIR   — local clone path (default: $HOME/.b-agentic)
#   B_AGENTIC_REF   — git ref to check out after clone/pull (default: leave on default branch)
#   B_AGENTIC_INSTALL_MCP — Y to install core MCP defaults; otherwise skipped
#   B_AGENTIC_INSTALL_GITNEXUS — Y to install optional GitNexus MCP when MCP defaults are enabled
#   B_AGENTIC_INSTALL_PLAYWRIGHT_MCP — Y to install optional Playwright MCP for /b-browser when MCP defaults are enabled
#   B_AGENTIC_DRY_RUN — Y to preview file/config changes without writing into OpenCode config
#   B_AGENTIC_REPLACE_AGENTS — Y to replace ~/.config/opencode/AGENTS.md without prompting; N to preserve it
#   B_AGENTIC_UNINSTALL — Y to remove b-agentic-managed files from OpenCode config
#   Legacy B_NEXUS_* and B_SKILLS_* environment variables are still honored as fallbacks.
#   BRAVE_API_KEY  — Brave Search MCP API key
#   CONTEXT7_API_KEY — Context7 MCP API key
#   FIRECRAWL_API_KEY — Firecrawl MCP API key
#
# Optional CLI flags:
#   --dry-run         Preview install changes without writing them
#   --replace-agents  Replace ~/.config/opencode/AGENTS.md without prompting
#   --preserve-agents Never replace ~/.config/opencode/AGENTS.md
#   --uninstall       Remove b-agentic-managed files from OpenCode config

set -euo pipefail

readonly REPO_URL="${B_AGENTIC_REPO:-${B_NEXUS_REPO:-${B_SKILLS_REPO:-https://github.com/dhoaibao/b-agentic.git}}}"
readonly LOCAL_REPO="${B_AGENTIC_DIR:-${B_NEXUS_DIR:-${B_SKILLS_DIR:-$HOME/.b-agentic}}}"
readonly REF="${B_AGENTIC_REF:-${B_NEXUS_REF:-${B_SKILLS_REF:-}}}"
readonly OPENCODE_DIR="$HOME/.config/opencode"
readonly B_AGENTIC_METADATA_DIR="$OPENCODE_DIR/b-agentic"
readonly B_AGENTIC_BACKUPS_DIR="$B_AGENTIC_METADATA_DIR/backups"
readonly LEGACY_B_NEXUS_METADATA_DIR="$OPENCODE_DIR/b-nexus"
readonly LEGACY_B_NEXUS_BACKUPS_DIR="$LEGACY_B_NEXUS_METADATA_DIR/backups"
readonly LEGACY_B_SKILLS_METADATA_DIR="$OPENCODE_DIR/b-skills"
readonly LEGACY_B_SKILLS_BACKUPS_DIR="$LEGACY_B_SKILLS_METADATA_DIR/backups"
readonly SKILLS_SRC="$LOCAL_REPO/skills"
readonly COMMANDS_SRC="$LOCAL_REPO/commands"
readonly REFERENCES_SRC="$LOCAL_REPO/references"
readonly RULES_SRC="$LOCAL_REPO/global/AGENTS.md"
readonly RULES_DST="$OPENCODE_DIR/AGENTS.md"
readonly RULES_SNAPSHOT_DST="$B_AGENTIC_METADATA_DIR/AGENTS.md"
readonly REFERENCES_DST="$OPENCODE_DIR/references/b-agentic"
readonly RUNTIME_CONTRACT_DST="$REFERENCES_DST/runtime-contract.md"
readonly CONFIG_FILE="$OPENCODE_DIR/opencode.json"
readonly INSTALL_MANIFEST="$B_AGENTIC_METADATA_DIR/install.json"
readonly LEGACY_B_NEXUS_RULES_SNAPSHOT_DST="$LEGACY_B_NEXUS_METADATA_DIR/AGENTS.md"
readonly LEGACY_B_NEXUS_REFERENCES_DST="$OPENCODE_DIR/references/b-nexus"
readonly LEGACY_B_NEXUS_INSTALL_MANIFEST="$LEGACY_B_NEXUS_METADATA_DIR/install.json"
readonly LEGACY_B_SKILLS_RULES_SNAPSHOT_DST="$LEGACY_B_SKILLS_METADATA_DIR/AGENTS.md"
readonly LEGACY_B_SKILLS_REFERENCES_DST="$OPENCODE_DIR/references/b-skills"
readonly LEGACY_B_SKILLS_INSTALL_MANIFEST="$LEGACY_B_SKILLS_METADATA_DIR/install.json"
readonly LEGACY_RULES_SNAPSHOT_DST="$OPENCODE_DIR/AGENTS.b-skills.md"
readonly LEGACY_INSTALL_MANIFEST="$OPENCODE_DIR/b-skills-install.json"
readonly TIMESTAMP="$(date +%Y%m%d%H%M%S)"

log()     { printf '%s
' "$*"; }
section() { printf '
[%s]
' "$*"; }
warn()    { printf '⚠️  %s
' "$*" >&2; }
die()     { printf '❌ %s
' "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      B_AGENTIC_DRY_RUN=Y
      ;;
    --replace-agents)
      B_AGENTIC_REPLACE_AGENTS=Y
      ;;
    --preserve-agents)
      B_AGENTIC_REPLACE_AGENTS=N
      ;;
    --uninstall)
      B_AGENTIC_UNINSTALL=Y
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
  shift
done

trap 'rc=$?; [ $rc -ne 0 ] && warn "install.sh failed at line $LINENO (exit $rc)"' EXIT

BRAVE_API_KEY_VALUE="${BRAVE_API_KEY:-}"
CONTEXT7_API_KEY_VALUE="${CONTEXT7_API_KEY:-}"
FIRECRAWL_API_KEY_VALUE="${FIRECRAWL_API_KEY:-}"
INSTALL_MCPS_VALUE="${B_AGENTIC_INSTALL_MCP:-${B_NEXUS_INSTALL_MCP:-${B_SKILLS_INSTALL_MCP:-}}}"
INSTALL_GITNEXUS_VALUE="${B_AGENTIC_INSTALL_GITNEXUS:-${B_NEXUS_INSTALL_GITNEXUS:-${B_SKILLS_INSTALL_GITNEXUS:-}}}"
INSTALL_PLAYWRIGHT_VALUE="${B_AGENTIC_INSTALL_PLAYWRIGHT_MCP:-}"
DRY_RUN_VALUE="${B_AGENTIC_DRY_RUN:-${B_NEXUS_DRY_RUN:-${B_SKILLS_DRY_RUN:-N}}}"
REPLACE_AGENTS_VALUE="${B_AGENTIC_REPLACE_AGENTS:-${B_NEXUS_REPLACE_AGENTS:-${B_SKILLS_REPLACE_AGENTS:-}}}"
UNINSTALL_VALUE="${B_AGENTIC_UNINSTALL:-${B_NEXUS_UNINSTALL:-${B_SKILLS_UNINSTALL:-N}}}"
CUSTOM_PROVIDER_ENABLED_VALUE="N"
CUSTOM_PROVIDER_ID_VALUE=""
CUSTOM_PROVIDER_NAME_VALUE=""
CUSTOM_PROVIDER_BASE_URL_VALUE=""
CUSTOM_PROVIDER_API_KEY_VALUE=""
CUSTOM_PROVIDER_MODELS_VALUE=""
CUSTOM_PROVIDER_DELETE_MODELS_VALUE=""
AGENTS_INSTALL_ACTION="preserve"
RUNTIME_ACTIVATION_STATE="active"
RULES_BACKUP_PATH="none"
CONFIG_BACKUP_PATH="none"

require_bin() {
  command -v "$1" >/dev/null 2>&1 || die "Required binary not found: $1"
}

require_bin git
require_bin python3
command -v opencode >/dev/null 2>&1 || warn "opencode CLI not found — files will still be installed, but you should install OpenCode before using them."

is_placeholder_value() {
  local value="${1:-}"
  [ -z "$value" ] && return 0
  [[ "$value" == YOUR_* ]]
}

prompt_available() {
  [ -r /dev/tty ] && [ -w /dev/tty ] && ( exec 3<>/dev/tty ) >/dev/null 2>&1
}

resolve_existing_install_manifest() {
  if [ -f "$INSTALL_MANIFEST" ]; then
    printf '%s' "$INSTALL_MANIFEST"
    return 0
  fi

  if [ -f "$LEGACY_B_NEXUS_INSTALL_MANIFEST" ]; then
    printf '%s' "$LEGACY_B_NEXUS_INSTALL_MANIFEST"
    return 0
  fi

  if [ -f "$LEGACY_B_SKILLS_INSTALL_MANIFEST" ]; then
    printf '%s' "$LEGACY_B_SKILLS_INSTALL_MANIFEST"
    return 0
  fi

  if [ -f "$LEGACY_INSTALL_MANIFEST" ]; then
    printf '%s' "$LEGACY_INSTALL_MANIFEST"
    return 0
  fi

  return 1
}

resolve_existing_rules_snapshot() {
  if [ -f "$RULES_SNAPSHOT_DST" ]; then
    printf '%s' "$RULES_SNAPSHOT_DST"
    return 0
  fi

  if [ -f "$LEGACY_B_NEXUS_RULES_SNAPSHOT_DST" ]; then
    printf '%s' "$LEGACY_B_NEXUS_RULES_SNAPSHOT_DST"
    return 0
  fi

  if [ -f "$LEGACY_B_SKILLS_RULES_SNAPSHOT_DST" ]; then
    printf '%s' "$LEGACY_B_SKILLS_RULES_SNAPSHOT_DST"
    return 0
  fi

  if [ -f "$LEGACY_RULES_SNAPSHOT_DST" ]; then
    printf '%s' "$LEGACY_RULES_SNAPSHOT_DST"
    return 0
  fi

  return 1
}

resolve_legacy_install_manifest() {
  if [ -f "$LEGACY_B_NEXUS_INSTALL_MANIFEST" ]; then
    printf '%s' "$LEGACY_B_NEXUS_INSTALL_MANIFEST"
    return 0
  fi

  if [ -f "$LEGACY_B_SKILLS_INSTALL_MANIFEST" ]; then
    printf '%s' "$LEGACY_B_SKILLS_INSTALL_MANIFEST"
    return 0
  fi

  if [ -f "$LEGACY_INSTALL_MANIFEST" ]; then
    printf '%s' "$LEGACY_INSTALL_MANIFEST"
    return 0
  fi

  return 1
}

backup_path_for_file() {
  local file_path="$1"
  printf '%s/%s.bak-%s' "$B_AGENTIC_BACKUPS_DIR" "$(basename "$file_path")" "$TIMESTAMP"
}

wants_mcp_install() {
  local value="${1:-}"
  case "$value" in
    y|Y|yes|YES|Yes)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

wants_no() {
  local value="${1:-}"
  case "$value" in
    n|N|no|NO|No)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

dry_run_enabled() {
  wants_mcp_install "$DRY_RUN_VALUE"
}

ensure_dir() {
  local dir_path="$1"
  if dry_run_enabled; then
    log "[dry-run] mkdir -p $dir_path"
    return 0
  fi

  mkdir -p "$dir_path"
}

show_diff() {
  local before_file="$1" after_file="$2" label="$3"
  env BEFORE_FILE="$before_file" AFTER_FILE="$after_file" LABEL="$label" python3 - <<'PYEOF'
import difflib
import os
from pathlib import Path

before_path = Path(os.environ["BEFORE_FILE"])
after_path = Path(os.environ["AFTER_FILE"])
label = os.environ["LABEL"]

before_lines = before_path.read_text().splitlines()
after_lines = after_path.read_text().splitlines()

diff = list(
    difflib.unified_diff(
        before_lines,
        after_lines,
        fromfile=f"{label} (current)",
        tofile=f"{label} (new)",
        lineterm="",
    )
)

if diff:
    print("\n".join(diff))
PYEOF
}

announce_write() {
  local label="$1"
  if dry_run_enabled; then
    log "Preview for $label"
  fi
}

backup_file_if_needed() {
  local file_path="$1"
  local backup_path

  backup_path="$(backup_path_for_file "$file_path")"

  [ -f "$file_path" ] || {
    printf 'none'
    return 0
  }

  ensure_dir "$B_AGENTIC_BACKUPS_DIR"

  if dry_run_enabled; then
    log "[dry-run] backup $file_path -> $backup_path"
    printf '%s' "$backup_path"
    return 0
  fi

  cp "$file_path" "$backup_path"
  printf '%s' "$backup_path"
}

write_file_from_source() {
  local source_file="$1" target_file="$2" label="$3" backup_existing="${4:-N}"
  local before_file after_file

  [ -f "$source_file" ] || die "Missing source file: $source_file"

  ensure_dir "$(dirname "$target_file")"

  if [ -f "$target_file" ] && cmp -s "$source_file" "$target_file"; then
    log "✅ $label unchanged"
    return 0
  fi

  before_file=$(mktemp)
  after_file=$(mktemp)

  if [ -f "$target_file" ]; then
    cp "$target_file" "$before_file"
  else
    : > "$before_file"
  fi
  cp "$source_file" "$after_file"

  announce_write "$label"
  if dry_run_enabled; then
    show_diff "$before_file" "$after_file" "$label"
  fi

  if dry_run_enabled; then
    log "[dry-run] write $target_file"
    rm -f "$before_file" "$after_file"
    return 0
  fi

  if [ "$backup_existing" = "Y" ]; then
    backup_file_if_needed "$target_file" >/dev/null
  fi

  cp "$source_file" "$target_file"
  rm -f "$before_file" "$after_file"
  log "✅ $label updated"
}

write_text_file() {
  local target_file="$1" content="$2" label="$3" backup_existing="${4:-N}"
  local before_file after_file

  ensure_dir "$(dirname "$target_file")"

  before_file=$(mktemp)
  after_file=$(mktemp)

  if [ -f "$target_file" ]; then
    cp "$target_file" "$before_file"
  else
    : > "$before_file"
  fi

  printf '%s\n' "$content" > "$after_file"

  if cmp -s "$before_file" "$after_file"; then
    rm -f "$before_file" "$after_file"
    log "✅ $label unchanged"
    return 0
  fi

  announce_write "$label"
  if dry_run_enabled; then
    show_diff "$before_file" "$after_file" "$label"
  fi

  if dry_run_enabled; then
    log "[dry-run] write $target_file"
    rm -f "$before_file" "$after_file"
    return 0
  fi

  if [ "$backup_existing" = "Y" ]; then
    backup_file_if_needed "$target_file" >/dev/null
  fi

  printf '%s\n' "$content" > "$target_file"
  rm -f "$before_file" "$after_file"
  log "✅ $label updated"
}

decide_agents_install_action() {
  local entered_value

  if [ ! -f "$RULES_DST" ]; then
    AGENTS_INSTALL_ACTION="replace"
    return 0
  fi

  if cmp -s "$RULES_SRC" "$RULES_DST"; then
    AGENTS_INSTALL_ACTION="unchanged"
    return 0
  fi

  if wants_mcp_install "$REPLACE_AGENTS_VALUE"; then
    AGENTS_INSTALL_ACTION="replace"
    return 0
  fi

  if wants_no "$REPLACE_AGENTS_VALUE"; then
    AGENTS_INSTALL_ACTION="preserve"
    RUNTIME_ACTIVATION_STATE="pending"
    return 0
  fi

  if ! prompt_available; then
    AGENTS_INSTALL_ACTION="preserve"
    RUNTIME_ACTIVATION_STATE="pending"
    return 0
  fi

  printf 'Replace existing OpenCode AGENTS.md with the b-agentic runtime kernel? [y/N]: ' > /dev/tty
  if IFS= read -r entered_value < /dev/tty; then
    :
  else
    entered_value=""
  fi

  if wants_mcp_install "$entered_value"; then
    AGENTS_INSTALL_ACTION="replace"
    RUNTIME_ACTIVATION_STATE="active"
  else
    AGENTS_INSTALL_ACTION="preserve"
    RUNTIME_ACTIVATION_STATE="pending"
  fi
}

write_install_manifest() {
  local manifest_content
  manifest_content=$(env \
    TIMESTAMP="$TIMESTAMP" \
    DRY_RUN_VALUE="$DRY_RUN_VALUE" \
    AGENTS_INSTALL_ACTION="$AGENTS_INSTALL_ACTION" \
    RUNTIME_ACTIVATION_STATE="$RUNTIME_ACTIVATION_STATE" \
    RULES_SNAPSHOT_DST="$RULES_SNAPSHOT_DST" \
    RUNTIME_CONTRACT_DST="$RUNTIME_CONTRACT_DST" \
    RULES_DST="$RULES_DST" \
    CONFIG_FILE="$CONFIG_FILE" \
    RULES_BACKUP_PATH="$RULES_BACKUP_PATH" \
    CONFIG_BACKUP_PATH="$CONFIG_BACKUP_PATH" \
    INSTALL_MCPS_VALUE="$INSTALL_MCPS_VALUE" \
    INSTALL_GITNEXUS_VALUE="$INSTALL_GITNEXUS_VALUE" \
    INSTALL_PLAYWRIGHT_VALUE="$INSTALL_PLAYWRIGHT_VALUE" \
    CUSTOM_PROVIDER_ENABLED_VALUE="$CUSTOM_PROVIDER_ENABLED_VALUE" \
    CUSTOM_PROVIDER_ID_VALUE="$CUSTOM_PROVIDER_ID_VALUE" \
    python3 - <<'PYEOF'
import json
import os

def is_yes(value):
    return (value or "").strip().lower() in {"y", "yes"}

payload = {
    "suite": "b-agentic",
    "installedAt": os.environ["TIMESTAMP"],
    "dryRun": is_yes(os.environ.get("DRY_RUN_VALUE", "")),
    "agentsAction": os.environ.get("AGENTS_INSTALL_ACTION", "preserve"),
    "activationState": os.environ.get("RUNTIME_ACTIVATION_STATE", "active"),
    "managedPaths": {
        "metadataDir": "~/.config/opencode/b-agentic",
        "skillsDir": "~/.config/opencode/skills",
        "commandsDir": "~/.config/opencode/commands",
        "referencesDir": "~/.config/opencode/references/b-agentic",
        "runtimeKernel": os.environ["RULES_SNAPSHOT_DST"],
        "runtimeContract": os.environ["RUNTIME_CONTRACT_DST"],
        "suiteRules": os.environ["RULES_SNAPSHOT_DST"],
        "globalAgents": os.environ["RULES_DST"],
        "config": os.environ["CONFIG_FILE"],
    },
    "backups": {
        "globalAgents": os.environ.get("RULES_BACKUP_PATH", "none"),
        "config": os.environ.get("CONFIG_BACKUP_PATH", "none"),
    },
    "managedConfig": {
        "mcpDefaults": is_yes(os.environ.get("INSTALL_MCPS_VALUE", "")),
        "gitnexus": is_yes(os.environ.get("INSTALL_GITNEXUS_VALUE", "")),
        "playwright": is_yes(os.environ.get("INSTALL_PLAYWRIGHT_VALUE", "")),
        "customProvider": os.environ.get("CUSTOM_PROVIDER_ID_VALUE", "") if is_yes(os.environ.get("CUSTOM_PROVIDER_ENABLED_VALUE", "")) else "none",
    },
}

print(json.dumps(payload, indent=2))
PYEOF
  )

  write_text_file "$INSTALL_MANIFEST" "$manifest_content" "b-agentic install manifest"
}

prompt_mcp_install_if_needed() {
  local entered_value

  if wants_mcp_install "$INSTALL_MCPS_VALUE"; then
    INSTALL_MCPS_VALUE="Y"
    return 0
  fi

  if [ -n "$INSTALL_MCPS_VALUE" ]; then
    INSTALL_MCPS_VALUE="N"
    return 0
  fi

  if ! prompt_available; then
    INSTALL_MCPS_VALUE="N"
    return 0
  fi

  printf 'Install core MCP defaults (serena, context7, brave-search, firecrawl) in OpenCode config? [y/N]: ' > /dev/tty
  if IFS= read -r entered_value < /dev/tty; then
    :
  else
    entered_value=""
  fi

  if wants_mcp_install "$entered_value"; then
    INSTALL_MCPS_VALUE="Y"
  else
    INSTALL_MCPS_VALUE="N"
  fi
}

has_existing_mcp_server() {
  local server_name="$1"
  [ -f "$CONFIG_FILE" ] || return 1

  env CONFIG_FILE="$CONFIG_FILE" SERVER_NAME="$server_name" python3 - <<'PYEOF'
import json
import os
from pathlib import Path

config_path = Path(os.environ["CONFIG_FILE"])
server_name = os.environ["SERVER_NAME"]

def strip_jsonc_comments(text):
    result = []
    in_string = False
    string_char = ""
    escaped = False
    i = 0

    while i < len(text):
        char = text[i]
        next_char = text[i + 1] if i + 1 < len(text) else ""

        if in_string:
            result.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == string_char:
                in_string = False
            i += 1
            continue

        if char == '"':
            in_string = True
            string_char = char
            result.append(char)
            i += 1
            continue

        if char == "/" and next_char == "/":
            i += 2
            while i < len(text) and text[i] not in "\r\n":
                i += 1
            continue

        if char == "/" and next_char == "*":
            i += 2
            while i + 1 < len(text) and text[i:i + 2] != "*/":
                i += 1
            i += 2 if i + 1 < len(text) else 0
            continue

        result.append(char)
        i += 1

    return "".join(result)

def strip_trailing_commas(text):
    result = []
    in_string = False
    string_char = ""
    escaped = False
    i = 0

    while i < len(text):
        char = text[i]

        if in_string:
            result.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == string_char:
                in_string = False
            i += 1
            continue

        if char == '"':
            in_string = True
            string_char = char
            result.append(char)
            i += 1
            continue

        if char == ",":
            j = i + 1
            while j < len(text) and text[j] in " \t\r\n":
                j += 1
            if j < len(text) and text[j] in "]}":
                i += 1
                continue

        result.append(char)
        i += 1

    return "".join(result)

try:
    raw_text = config_path.read_text()
except (FileNotFoundError, OSError):
    raise SystemExit(1)

try:
    config = json.loads(raw_text)
except json.JSONDecodeError:
    normalized = strip_trailing_commas(strip_jsonc_comments(raw_text)).strip() or "{}"
    config = json.loads(normalized)

mcp = config.get("mcp", {})
if isinstance(mcp, dict) and server_name in mcp:
    raise SystemExit(0)

raise SystemExit(1)
PYEOF
}

prompt_gitnexus_install_if_needed() {
  local entered_value
  local default_choice="N"

  if ! wants_mcp_install "$INSTALL_MCPS_VALUE"; then
    INSTALL_GITNEXUS_VALUE="N"
    return 0
  fi

  if has_existing_mcp_server gitnexus; then
    default_choice="Y"
  fi

  if wants_mcp_install "$INSTALL_GITNEXUS_VALUE"; then
    INSTALL_GITNEXUS_VALUE="Y"
    return 0
  fi

  if [ -n "$INSTALL_GITNEXUS_VALUE" ]; then
    INSTALL_GITNEXUS_VALUE="N"
    return 0
  fi

  if ! prompt_available; then
    INSTALL_GITNEXUS_VALUE="$default_choice"
    return 0
  fi

  if [ "$default_choice" = "Y" ]; then
    printf 'Install optional GitNexus graph radar for indexed-repo impact/architecture tasks? [Y/n]: ' > /dev/tty
  else
    printf 'Install optional GitNexus graph radar for indexed-repo impact/architecture tasks? [y/N]: ' > /dev/tty
  fi
  if IFS= read -r entered_value < /dev/tty; then
    :
  else
    entered_value=""
  fi

  if [ -z "$entered_value" ]; then
    INSTALL_GITNEXUS_VALUE="$default_choice"
  elif wants_mcp_install "$entered_value"; then
    INSTALL_GITNEXUS_VALUE="Y"
  else
    INSTALL_GITNEXUS_VALUE="N"
  fi
}

prompt_playwright_install_if_needed() {
  local entered_value
  local default_choice="N"

  if ! wants_mcp_install "$INSTALL_MCPS_VALUE"; then
    INSTALL_PLAYWRIGHT_VALUE="N"
    return 0
  fi

  if has_existing_mcp_server playwright; then
    default_choice="Y"
  fi

  if wants_mcp_install "$INSTALL_PLAYWRIGHT_VALUE"; then
    INSTALL_PLAYWRIGHT_VALUE="Y"
    return 0
  fi

  if [ -n "$INSTALL_PLAYWRIGHT_VALUE" ]; then
    INSTALL_PLAYWRIGHT_VALUE="N"
    return 0
  fi

  if ! prompt_available; then
    INSTALL_PLAYWRIGHT_VALUE="$default_choice"
    return 0
  fi

  if [ "$default_choice" = "Y" ]; then
    printf 'Install optional Playwright browser automation MCP for /b-browser live UI checks? [Y/n]: ' > /dev/tty
  else
    printf 'Install optional Playwright browser automation MCP for /b-browser live UI checks? [y/N]: ' > /dev/tty
  fi
  if IFS= read -r entered_value < /dev/tty; then
    :
  else
    entered_value=""
  fi

  if [ -z "$entered_value" ]; then
    INSTALL_PLAYWRIGHT_VALUE="$default_choice"
  elif wants_mcp_install "$entered_value"; then
    INSTALL_PLAYWRIGHT_VALUE="Y"
  else
    INSTALL_PLAYWRIGHT_VALUE="N"
  fi
}

get_existing_mcp_secret() {
  local server_name="$1" container_name="$2" secret_name="$3"
  [ -f "$CONFIG_FILE" ] || return 0

  env CONFIG_FILE="$CONFIG_FILE" SERVER_NAME="$server_name" CONTAINER_NAME="$container_name" SECRET_NAME="$secret_name" python3 - <<'PYEOF'
import json, os
from pathlib import Path

config_path = Path(os.environ["CONFIG_FILE"])
server_name = os.environ["SERVER_NAME"]
container_name = os.environ["CONTAINER_NAME"]
secret_name = os.environ["SECRET_NAME"]

try:
    config = json.loads(config_path.read_text())
except (FileNotFoundError, json.JSONDecodeError, OSError):
    raise SystemExit(0)

mcp = config.get("mcp", {})
if not isinstance(mcp, dict):
    raise SystemExit(0)

server = mcp.get(server_name, {})
if not isinstance(server, dict):
    raise SystemExit(0)

container = server.get(container_name, {})
if not isinstance(container, dict):
    raise SystemExit(0)

value = container.get(secret_name, "")

if isinstance(value, str):
    print(value)
PYEOF
}

get_existing_provider_value() {
  local provider_id="$1" value_path="$2"
  [ -f "$CONFIG_FILE" ] || return 0

  env CONFIG_FILE="$CONFIG_FILE" PROVIDER_ID="$provider_id" VALUE_PATH="$value_path" python3 - <<'PYEOF'
import json, os
from pathlib import Path

config_path = Path(os.environ["CONFIG_FILE"])
provider_id = os.environ["PROVIDER_ID"]
value_path = os.environ["VALUE_PATH"]

try:
    config = json.loads(config_path.read_text())
except (FileNotFoundError, json.JSONDecodeError, OSError):
    raise SystemExit(0)

provider = config.get("provider", {})
if not isinstance(provider, dict):
    raise SystemExit(0)

value = provider.get(provider_id)
if not isinstance(value, dict):
    raise SystemExit(0)

for part in value_path.split("."):
    if not isinstance(value, dict):
        raise SystemExit(0)
    value = value.get(part)

if isinstance(value, str):
    print(value)
PYEOF
}

get_existing_provider_models() {
  local provider_id="$1"
  [ -f "$CONFIG_FILE" ] || return 0

  env CONFIG_FILE="$CONFIG_FILE" PROVIDER_ID="$provider_id" python3 - <<'PYEOF'
import json, os
from pathlib import Path

config_path = Path(os.environ["CONFIG_FILE"])
provider_id = os.environ["PROVIDER_ID"]

try:
    config = json.loads(config_path.read_text())
except (FileNotFoundError, json.JSONDecodeError, OSError):
    raise SystemExit(0)

provider = config.get("provider", {})
if not isinstance(provider, dict):
    raise SystemExit(0)

value = provider.get(provider_id)
if not isinstance(value, dict):
    raise SystemExit(0)

models = value.get("models", {})
if not isinstance(models, dict):
    raise SystemExit(0)

for model_id, model_config in models.items():
    model_name = ""
    if isinstance(model_config, dict):
        model_name = model_config.get("name", "")
    if not isinstance(model_name, str) or not model_name:
        model_name = model_id
    print(f"{model_id}\t{model_name}")
PYEOF
}

prompt_api_key_if_needed() {
  local var_name="$1" prompt_label="$2" existing_value="$3"
  local current_value="${!var_name:-}"
  local entered_value

  if ! is_placeholder_value "$current_value"; then
    return 0
  fi

  if ! is_placeholder_value "$existing_value"; then
    printf -v "$var_name" '%s' "$existing_value"
    return 0
  fi

  if ! prompt_available; then
    printf -v "$var_name" '%s' 'YOUR_API_KEY'
    return 0
  fi

  printf 'Enter %s (press Enter to skip): ' "$prompt_label" > /dev/tty
  if IFS= read -r -s entered_value < /dev/tty; then
    printf '\n' > /dev/tty
  else
    entered_value=""
    printf '\n' > /dev/tty
  fi

  if is_placeholder_value "$entered_value"; then
    entered_value=""
  fi

  if [ -n "$entered_value" ]; then
    printf -v "$var_name" '%s' "$entered_value"
  else
    printf -v "$var_name" '%s' 'YOUR_API_KEY'
  fi
}

prompt_value_with_default() {
  local var_name="$1" prompt_label="$2" default_value="${3:-}" secret_input="${4:-N}"
  local entered_value prompt_suffix=""

  if ! prompt_available; then
    printf -v "$var_name" '%s' "$default_value"
    return 0
  fi

  if [ -n "$default_value" ]; then
    if [ "$secret_input" = "Y" ] && ! is_placeholder_value "$default_value"; then
      prompt_suffix=" [saved]"
    else
      prompt_suffix=" [$default_value]"
    fi
  fi

  printf 'Enter %s%s: ' "$prompt_label" "$prompt_suffix" > /dev/tty
  if [ "$secret_input" = "Y" ]; then
    if IFS= read -r -s entered_value < /dev/tty; then
      printf '\n' > /dev/tty
    else
      entered_value=""
      printf '\n' > /dev/tty
    fi
  else
    if IFS= read -r entered_value < /dev/tty; then
      :
    else
      entered_value=""
    fi
  fi

  if [ -n "$entered_value" ]; then
    printf -v "$var_name" '%s' "$entered_value"
  else
    printf -v "$var_name" '%s' "$default_value"
  fi
}

prompt_choice() {
  local var_name="$1" prompt_label="$2" default_value="${3:-}" valid_values="$4"
  local entered_value choice i
  local -a options
  IFS=',' read -ra options <<< "$valid_values"

  if ! prompt_available; then
    printf -v "$var_name" '%s' "$default_value"
    return 0
  fi

  printf '%s\n' "$prompt_label" > /dev/tty
  for i in "${!options[@]}"; do
    local opt="${options[$i]}"
    if [ "$opt" = "$default_value" ]; then
      printf '  %d) %s (default)\n' "$((i + 1))" "$opt" > /dev/tty
    else
      printf '  %d) %s\n' "$((i + 1))" "$opt" > /dev/tty
    fi
  done

  while :; do
    printf 'Enter number [1-%d] or press Enter for default: ' "${#options[@]}" > /dev/tty
    if IFS= read -r entered_value < /dev/tty; then
      :
    else
      entered_value=""
    fi

    if [ -z "$entered_value" ]; then
      printf -v "$var_name" '%s' "$default_value"
      return 0
    fi

    if [[ "$entered_value" =~ ^[0-9]+$ ]] && [ "$entered_value" -ge 1 ] && [ "$entered_value" -le "${#options[@]}" ]; then
      choice="${options[$((entered_value - 1))]}"
      printf -v "$var_name" '%s' "$choice"
      return 0
    fi

    printf '⚠️  Invalid choice. Enter 1-%d or press Enter for default.\n' "${#options[@]}" > /dev/tty
  done
}

collect_mcp_api_keys() {
  local existing_brave existing_context7 existing_firecrawl

  if ! wants_mcp_install "$INSTALL_MCPS_VALUE"; then
    return 0
  fi

  existing_brave=$(get_existing_mcp_secret "brave-search" "environment" "BRAVE_API_KEY")
  existing_context7=$(get_existing_mcp_secret "context7" "headers" "CONTEXT7_API_KEY")
  existing_firecrawl=$(get_existing_mcp_secret "firecrawl" "environment" "FIRECRAWL_API_KEY")

  prompt_api_key_if_needed BRAVE_API_KEY_VALUE "Brave Search API key" "$existing_brave"
  prompt_api_key_if_needed CONTEXT7_API_KEY_VALUE "Context7 API key" "$existing_context7"
  prompt_api_key_if_needed FIRECRAWL_API_KEY_VALUE "Firecrawl API key" "$existing_firecrawl"
}

append_custom_provider_model() {
  local model_id="$1" model_name="$2" reasoning="${3:-}"

  if [ -n "$CUSTOM_PROVIDER_MODELS_VALUE" ]; then
    CUSTOM_PROVIDER_MODELS_VALUE="${CUSTOM_PROVIDER_MODELS_VALUE}"$'\n'
  fi

  CUSTOM_PROVIDER_MODELS_VALUE="${CUSTOM_PROVIDER_MODELS_VALUE}${model_id}"$'\t'"${model_name}"$'\t'"${reasoning}"
}

append_custom_provider_delete_model() {
  local model_id="$1"

  if [ -n "$CUSTOM_PROVIDER_DELETE_MODELS_VALUE" ]; then
    CUSTOM_PROVIDER_DELETE_MODELS_VALUE="${CUSTOM_PROVIDER_DELETE_MODELS_VALUE}"$'\n'
  fi

  CUSTOM_PROVIDER_DELETE_MODELS_VALUE="${CUSTOM_PROVIDER_DELETE_MODELS_VALUE}${model_id}"
}

prompt_custom_provider_model_deletions() {
  local existing_models="$1"
  local entered_value model_id model_name model_number=0

  [ -n "$existing_models" ] || return 0
  prompt_available || return 0

  printf 'Existing models for provider %s:\n' "$CUSTOM_PROVIDER_ID_VALUE" > /dev/tty
  while IFS=$'\t' read -r model_id model_name; do
    [ -n "$model_id" ] || continue
    model_number=$((model_number + 1))
    if [ "$model_name" = "$model_id" ] || [ -z "$model_name" ]; then
      printf '  %d) %s\n' "$model_number" "$model_id" > /dev/tty
    else
      printf '  %d) %s (%s)\n' "$model_number" "$model_id" "$model_name" > /dev/tty
    fi
  done <<< "$existing_models"

  printf 'Remove any existing models from this provider before adding new ones? [y/N]: ' > /dev/tty
  if IFS= read -r entered_value < /dev/tty; then
    :
  else
    entered_value=""
  fi

  wants_mcp_install "$entered_value" || return 0

  while IFS=$'\t' read -r model_id model_name; do
    [ -n "$model_id" ] || continue
    if [ "$model_name" = "$model_id" ] || [ -z "$model_name" ]; then
      printf 'Remove model %s? [y/N]: ' "$model_id" > /dev/tty
    else
      printf 'Remove model %s (%s)? [y/N]: ' "$model_id" "$model_name" > /dev/tty
    fi

    if IFS= read -r entered_value < /dev/tty; then
      :
    else
      entered_value=""
    fi

    if wants_mcp_install "$entered_value"; then
      append_custom_provider_delete_model "$model_id"
    fi
  done <<< "$existing_models"
}

collect_custom_provider_config() {
  local entered_value model_id model_name existing_provider_name existing_provider_base_url existing_provider_api_key existing_provider_models

  CUSTOM_PROVIDER_ENABLED_VALUE="N"
  CUSTOM_PROVIDER_ID_VALUE=""
  CUSTOM_PROVIDER_NAME_VALUE=""
  CUSTOM_PROVIDER_BASE_URL_VALUE=""
  CUSTOM_PROVIDER_API_KEY_VALUE=""
  CUSTOM_PROVIDER_MODELS_VALUE=""
  CUSTOM_PROVIDER_DELETE_MODELS_VALUE=""

  if ! prompt_available; then
    return 0
  fi

  printf 'Add a custom OpenAI-compatible provider to OpenCode config? [y/N]: ' > /dev/tty
  if IFS= read -r entered_value < /dev/tty; then
    :
  else
    entered_value=""
  fi

  if ! wants_mcp_install "$entered_value"; then
    return 0
  fi

  prompt_value_with_default CUSTOM_PROVIDER_ID_VALUE "provider id" ""
  if [ -z "$CUSTOM_PROVIDER_ID_VALUE" ]; then
    warn "Skipping custom provider: provider id is required."
    return 0
  fi

  existing_provider_name=$(get_existing_provider_value "$CUSTOM_PROVIDER_ID_VALUE" "name")
  existing_provider_base_url=$(get_existing_provider_value "$CUSTOM_PROVIDER_ID_VALUE" "options.baseURL")
  existing_provider_api_key=$(get_existing_provider_value "$CUSTOM_PROVIDER_ID_VALUE" "options.apiKey")
  existing_provider_models=$(get_existing_provider_models "$CUSTOM_PROVIDER_ID_VALUE")

  prompt_value_with_default CUSTOM_PROVIDER_NAME_VALUE "provider name" "${existing_provider_name:-$CUSTOM_PROVIDER_ID_VALUE}"
  [ -n "$CUSTOM_PROVIDER_NAME_VALUE" ] || CUSTOM_PROVIDER_NAME_VALUE="$CUSTOM_PROVIDER_ID_VALUE"

  prompt_value_with_default CUSTOM_PROVIDER_BASE_URL_VALUE "base URL" "$existing_provider_base_url"
  if [ -z "$CUSTOM_PROVIDER_BASE_URL_VALUE" ]; then
    warn "Skipping custom provider: base URL is required."
    return 0
  fi

  prompt_value_with_default CUSTOM_PROVIDER_API_KEY_VALUE "API key" "${existing_provider_api_key:-YOUR_API_KEY}" "Y"
  [ -n "$CUSTOM_PROVIDER_API_KEY_VALUE" ] || CUSTOM_PROVIDER_API_KEY_VALUE="YOUR_API_KEY"

  prompt_custom_provider_model_deletions "$existing_provider_models"

  while :; do
    prompt_value_with_default model_id "model id (press Enter to finish)" ""
    if [ -z "$model_id" ]; then
      break
    fi

    prompt_value_with_default model_name "model name" "$model_id"
    [ -n "$model_name" ] || model_name="$model_id"

    prompt_choice model_reasoning "reasoning effort" "high" "low,medium,high,xhigh,max"

    append_custom_provider_model "$model_id" "$model_name" "$model_reasoning"
  done

  if [ -z "$CUSTOM_PROVIDER_MODELS_VALUE" ] && [ -z "$CUSTOM_PROVIDER_DELETE_MODELS_VALUE" ]; then
    warn "Skipping custom provider: add or remove at least one model to update it."
    CUSTOM_PROVIDER_ID_VALUE=""
    CUSTOM_PROVIDER_NAME_VALUE=""
    CUSTOM_PROVIDER_BASE_URL_VALUE=""
    CUSTOM_PROVIDER_API_KEY_VALUE=""
    return 0
  fi

  CUSTOM_PROVIDER_ENABLED_VALUE="Y"
}

api_key_status() {
  local value="$1"
  if is_placeholder_value "$value"; then
    printf 'placeholder'
  else
    printf 'set'
  fi
}

count_custom_provider_models() {
  local count=0 ignored_line

  if [ -z "$CUSTOM_PROVIDER_MODELS_VALUE" ]; then
    printf '0'
    return 0
  fi

  while IFS= read -r ignored_line; do
    count=$((count + 1))
  done <<< "$CUSTOM_PROVIDER_MODELS_VALUE"

  printf '%s' "$count"
}

count_custom_provider_deleted_models() {
  local count=0 ignored_line

  if [ -z "$CUSTOM_PROVIDER_DELETE_MODELS_VALUE" ]; then
    printf '0'
    return 0
  fi

  while IFS= read -r ignored_line; do
    count=$((count + 1))
  done <<< "$CUSTOM_PROVIDER_DELETE_MODELS_VALUE"

  printf '%s' "$count"
}

sync_directory() {
  local source_dir="$1" target_dir="$2"
  [ -d "$source_dir" ] || die "sync_directory: source missing: $source_dir"
  [ "$source_dir" = "$target_dir" ] && die "sync_directory: source and target identical"

  ensure_dir "$(dirname "$target_dir")"

  if dry_run_enabled; then
    log "[dry-run] sync $source_dir -> $target_dir"
    return 0
  fi

  rm -rf "$target_dir"
  mkdir -p "$target_dir"
  cp -R "$source_dir"/. "$target_dir"/
}

is_b_agentic_skill_dir() {
  local skill_dir="$1"
  [ -f "$skill_dir/SKILL.md" ] || return 1
  grep -Eq '^[[:space:]]*suite:[[:space:]]*(b-agentic|b-nexus|b-skills)[[:space:]]*$' "$skill_dir/SKILL.md"
}

is_legacy_b_command_name() {
  case "$1" in
    b-orchestrate|b-plan|b-spec|b-research|b-implement|b-refactor|b-debug|b-test|b-browser|b-e2e|b-review)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_b_agentic_command_file() {
  local command_file="$1"
  local command_name
  [ -f "$command_file" ] || return 1
  grep -q '<!-- b-agentic-managed -->' "$command_file" && return 0
  grep -q '<!-- b-nexus-managed -->' "$command_file" && return 0
  grep -q '<!-- b-skills-managed -->' "$command_file" && return 0

  command_name=$(basename "$command_file" .md)
  is_legacy_b_command_name "$command_name" || return 1
  grep -Fq "Load the \`$command_name\` skill and follow it exactly for this request." "$command_file" \
    && grep -Fq '$ARGUMENTS' "$command_file"
}

prune_stale_skills() {
  local source_dir="$1" target_dir="$2" removed=0 skill_name
  [ -d "$target_dir" ] || { printf '0'; return; }

  # Only prune explicitly b-agentic-managed entries so unrelated user skills stay intact.
  for installed_dir in "$target_dir"/b-*; do
    [ -d "$installed_dir" ] || continue
    is_b_agentic_skill_dir "$installed_dir" || continue
    skill_name=$(basename "$installed_dir")
    if [ ! -d "$source_dir/$skill_name" ] || [ ! -f "$source_dir/$skill_name/SKILL.md" ]; then
      if dry_run_enabled; then
        log "[dry-run] remove stale skill $installed_dir"
      else
        rm -rf "$installed_dir"
      fi
      removed=$((removed + 1))
    fi
  done

  printf '%s' "$removed"
}

prune_stale_commands() {
  local source_dir="$1" target_dir="$2" removed=0 command_name
  [ -d "$target_dir" ] || { printf '0'; return; }

  # Only prune explicitly b-agentic-managed wrappers so unrelated user commands stay intact.
  for installed_file in "$target_dir"/b-*.md; do
    [ -f "$installed_file" ] || continue
    is_b_agentic_command_file "$installed_file" || continue
    command_name=$(basename "$installed_file")
    if [ ! -f "$source_dir/$command_name" ]; then
      if dry_run_enabled; then
        log "[dry-run] remove stale command $installed_file"
      else
        rm -f "$installed_file"
      fi
      removed=$((removed + 1))
    fi
  done

  printf '%s' "$removed"
}

remove_path_if_exists() {
  local path="$1" label="$2"
  [ -e "$path" ] || {
    log "✅ $label already absent"
    return 0
  }

  if dry_run_enabled; then
    log "[dry-run] remove $path"
    return 0
  fi

  rm -rf "$path"
  log "✅ $label removed"
}

remove_skill_if_managed() {
  local skill_name="$1"
  local skill_dir="$OPENCODE_DIR/skills/$skill_name"
  [ -e "$skill_dir" ] || {
    log "✅ skill $skill_name already absent"
    return 0
  }

  if is_b_agentic_skill_dir "$skill_dir"; then
    remove_path_if_exists "$skill_dir" "skill $skill_name"
  else
    log "⏭ Preserved skill $skill_name because it is not marked as b-agentic-managed"
  fi
}

remove_command_if_managed() {
  local command_name="$1"
  local command_file="$OPENCODE_DIR/commands/$command_name.md"
  [ -e "$command_file" ] || {
    log "✅ command $command_name already absent"
    return 0
  }

  if is_b_agentic_command_file "$command_file"; then
    remove_path_if_exists "$command_file" "command $command_name"
  else
    log "⏭ Preserved command $command_name because it is not marked as b-agentic-managed"
  fi
}

restore_agents_backup_if_available() {
  local backup_path manifest_path snapshot_path
  manifest_path=$(resolve_existing_install_manifest) || return 1
  snapshot_path=$(resolve_existing_rules_snapshot) || return 1
  [ -f "$RULES_DST" ] || return 1
  if ! cmp -s "$RULES_DST" "$snapshot_path"; then
    log "⏭ Preserved OpenCode AGENTS.md because it has changed since b-agentic install"
    return 0
  fi

  backup_path=$(env INSTALL_MANIFEST_PATH="$manifest_path" python3 - <<'PYEOF'
import json
import os
from pathlib import Path

try:
    payload = json.loads(Path(os.environ["INSTALL_MANIFEST_PATH"]).read_text())
except (FileNotFoundError, json.JSONDecodeError, OSError):
    raise SystemExit(0)

path = payload.get("backups", {}).get("globalAgents", "")
if isinstance(path, str) and path and path != "none":
    print(path)
PYEOF
  )

  [ -n "$backup_path" ] || return 1
  [ -f "$backup_path" ] || {
    warn "Recorded AGENTS backup not found: $backup_path"
    return 1
  }

  if dry_run_enabled; then
    log "[dry-run] restore $backup_path -> $RULES_DST"
    return 0
  fi

  cp "$backup_path" "$RULES_DST"
  log "✅ OpenCode AGENTS.md restored from $backup_path"
}

remove_agents_if_b_agentic_managed() {
  local snapshot_path
  [ -f "$RULES_DST" ] || {
    log "✅ OpenCode AGENTS.md already absent"
    return 0
  }

  snapshot_path=$(resolve_existing_rules_snapshot) || snapshot_path=""

  if [ -n "$snapshot_path" ] && cmp -s "$RULES_DST" "$snapshot_path"; then
    remove_path_if_exists "$RULES_DST" "OpenCode AGENTS.md"
    return 0
  fi

  log "⏭ Preserved OpenCode AGENTS.md because it does not match the b-agentic snapshot"
}

cleanup_legacy_metadata_paths() {
  [ -e "$LEGACY_B_NEXUS_REFERENCES_DST" ] && remove_path_if_exists "$LEGACY_B_NEXUS_REFERENCES_DST" "legacy shared references"
  [ -e "$LEGACY_B_NEXUS_RULES_SNAPSHOT_DST" ] && remove_path_if_exists "$LEGACY_B_NEXUS_RULES_SNAPSHOT_DST" "legacy runtime kernel snapshot"
  [ -e "$LEGACY_B_NEXUS_INSTALL_MANIFEST" ] && remove_path_if_exists "$LEGACY_B_NEXUS_INSTALL_MANIFEST" "legacy install manifest"
  [ -e "$LEGACY_B_SKILLS_REFERENCES_DST" ] && remove_path_if_exists "$LEGACY_B_SKILLS_REFERENCES_DST" "legacy shared references"
  [ -e "$LEGACY_B_SKILLS_RULES_SNAPSHOT_DST" ] && remove_path_if_exists "$LEGACY_B_SKILLS_RULES_SNAPSHOT_DST" "legacy runtime kernel snapshot"
  [ -e "$LEGACY_B_SKILLS_INSTALL_MANIFEST" ] && remove_path_if_exists "$LEGACY_B_SKILLS_INSTALL_MANIFEST" "legacy install manifest"
  [ -e "$LEGACY_RULES_SNAPSHOT_DST" ] && remove_path_if_exists "$LEGACY_RULES_SNAPSHOT_DST" "legacy runtime kernel snapshot"
  [ -e "$LEGACY_INSTALL_MANIFEST" ] && remove_path_if_exists "$LEGACY_INSTALL_MANIFEST" "legacy install manifest"
  remove_dir_if_empty "$LEGACY_B_NEXUS_BACKUPS_DIR" "legacy backups directory"
  remove_dir_if_empty "$LEGACY_B_NEXUS_METADATA_DIR" "legacy metadata directory"
  remove_dir_if_empty "$LEGACY_B_SKILLS_BACKUPS_DIR" "legacy backups directory"
  remove_dir_if_empty "$LEGACY_B_SKILLS_METADATA_DIR" "legacy metadata directory"
  return 0
}

migrate_legacy_backup_files() {
  local legacy_backup_pairs backup_key source_path destination_path

  local legacy_manifest_path
  legacy_manifest_path=$(resolve_legacy_install_manifest) || return 0

  legacy_backup_pairs=$(env LEGACY_MANIFEST_PATH="$legacy_manifest_path" python3 - <<'PYEOF'
import json
import os
from pathlib import Path

try:
    payload = json.loads(Path(os.environ["LEGACY_MANIFEST_PATH"]).read_text())
except (FileNotFoundError, json.JSONDecodeError, OSError):
    raise SystemExit(0)

for key, backup_path in payload.get("backups", {}).items():
    if isinstance(backup_path, str) and backup_path and backup_path != "none":
        print(f"{key}\t{backup_path}")
PYEOF
  )

  [ -n "$legacy_backup_pairs" ] || return 0

  while IFS=$'\t' read -r backup_key source_path; do
    [ -n "$source_path" ] || continue
    destination_path="$B_AGENTIC_BACKUPS_DIR/$(basename "$source_path")"

    case "$source_path" in
      "$B_AGENTIC_BACKUPS_DIR"/*)
        destination_path="$source_path"
        ;;
      "$LEGACY_B_NEXUS_BACKUPS_DIR"/*)
        ;;
      "$LEGACY_B_SKILLS_BACKUPS_DIR"/*)
        ;;
      "$OPENCODE_DIR"/*.bak-*)
        ;;
      *)
        continue
        ;;
    esac

    [ -f "$source_path" ] || continue

    if [ "$destination_path" != "$source_path" ] && [ -e "$destination_path" ]; then
      log "⏭ Preserved legacy backup $source_path because $destination_path already exists"
    elif [ "$destination_path" != "$source_path" ]; then
      ensure_dir "$B_AGENTIC_BACKUPS_DIR"

      if dry_run_enabled; then
        log "[dry-run] move $source_path -> $destination_path"
      else
        mv "$source_path" "$destination_path"
        log "✅ Moved legacy backup $(basename "$source_path") into $B_AGENTIC_BACKUPS_DIR"
      fi
    fi

    case "$backup_key" in
      globalAgents)
        if [ "$RULES_BACKUP_PATH" = "none" ]; then
          RULES_BACKUP_PATH="$destination_path"
        fi
        ;;
      config)
        if [ "$CONFIG_BACKUP_PATH" = "none" ]; then
          CONFIG_BACKUP_PATH="$destination_path"
        fi
        ;;
      *)
        ;;
    esac
  done <<< "$legacy_backup_pairs"

  return 0
}

remove_dir_if_empty() {
  local dir_path="$1" label="$2"

  [ -d "$dir_path" ] || return 0
  if [ -n "$(ls -A "$dir_path")" ]; then
    return 0
  fi

  if dry_run_enabled; then
    log "[dry-run] remove empty directory $dir_path"
    return 0
  fi

  rmdir "$dir_path"
  log "✅ $label removed"
}

uninstall_b_agentic() {
  section "Uninstall b-agentic"

  remove_skill_if_managed b-spec
  remove_skill_if_managed b-orchestrate
  remove_skill_if_managed b-plan
  remove_skill_if_managed b-research
  remove_skill_if_managed b-implement
  remove_skill_if_managed b-refactor
  remove_skill_if_managed b-debug
  remove_skill_if_managed b-test
  remove_skill_if_managed b-browser
  remove_skill_if_managed b-e2e
  remove_skill_if_managed b-review
  remove_skill_if_managed b-audit

  remove_command_if_managed b-spec
  remove_command_if_managed b-orchestrate
  remove_command_if_managed b-plan
  remove_command_if_managed b-research
  remove_command_if_managed b-implement
  remove_command_if_managed b-refactor
  remove_command_if_managed b-debug
  remove_command_if_managed b-test
  remove_command_if_managed b-browser
  remove_command_if_managed b-e2e
  remove_command_if_managed b-review
  remove_command_if_managed b-audit

  remove_path_if_exists "$REFERENCES_DST" "shared references"

  if ! restore_agents_backup_if_available; then
    remove_agents_if_b_agentic_managed
  fi

  remove_path_if_exists "$RULES_SNAPSHOT_DST" "runtime kernel snapshot"
  remove_path_if_exists "$INSTALL_MANIFEST" "install manifest"
  cleanup_legacy_metadata_paths
  remove_dir_if_empty "$B_AGENTIC_BACKUPS_DIR" "b-agentic backups directory"
  remove_dir_if_empty "$B_AGENTIC_METADATA_DIR" "b-agentic metadata directory"

  section "Done"
  if dry_run_enabled; then
    log "✅ b-agentic uninstall preview completed."
  else
    log "✅ b-agentic uninstalled from OpenCode."
  fi
}

if wants_mcp_install "$UNINSTALL_VALUE"; then
  uninstall_b_agentic
  trap - EXIT
  exit 0
fi

merge_opencode_config() {
  ensure_dir "$(dirname "$CONFIG_FILE")"
  local existing
  existing=$(python3 - "$CONFIG_FILE" <<'PYEOF'
from pathlib import Path
import sys

path = Path(sys.argv[1])
try:
    print(path.read_text(), end="")
except FileNotFoundError:
    print("{}", end="")
PYEOF
  )

  local merged
  merged=$(env \
    CONFIG_FILE="$CONFIG_FILE" \
    EXISTING="$existing" \
    BRAVE_API_KEY_VALUE="$BRAVE_API_KEY_VALUE" \
    CONTEXT7_API_KEY_VALUE="$CONTEXT7_API_KEY_VALUE" \
    FIRECRAWL_API_KEY_VALUE="$FIRECRAWL_API_KEY_VALUE" \
    INSTALL_MCPS_VALUE="$INSTALL_MCPS_VALUE" \
    INSTALL_GITNEXUS_VALUE="$INSTALL_GITNEXUS_VALUE" \
    INSTALL_PLAYWRIGHT_VALUE="$INSTALL_PLAYWRIGHT_VALUE" \
    CUSTOM_PROVIDER_ENABLED_VALUE="$CUSTOM_PROVIDER_ENABLED_VALUE" \
    CUSTOM_PROVIDER_ID_VALUE="$CUSTOM_PROVIDER_ID_VALUE" \
    CUSTOM_PROVIDER_NAME_VALUE="$CUSTOM_PROVIDER_NAME_VALUE" \
    CUSTOM_PROVIDER_BASE_URL_VALUE="$CUSTOM_PROVIDER_BASE_URL_VALUE" \
    CUSTOM_PROVIDER_API_KEY_VALUE="$CUSTOM_PROVIDER_API_KEY_VALUE" \
    CUSTOM_PROVIDER_MODELS_VALUE="$CUSTOM_PROVIDER_MODELS_VALUE" \
    CUSTOM_PROVIDER_DELETE_MODELS_VALUE="$CUSTOM_PROVIDER_DELETE_MODELS_VALUE" \
    python3 - <<'PYEOF'
import json, os

existing_raw = os.environ.get("EXISTING", "{}")
brave_api_key = os.environ.get("BRAVE_API_KEY_VALUE") or "YOUR_API_KEY"
context7_api_key = os.environ.get("CONTEXT7_API_KEY_VALUE") or "YOUR_API_KEY"
firecrawl_api_key = os.environ.get("FIRECRAWL_API_KEY_VALUE") or "YOUR_API_KEY"
install_mcps = (os.environ.get("INSTALL_MCPS_VALUE") or "").strip().lower() in {"y", "yes"}
install_gitnexus = (os.environ.get("INSTALL_GITNEXUS_VALUE") or "").strip().lower() in {"y", "yes"}
install_playwright = (os.environ.get("INSTALL_PLAYWRIGHT_VALUE") or "").strip().lower() in {"y", "yes"}
custom_provider_enabled = (os.environ.get("CUSTOM_PROVIDER_ENABLED_VALUE") or "").strip().lower() in {"y", "yes"}
custom_provider_id = (os.environ.get("CUSTOM_PROVIDER_ID_VALUE") or "").strip()
custom_provider_name = (os.environ.get("CUSTOM_PROVIDER_NAME_VALUE") or "").strip()
custom_provider_base_url = (os.environ.get("CUSTOM_PROVIDER_BASE_URL_VALUE") or "").strip()
custom_provider_api_key = os.environ.get("CUSTOM_PROVIDER_API_KEY_VALUE") or "YOUR_API_KEY"
custom_provider_models_raw = os.environ.get("CUSTOM_PROVIDER_MODELS_VALUE", "")
custom_provider_delete_models_raw = os.environ.get("CUSTOM_PROVIDER_DELETE_MODELS_VALUE", "")


def strip_jsonc_comments(text):
    result = []
    in_string = False
    string_char = ""
    escaped = False
    i = 0

    while i < len(text):
        char = text[i]
        next_char = text[i + 1] if i + 1 < len(text) else ""

        if in_string:
            result.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == string_char:
                in_string = False
            i += 1
            continue

        if char == '"':
            in_string = True
            string_char = char
            result.append(char)
            i += 1
            continue

        if char == "/" and next_char == "/":
            i += 2
            while i < len(text) and text[i] not in "\r\n":
                i += 1
            continue

        if char == "/" and next_char == "*":
            i += 2
            while i + 1 < len(text) and text[i:i + 2] != "*/":
                i += 1
            i += 2 if i + 1 < len(text) else 0
            continue

        result.append(char)
        i += 1

    return "".join(result)


def strip_trailing_commas(text):
    result = []
    in_string = False
    string_char = ""
    escaped = False
    i = 0

    while i < len(text):
        char = text[i]

        if in_string:
            result.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == string_char:
                in_string = False
            i += 1
            continue

        if char == '"':
            in_string = True
            string_char = char
            result.append(char)
            i += 1
            continue

        if char == ",":
            j = i + 1
            while j < len(text) and text[j] in " \t\r\n":
                j += 1
            if j < len(text) and text[j] in "]}":
                i += 1
                continue

        result.append(char)
        i += 1

    return "".join(result)


def load_existing_config(raw_text):
    source = raw_text.strip()
    if not source:
        return {}

    try:
        return json.loads(source)
    except json.JSONDecodeError:
        pass

    # OpenCode configs may include JSONC-style comments and trailing commas.
    normalized = strip_trailing_commas(strip_jsonc_comments(raw_text)).strip()
    if not normalized:
        return {}

    try:
        return json.loads(normalized)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Unable to parse existing OpenCode config at {os.environ.get('CONFIG_FILE', 'opencode.json')}: {exc}")


def parse_custom_provider_models(raw_text):
    models = {}
    for line in raw_text.splitlines():
        parts = line.split("\t")
        model_id = parts[0].strip() if len(parts) > 0 else ""
        model_name = parts[1].strip() if len(parts) > 1 else ""
        reasoning = parts[2].strip() if len(parts) > 2 else ""

        if not model_id:
            continue

        model_config = {
            "name": model_name or model_id,
        }

        if reasoning:
            model_config["reasoning"] = reasoning

        models[model_id] = model_config

    return models


def parse_custom_provider_delete_models(raw_text):
    return [line.strip() for line in raw_text.splitlines() if line.strip()]


def deep_fill(target, defaults):
    for key, value in defaults.items():
        if key not in target:
            target[key] = value
        elif isinstance(value, dict):
            if isinstance(target.get(key), dict):
                deep_fill(target[key], value)
            else:
                target[key] = value


def is_placeholder(value):
    return not isinstance(value, str) or not value.strip() or value.startswith("YOUR_")


def ensure_secret(container, key, value):
    if not isinstance(container, dict):
        return
    current = container.get(key)
    if is_placeholder(current):
        container[key] = value


def ensure_mapping(container, key):
    value = container.get(key)
    if isinstance(value, dict):
        return value

    value = {}
    container[key] = value
    return value

config = load_existing_config(existing_raw)

mcp_defaults = {
    "brave-search": {
        "type": "local",
        "command": [
            "npx",
            "-y",
            "@brave/brave-search-mcp-server",
        ],
        "environment": {
            "BRAVE_API_KEY": brave_api_key,
        },
    },
    "context7": {
        "type": "remote",
        "url": "https://mcp.context7.com/mcp",
        "headers": {
            "CONTEXT7_API_KEY": context7_api_key,
        },
    },
    "firecrawl": {
        "type": "local",
        "command": [
            "npx",
            "-y",
            "firecrawl-mcp",
        ],
        "environment": {
            "FIRECRAWL_API_KEY": firecrawl_api_key,
        },
    },
    "serena": {
        "type": "local",
        "command": [
            "serena",
            "start-mcp-server",
            "--context=ide",
            "--project-from-cwd",
            "--open-web-dashboard",
            "False",
        ],
    },
}

gitnexus_defaults = {
    "gitnexus": {
        "type": "local",
        "command": [
            "gitnexus",
            "mcp",
        ],
    },
}

playwright_defaults = {
    "playwright": {
        "type": "local",
        "command": [
            "npx",
            "-y",
            "@playwright/mcp@latest",
            "--isolated",
        ],
    },
}

if install_mcps:
    mcp = config.setdefault("mcp", {})
    if not isinstance(mcp, dict):
        mcp = {}
        config["mcp"] = mcp

    for server_name, defaults in mcp_defaults.items():
        current = mcp.get(server_name)
        if isinstance(current, dict):
            deep_fill(current, defaults)
        else:
            mcp[server_name] = defaults

    ensure_secret(mcp["brave-search"].get("environment"), "BRAVE_API_KEY", brave_api_key)
    ensure_secret(mcp["context7"].get("headers"), "CONTEXT7_API_KEY", context7_api_key)
    ensure_secret(mcp["firecrawl"].get("environment"), "FIRECRAWL_API_KEY", firecrawl_api_key)

    if install_gitnexus:
        for server_name, defaults in gitnexus_defaults.items():
            current = mcp.get(server_name)
            if isinstance(current, dict):
                deep_fill(current, defaults)
            else:
                mcp[server_name] = defaults
    else:
        mcp.pop("gitnexus", None)

    if install_playwright:
        for server_name, defaults in playwright_defaults.items():
            current = mcp.get(server_name)
            if isinstance(current, dict):
                deep_fill(current, defaults)
            else:
                mcp[server_name] = defaults

custom_provider_models = parse_custom_provider_models(custom_provider_models_raw)
custom_provider_delete_models = parse_custom_provider_delete_models(custom_provider_delete_models_raw)

if custom_provider_enabled and custom_provider_id and custom_provider_base_url and (custom_provider_models or custom_provider_delete_models):
    provider = config.setdefault("provider", {})
    if not isinstance(provider, dict):
        provider = {}
        config["provider"] = provider

    current_provider = provider.get(custom_provider_id)
    if not isinstance(current_provider, dict):
        current_provider = {}
        provider[custom_provider_id] = current_provider

    current_provider["npm"] = "@ai-sdk/openai-compatible"
    current_provider["name"] = custom_provider_name or custom_provider_id

    options = ensure_mapping(current_provider, "options")
    options["baseURL"] = custom_provider_base_url
    options["apiKey"] = custom_provider_api_key

    models = ensure_mapping(current_provider, "models")
    for model_id in custom_provider_delete_models:
        models.pop(model_id, None)

    for model_id, model_config in custom_provider_models.items():
        current_model = models.get(model_id)
        if not isinstance(current_model, dict):
            current_model = {}
            models[model_id] = current_model

        current_model["name"] = model_config["name"]

        if "reasoning" in model_config:
            options = ensure_mapping(current_model, "options")
            options["reasoningEffort"] = model_config["reasoning"]

print(json.dumps(config, indent=2))
PYEOF
)

  if [ -f "$CONFIG_FILE" ]; then
    local normalized_existing
    normalized_existing=$(env CONFIG_FILE="$CONFIG_FILE" EXISTING="$existing" python3 - <<'PYEOF'
import json
import os

existing_raw = os.environ.get("EXISTING", "{}")

def strip_jsonc_comments(text):
    result = []
    in_string = False
    string_char = ""
    escaped = False
    i = 0

    while i < len(text):
        char = text[i]
        next_char = text[i + 1] if i + 1 < len(text) else ""

        if in_string:
            result.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == string_char:
                in_string = False
            i += 1
            continue

        if char == '"':
            in_string = True
            string_char = char
            result.append(char)
            i += 1
            continue

        if char == "/" and next_char == "/":
            i += 2
            while i < len(text) and text[i] not in "\r\n":
                i += 1
            continue

        if char == "/" and next_char == "*":
            i += 2
            while i + 1 < len(text) and text[i:i + 2] != "*/":
                i += 1
            i += 2 if i + 1 < len(text) else 0
            continue

        result.append(char)
        i += 1

    return "".join(result)

def strip_trailing_commas(text):
    result = []
    in_string = False
    string_char = ""
    escaped = False
    i = 0

    while i < len(text):
        char = text[i]

        if in_string:
            result.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == string_char:
                in_string = False
            i += 1
            continue

        if char == '"':
            in_string = True
            string_char = char
            result.append(char)
            i += 1
            continue

        if char == ",":
            j = i + 1
            while j < len(text) and text[j] in " \t\r\n":
                j += 1
            if j < len(text) and text[j] in "]}":
                i += 1
                continue

        result.append(char)
        i += 1

    return "".join(result)

try:
    parsed = json.loads(existing_raw)
except json.JSONDecodeError:
    parsed = json.loads(strip_trailing_commas(strip_jsonc_comments(existing_raw)).strip() or "{}")

print(json.dumps(parsed, indent=2))
PYEOF
    )

    if [ "$normalized_existing" = "$merged" ]; then
      log "✅ OpenCode config unchanged"
      return 0
    fi
  fi

  write_text_file "$CONFIG_FILE" "$merged" "OpenCode config" Y
  if [ -f "$CONFIG_FILE" ] && ! dry_run_enabled; then
    CONFIG_BACKUP_PATH="$(backup_path_for_file "$CONFIG_FILE")"
    [ -f "$CONFIG_BACKUP_PATH" ] || CONFIG_BACKUP_PATH="none"
  fi
}

section "Sync b-agentic repo"
if [ -d "$LOCAL_REPO/.git" ]; then
  if [ -n "$(git -C "$LOCAL_REPO" status --porcelain)" ]; then
    die "Local changes detected in $LOCAL_REPO — commit or stash before re-running."
  fi
  log "🔄 Updating $LOCAL_REPO"
  git -C "$LOCAL_REPO" pull --ff-only || die "git pull --ff-only failed. Resolve in $LOCAL_REPO and re-run."
else
  log "📦 Cloning $REPO_URL → $LOCAL_REPO"
  git clone "$REPO_URL" "$LOCAL_REPO"
fi

if [ -n "$REF" ]; then
  log "🏷  Checking out ref: $REF"
  git -C "$LOCAL_REPO" checkout "$REF"
fi

section "Install OpenCode skills"
[ -d "$SKILLS_SRC" ] || die "Missing skills source directory: $SKILLS_SRC"
ensure_dir "$OPENCODE_DIR/skills"
synced_skills=0
for skill_dir in "$SKILLS_SRC"/*/; do
  [ -d "$skill_dir" ] || continue
  [ -f "$skill_dir/SKILL.md" ] || continue
  skill_name=$(basename "$skill_dir")
  sync_directory "$skill_dir" "$OPENCODE_DIR/skills/$skill_name"
  synced_skills=$((synced_skills + 1))
done
pruned_skills=$(prune_stale_skills "$SKILLS_SRC" "$OPENCODE_DIR/skills")
skills_summary="✅ Skills synced: $synced_skills"
[ "$pruned_skills" -gt 0 ] && skills_summary="$skills_summary, $pruned_skills stale removed"
log "$skills_summary"

section "Install OpenCode commands"
[ -d "$COMMANDS_SRC" ] || die "Missing commands source directory: $COMMANDS_SRC"
ensure_dir "$OPENCODE_DIR/commands"
synced_commands=0
for command_file in "$COMMANDS_SRC"/*.md; do
  [ -f "$command_file" ] || continue
  if dry_run_enabled; then
    log "[dry-run] copy $command_file -> $OPENCODE_DIR/commands/"
  else
    cp "$command_file" "$OPENCODE_DIR/commands/"
  fi
  synced_commands=$((synced_commands + 1))
done
pruned_commands=$(prune_stale_commands "$COMMANDS_SRC" "$OPENCODE_DIR/commands")
commands_summary="✅ Commands synced: $synced_commands"
[ "$pruned_commands" -gt 0 ] && commands_summary="$commands_summary, $pruned_commands stale removed"
log "$commands_summary"

section "Install shared references"
[ -d "$REFERENCES_SRC" ] || die "Missing references source directory: $REFERENCES_SRC"
sync_directory "$REFERENCES_SRC" "$REFERENCES_DST"
log "✅ Shared references synced"

section "Install runtime rules"
decide_agents_install_action
write_file_from_source "$RULES_SRC" "$RULES_SNAPSHOT_DST" "b-agentic runtime kernel snapshot"

case "$AGENTS_INSTALL_ACTION" in
  replace)
    if [ -f "$RULES_DST" ] && ! dry_run_enabled; then
      RULES_BACKUP_PATH="$(backup_file_if_needed "$RULES_DST")"
    elif [ -f "$RULES_DST" ]; then
      RULES_BACKUP_PATH="$(backup_path_for_file "$RULES_DST")"
    fi
    write_file_from_source "$RULES_SRC" "$RULES_DST" "OpenCode AGENTS.md"
    RUNTIME_ACTIVATION_STATE="active"
    ;;
  unchanged)
    log "✅ OpenCode AGENTS.md already matches b-agentic"
    RUNTIME_ACTIVATION_STATE="active"
    ;;
  preserve)
    log "⏭ Preserved existing OpenCode AGENTS.md; b-agentic runtime kernel is pending"
    log "   b-agentic runtime kernel snapshot: $RULES_SNAPSHOT_DST"
    RUNTIME_ACTIVATION_STATE="pending"
    ;;
esac

section "MCP setup"
prompt_mcp_install_if_needed
if wants_mcp_install "$INSTALL_MCPS_VALUE"; then
  collect_mcp_api_keys
  prompt_gitnexus_install_if_needed
  prompt_playwright_install_if_needed
else
  INSTALL_GITNEXUS_VALUE="N"
  INSTALL_PLAYWRIGHT_VALUE="N"
fi

section "Provider setup"
collect_custom_provider_config

merge_opencode_config
migrate_legacy_backup_files
write_install_manifest
cleanup_legacy_metadata_paths

section "MCP defaults"
if wants_mcp_install "$INSTALL_MCPS_VALUE"; then
  log "✅ MCP defaults merged"
  log "   Core servers: serena, context7, brave-search, firecrawl"
  if wants_mcp_install "$INSTALL_GITNEXUS_VALUE"; then
    log "   Optional servers: gitnexus"
  else
    log "   Optional servers: gitnexus (skipped)"
  fi
  if wants_mcp_install "$INSTALL_PLAYWRIGHT_VALUE"; then
    log "   Optional servers: playwright"
  else
    log "   Optional servers: playwright (skipped)"
  fi
  log "   brave-search: $(api_key_status "$BRAVE_API_KEY_VALUE")"
  log "   context7: $(api_key_status "$CONTEXT7_API_KEY_VALUE")"
  log "   firecrawl: $(api_key_status "$FIRECRAWL_API_KEY_VALUE")"
else
  log "⏭ MCP defaults skipped."
fi

section "Custom provider"
if wants_mcp_install "$CUSTOM_PROVIDER_ENABLED_VALUE"; then
  log "✅ Custom provider merged"
  log "   provider: $CUSTOM_PROVIDER_ID_VALUE"
  log "   baseURL:  $CUSTOM_PROVIDER_BASE_URL_VALUE"
  log "   models added/updated: $(count_custom_provider_models)"
  log "   models removed:       $(count_custom_provider_deleted_models)"
  log "   apiKey:   $(api_key_status "$CUSTOM_PROVIDER_API_KEY_VALUE")"
else
  log "⏭ Custom provider skipped."
fi

section "Done"
if [ "$RUNTIME_ACTIVATION_STATE" = "pending" ]; then
  log "⚠️  RUNTIME KERNEL NOT ACTIVE"
  log "   Skills, commands, and references were installed, but the active OpenCode AGENTS.md was preserved."
  log "   b-agentic runtime gates, required read gates, and status/handoff rules may not be enforced until activation."
elif dry_run_enabled; then
  log "✅ b-agentic install preview completed."
else
  log "✅ b-agentic installed successfully for OpenCode."
fi
log "   Skills:       $OPENCODE_DIR/skills"
log "   Commands:     $OPENCODE_DIR/commands"
log "   Runtime kernel:   $RULES_SNAPSHOT_DST"
log "   Runtime contract: $RUNTIME_CONTRACT_DST"
log "   AGENTS.md:    $RULES_DST ($AGENTS_INSTALL_ACTION)"
log "   Config:       $CONFIG_FILE"
if [ "$RULES_BACKUP_PATH" != "none" ]; then
  log "   AGENTS backup: $RULES_BACKUP_PATH"
fi
if [ "$CONFIG_BACKUP_PATH" != "none" ]; then
  log "   Config backup: $CONFIG_BACKUP_PATH"
fi
if dry_run_enabled; then
  log "   Manifest:     $INSTALL_MANIFEST (preview only; not written)"
else
  log "   Manifest:     $INSTALL_MANIFEST"
fi

if [ "$RUNTIME_ACTIVATION_STATE" = "pending" ]; then
  log "   Next step:    rerun with --replace-agents, or manually merge $RULES_SNAPSHOT_DST into $RULES_DST"
  log "   Verify:       rerun install and confirm activationState is active in $INSTALL_MANIFEST"
  trap - EXIT
  exit 2
fi

trap - EXIT
