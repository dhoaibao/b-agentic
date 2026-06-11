# Common installer core sourced by install.sh after source sync.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by install.sh" >&2
  exit 1
fi

ensure_dir() {
  local dir_path="$1"
  run_cmd mkdir -p "$dir_path"
}

INSTALL_STAGE_CURRENT=0
INSTALL_STAGE_TOTAL=0
INSTALL_STAGE_LABEL=""

set_install_stage_total() {
  INSTALL_STAGE_CURRENT=0
  INSTALL_STAGE_TOTAL="${1:-0}"
}

set_next_install_stage_label() {
  local label="$1"
  INSTALL_STAGE_CURRENT=$((INSTALL_STAGE_CURRENT + 1))

  if [ "${INSTALL_STAGE_TOTAL:-0}" -gt 0 ]; then
    printf -v INSTALL_STAGE_LABEL '[%s/%s] %s' "$INSTALL_STAGE_CURRENT" "$INSTALL_STAGE_TOTAL" "$label"
    return 0
  fi

  printf -v INSTALL_STAGE_LABEL '[%s] %s' "$INSTALL_STAGE_CURRENT" "$label"
}

announce_install_stage() {
  local stage_label="$1"
  log "==> $stage_label"
}

run_stage() {
  local label="$1"
  shift
  local rc=0 stage_label=""

  set_next_install_stage_label "$label"
  stage_label="$INSTALL_STAGE_LABEL"
  announce_install_stage "$stage_label"

  if dry_run_enabled; then
    "$@"
    return $?
  fi

  if "$@"; then
    rc=0
  else
    rc=$?
  fi
  return "$rc"
}

capture_output_stage() {
  local label="$1" output_var="$2"
  shift 2
  local output="" rc=0 stage_label=""

  set_next_install_stage_label "$label"
  stage_label="$INSTALL_STAGE_LABEL"
  announce_install_stage "$stage_label"

  if dry_run_enabled; then
    output="$("$@")"
    printf -v "$output_var" '%s' "$output"
    return $?
  fi

  if output=$("$@"); then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -eq 0 ] || return "$rc"

  printf -v "$output_var" '%s' "$output"
}

run_install_triplet_stage() {
  local label="$1" command_name="$2" default_action="$3" default_state="$4" default_backup="$5"
  local action_var="$6" state_var="$7" backup_var="$8"
  local result=""

  capture_output_stage "$label" result "$command_name"
  read_install_triplet "$result" "$default_action" "$default_state" "$default_backup" \
    "$action_var" "$state_var" "$backup_var"
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

skill_names() {
  python3 - "$SKILLS_SRC" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
for path in sorted(root.glob('*/SKILL.md')):
    print(path.parent.name)
PY
}

managed_asset_name_is_safe() {
  local name="$1"
  case "$name" in
    b-[a-z]*)
      ;;
    *)
      return 1
      ;;
  esac

  case "$name" in
    *[!a-z0-9-]*|*-)
      return 1
      ;;
  esac

  return 0
}

managed_profile_name_is_safe() {
  managed_asset_name_is_safe "$1"
}

managed_profile_names() {
  local src_dir="$1" extension="$2"
  python3 - "$src_dir" "$extension" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
extension = sys.argv[2]
for path in sorted(root.glob(f'*.{extension}')):
    print(path.stem)
PY
}

install_managed_profiles() {
  local src_dir="$1" dst_dir="$2" snapshot_dir="$3" extension="$4" label="$5" output_var="$6"
  eval "$output_var=()"

  [ -d "$src_dir" ] || return 0
  ensure_dir "$dst_dir"

  local name src dst previous_snapshot next_snapshot
  next_snapshot="$(mktemp -d "${TMPDIR:-/tmp}/b-agentic-${label}.XXXXXX")"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    src="$src_dir/$name.$extension"
    dst="$dst_dir/$name.$extension"
    previous_snapshot="$snapshot_dir/$name.$extension"

    if [ -f "$dst" ]; then
      if [ -f "$previous_snapshot" ] && cmp -s "$dst" "$previous_snapshot"; then
        copy_file "$src" "$dst"
        copy_file "$src" "$next_snapshot/$name.$extension"
        eval "$output_var+=(\"$name\")"
        continue
      fi
      if cmp -s "$dst" "$src"; then
        if [ -f "$previous_snapshot" ]; then
          copy_file "$src" "$next_snapshot/$name.$extension"
          eval "$output_var+=(\"$name\")"
        else
          warn "preserving existing $label profile: $dst"
        fi
        continue
      fi
      if [ -f "$previous_snapshot" ]; then
        warn "preserving modified $label profile: $dst"
      else
        warn "preserving existing $label profile: $dst"
      fi
      continue
    fi

    copy_file "$src" "$dst"
    copy_file "$src" "$next_snapshot/$name.$extension"
    eval "$output_var+=(\"$name\")"
  done < <(managed_profile_names "$src_dir" "$extension")

  copy_dir_replace "$next_snapshot" "$snapshot_dir"
  rm -rf "$next_snapshot"
}

