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
CUSTOM_PROVIDER_ENABLED_VALUE="N"
CUSTOM_PROVIDER_ID_VALUE=""
CUSTOM_PROVIDER_NAME_VALUE=""
CUSTOM_PROVIDER_BASE_URL_VALUE=""
CUSTOM_PROVIDER_API_KEY_VALUE=""
CUSTOM_PROVIDER_MODELS_VALUE=""

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

collect_custom_provider_config() {
  local entered_value model_id model_name existing_provider_name existing_provider_base_url existing_provider_api_key

  CUSTOM_PROVIDER_ENABLED_VALUE="N"
  CUSTOM_PROVIDER_ID_VALUE=""
  CUSTOM_PROVIDER_NAME_VALUE=""
  CUSTOM_PROVIDER_BASE_URL_VALUE=""
  CUSTOM_PROVIDER_API_KEY_VALUE=""
  CUSTOM_PROVIDER_MODELS_VALUE=""

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

  prompt_value_with_default CUSTOM_PROVIDER_NAME_VALUE "provider name" "${existing_provider_name:-$CUSTOM_PROVIDER_ID_VALUE}"
  [ -n "$CUSTOM_PROVIDER_NAME_VALUE" ] || CUSTOM_PROVIDER_NAME_VALUE="$CUSTOM_PROVIDER_ID_VALUE"

  prompt_value_with_default CUSTOM_PROVIDER_BASE_URL_VALUE "base URL" "$existing_provider_base_url"
  if [ -z "$CUSTOM_PROVIDER_BASE_URL_VALUE" ]; then
    warn "Skipping custom provider: base URL is required."
    return 0
  fi

  prompt_value_with_default CUSTOM_PROVIDER_API_KEY_VALUE "API key" "${existing_provider_api_key:-YOUR_API_KEY}" "Y"
  [ -n "$CUSTOM_PROVIDER_API_KEY_VALUE" ] || CUSTOM_PROVIDER_API_KEY_VALUE="YOUR_API_KEY"

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

  if [ -z "$CUSTOM_PROVIDER_MODELS_VALUE" ]; then
    warn "Skipping custom provider: add at least one model to install it."
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

sync_directory() {
  local source_dir="$1" target_dir="$2"
  [ -d "$source_dir" ] || die "sync_directory: source missing: $source_dir"
  [ "$source_dir" = "$target_dir" ] && die "sync_directory: source and target identical"

  mkdir -p "$(dirname "$target_dir")"
  rm -rf "$target_dir"
  mkdir -p "$target_dir"
  cp -R "$source_dir"/. "$target_dir"/
}

is_b_skills_skill_dir() {
  local skill_dir="$1"
  [ -f "$skill_dir/SKILL.md" ] || return 1
  grep -Eq '^[[:space:]]*suite:[[:space:]]*b-skills[[:space:]]*$' "$skill_dir/SKILL.md"
}

is_legacy_b_skills_command_name() {
  case "$1" in
    b-plan|b-research|b-implement|b-refactor|b-debug|b-test|b-e2e|b-review)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_b_skills_command_file() {
  local command_file="$1"
  local command_name
  [ -f "$command_file" ] || return 1
  grep -q '<!-- b-skills-managed -->' "$command_file" && return 0

  command_name=$(basename "$command_file" .md)
  is_legacy_b_skills_command_name "$command_name" || return 1
  grep -Fq "Load the \`$command_name\` skill and follow it exactly for this request." "$command_file" \
    && grep -Fq '$ARGUMENTS' "$command_file"
}

prune_stale_skills() {
  local source_dir="$1" target_dir="$2" removed=0 skill_name
  [ -d "$target_dir" ] || { printf '0'; return; }

  # Only prune explicitly b-skills-managed entries so unrelated user skills stay intact.
  for installed_dir in "$target_dir"/b-*; do
    [ -d "$installed_dir" ] || continue
    is_b_skills_skill_dir "$installed_dir" || continue
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

  # Only prune explicitly b-skills-managed wrappers so unrelated user commands stay intact.
  for installed_file in "$target_dir"/b-*.md; do
    [ -f "$installed_file" ] || continue
    is_b_skills_command_file "$installed_file" || continue
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
  merged=$(env \
    CONFIG_FILE="$CONFIG_FILE" \
    EXISTING="$existing" \
    BRAVE_API_KEY_VALUE="$BRAVE_API_KEY_VALUE" \
    CONTEXT7_API_KEY_VALUE="$CONTEXT7_API_KEY_VALUE" \
    FIRECRAWL_API_KEY_VALUE="$FIRECRAWL_API_KEY_VALUE" \
    INSTALL_MCPS_VALUE="$INSTALL_MCPS_VALUE" \
    CUSTOM_PROVIDER_ENABLED_VALUE="$CUSTOM_PROVIDER_ENABLED_VALUE" \
    CUSTOM_PROVIDER_ID_VALUE="$CUSTOM_PROVIDER_ID_VALUE" \
    CUSTOM_PROVIDER_NAME_VALUE="$CUSTOM_PROVIDER_NAME_VALUE" \
    CUSTOM_PROVIDER_BASE_URL_VALUE="$CUSTOM_PROVIDER_BASE_URL_VALUE" \
    CUSTOM_PROVIDER_API_KEY_VALUE="$CUSTOM_PROVIDER_API_KEY_VALUE" \
    CUSTOM_PROVIDER_MODELS_VALUE="$CUSTOM_PROVIDER_MODELS_VALUE" \
    python3 - <<'PYEOF'
import json, os

existing_raw = os.environ.get("EXISTING", "{}")
brave_api_key = os.environ.get("BRAVE_API_KEY_VALUE") or "YOUR_API_KEY"
context7_api_key = os.environ.get("CONTEXT7_API_KEY_VALUE") or "YOUR_API_KEY"
firecrawl_api_key = os.environ.get("FIRECRAWL_API_KEY_VALUE") or "YOUR_API_KEY"
install_mcps = (os.environ.get("INSTALL_MCPS_VALUE") or "").strip().lower() in {"y", "yes"}
custom_provider_enabled = (os.environ.get("CUSTOM_PROVIDER_ENABLED_VALUE") or "").strip().lower() in {"y", "yes"}
custom_provider_id = (os.environ.get("CUSTOM_PROVIDER_ID_VALUE") or "").strip()
custom_provider_name = (os.environ.get("CUSTOM_PROVIDER_NAME_VALUE") or "").strip()
custom_provider_base_url = (os.environ.get("CUSTOM_PROVIDER_BASE_URL_VALUE") or "").strip()
custom_provider_api_key = os.environ.get("CUSTOM_PROVIDER_API_KEY_VALUE") or "YOUR_API_KEY"
custom_provider_models_raw = os.environ.get("CUSTOM_PROVIDER_MODELS_VALUE", "")


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
    "gitnexus": {
        "type": "local",
        "command": [
            "gitnexus",
            "mcp",
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

custom_provider_models = parse_custom_provider_models(custom_provider_models_raw)

if custom_provider_enabled and custom_provider_id and custom_provider_base_url and custom_provider_models:
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

section "Provider setup"
collect_custom_provider_config

merge_opencode_config
log "✅ Config updated"

section "MCP defaults"
if wants_mcp_install "$INSTALL_MCPS_VALUE"; then
  log "✅ MCP defaults merged"
  log "   Servers: serena, context7, brave-search, firecrawl, playwright, sequential-thinking (optional), gitnexus"
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
  log "   models:   $(count_custom_provider_models)"
  log "   apiKey:   $(api_key_status "$CUSTOM_PROVIDER_API_KEY_VALUE")"
else
  log "⏭ Custom provider skipped."
fi

section "Done"
log "✅ b-skills installed successfully for OpenCode."
log "   Skills:       $OPENCODE_DIR/skills"
log "   Commands:     $OPENCODE_DIR/commands"
  log "   AGENTS.md:    $RULES_DST"
log "   Config:       $CONFIG_FILE"

trap - EXIT
