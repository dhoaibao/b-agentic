#!/usr/bin/env bash
# install.sh - Bootstrap or update b-agentic
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --dry-run
#   curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --uninstall

set -euo pipefail

readonly REPO_URL="${B_AGENTIC_REPO:-https://github.com/dhoaibao/b-agentic.git}"
readonly LOCAL_REPO="${B_AGENTIC_DIR:-$HOME/.b-agentic}"
readonly REF="${B_AGENTIC_REF:-}"
readonly TIMESTAMP="$(date +%Y%m%d%H%M%S)"

DRY_RUN_VALUE="${B_AGENTIC_DRY_RUN:-N}"
REPLACE_MEMORY_VALUE="${B_AGENTIC_REPLACE_MEMORY:-}"
UNINSTALL_VALUE="${B_AGENTIC_UNINSTALL:-N}"
PROMPT_API_KEYS_VALUE="${B_AGENTIC_PROMPT_API_KEYS:-auto}"
RUNTIME="${B_AGENTIC_RUNTIME:-claude-code}"

SOURCE_DIR="$LOCAL_REPO"
SKILLS_SRC="$SOURCE_DIR/skills"
REFERENCES_SRC="$SOURCE_DIR/references"
TEMPLATES_SRC="$SOURCE_DIR/runtimes/$RUNTIME/configs"
KERNEL_SRC="$SOURCE_DIR/runtimes/$RUNTIME/kernel.md"
DRY_RUN_SOURCE_DIR=""

log() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [ -n "$DRY_RUN_SOURCE_DIR" ]; then
    rm -rf "$DRY_RUN_SOURCE_DIR"
  fi
}

trap cleanup EXIT

yes_value() {
  case "${1:-}" in
    y|Y|yes|YES|Yes|true|TRUE|1) return 0 ;;
    *) return 1 ;;
  esac
}

dry_run_enabled() {
  yes_value "$DRY_RUN_VALUE"
}

replace_memory_enabled() {
  yes_value "$REPLACE_MEMORY_VALUE"
}

uninstall_enabled() {
  yes_value "$UNINSTALL_VALUE"
}

can_prompt_api_keys() {
  ! dry_run_enabled || return 1
  case "$PROMPT_API_KEYS_VALUE" in
    n|N|no|NO|No|false|FALSE|0) return 1 ;;
    auto|AUTO|Auto|y|Y|yes|YES|Yes|true|TRUE|1) ;;
    *) die "invalid B_AGENTIC_PROMPT_API_KEYS value: $PROMPT_API_KEYS_VALUE" ;;
  esac
  [ -r /dev/tty ] && [ -w /dev/tty ]
}

run_cmd() {
  if dry_run_enabled; then
    printf '[dry-run] %s\n' "$*" >&2
    return 0
  fi
  "$@"
}

ensure_repo_gitignore_guard() {
  # Only act when in a git repo and the guard is missing
  [ -d .git ] || [ -f .git ] || return 0
  if [ -f .b-agentic/.gitignore ]; then
    return 0
  fi
  run_cmd mkdir -p .b-agentic
  printf '*' | run_cmd tee .b-agentic/.gitignore >/dev/null
}

ensure_dir() {
  local dir_path="$1"
  run_cmd mkdir -p "$dir_path"
}

copy_file() {
  local src="$1" dst="$2"
  ensure_dir "$(dirname "$dst")"
  run_cmd cp "$src" "$dst"
}

copy_dir_replace() {
  local src="$1" dst="$2"
  ensure_dir "$(dirname "$dst")"
  if dry_run_enabled; then
    printf '[dry-run] rm -rf %s\n' "$dst" >&2
    printf '[dry-run] cp -R %s %s\n' "$src" "$dst" >&2
    return 0
  fi
  rm -rf "$dst"
  cp -R "$src" "$dst"
}