uninstall_managed_profiles() {
  local manifest_key="$1" dst_dir="$2" snapshot_dir="$3" extension="$4" label="$5"
  local name path snapshot names_source
  names_source="$(mktemp "${TMPDIR:-/tmp}/b-agentic-${manifest_key}.XXXXXX")"
  manifest_array_values "$manifest_key" >"$names_source" || true
  if [ ! -s "$names_source" ]; then
    managed_profile_names "$snapshot_dir" "$extension" >"$names_source"
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! managed_profile_name_is_safe "$name"; then
      warn "preserving $label profile with unsafe manifest name"
      continue
    fi
    path="$dst_dir/$name.$extension"
    snapshot="$snapshot_dir/$name.$extension"
    [ -f "$path" ] || continue
    if [ ! -f "$snapshot" ]; then
      warn "preserving $label profile with no managed snapshot: $path"
      continue
    fi
    if cmp -s "$path" "$snapshot"; then
      run_cmd rm -f "$path"
    else
      warn "preserving modified $label profile: $path"
    fi
  done < "$names_source"
  rm -f "$names_source"
}

skill_name_is_current() {
  local target="$1" name
  while IFS= read -r name; do
    [ "$name" = "$target" ] && return 0
  done < <(skill_names)
  return 1
}

prune_stale_installed_skills() {
  [ -f "$MANIFEST_DST" ] || return 0

  local name skill_dir skill_file
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! managed_asset_name_is_safe "$name"; then
      warn "preserving stale skill with unsafe manifest name"
      continue
    fi
    skill_name_is_current "$name" && continue

    skill_dir="$SKILLS_DST/$name"
    skill_file="$skill_dir/SKILL.md"
    [ -e "$skill_dir" ] || continue

    if [ -f "$skill_file" ] && grep -Fq 'Generated from skills/registry.yaml' "$skill_file"; then
      run_cmd rm -rf "$skill_dir"
    else
      warn "preserving stale skill without managed marker: $skill_dir"
    fi
  done < <(manifest_array_values skills)
}

skill_dir_is_managed() {
  local skill_dir="$1" skill_file
  skill_file="$skill_dir/SKILL.md"
  [ -f "$skill_file" ] && grep -Fq 'Generated from skills/registry.yaml' "$skill_file"
}

install_one_skill() {
  local name="$1" src="$SKILLS_SRC/$name" dst="$SKILLS_DST/$name"

  if [ -e "$dst" ] && ! skill_dir_is_managed "$dst"; then
    warn "preserving user-owned skill directory: $dst"
    return 1
  fi

  copy_dir_replace "$src" "$dst"
  return 0
}

