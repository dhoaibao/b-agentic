#!/usr/bin/env bash
# install.sh — Bootstrap or update b-skills for OpenCode
# Usage:
#   First time / update:
#     curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-skills/main/install.sh | bash
#
# Optional environment overrides:
#   B_SKILLS_REPO  — git URL to clone (default: https://github.com/dhoaibao/b-skills.git)
#   B_SKILLS_DIR   — local clone path (default: $HOME/.b-skills)
#   B_SKILLS_REF   — git ref to check out after clone/pull (default: leave on default branch)
#   B_SKILLS_INSTALL_MCP — Y to install MCP defaults; otherwise skipped
#   BRAVE_API_KEY  — Brave Search MCP API key
#   CONTEXT7_API_KEY — Context7 MCP API key
#   FIRECRAWL_API_KEY — Firecrawl MCP API key

set -euo pipefail

readonly REPO_URL="${B_SKILLS_REPO:-https://github.com/dhoaibao/b-skills.git}"
readonly LOCAL_REPO="${B_SKILLS_DIR:-$HOME/.b-skills}"
readonly REF="${B_SKILLS_REF:-}"
readonly OPENCODE_DIR="$HOME/.config/opencode"
readonly SKILLS_SRC="$LOCAL_REPO/skills"
readonly COMMANDS_SRC="$LOCAL_REPO/commands"
readonly RULES_SRC="$LOCAL_REPO/global/AGENTS.md"
readonly RULES_DST="$OPENCODE_DIR/AGENTS.md"
readonly CONFIG_FILE="$OPENCODE_DIR/opencode.json"
readonly TIMESTAMP="$(date +%Y%m%d%H%M%S)"