backup_file() {
  local path="$1"
  [ -f "$path" ] || return 0
  local backups_dir="${BACKUPS_DIR:-${TMPDIR:-/tmp}/b-agentic-backups}"
  ensure_dir "$backups_dir"
  local backup="$backups_dir/$(basename "$path").bak-$TIMESTAMP"
  copy_file "$path" "$backup"
  printf '%s' "$backup"
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || die "required binary not found: $1"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run)
        DRY_RUN_VALUE=Y
        ;;
      --replace-memory)
        REPLACE_MEMORY_VALUE=Y
        ;;
      --preserve-memory)
        REPLACE_MEMORY_VALUE=N
        ;;
      --uninstall)
        UNINSTALL_VALUE=Y
        ;;
      --prompt-api-keys)
        PROMPT_API_KEYS_VALUE=Y
        ;;
      --no-prompt-api-keys)
        PROMPT_API_KEYS_VALUE=N
        ;;
      --runtime=*)
        RUNTIME="${1#--runtime=}"
        case "$RUNTIME" in
          *[^a-z0-9_-]*) die "invalid runtime name: $RUNTIME (use lowercase alphanumeric, dashes, underscores)" ;;
        esac
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
    shift
  done
}

set_source_dir() {
  SOURCE_DIR="$1"
  SKILLS_SRC="$SOURCE_DIR/skills"
  REFERENCES_SRC="$SOURCE_DIR/references"
  TEMPLATES_SRC="$SOURCE_DIR/runtimes/$RUNTIME/configs"
  KERNEL_SRC="$SOURCE_DIR/runtimes/$RUNTIME/kernel.md"
}

sync_source() {
  require_bin git
  require_bin python3

  if dry_run_enabled; then
    if [ -d "$LOCAL_REPO/.git" ] || [ -d "$LOCAL_REPO/skills" ]; then
      log "Dry-run source: $LOCAL_REPO (no fetch/pull)"
      set_source_dir "$LOCAL_REPO"
    else
      DRY_RUN_SOURCE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/b-agentic-dry-run.XXXXXX")"
      log "Dry-run source clone: $REPO_URL -> $DRY_RUN_SOURCE_DIR"
      git clone "$REPO_URL" "$DRY_RUN_SOURCE_DIR"
      if [ -n "$REF" ]; then
        git -C "$DRY_RUN_SOURCE_DIR" checkout "$REF"
      fi
      set_source_dir "$DRY_RUN_SOURCE_DIR"
    fi
  elif [ -d "$LOCAL_REPO/.git" ]; then
    log "Updating source: $LOCAL_REPO"
    git -C "$LOCAL_REPO" fetch --all --tags --prune
    if [ -n "$REF" ]; then
      git -C "$LOCAL_REPO" checkout "$REF"
    else
      git -C "$LOCAL_REPO" pull --ff-only
    fi
    set_source_dir "$LOCAL_REPO"
  else
    log "Cloning source: $REPO_URL -> $LOCAL_REPO"
    mkdir -p "$(dirname "$LOCAL_REPO")"
    git clone "$REPO_URL" "$LOCAL_REPO"
    if [ -n "$REF" ]; then
      git -C "$LOCAL_REPO" checkout "$REF"
    fi
    set_source_dir "$LOCAL_REPO"
  fi

  [ -d "$SKILLS_SRC" ] || die "missing source directory: $SKILLS_SRC"
  [ -d "$REFERENCES_SRC" ] || die "missing source directory: $REFERENCES_SRC"
  [ -d "$TEMPLATES_SRC" ] || die "missing source directory: $TEMPLATES_SRC"
  [ -f "$KERNEL_SRC" ] || die "missing kernel source: $KERNEL_SRC"
}

skill_names() {
  python3 - "$SKILLS_SRC" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for path in sorted(root.glob('*/SKILL.md')):
    print(path.parent.name)
PY
}