install_skills() {
  ensure_dir "$SKILLS_DST"
  prune_stale_installed_skills

  local name
  INSTALL_SKILL_NAMES=()
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if install_one_skill "$name"; then
      INSTALL_SKILL_NAMES+=("$name")
    fi
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
    printf 'write\nactive\nnone'
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
import re
from pathlib import Path

src = Path(os.environ['JSON_SRC'])
dst = Path(os.environ['JSON_DST'])
tmp = Path(os.environ['JSON_TMP'])
label = os.environ['JSON_LABEL']

def _load_jsonc(text):
    text = re.sub(r'"(?:[^"\\]|\\.)*"|//[^\n]*',
                  lambda m: m.group(0) if m.group(0).startswith('"') else '',
                  text.strip())
    text = re.sub(r',(\s*[}\]])', r'\1', text)
    return json.loads(text) if text.strip() else {}

recommended = json.loads(src.read_text())
current = _load_jsonc(dst.read_text())

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

        def merged_sequence(existing_items, incoming_items):
            merged = list(existing_items)
            for item in incoming_items:
                if item not in merged:
                    merged.append(item)
            return merged

        incoming_command = incoming_server.get('command')
        if isinstance(incoming_command, str) and isinstance(old_command, str):
            legacy_args = [old_args]
            if isinstance(old_args, list):
                legacy_args.append(merged_sequence(old_args, incoming_server.get('args', [])))
            if server.get('command') == old_command and server.get('args') in legacy_args:
                server['command'] = incoming_command
                server['args'] = list(incoming_server.get('args', []))
            return

        if isinstance(incoming_command, list) and isinstance(old_command, list):
            legacy_commands = [list(old_command), merged_sequence(old_command, incoming_command)]
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

            migrate_managed_launcher(
                servers.get('brave-search'),
                recommended_servers.get('brave-search'),
                'npx',
                ['-y', '@brave/brave-search-mcp-server', '--transport', 'stdio'],
            )
            migrate_managed_launcher(
                servers.get('brave-search'),
                recommended_servers.get('brave-search'),
                'bunx',
                ['@brave/brave-search-mcp-server', '--transport', 'stdio'],
            )
            migrate_managed_launcher(
                servers.get('firecrawl'),
                recommended_servers.get('firecrawl'),
                'npx',
                ['-y', 'firecrawl-mcp'],
            )
            migrate_managed_launcher(
                servers.get('firecrawl'),
                recommended_servers.get('firecrawl'),
                'bunx',
                ['firecrawl-mcp'],
            )
            migrate_managed_launcher(
                servers.get('playwright'),
                recommended_servers.get('playwright'),
                'npx',
                ['-y', '@playwright/mcp@latest', '--isolated'],
            )
            migrate_managed_launcher(
                servers.get('playwright'),
                recommended_servers.get('playwright'),
                'bunx',
                ['@playwright/mcp@latest', '--isolated'],
            )
            continue

        migrate_managed_launcher(
            servers.get('brave-search'),
            recommended_servers.get('brave-search'),
            ['npx', '-y', '@brave/brave-search-mcp-server', '--transport', 'stdio'],
        )
        migrate_managed_launcher(
            servers.get('brave-search'),
            recommended_servers.get('brave-search'),
            ['bunx', '@brave/brave-search-mcp-server', '--transport', 'stdio'],
        )
        migrate_managed_launcher(
            servers.get('firecrawl'),
            recommended_servers.get('firecrawl'),
            ['npx', '-y', 'firecrawl-mcp'],
        )
        migrate_managed_launcher(
            servers.get('firecrawl'),
            recommended_servers.get('firecrawl'),
            ['bunx', 'firecrawl-mcp'],
        )
        migrate_managed_launcher(
            servers.get('playwright'),
            recommended_servers.get('playwright'),
            ['npx', '-y', '@playwright/mcp@latest', '--isolated'],
        )
        migrate_managed_launcher(
            servers.get('playwright'),
            recommended_servers.get('playwright'),
            ['bunx', '@playwright/mcp@latest', '--isolated'],
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

manifest_array_values() {
  local key="$1"
  [ -f "$MANIFEST_DST" ] || return 1
  python3 - "$MANIFEST_DST" "$key" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
try:
    data = json.loads(path.read_text())
except Exception:
    data = {}
for value in data.get(key, []):
    print(value)
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
import re
from pathlib import Path

current_path = Path(os.environ['JSON_CURRENT'])
template_path = Path(os.environ['JSON_TEMPLATE'])
original_path = Path(os.environ['JSON_ORIGINAL'])
tmp_path = Path(os.environ['JSON_TMP'])
label = os.environ['JSON_LABEL']

def _load_jsonc(text):
    text = re.sub(r'"(?:[^"\\]|\\.)*"|//[^\n]*',
                  lambda m: m.group(0) if m.group(0).startswith('"') else '',
                  text.strip())
    text = re.sub(r',(\s*[}\]])', r'\1', text)
    return json.loads(text) if text.strip() else {}

current = _load_jsonc(current_path.read_text())
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
        def merged_sequence(existing_items, incoming_items):
            merged = list(existing_items)
            for item in incoming_items:
                if item not in merged:
                    merged.append(item)
            return merged

        incoming_command = incoming_server.get('command')
        if isinstance(incoming_command, str) and isinstance(old_command, str):
            legacy_args = [old_args]
            if isinstance(old_args, list):
                legacy_args.append(merged_sequence(old_args, incoming_server.get('args', [])))
            if normalized.get('command') == old_command and normalized.get('args') in legacy_args:
                normalized['command'] = incoming_command
                normalized['args'] = list(incoming_server.get('args', []))
            return

        if isinstance(incoming_command, list) and isinstance(old_command, list):
            legacy_commands = [list(old_command), merged_sequence(old_command, incoming_command)]
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
            normalize_managed_launcher('bunx', ['@brave/brave-search-mcp-server', '--transport', 'stdio'])
        else:
            normalize_managed_launcher(['npx', '-y', '@brave/brave-search-mcp-server', '--transport', 'stdio'])
            normalize_managed_launcher(['bunx', '@brave/brave-search-mcp-server', '--transport', 'stdio'])
    elif server_name == 'firecrawl':
        env_key = 'environment' if 'environment' in incoming_server else 'env'
        env = normalized.get(env_key)
        incoming_env = incoming_server.get(env_key, {})
        if isinstance(env, dict) and isinstance(incoming_env, dict) and 'FIRECRAWL_API_KEY' in env:
            env['FIRECRAWL_API_KEY'] = incoming_env.get('FIRECRAWL_API_KEY')
        if env_key == 'env':
            normalize_managed_launcher('npx', ['-y', 'firecrawl-mcp'])
            normalize_managed_launcher('bunx', ['firecrawl-mcp'])
        else:
            normalize_managed_launcher(['npx', '-y', 'firecrawl-mcp'])
            normalize_managed_launcher(['bunx', 'firecrawl-mcp'])
    elif server_name == 'playwright':
        if isinstance(incoming_server.get('command'), str):
            normalize_managed_launcher('npx', ['-y', '@playwright/mcp@latest', '--isolated'])
            normalize_managed_launcher('bunx', ['@playwright/mcp@latest', '--isolated'])
        else:
            normalize_managed_launcher(['npx', '-y', '@playwright/mcp@latest', '--isolated'])
            normalize_managed_launcher(['bunx', '@playwright/mcp@latest', '--isolated'])
    return normalized == incoming_server

if not isinstance(current, dict) or not isinstance(incoming, dict) or not isinstance(original, dict):
    raise SystemExit(f'{label} cleanup requires JSON object inputs')

cleaned = cleanup(current, incoming, original)
mcp_labels = {
    '.claude.json': 'mcpServers',
    'opencode.json': 'mcp',
    'kilo.jsonc': 'mcp',
}
mcp_key = mcp_labels.get(label)
if mcp_key is not None:
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

prompt_secret() {
  local label="$1" value=""
  printf '%s (leave blank to skip): ' "$label" > /dev/tty
  IFS= read -r -s value < /dev/tty || value=""
  printf '\n' > /dev/tty
  printf '%s' "$value"
}

prompt_value() {
  local label="$1" help="$2" value=""
  printf '%s (%s): ' "$label" "$help" > /dev/tty
  IFS= read -r value < /dev/tty || value=""
  printf '%s' "$value"
}

mcp_secret_configured() {
  local server="$1" section="$2" key="$3"
  [ -f "$MCP_CONFIG_DST" ] || return 1
  python3 - "$MCP_CONFIG_DST" "$MCP_ROOT_KEY" "$server" "$section" "$key" "$MCP_PLACEHOLDER_STYLE" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
root_key, server, section, key, placeholder_style = sys.argv[2:7]
try:
    data = json.loads(path.read_text())
except Exception:
    sys.exit(1)

value = data.get(root_key, {}).get(server, {}).get(section, {}).get(key)
if not isinstance(value, str) or not value:
    sys.exit(1)
if placeholder_style == 'claude':
    sys.exit(1 if value.startswith('${') else 0)
if placeholder_style in ('opencode', 'kilo'):
    sys.exit(1 if value.startswith('{env:') else 0)
sys.exit(1)
PY
}

collect_api_keys() {
  can_prompt_api_keys || return 0

  printf '\nOptional MCP API keys. Values are written to %s and never to tracked templates.\n' "$MCP_CONFIG_DST" > /dev/tty
  if ! mcp_secret_configured context7 "$MCP_CONTEXT7_SECTION" CONTEXT7_API_KEY; then
    CONTEXT7_API_KEY_INPUT="$(prompt_secret 'Context7 API key')"
  fi
  if ! mcp_secret_configured brave-search "$MCP_BRAVE_SECTION" BRAVE_API_KEY; then
    BRAVE_API_KEY_INPUT="$(prompt_secret 'Brave Search API key')"
  fi
  if ! mcp_secret_configured firecrawl "$MCP_FIRECRAWL_SECTION" FIRECRAWL_API_KEY; then
    FIRECRAWL_API_KEY_INPUT="$(prompt_secret 'Firecrawl API key')"
  fi
  if ! mcp_secret_configured firecrawl "$MCP_FIRECRAWL_SECTION" FIRECRAWL_API_URL; then
    FIRECRAWL_API_URL_INPUT="$(prompt_value 'Firecrawl API URL' 'leave blank to use current default')"
  fi
}

recommended_shell_commands() {
  printf 'rg, fd/fdfind, jq'
}

linux_distribution_family() {
  [ -r /etc/os-release ] || {
    printf 'unknown'
    return 0
  }

  local distro_id="" distro_like=""
  while IFS='=' read -r key value; do
    value="${value%\"}"
    value="${value#\"}"
    case "$key" in
      ID) distro_id="$value" ;;
      ID_LIKE) distro_like="$value" ;;
    esac
  done < /etc/os-release

  case " $distro_id $distro_like " in
    *" debian "*|*" ubuntu "*) printf 'debian' ;;
    *" fedora "*|*" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*) printf 'redhat' ;;
    *) printf 'unknown' ;;
  esac
}