log()     { printf '%s
' "$*"; }
section() { printf '
── %s %s
' "$*" "$(printf '%.0s─' $(seq 1 $((60 - ${#1}))))"; }
warn()    { printf '⚠️  %s
' "$*" >&2; }
die()     { printf '❌ %s
' "$*" >&2; exit 1; }

trap 'rc=$?; [ $rc -ne 0 ] && warn "install.sh failed at line $LINENO (exit $rc)"' EXIT

BRAVE_API_KEY_VALUE="${BRAVE_API_KEY:-}"
CONTEXT7_API_KEY_VALUE="${CONTEXT7_API_KEY:-}"
FIRECRAWL_API_KEY_VALUE="${FIRECRAWL_API_KEY:-}"
INSTALL_MCPS_VALUE="${B_SKILLS_INSTALL_MCP:-}"

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
  [ -r /dev/tty ] && [ -w /dev/tty ]
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

  printf 'Install MCP defaults in OpenCode config? [y/N]: ' > /dev/tty
  if IFS= read -r entered_value < /dev/tty; then
    :
  else
    entered_value=""
  fi
  printf '\n' > /dev/tty

  if wants_mcp_install "$entered_value"; then
    INSTALL_MCPS_VALUE="Y"
  else
    INSTALL_MCPS_VALUE="N"
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

api_key_status() {
  local value="$1"
  if is_placeholder_value "$value"; then
    printf 'placeholder'
  else
    printf 'set'
  fi
}

sync_directory() {
  local source_dir="$1" target_dir="$2"
  [ -d "$source_dir" ] || die "sync_directory: source missing: $source_dir"
  [ "$source_dir" = "$target_dir" ] && die "sync_directory: source and target identical"

  mkdir -p "$(dirname "$target_dir")"
  rm -rf "$target_dir"
  mkdir -p "$target_dir"
  cp -R "$source_dir"/. "$target_dir"/
}

prune_stale_skills() {
  local source_dir="$1" target_dir="$2" removed=0 skill_name
  [ -d "$target_dir" ] || { printf '0'; return; }

  # Only prune b-skills-managed entries so unrelated user skills stay intact.
  for installed_dir in "$target_dir"/b-*; do
    [ -d "$installed_dir" ] || continue
    [ -f "$installed_dir/SKILL.md" ] || continue
    skill_name=$(basename "$installed_dir")
    if [ ! -d "$source_dir/$skill_name" ] || [ ! -f "$source_dir/$skill_name/SKILL.md" ]; then
      rm -rf "$installed_dir"
      removed=$((removed + 1))
    fi
  done

  printf '%s' "$removed"
}

prune_stale_commands() {
  local source_dir="$1" target_dir="$2" removed=0 command_name
  [ -d "$target_dir" ] || { printf '0'; return; }

  # Only prune b-skills-managed wrappers so unrelated user commands stay intact.
  for installed_file in "$target_dir"/b-*.md; do
    [ -f "$installed_file" ] || continue
    command_name=$(basename "$installed_file")
    if [ ! -f "$source_dir/$command_name" ]; then
      rm -f "$installed_file"
      removed=$((removed + 1))
    fi
  done

  printf '%s' "$removed"
}

merge_opencode_config() {
  mkdir -p "$(dirname "$CONFIG_FILE")"
  local existing
  existing=$(cat "$CONFIG_FILE" 2>/dev/null || echo '{}')

  local merged
  merged=$(env EXISTING="$existing" BRAVE_API_KEY_VALUE="$BRAVE_API_KEY_VALUE" CONTEXT7_API_KEY_VALUE="$CONTEXT7_API_KEY_VALUE" FIRECRAWL_API_KEY_VALUE="$FIRECRAWL_API_KEY_VALUE" INSTALL_MCPS_VALUE="$INSTALL_MCPS_VALUE" python3 - <<'PYEOF'
import json, os

existing_raw = os.environ.get("EXISTING", "{}")
brave_api_key = os.environ.get("BRAVE_API_KEY_VALUE") or "YOUR_API_KEY"
context7_api_key = os.environ.get("CONTEXT7_API_KEY_VALUE") or "YOUR_API_KEY"
firecrawl_api_key = os.environ.get("FIRECRAWL_API_KEY_VALUE") or "YOUR_API_KEY"
install_mcps = (os.environ.get("INSTALL_MCPS_VALUE") or "").strip().lower() in {"y", "yes"}


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

try:
    config = json.loads(existing_raw) if existing_raw.strip() else {}
except json.JSONDecodeError:
    config = {}

permission = config.setdefault("permission", {})
skill_permission = permission.setdefault("skill", {})
skill_permission.setdefault("*", "allow")

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
    "sequential-thinking": {
        "type": "local",
        "command": [
            "npx",
            "-y",
            "@modelcontextprotocol/server-sequential-thinking",
        ],
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
    "playwright": {
        "type": "local",
        "command": [
            "npx",
            "@playwright/mcp@latest",
        ],
    },
    "serena": {
        "type": "local",
        "command": [
            "serena",
            "start-mcp-server",
            "--context=ide",
            "--project-from-cwd",
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

print(json.dumps(config, indent=2))
PYEOF
)

  local tmp="${CONFIG_FILE}.tmp-${TIMESTAMP}"
  printf '%s
' "$merged" > "$tmp"
  mv "$tmp" "$CONFIG_FILE"
}

section "Sync b-skills repo"
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
mkdir -p "$OPENCODE_DIR/skills"
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
mkdir -p "$OPENCODE_DIR/commands"
synced_commands=0
for command_file in "$COMMANDS_SRC"/*.md; do
  [ -f "$command_file" ] || continue
  cp "$command_file" "$OPENCODE_DIR/commands/"
  synced_commands=$((synced_commands + 1))
done
pruned_commands=$(prune_stale_commands "$COMMANDS_SRC" "$OPENCODE_DIR/commands")
commands_summary="✅ Commands synced: $synced_commands"
[ "$pruned_commands" -gt 0 ] && commands_summary="$commands_summary, $pruned_commands stale removed"
log "$commands_summary"

section "Install AGENTS.md"
mkdir -p "$(dirname "$RULES_DST")"
cp "$RULES_SRC" "$RULES_DST"
log "✅ AGENTS.md installed"

section "MCP setup"
prompt_mcp_install_if_needed
if wants_mcp_install "$INSTALL_MCPS_VALUE"; then
  collect_mcp_api_keys
fi
merge_opencode_config
log "✅ Config updated"

section "MCP defaults"
if wants_mcp_install "$INSTALL_MCPS_VALUE"; then
  log "✅ MCP defaults merged"
  log "   Servers: serena, context7, brave-search, firecrawl, playwright, sequential-thinking"
  log "   brave-search: $(api_key_status "$BRAVE_API_KEY_VALUE")"
  log "   context7: $(api_key_status "$CONTEXT7_API_KEY_VALUE")"
  log "   firecrawl: $(api_key_status "$FIRECRAWL_API_KEY_VALUE")"
else
  log "⏭ MCP defaults skipped."
fi

section "Done"
log "✅ b-skills installed successfully for OpenCode."
log "   Skills:       $OPENCODE_DIR/skills"
log "   Commands:     $OPENCODE_DIR/commands"
  log "   AGENTS.md:    $RULES_DST"
log "   Config:       $CONFIG_FILE"

trap - EXIT