sync_references_into_skill() {
  local skill_dir="$1"
  local support_dir="$skill_dir/references/b-agentic"
  ensure_dir "$support_dir"
  if dry_run_enabled; then
    printf '[dry-run] cp -r %s/* %s/\n' "$REFERENCES_SRC" "$support_dir" >&2
    return 0
  fi
  cp -r "$REFERENCES_SRC"/* "$support_dir"/
}

install_skills() {
  ensure_dir "$SKILLS_DST"
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    copy_dir_replace "$SKILLS_SRC/$name" "$SKILLS_DST/$name"
    sync_references_into_skill "$SKILLS_DST/$name"
  done < <(skill_names)
}

install_references_and_templates() {
  copy_dir_replace "$REFERENCES_SRC" "$REFERENCES_DST"
  copy_dir_replace "$TEMPLATES_SRC" "$TEMPLATES_DST"
}

install_kernel() {
  ensure_dir "$METADATA_DIR"
  copy_file "$KERNEL_SRC" "$KERNEL_SNAPSHOT_DST"

  if [ ! -e "$KERNEL_DST" ]; then
    copy_file "$KERNEL_SRC" "$KERNEL_DST"
    printf 'replace\nactive\nnone'
    return 0
  fi

  if grep -Fq '<!-- b-agentic-managed -->' "$KERNEL_DST"; then
    local backup
    backup="$(backup_file "$KERNEL_DST")"
    copy_file "$KERNEL_SRC" "$KERNEL_DST"
    printf 'replace\nactive\n%s' "${backup:-none}"
    return 0
  fi

  if replace_memory_enabled; then
    local backup
    backup="$(backup_file "$KERNEL_DST")"
    copy_file "$KERNEL_SRC" "$KERNEL_DST"
    printf 'replace\nactive\n%s' "${backup:-none}"
    return 0
  fi

  printf 'preserve\npending\nnone'
}

remove_managed_kernel() {
  if [ -f "$KERNEL_DST" ] && grep -Fq '<!-- b-agentic-managed -->' "$KERNEL_DST"; then
    if [ -f "$KERNEL_SNAPSHOT_DST" ] && cmp -s "$KERNEL_DST" "$KERNEL_SNAPSHOT_DST"; then
      run_cmd rm -f "$KERNEL_DST"
    else
      warn "preserving modified managed kernel: $KERNEL_DST"
    fi
  fi
}

merge_json_file() {
  local src="$1" dst="$2" label="$3" backup_key="$4"
  if [ ! -e "$dst" ]; then
    copy_file "$src" "$dst"
    printf 'write\nactive\nnone'
    return 0
  fi

  if dry_run_enabled; then
    printf '[dry-run] merge %s %s into %s\n' "$label" "$src" "$dst" >&2
    printf 'merge\nactive\n%s' "$(manifest_backup_value "$backup_key" none)"
    return 0
  fi

  local tmp rc
  tmp="$(mktemp "${TMPDIR:-/tmp}/b-agentic-${label}.XXXXXX")"
  if env JSON_SRC="$src" JSON_DST="$dst" JSON_TMP="$tmp" JSON_LABEL="$label" python3 - <<'PY'
import json
import os
from pathlib import Path

src = Path(os.environ['JSON_SRC'])
dst = Path(os.environ['JSON_DST'])
tmp = Path(os.environ['JSON_TMP'])
label = os.environ['JSON_LABEL']
recommended = json.loads(src.read_text())
current = json.loads(dst.read_text())

def merge(existing, incoming):
    if isinstance(existing, dict) and isinstance(incoming, dict):
        merged = dict(existing)
        for key, value in incoming.items():
            if key not in merged:
                merged[key] = value
            else:
                merged[key] = merge(merged[key], value)
        return merged
    if isinstance(existing, list) and isinstance(incoming, list):
        merged = list(existing)
        for item in incoming:
            if item not in merged:
                merged.append(item)
        return merged
    return existing

def migrate_managed_values(data):
    if label != 'mcp':
        return

    def migrate_managed_launcher(server, incoming_server, old_command, old_args=None):
        if not isinstance(server, dict) or not isinstance(incoming_server, dict):
            return

        incoming_command = incoming_server.get('command')
        if isinstance(incoming_command, str) and isinstance(old_command, str):
            if server.get('command') == old_command and server.get('args') == old_args:
                server['command'] = incoming_command
                server['args'] = list(incoming_server.get('args', []))
            return

        if isinstance(incoming_command, list) and isinstance(old_command, list):
            legacy_commands = [list(old_command)]
            if old_command and old_command[0] == 'npx' and incoming_command and incoming_command[0] == 'bunx':
                legacy_commands.append(list(old_command) + [incoming_command[0]])
            if server.get('command') in legacy_commands:
                server['command'] = list(incoming_command)

    for server_key in ('mcpServers', 'mcp'):
        servers = data.get(server_key)
        recommended_servers = recommended.get(server_key, {})
        if not isinstance(servers, dict) or not isinstance(recommended_servers, dict):
            continue

        if server_key == 'mcpServers':
            context7 = servers.get('context7')
            headers = context7.get('headers') if isinstance(context7, dict) else None
            if isinstance(headers, dict) and headers.get('CONTEXT7_API_KEY') == '${CONTEXT7_API_KEY}':
                headers['CONTEXT7_API_KEY'] = '${CONTEXT7_API_KEY:-}'

            gitnexus = servers.get('gitnexus')
            if isinstance(gitnexus, dict) and gitnexus.get('command') == 'npx' and gitnexus.get('args') == ['-y', 'gitnexus@latest', 'mcp']:
                gitnexus['command'] = 'gitnexus'
                gitnexus['args'] = ['mcp']

            migrate_managed_launcher(
                servers.get('brave-search'),
                recommended_servers.get('brave-search'),
                'npx',
                ['-y', '@brave/brave-search-mcp-server', '--transport', 'stdio'],
            )
            migrate_managed_launcher(
                servers.get('firecrawl'),
                recommended_servers.get('firecrawl'),
                'npx',
                ['-y', 'firecrawl-mcp'],
            )
            migrate_managed_launcher(
                servers.get('playwright'),
                recommended_servers.get('playwright'),
                'npx',
                ['-y', '@playwright/mcp@latest', '--isolated'],
            )
            continue

        migrate_managed_launcher(
            servers.get('brave-search'),
            recommended_servers.get('brave-search'),
            ['npx', '-y', '@brave/brave-search-mcp-server', '--transport', 'stdio'],
        )
        migrate_managed_launcher(
            servers.get('firecrawl'),
            recommended_servers.get('firecrawl'),
            ['npx', '-y', 'firecrawl-mcp'],
        )
        migrate_managed_launcher(
            servers.get('playwright'),
            recommended_servers.get('playwright'),
            ['npx', '-y', '@playwright/mcp@latest', '--isolated'],
        )

if not isinstance(current, dict):
    raise SystemExit(f'{label} merge requires existing target to be a JSON object')

merged = merge(current, recommended)
migrate_managed_values(merged)
if merged == current:
    raise SystemExit(2)
tmp.write_text(json.dumps(merged, indent=2, sort_keys=True) + '\n')
PY
  then
    rc=0
  else
    rc=$?
  fi

  if [ "$rc" -eq 2 ]; then
    rm -f "$tmp"
    printf 'merge\nactive\n%s' "$(manifest_backup_value "$backup_key" none)"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    die "failed to merge $label config: $dst"
  fi

  local backup
  backup="$(backup_file "$dst")"
  run_cmd mv "$tmp" "$dst"
  printf 'merge\nactive\n%s' "${backup:-none}"
}

manifest_path_value() {
  local key="$1" fallback="$2"
  if [ ! -f "$MANIFEST_DST" ]; then
    printf '%s' "$fallback"
    return 0
  fi
  python3 - "$MANIFEST_DST" "$key" "$fallback" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
key = sys.argv[2]
fallback = sys.argv[3]
try:
    data = json.loads(path.read_text())
    print(data.get('paths', {}).get(key, fallback))
except Exception:
    print(fallback)
PY
}

manifest_backup_value() {
  local key="$1" fallback="$2"
  if [ ! -f "$MANIFEST_DST" ]; then
    printf '%s' "$fallback"
    return 0
  fi
  python3 - "$MANIFEST_DST" "$key" "$fallback" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
key = sys.argv[2]
fallback = sys.argv[3]
try:
    data = json.loads(path.read_text())
    print(data.get('backups', {}).get(key, fallback))
except Exception:
    print(fallback)
PY
}

manifest_action_value() {
  local key="$1" fallback="$2"
  if [ ! -f "$MANIFEST_DST" ]; then
    printf '%s' "$fallback"
    return 0
  fi
  python3 - "$MANIFEST_DST" "$key" "$fallback" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
key = sys.argv[2]
fallback = sys.argv[3]
try:
    data = json.loads(path.read_text())
    print(data.get(key, fallback))
except Exception:
    print(fallback)
PY
}

remove_managed_config() {
  local path="$1" template="$2" label="$3"
  [ -f "$path" ] || return 0
  if [ -f "$template" ] && cmp -s "$path" "$template"; then
    run_cmd rm -f "$path"
  else
    warn "preserving modified $label: $path"
  fi
}

remove_merged_config() {
  local path="$1" template="$2" label="$3" backup_key="$4" action_key="$5"
  [ -f "$path" ] || return 0
  if [ -f "$template" ] && cmp -s "$path" "$template"; then
    run_cmd rm -f "$path"
    return 0
  fi

  local original
  original="$(manifest_backup_value "$backup_key" "")"
  if [ ! -f "$original" ] && [ "$(manifest_action_value "$action_key" "")" = "write" ]; then
    original="empty"
  fi
  if [ "$original" != "empty" ] && [ ! -f "$original" ]; then
    warn "preserving modified $label: $path"
    return 0
  fi
  if dry_run_enabled; then
    printf '[dry-run] remove managed %s entries from %s\n' "$label" "$path" >&2
    return 0
  fi

  local tmp rc
  tmp="$(mktemp "${TMPDIR:-/tmp}/b-agentic-uninstall-${label}.XXXXXX")"
  if env JSON_CURRENT="$path" JSON_TEMPLATE="$template" JSON_ORIGINAL="$original" JSON_TMP="$tmp" JSON_LABEL="$label" python3 - <<'PY'
import json
import os
from pathlib import Path

current_path = Path(os.environ['JSON_CURRENT'])
template_path = Path(os.environ['JSON_TEMPLATE'])
original_path = Path(os.environ['JSON_ORIGINAL'])
tmp_path = Path(os.environ['JSON_TMP'])
label = os.environ['JSON_LABEL']

current = json.loads(current_path.read_text())
incoming = json.loads(template_path.read_text())
original = {} if str(original_path) == 'empty' else json.loads(original_path.read_text())

MISSING = object()

def cleanup(current_value, incoming_value, original_value):
    if isinstance(current_value, dict) and isinstance(incoming_value, dict):
        original_dict = original_value if isinstance(original_value, dict) else {}
        result = dict(current_value)
        for key, incoming_child in incoming_value.items():
            if key not in result:
                continue
            original_child = original_dict.get(key, MISSING)
            current_child = result[key]
            if original_child is MISSING:
                if current_child == incoming_child:
                    result.pop(key)
                elif isinstance(current_child, (dict, list)) and isinstance(incoming_child, type(current_child)):
                    empty_original = {} if isinstance(current_child, dict) else []
                    cleaned = cleanup(current_child, incoming_child, empty_original)
                    if cleaned in ({}, []):
                        result.pop(key)
                    else:
                        result[key] = cleaned
            else:
                result[key] = cleanup(current_child, incoming_child, original_child)
        return result

    if isinstance(current_value, list) and isinstance(incoming_value, list):
        original_list = original_value if isinstance(original_value, list) else []
        result = list(current_value)
        for item in incoming_value:
            if item not in original_list and item in result:
                result.remove(item)
        return result

    return current_value

def managed_mcp_server(current_server, incoming_server, server_name):
    if not isinstance(current_server, dict) or not isinstance(incoming_server, dict):
        return False
    normalized = json.loads(json.dumps(current_server))

    def normalize_managed_launcher(old_command, old_args=None):
        incoming_command = incoming_server.get('command')
        if isinstance(incoming_command, str) and isinstance(old_command, str):
            if normalized.get('command') == old_command and normalized.get('args') == old_args:
                normalized['command'] = incoming_command
                normalized['args'] = list(incoming_server.get('args', []))
            return

        if isinstance(incoming_command, list) and isinstance(old_command, list):
            legacy_commands = [list(old_command)]
            if old_command and old_command[0] == 'npx' and incoming_command and incoming_command[0] == 'bunx':
                legacy_commands.append(list(old_command) + [incoming_command[0]])
            if normalized.get('command') in legacy_commands:
                normalized['command'] = list(incoming_command)

    if server_name == 'context7':
        headers = normalized.get('headers')
        incoming_headers = incoming_server.get('headers', {})
        if isinstance(headers, dict) and isinstance(incoming_headers, dict) and 'CONTEXT7_API_KEY' in headers:
            headers['CONTEXT7_API_KEY'] = incoming_headers.get('CONTEXT7_API_KEY')
    elif server_name == 'brave-search':
        env_key = 'environment' if 'environment' in incoming_server else 'env'
        env = normalized.get(env_key)
        incoming_env = incoming_server.get(env_key, {})
        if isinstance(env, dict) and isinstance(incoming_env, dict) and 'BRAVE_API_KEY' in env:
            env['BRAVE_API_KEY'] = incoming_env.get('BRAVE_API_KEY')
        if env_key == 'env':
            normalize_managed_launcher('npx', ['-y', '@brave/brave-search-mcp-server', '--transport', 'stdio'])
        else:
            normalize_managed_launcher(['npx', '-y', '@brave/brave-search-mcp-server', '--transport', 'stdio'])
    elif server_name == 'firecrawl':
        env_key = 'environment' if 'environment' in incoming_server else 'env'
        env = normalized.get(env_key)
        incoming_env = incoming_server.get(env_key, {})
        if isinstance(env, dict) and isinstance(incoming_env, dict) and 'FIRECRAWL_API_KEY' in env:
            env['FIRECRAWL_API_KEY'] = incoming_env.get('FIRECRAWL_API_KEY')
        if env_key == 'env':
            normalize_managed_launcher('npx', ['-y', 'firecrawl-mcp'])
        else:
            normalize_managed_launcher(['npx', '-y', 'firecrawl-mcp'])
    elif server_name == 'playwright':
        if isinstance(incoming_server.get('command'), str):
            normalize_managed_launcher('npx', ['-y', '@playwright/mcp@latest', '--isolated'])
        else:
            normalize_managed_launcher(['npx', '-y', '@playwright/mcp@latest', '--isolated'])
    elif server_name == 'gitnexus':
        if normalized.get('command') == 'npx' and normalized.get('args') == ['-y', 'gitnexus@latest', 'mcp']:
            normalized['command'] = 'gitnexus'
            normalized['args'] = ['mcp']
    return normalized == incoming_server

if not isinstance(current, dict) or not isinstance(incoming, dict) or not isinstance(original, dict):
    raise SystemExit(f'{label} cleanup requires JSON object inputs')

cleaned = cleanup(current, incoming, original)
if label in ('.claude.json', 'opencode.json'):
    mcp_key = 'mcp' if label == 'opencode.json' else 'mcpServers'
    cleaned_servers = cleaned.get(mcp_key)
    incoming_servers = incoming.get(mcp_key, {})
    original_servers = original.get(mcp_key, {})
    if isinstance(cleaned_servers, dict) and isinstance(incoming_servers, dict):
        for server_name in incoming_servers:
            if not isinstance(original_servers, dict) or server_name not in original_servers:
                cleaned_servers.pop(server_name, None)
                continue
            if managed_mcp_server(cleaned_servers.get(server_name), incoming_servers.get(server_name), server_name):
                cleaned_servers.pop(server_name, None)
        if not cleaned_servers:
            cleaned.pop(mcp_key, None)
if cleaned == current:
    raise SystemExit(2)
if cleaned == {}:
    raise SystemExit(3)
tmp_path.write_text(json.dumps(cleaned, indent=2, sort_keys=True) + '\n')
PY
  then
    rc=0
  else
    rc=$?
  fi

  if [ "$rc" -eq 2 ]; then
    rm -f "$tmp"
    warn "preserving modified $label: $path"
    return 0
  fi
  if [ "$rc" -eq 3 ]; then
    rm -f "$tmp"
    rm -f "$path"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    warn "preserving modified $label: $path"
    return 0
  fi

  mv "$tmp" "$path"
}

main() {
  parse_args "$@"

  if uninstall_enabled; then
    # Skip git pull when the local clone already exists; uninstall only needs the scripts on disk.
    [ -d "$LOCAL_REPO/.git" ] || sync_source
  else
    sync_source
  fi

  local runtime_script="$SOURCE_DIR/runtimes/$RUNTIME/scripts/install.sh"
  [ -f "$runtime_script" ] || die "missing runtime install script: $runtime_script"
  source "$runtime_script"

  if uninstall_enabled; then
    runtime_uninstall
    return 0
  fi

  runtime_main
}

main "$@"