detect_shell_tool_package_manager() {
  local override="${B_AGENTIC_SHELL_RECOMMEND_MANAGER:-}"
  local linux_family=""
  if [ -n "$override" ]; then
    case "$override" in
      brew|apt|dnf|manual)
        printf '%s' "$override"
        return 0
        ;;
      *)
        printf 'manual'
        return 0
        ;;
    esac
  fi

  case "$(uname -s 2>/dev/null || printf 'unknown')" in
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        printf 'brew'
      else
        printf 'manual'
      fi
      ;;
    Linux)
      linux_family="$(linux_distribution_family)"
      case "$linux_family" in
        debian)
          if command -v apt-get >/dev/null 2>&1 || command -v apt >/dev/null 2>&1; then
            printf 'apt'
          else
            printf 'manual'
          fi
          ;;
        redhat)
          if command -v dnf >/dev/null 2>&1; then
            printf 'dnf'
          else
            printf 'manual'
          fi
          ;;
        *)
          if command -v apt-get >/dev/null 2>&1 || command -v apt >/dev/null 2>&1; then
            printf 'apt'
            return 0
          fi
          if command -v dnf >/dev/null 2>&1; then
            printf 'dnf'
            return 0
          fi
          printf 'manual'
          ;;
      esac
      ;;
    *)
      printf 'manual'
      ;;
  esac
}

shell_tool_install_hint() {
  case "$1" in
    brew) printf 'brew install ripgrep fd jq' ;;
    apt) printf 'sudo apt install -y ripgrep fd-find jq' ;;
    dnf) printf 'sudo dnf install -y ripgrep fd-find jq' ;;
    *) printf 'install manually: ripgrep, fd or fd-find, jq' ;;
  esac
}

report_section() {
  log ""
  log "$1:"
}

report_item() {
  local label="$1" value="$2"
  log "  $label: $value"
}

print_install_report_header() {
  local runtime_label="$1"
  local action_label="install"

  if dry_run_enabled; then
    action_label="dry-run"
  fi

  log "b-agentic $action_label complete for $runtime_label"
}

print_install_report_readiness() {
  report_section "Readiness"
  report_item "serena" "install/init separately; installer never runs onboarding"
  report_item "mcp-config" "templates installed only; external MCP servers are not started or authenticated by installer"
  report_item "api-keys" "Context7, Brave Search, and Firecrawl need user-scope keys"
  case "${RUNTIME_PRE_ACTION_ENFORCEMENT:-advisory-only}" in
    enforced)
      report_item "strict-state" "strict mode needs repo-local .b-agentic/state.json; init with: python3 -m tooling.state.cli init --runtime=$RUNTIME --strict"
      ;;
    *)
      report_item "strict-state" "advisory-only runtime; init state with: python3 -m tooling.state.cli init --runtime=$RUNTIME (no --strict; enforcement is model-level only)"
      ;;
  esac
  if yes_value "${STRICT_VALUE:-N}"; then
    case "${RUNTIME_PRE_ACTION_ENFORCEMENT:-advisory-only}" in
      enforced)
        report_item "hooks" "strict requested; pre-action blocking is installed for supported payloads, advisory-only gaps are still reported by capability checks"
        ;;
      *)
        report_item "hooks" "strict requested; this runtime has no b-agentic pre-action blocking hook, so high-risk tool actions remain advisory-only"
        ;;
    esac
  else
    report_item "hooks" "strict enforcement ON by default; use --advisory or set B_AGENTIC_ADVISORY=1 to opt out"
  fi
}

print_shell_tool_recommendations() {
  local package_manager
  package_manager="$(detect_shell_tool_package_manager)"

  report_section "Shell tooling"
  report_item "core" "$(recommended_shell_commands)"
  report_item "core-install" "$(shell_tool_install_hint "$package_manager")"
  report_item "installer" "suggestions only; no packages were installed automatically"
}

print_install_report_next_steps() {
  local runtime_label="$1"

  report_section "Next steps"

  if dry_run_enabled; then
    report_item "apply" "rerun without --dry-run when you want to write files"
    report_item "manifest" "no manifest was written during dry-run"
    return 0
  fi

  if [ "$INSTALL_ACTIVATION_STATE" = "pending" ]; then
    report_item "activate" "review $KERNEL_SNAPSHOT_DST, then rerun with --replace-memory if you want b-agentic active in $KERNEL_DST"
  else
    report_item "launch" "start a new $runtime_label session so it picks up $KERNEL_DST"
  fi

  report_item "manifest" "review $MANIFEST_DST for installed paths and backup metadata"
  report_item "keys" "add user-scope API keys only if you plan to use Context7, Brave Search, or Firecrawl"
}

install_mcp_config() {
  local template_src="${MCP_TEMPLATE_SRC:-$TEMPLATES_SRC/mcp.user.template.json}"
  merge_json_file "$template_src" "$MCP_CONFIG_DST" "mcp" "$MCP_BACKUP_KEY"
}

apply_prompted_mcp_keys() {
  local action="$1" current_backup="$2"
  if [ -z "$CONTEXT7_API_KEY_INPUT" ] && [ -z "$BRAVE_API_KEY_INPUT" ] && [ -z "$FIRECRAWL_API_KEY_INPUT" ] && [ -z "$FIRECRAWL_API_URL_INPUT" ]; then
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
    MCP_CONFIG_DST="$MCP_CONFIG_DST" \
    MCP_ROOT_KEY="$MCP_ROOT_KEY" \
    JSON_TMP="$tmp" \
    MCP_CONTEXT7_SECTION="$MCP_CONTEXT7_SECTION" \
    MCP_BRAVE_SECTION="$MCP_BRAVE_SECTION" \
    MCP_FIRECRAWL_SECTION="$MCP_FIRECRAWL_SECTION" \
    CONTEXT7_API_KEY_INPUT="$CONTEXT7_API_KEY_INPUT" \
    BRAVE_API_KEY_INPUT="$BRAVE_API_KEY_INPUT" \
    FIRECRAWL_API_KEY_INPUT="$FIRECRAWL_API_KEY_INPUT" \
    FIRECRAWL_API_URL_INPUT="$FIRECRAWL_API_URL_INPUT" \
    python3 - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ['MCP_CONFIG_DST'])
root_key = os.environ['MCP_ROOT_KEY']
tmp = Path(os.environ['JSON_TMP'])
data = json.loads(path.read_text())
servers = data.setdefault(root_key, {})

updates = [
    ('context7', os.environ['MCP_CONTEXT7_SECTION'], 'CONTEXT7_API_KEY', os.environ.get('CONTEXT7_API_KEY_INPUT', '')),
    ('brave-search', os.environ['MCP_BRAVE_SECTION'], 'BRAVE_API_KEY', os.environ.get('BRAVE_API_KEY_INPUT', '')),
    ('firecrawl', os.environ['MCP_FIRECRAWL_SECTION'], 'FIRECRAWL_API_KEY', os.environ.get('FIRECRAWL_API_KEY_INPUT', '')),
    ('firecrawl', os.environ['MCP_FIRECRAWL_SECTION'], 'FIRECRAWL_API_URL', os.environ.get('FIRECRAWL_API_URL_INPUT', '')),
]

for server_name, section_name, key_name, value in updates:
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
    die "failed to write prompted MCP API keys: $MCP_CONFIG_DST"
  fi

  local backup="$current_backup"
  if [ "$action" != "write" ] && [ "$backup" = "none" ]; then
    backup="$(backup_file "$MCP_CONFIG_DST")"
  fi
  run_cmd mv "$tmp" "$MCP_CONFIG_DST"
  printf '%s' "${backup:-none}"
}

read_install_triplet() {
  local result="$1" default_action="$2" default_state="$3" default_backup="$4"
  local action_var="$5" state_var="$6" backup_var="$7"
  local -a lines=()
  local line

  while IFS= read -r line; do
    lines+=("$line")
  done <<< "$result"

  printf -v "$action_var" '%s' "${lines[0]:-$default_action}"
  printf -v "$state_var" '%s' "${lines[1]:-$default_state}"
  printf -v "$backup_var" '%s' "${lines[2]:-$default_backup}"
}

collect_installed_skills() {
  local skills_var="$1"
  local skill
  eval "$skills_var=()"
  while IFS= read -r skill; do
    [ -n "$skill" ] || continue
    eval "$skills_var+=(\"$skill\")"
  done < <(skill_names)
}

manifest_skill_names() {
  if manifest_array_values skills; then
    return 0
  fi
  skill_names
}

uninstall_installed_skills() {
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! managed_asset_name_is_safe "$name"; then
      warn "preserving skill with unsafe manifest name"
      continue
    fi
    run_cmd rm -rf "$SKILLS_DST/$name"
  done < <(manifest_skill_names)
}

runtime_warn_missing_cli() { :; }
runtime_install_extra_assets() { :; }
runtime_uninstall_extra_assets() { :; }
runtime_install_config_stage_count() { printf '0'; }

runtime_install_common() {
  local config_stage_count=0

  runtime_warn_missing_cli
  config_stage_count="$(runtime_install_config_stage_count)"
  set_install_stage_total $((6 + config_stage_count))

  collect_installed_skills INSTALL_SKILL_NAMES
  run_stage "Syncing skills" install_skills
  run_stage "Installing runtime extras" runtime_install_extra_assets
  run_stage "Syncing references and templates" install_references_and_templates

  run_install_triplet_stage "Installing kernel" install_kernel "preserve" "pending" "none" \
    INSTALL_MEMORY_ACTION INSTALL_ACTIVATION_STATE INSTALL_MEMORY_BACKUP

  runtime_install_configs
  local prompted_mcp_backup
  collect_api_keys
  capture_output_stage "Writing prompted MCP keys" prompted_mcp_backup apply_prompted_mcp_keys "$INSTALL_MCP_ACTION" "$INSTALL_MCP_BACKUP"
  if [ "$prompted_mcp_backup" != "none" ]; then
    INSTALL_MCP_BACKUP="$prompted_mcp_backup"
  fi

  run_stage "Installing uninstall helper" install_uninstall_helper
  run_stage "Writing install manifest" runtime_write_manifest
  runtime_print_install_report

  if [ "$INSTALL_ACTIVATION_STATE" = "pending" ]; then
    return 2
  fi
}

install_uninstall_helper() {
  local script_src="$SOURCE_DIR/tooling/install/manifest_uninstall.py"
  local script_dst="$METADATA_DIR/tooling/install/manifest_uninstall.py"
  [ -f "$script_src" ] || return 0
  ensure_dir "$(dirname "$script_dst")"
  copy_file "$script_src" "$script_dst"
}

install_hook_checker() {
  local script_src="$SOURCE_DIR/tooling/hooks/check-runtime.py"
  local script_dst="$METADATA_DIR/hooks/check-runtime.py"
  [ -f "$script_src" ] || return 0
  ensure_dir "$(dirname "$script_dst")"
  copy_file "$script_src" "$script_dst"
}

runtime_uninstall_common() {
  require_bin python3
  set_install_stage_total 4
  log "Uninstalling b-agentic from $RUNTIME_UNINSTALL_LABEL"
  run_stage "Removing managed skills" uninstall_installed_skills
  run_stage "Removing runtime extras" runtime_uninstall_extra_assets
  run_stage "Removing managed kernel" remove_managed_kernel
  run_stage "Cleaning runtime config" runtime_uninstall_configs
  run_cmd rm -rf "$METADATA_DIR"
  log "Uninstall complete. User-owned $RUNTIME_PRESERVE_LABEL files were preserved."
}
