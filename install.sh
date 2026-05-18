#!/usr/bin/env bash
# install.sh — Bootstrap or update b-skills for Claude Code
# Usage:
#   First time / update:
#     curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-skills/main/install.sh | bash
#
# Optional environment overrides:
#   B_SKILLS_REPO  — git URL to clone (default: https://github.com/dhoaibao/b-skills.git)
#   B_SKILLS_DIR   — local clone path (default: $HOME/.b-skills)
#   B_SKILLS_REF   — git ref to check out after clone/pull (default: leave on default branch)
#   B_SKILLS_INSTALL_MCP — Y to install core MCP defaults in ~/.claude.json; otherwise skipped
#   B_SKILLS_INSTALL_GITNEXUS — Y to install optional GitNexus MCP when MCP defaults are enabled
#   B_SKILLS_DRY_RUN — Y to preview file/config changes without writing into Claude config
#   B_SKILLS_REPLACE_MEMORY — Y to replace ~/.claude/CLAUDE.md without prompting; N to preserve it
#   B_SKILLS_UNINSTALL — Y to remove b-skills-managed files from Claude config
#   BRAVE_API_KEY — Brave Search MCP API key
#   CONTEXT7_API_KEY — Context7 MCP API key
#   FIRECRAWL_API_KEY — Firecrawl MCP API key
#
# Optional CLI flags:
#   --dry-run          Preview install changes without writing them
#   --replace-memory   Replace ~/.claude/CLAUDE.md without prompting
#   --preserve-memory  Never replace ~/.claude/CLAUDE.md
#   --uninstall        Remove b-skills-managed files from Claude config

set -euo pipefail

readonly REPO_URL="${B_SKILLS_REPO:-https://github.com/dhoaibao/b-skills.git}"
readonly LOCAL_REPO="${B_SKILLS_DIR:-$HOME/.b-skills}"
readonly REF="${B_SKILLS_REF:-}"
readonly CLAUDE_DIR="$HOME/.claude"
readonly CLAUDE_JSON="$HOME/.claude.json"
readonly B_SKILLS_METADATA_DIR="$CLAUDE_DIR/b-skills"
readonly B_SKILLS_BACKUPS_DIR="$B_SKILLS_METADATA_DIR/backups"
readonly SKILLS_SRC="$LOCAL_REPO/skills"
readonly AGENTS_SRC="$LOCAL_REPO/agents"
readonly HOOKS_SRC="$LOCAL_REPO/hooks"
readonly REFERENCES_SRC="$LOCAL_REPO/references"
readonly SETTINGS_TEMPLATE_SRC="$LOCAL_REPO/settings/b-skills.settings.json"
readonly MEMORY_SRC="$LOCAL_REPO/global/CLAUDE.md"
readonly SKILLS_DST="$CLAUDE_DIR/skills"
readonly AGENTS_DST="$CLAUDE_DIR/agents"
readonly HOOKS_DST="$CLAUDE_DIR/hooks"
readonly REFERENCES_DST="$CLAUDE_DIR/references/b-skills"
readonly SETTINGS_DST="$CLAUDE_DIR/settings.json"
readonly MEMORY_DST="$CLAUDE_DIR/CLAUDE.md"
readonly MEMORY_SNAPSHOT_DST="$B_SKILLS_METADATA_DIR/CLAUDE.md"
readonly SETTINGS_SNAPSHOT_DST="$B_SKILLS_METADATA_DIR/b-skills.settings.json"
readonly INSTALL_MANIFEST="$B_SKILLS_METADATA_DIR/install.json"
readonly TIMESTAMP="$(date +%Y%m%d%H%M%S)"

log() { printf '%s\n' "$*"; }
section() { printf '\n[%s]\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

BRAVE_API_KEY_VALUE="${BRAVE_API_KEY:-}"
CONTEXT7_API_KEY_VALUE="${CONTEXT7_API_KEY:-}"
FIRECRAWL_API_KEY_VALUE="${FIRECRAWL_API_KEY:-}"
INSTALL_MCPS_VALUE="${B_SKILLS_INSTALL_MCP:-}"
INSTALL_GITNEXUS_VALUE="${B_SKILLS_INSTALL_GITNEXUS:-}"
DRY_RUN_VALUE="${B_SKILLS_DRY_RUN:-N}"
REPLACE_MEMORY_VALUE="${B_SKILLS_REPLACE_MEMORY:-}"
UNINSTALL_VALUE="${B_SKILLS_UNINSTALL:-N}"
MEMORY_INSTALL_ACTION="preserve"
RUNTIME_ACTIVATION_STATE="active"
MEMORY_BACKUP_PATH="none"
SETTINGS_BACKUP_PATH="none"
MCP_BACKUP_PATH="none"
LAST_BACKUP_PATH="none"
SETTINGS_ADDED_PERMISSIONS_JSON='{}'
MCP_ADDED_SERVERS_JSON='[]'

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      B_SKILLS_DRY_RUN=Y
      DRY_RUN_VALUE=Y
      ;;
    --replace-memory)
      B_SKILLS_REPLACE_MEMORY=Y
      REPLACE_MEMORY_VALUE=Y
      ;;
    --preserve-memory)
      B_SKILLS_REPLACE_MEMORY=N
      REPLACE_MEMORY_VALUE=N
      ;;
    --uninstall)
      B_SKILLS_UNINSTALL=Y
      UNINSTALL_VALUE=Y
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
  shift
done

trap 'rc=$?; [ $rc -ne 0 ] && warn "install.sh failed at line $LINENO (exit $rc)"' EXIT

require_bin() {
  command -v "$1" >/dev/null 2>&1 || die "Required binary not found: $1"
}

require_bin git
require_bin python3
command -v claude >/dev/null 2>&1 || warn "claude CLI not found; files will still be installed, but install Claude Code before using them."

wants_yes() {
  case "${1:-}" in
    y|Y|yes|YES|Yes)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

wants_no() {
  case "${1:-}" in
    n|N|no|NO|No)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

dry_run_enabled() {
  wants_yes "$DRY_RUN_VALUE"
}

prompt_available() {
  [ -r /dev/tty ] && [ -w /dev/tty ] && (exec 3<>/dev/tty) >/dev/null 2>&1
}

is_placeholder_value() {
  local value="${1:-}"
  [ -z "$value" ] && return 0
  [[ "$value" == YOUR_* ]]
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

before = Path(os.environ["BEFORE_FILE"]).read_text().splitlines()
after = Path(os.environ["AFTER_FILE"]).read_text().splitlines()
label = os.environ["LABEL"]
diff = difflib.unified_diff(before, after, fromfile=f"{label} (current)", tofile=f"{label} (new)", lineterm="")
print("\n".join(diff))
PYEOF
}

backup_path_for_file() {
  local file_path="$1"
  printf '%s/%s.bak-%s' "$B_SKILLS_BACKUPS_DIR" "$(basename "$file_path")" "$TIMESTAMP"
}

backup_file_if_needed() {
  local file_path="$1" backup_path
  LAST_BACKUP_PATH="none"
  [ -f "$file_path" ] || return 0
  backup_path="$(backup_path_for_file "$file_path")"
  LAST_BACKUP_PATH="$backup_path"
  ensure_dir "$B_SKILLS_BACKUPS_DIR"
  if dry_run_enabled; then
    log "[dry-run] backup $file_path -> $backup_path"
    return 0
  fi
  cp "$file_path" "$backup_path"
}

write_file_from_source() {
  local source_file="$1" target_file="$2" label="$3" backup_existing="${4:-N}"
  local before_file after_file
  LAST_BACKUP_PATH="none"
  [ -f "$source_file" ] || die "Missing source file: $source_file"
  ensure_dir "$(dirname "$target_file")"
  if [ -f "$target_file" ] && cmp -s "$source_file" "$target_file"; then
    log "OK: $label unchanged"
    return 0
  fi
  before_file="$(mktemp)"
  after_file="$(mktemp)"
  [ -f "$target_file" ] && cp "$target_file" "$before_file" || : > "$before_file"
  cp "$source_file" "$after_file"
  if dry_run_enabled; then
    log "Preview for $label"
    show_diff "$before_file" "$after_file" "$label"
    log "[dry-run] write $target_file"
    rm -f "$before_file" "$after_file"
    return 0
  fi
  if [ "$backup_existing" = "Y" ]; then
    backup_file_if_needed "$target_file"
  fi
  cp "$source_file" "$target_file"
  rm -f "$before_file" "$after_file"
  log "OK: $label updated"
}

write_text_file() {
  local target_file="$1" content="$2" label="$3" backup_existing="${4:-N}"
  local before_file after_file
  LAST_BACKUP_PATH="none"
  ensure_dir "$(dirname "$target_file")"
  before_file="$(mktemp)"
  after_file="$(mktemp)"
  [ -f "$target_file" ] && cp "$target_file" "$before_file" || : > "$before_file"
  printf '%s\n' "$content" > "$after_file"
  if cmp -s "$before_file" "$after_file"; then
    rm -f "$before_file" "$after_file"
    log "OK: $label unchanged"
    return 0
  fi
  if dry_run_enabled; then
    log "Preview for $label"
    show_diff "$before_file" "$after_file" "$label"
    log "[dry-run] write $target_file"
    rm -f "$before_file" "$after_file"
    return 0
  fi
  if [ "$backup_existing" = "Y" ]; then
    backup_file_if_needed "$target_file"
  fi
  printf '%s\n' "$content" > "$target_file"
  rm -f "$before_file" "$after_file"
  log "OK: $label updated"
}

sync_directory() {
  local source_dir="$1" target_dir="$2" label="$3"
  [ -d "$source_dir" ] || die "Missing source directory: $source_dir"
  [ "$source_dir" = "$target_dir" ] && die "Refusing to sync a directory onto itself: $source_dir"
  ensure_dir "$(dirname "$target_dir")"
  if dry_run_enabled; then
    log "[dry-run] sync $source_dir -> $target_dir"
    return 0
  fi
  rm -rf "$target_dir"
  mkdir -p "$target_dir"
  cp -R "$source_dir"/. "$target_dir"/
  log "OK: $label synced"
}

sync_file() {
  local source_file="$1" target_file="$2" label="$3"
  [ -f "$source_file" ] || die "Missing source file: $source_file"
  ensure_dir "$(dirname "$target_file")"
  if dry_run_enabled; then
    log "[dry-run] copy $source_file -> $target_file"
    return 0
  fi
  cp "$source_file" "$target_file"
  log "OK: $label synced"
}

is_b_skills_skill_dir() {
  local skill_dir="$1"
  [ -f "$skill_dir/SKILL.md" ] || return 1
  grep -Eq '^[[:space:]]*suite:[[:space:]]*b-skills[[:space:]]*$' "$skill_dir/SKILL.md"
}

is_b_skills_agent_file() {
  local agent_file="$1"
  [ -f "$agent_file" ] || return 1
  grep -Eq '^name:[[:space:]]*b-.*-agent[[:space:]]*$' "$agent_file" && grep -q 'b-skills' "$agent_file"
}

is_b_skills_hook_file() {
  local hook_file="$1"
  [ -f "$hook_file" ] || return 1
  grep -q 'b-skills' "$hook_file" && grep -q 'DENY_PATTERNS' "$hook_file" && grep -q 'ASK_PATTERNS' "$hook_file"
}

assert_managed_or_absent() {
  local target_path="$1" label="$2" checker="$3"
  [ -e "$target_path" ] || return 0
  if "$checker" "$target_path"; then
    return 0
  fi
  die "Refusing to overwrite existing $label at $target_path because it is not marked as b-skills-managed. Move it aside or remove it, then re-run."
}

remove_path_if_exists() {
  local path="$1" label="$2"
  [ -e "$path" ] || {
    log "OK: $label already absent"
    return 0
  }
  if dry_run_enabled; then
    log "[dry-run] remove $path"
    return 0
  fi
  rm -rf "$path"
  log "OK: $label removed"
}

remove_skill_if_managed() {
  local skill_name="$1" skill_dir
  skill_dir="$SKILLS_DST/$skill_name"
  [ -e "$skill_dir" ] || {
    log "OK: skill $skill_name already absent"
    return 0
  }
  if is_b_skills_skill_dir "$skill_dir"; then
    remove_path_if_exists "$skill_dir" "skill $skill_name"
  else
    log "Preserved skill $skill_name because it is not marked as b-skills-managed"
  fi
}

remove_agent_if_managed() {
  local agent_name="$1" agent_file
  agent_file="$AGENTS_DST/$agent_name.md"
  [ -e "$agent_file" ] || {
    log "OK: agent $agent_name already absent"
    return 0
  }
  if is_b_skills_agent_file "$agent_file"; then
    remove_path_if_exists "$agent_file" "agent $agent_name"
  else
    log "Preserved agent $agent_name because it is not marked as b-skills-managed"
  fi
}

remove_hook_if_managed() {
  local hook_name="$1" hook_file
  hook_file="$HOOKS_DST/$hook_name"
  [ -e "$hook_file" ] || {
    log "OK: hook $hook_name already absent"
    return 0
  }
  if is_b_skills_hook_file "$hook_file"; then
    remove_path_if_exists "$hook_file" "hook $hook_name"
  else
    log "Preserved hook $hook_name because it is not marked as b-skills-managed"
  fi
}

remove_dir_if_empty() {
  local dir_path="$1" label="$2"
  [ -d "$dir_path" ] || return 0
  [ -n "$(find "$dir_path" -mindepth 1 -maxdepth 1 -print -quit)" ] && return 0
  if dry_run_enabled; then
    log "[dry-run] remove empty directory $dir_path"
    return 0
  fi
  rmdir "$dir_path"
  log "OK: $label removed"
}

preflight_install_targets() {
  local skill_dir skill_name agent_file agent_name hook_file hook_name
  [ -d "$SKILLS_SRC" ] || die "Missing skills source directory: $SKILLS_SRC"
  [ -d "$AGENTS_SRC" ] || die "Missing agents source directory: $AGENTS_SRC"
  [ -d "$HOOKS_SRC" ] || die "Missing hooks source directory: $HOOKS_SRC"
  [ -d "$REFERENCES_SRC" ] || die "Missing references source directory: $REFERENCES_SRC"
  [ -f "$SETTINGS_TEMPLATE_SRC" ] || die "Missing settings template: $SETTINGS_TEMPLATE_SRC"
  [ -f "$MEMORY_SRC" ] || die "Missing Claude memory source: $MEMORY_SRC"

  for skill_dir in "$SKILLS_SRC"/*/; do
    [ -d "$skill_dir" ] || continue
    [ -f "$skill_dir/SKILL.md" ] || continue
    skill_name="$(basename "$skill_dir")"
    assert_managed_or_absent "$SKILLS_DST/$skill_name" "skill $skill_name" is_b_skills_skill_dir
  done

  for agent_file in "$AGENTS_SRC"/*.md; do
    [ -f "$agent_file" ] || continue
    agent_name="$(basename "$agent_file" .md)"
    assert_managed_or_absent "$AGENTS_DST/$agent_name.md" "agent $agent_name" is_b_skills_agent_file
  done

  for hook_file in "$HOOKS_SRC"/*; do
    [ -f "$hook_file" ] || continue
    hook_name="$(basename "$hook_file")"
    assert_managed_or_absent "$HOOKS_DST/$hook_name" "hook $hook_name" is_b_skills_hook_file
  done
}

prompt_mcp_install_if_needed() {
  local entered_value
  if wants_yes "$INSTALL_MCPS_VALUE"; then
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
  printf 'Configure core MCP defaults (serena, context7, brave-search, firecrawl) in ~/.claude.json? [y/N]: ' > /dev/tty
  IFS= read -r entered_value < /dev/tty || entered_value=""
  wants_yes "$entered_value" && INSTALL_MCPS_VALUE="Y" || INSTALL_MCPS_VALUE="N"
}

prompt_gitnexus_install_if_needed() {
  local entered_value
  if ! wants_yes "$INSTALL_MCPS_VALUE"; then
    INSTALL_GITNEXUS_VALUE="N"
    return 0
  fi
  if wants_yes "$INSTALL_GITNEXUS_VALUE"; then
    INSTALL_GITNEXUS_VALUE="Y"
    return 0
  fi
  if [ -n "$INSTALL_GITNEXUS_VALUE" ]; then
    INSTALL_GITNEXUS_VALUE="N"
    return 0
  fi
  if ! prompt_available; then
    INSTALL_GITNEXUS_VALUE="N"
    return 0
  fi
  printf 'Configure optional GitNexus graph radar MCP? [y/N]: ' > /dev/tty
  IFS= read -r entered_value < /dev/tty || entered_value=""
  wants_yes "$entered_value" && INSTALL_GITNEXUS_VALUE="Y" || INSTALL_GITNEXUS_VALUE="N"
}

prompt_api_key_if_needed() {
  local var_name="$1" prompt_label="$2" current_value entered_value
  current_value="${!var_name:-}"
  if ! is_placeholder_value "$current_value"; then
    return 0
  fi
  if ! prompt_available; then
    printf -v "$var_name" '%s' 'YOUR_API_KEY'
    return 0
  fi
  printf 'Enter %s (press Enter to skip): ' "$prompt_label" > /dev/tty
  IFS= read -r -s entered_value < /dev/tty || entered_value=""
  printf '\n' > /dev/tty
  is_placeholder_value "$entered_value" && entered_value="YOUR_API_KEY"
  printf -v "$var_name" '%s' "$entered_value"
}

collect_mcp_api_keys() {
  prompt_api_key_if_needed BRAVE_API_KEY_VALUE "Brave Search API key"
  prompt_api_key_if_needed CONTEXT7_API_KEY_VALUE "Context7 API key"
  prompt_api_key_if_needed FIRECRAWL_API_KEY_VALUE "Firecrawl API key"
}

api_key_status() {
  local value="${1:-}"
  if is_placeholder_value "$value"; then
    printf 'placeholder'
  else
    printf 'configured'
  fi
}

decide_memory_install_action() {
  local entered_value
  if [ ! -f "$MEMORY_DST" ]; then
    MEMORY_INSTALL_ACTION="replace"
    return 0
  fi
  if cmp -s "$MEMORY_SRC" "$MEMORY_DST"; then
    MEMORY_INSTALL_ACTION="unchanged"
    return 0
  fi
  if wants_yes "$REPLACE_MEMORY_VALUE"; then
    MEMORY_INSTALL_ACTION="replace"
    return 0
  fi
  if wants_no "$REPLACE_MEMORY_VALUE"; then
    MEMORY_INSTALL_ACTION="preserve"
    RUNTIME_ACTIVATION_STATE="pending"
    return 0
  fi
  if ! prompt_available; then
    MEMORY_INSTALL_ACTION="preserve"
    RUNTIME_ACTIVATION_STATE="pending"
    return 0
  fi
  printf 'Replace existing Claude CLAUDE.md with the b-skills runtime memory? [y/N]: ' > /dev/tty
  IFS= read -r entered_value < /dev/tty || entered_value=""
  if wants_yes "$entered_value"; then
    MEMORY_INSTALL_ACTION="replace"
    RUNTIME_ACTIVATION_STATE="active"
  else
    MEMORY_INSTALL_ACTION="preserve"
    RUNTIME_ACTIVATION_STATE="pending"
  fi
}

json_settings_added_permissions() {
  env SETTINGS_DST="$SETTINGS_DST" SETTINGS_TEMPLATE_SRC="$SETTINGS_TEMPLATE_SRC" INSTALL_MANIFEST="$INSTALL_MANIFEST" python3 - <<'PYEOF'
import json
import os
from pathlib import Path

settings_path = Path(os.environ["SETTINGS_DST"])
template_path = Path(os.environ["SETTINGS_TEMPLATE_SRC"])
manifest_path = Path(os.environ["INSTALL_MANIFEST"])

def load_json(path):
    try:
        text = path.read_text().strip()
    except FileNotFoundError:
        return {}
    if not text:
        return {}
    return json.loads(text)

def as_list(value):
    return value if isinstance(value, list) else []

def dedupe(values):
    result = []
    for value in values:
        if value not in result:
            result.append(value)
    return result

settings = load_json(settings_path)
template = load_json(template_path)
manifest = load_json(manifest_path)
if not isinstance(settings, dict):
    settings = {}
if not isinstance(template, dict):
    template = {}
if not isinstance(manifest, dict):
    manifest = {}

previous = manifest.get("managedConfig", {}).get("settingsAddedPermissions", {})
if not isinstance(previous, dict):
    previous = {}

settings_permissions = settings.get("permissions", {})
if not isinstance(settings_permissions, dict):
    settings_permissions = {}
template_permissions = template.get("permissions", {})
if not isinstance(template_permissions, dict):
    template_permissions = {}

added = {}
for bucket in ("allow", "ask", "deny"):
    current = as_list(settings_permissions.get(bucket))
    additions = [value for value in as_list(template_permissions.get(bucket)) if value not in current]
    carried = [value for value in as_list(previous.get(bucket)) if value in as_list(template_permissions.get(bucket))]
    values = dedupe(carried + additions)
    if values:
        added[bucket] = values

print(json.dumps(added, separators=(",", ":")))
PYEOF
}

json_merge_claude_settings() {
  env SETTINGS_DST="$SETTINGS_DST" SETTINGS_TEMPLATE_SRC="$SETTINGS_TEMPLATE_SRC" python3 - <<'PYEOF'
import json
import os
from pathlib import Path

settings_path = Path(os.environ["SETTINGS_DST"])
template_path = Path(os.environ["SETTINGS_TEMPLATE_SRC"])

def load_json(path):
    try:
        text = path.read_text().strip()
    except FileNotFoundError:
        return {}
    if not text:
        return {}
    return json.loads(text)

def dedupe(values):
    result = []
    for value in values:
        if value not in result:
            result.append(value)
    return result

def is_b_skills_hook(hook):
    return isinstance(hook, dict) and "b-skills-guard.py" in str(hook.get("command", ""))

def without_b_skills_hooks(group):
    if not isinstance(group, dict):
        return group
    hooks = group.get("hooks")
    if not isinstance(hooks, list):
        return group
    kept_hooks = [hook for hook in hooks if not is_b_skills_hook(hook)]
    if not kept_hooks:
        return None
    cleaned = dict(group)
    cleaned["hooks"] = kept_hooks
    return cleaned

settings = load_json(settings_path)
template = load_json(template_path)
if not isinstance(settings, dict):
    settings = {}

settings_hooks = settings.setdefault("hooks", {})
if not isinstance(settings_hooks, dict):
    settings_hooks = {}
    settings["hooks"] = settings_hooks

for event, groups in template.get("hooks", {}).items():
    existing_groups = settings_hooks.get(event, [])
    if not isinstance(existing_groups, list):
        existing_groups = []
    filtered = []
    for group in existing_groups:
        cleaned = without_b_skills_hooks(group)
        if cleaned is not None:
            filtered.append(cleaned)
    for group in groups:
        if group not in filtered:
            filtered.append(group)
    settings_hooks[event] = filtered

settings_permissions = settings.setdefault("permissions", {})
if not isinstance(settings_permissions, dict):
    settings_permissions = {}
    settings["permissions"] = settings_permissions
for bucket in ("allow", "ask", "deny"):
    current = settings_permissions.get(bucket, [])
    if not isinstance(current, list):
        current = []
    additions = template.get("permissions", {}).get(bucket, [])
    settings_permissions[bucket] = dedupe(current + additions)

settings_env = settings.setdefault("env", {})
if not isinstance(settings_env, dict):
    settings_env = {}
    settings["env"] = settings_env
settings_env.update(template.get("env", {}))

print(json.dumps(settings, indent=2))
PYEOF
}

json_unmerge_claude_settings() {
  env SETTINGS_DST="$SETTINGS_DST" SETTINGS_TEMPLATE_PATH="${1:-}" INSTALL_MANIFEST="$INSTALL_MANIFEST" python3 - <<'PYEOF'
import json
import os
from pathlib import Path

settings_path = Path(os.environ["SETTINGS_DST"])
template_path_value = os.environ.get("SETTINGS_TEMPLATE_PATH") or ""
template_path = Path(template_path_value) if template_path_value else None
manifest_path = Path(os.environ["INSTALL_MANIFEST"])

def load_json(path):
    if path is None:
        return {}
    try:
        text = path.read_text().strip()
    except OSError:
        return {}
    if not text:
        return {}
    return json.loads(text)

settings = load_json(settings_path)
template = load_json(template_path)
manifest = load_json(manifest_path)
if not isinstance(settings, dict):
    settings = {}
if not isinstance(template, dict):
    template = {}
if not isinstance(manifest, dict):
    manifest = {}

added_permissions = manifest.get("managedConfig", {}).get("settingsAddedPermissions", {})
if not isinstance(added_permissions, dict):
    added_permissions = {}

def is_b_skills_hook(hook):
    return isinstance(hook, dict) and "b-skills-guard.py" in str(hook.get("command", ""))

def without_b_skills_hooks(group):
    if not isinstance(group, dict):
        return group
    hook_list = group.get("hooks")
    if not isinstance(hook_list, list):
        return group
    kept_hooks = [hook for hook in hook_list if not is_b_skills_hook(hook)]
    if not kept_hooks:
        return None
    cleaned = dict(group)
    cleaned["hooks"] = kept_hooks
    return cleaned

hooks = settings.get("hooks", {})
if isinstance(hooks, dict):
    for event in list(hooks):
        groups = hooks.get(event, [])
        if not isinstance(groups, list):
            continue
        filtered = []
        for group in groups:
            cleaned = without_b_skills_hooks(group)
            if cleaned is not None:
                filtered.append(cleaned)
        if filtered:
            hooks[event] = filtered
        else:
            hooks.pop(event, None)
    if not hooks:
        settings.pop("hooks", None)

permissions = settings.get("permissions", {})
if isinstance(permissions, dict):
    for bucket in ("allow", "ask", "deny"):
        current = permissions.get(bucket, [])
        remove = set(added_permissions.get(bucket, []))
        if isinstance(current, list):
            kept = [value for value in current if value not in remove]
            if kept:
                permissions[bucket] = kept
            else:
                permissions.pop(bucket, None)
    if not permissions:
        settings.pop("permissions", None)

env = settings.get("env", {})
if isinstance(env, dict) and env.get("B_SKILLS_GOVERNANCE") == template.get("env", {}).get("B_SKILLS_GOVERNANCE"):
    env.pop("B_SKILLS_GOVERNANCE", None)
    if not env:
        settings.pop("env", None)

print(json.dumps(settings, indent=2))
PYEOF
}

json_merge_mcp_config() {
  env CLAUDE_JSON="$CLAUDE_JSON" BRAVE_API_KEY_VALUE="$BRAVE_API_KEY_VALUE" CONTEXT7_API_KEY_VALUE="$CONTEXT7_API_KEY_VALUE" FIRECRAWL_API_KEY_VALUE="$FIRECRAWL_API_KEY_VALUE" INSTALL_GITNEXUS_VALUE="$INSTALL_GITNEXUS_VALUE" python3 - <<'PYEOF'
import json
import os
from pathlib import Path

path = Path(os.environ["CLAUDE_JSON"])

def load_json(path):
    try:
        text = path.read_text().strip()
    except FileNotFoundError:
        return {}
    if not text:
        return {}
    return json.loads(text)

config = load_json(path)
if not isinstance(config, dict):
    config = {}
mcp = config.setdefault("mcpServers", {})
if not isinstance(mcp, dict):
    mcp = {}
    config["mcpServers"] = mcp

defaults = {
    "serena": {
        "type": "stdio",
        "command": "serena",
        "args": ["start-mcp-server", "--context=ide", "--project-from-cwd", "--open-web-dashboard", "False"],
    },
    "context7": {
        "type": "http",
        "url": "https://mcp.context7.com/mcp",
        "headers": {"CONTEXT7_API_KEY": os.environ.get("CONTEXT7_API_KEY_VALUE") or "YOUR_API_KEY"},
    },
    "brave-search": {
        "type": "stdio",
        "command": "npx",
        "args": ["-y", "@brave/brave-search-mcp-server"],
        "env": {"BRAVE_API_KEY": os.environ.get("BRAVE_API_KEY_VALUE") or "YOUR_API_KEY"},
    },
    "firecrawl": {
        "type": "stdio",
        "command": "npx",
        "args": ["-y", "firecrawl-mcp"],
        "env": {"FIRECRAWL_API_KEY": os.environ.get("FIRECRAWL_API_KEY_VALUE") or "YOUR_API_KEY"},
    },
}
if (os.environ.get("INSTALL_GITNEXUS_VALUE") or "").lower() in {"y", "yes"}:
    defaults["gitnexus"] = {"type": "stdio", "command": "gitnexus", "args": ["mcp"]}

for name, value in defaults.items():
    if name not in mcp:
        mcp[name] = value

print(json.dumps(config, indent=2))
PYEOF
}

json_mcp_added_servers() {
  env CLAUDE_JSON="$CLAUDE_JSON" INSTALL_MANIFEST="$INSTALL_MANIFEST" INSTALL_GITNEXUS_VALUE="$INSTALL_GITNEXUS_VALUE" python3 - <<'PYEOF'
import json
import os
from pathlib import Path

config_path = Path(os.environ["CLAUDE_JSON"])
manifest_path = Path(os.environ["INSTALL_MANIFEST"])

def load_json(path):
    try:
        text = path.read_text().strip()
    except FileNotFoundError:
        return {}
    if not text:
        return {}
    return json.loads(text)

def dedupe(values):
    result = []
    for value in values:
        if value not in result:
            result.append(value)
    return result

config = load_json(config_path)
manifest = load_json(manifest_path)
if not isinstance(config, dict):
    config = {}
if not isinstance(manifest, dict):
    manifest = {}

mcp = config.get("mcpServers", {})
if not isinstance(mcp, dict):
    mcp = {}

defaults = ["serena", "context7", "brave-search", "firecrawl"]
if (os.environ.get("INSTALL_GITNEXUS_VALUE") or "").lower() in {"y", "yes"}:
    defaults.append("gitnexus")

previous = manifest.get("managedConfig", {}).get("mcpAddedServers", [])
if not isinstance(previous, list):
    previous = []

added = [name for name in previous if isinstance(name, str) and name in mcp]
added.extend(name for name in defaults if name not in mcp)
print(json.dumps(dedupe(added), separators=(",", ":")))
PYEOF
}

json_unmerge_mcp_config() {
  env CLAUDE_JSON="$CLAUDE_JSON" INSTALL_MANIFEST="$INSTALL_MANIFEST" python3 - <<'PYEOF'
import json
import os
from pathlib import Path

config_path = Path(os.environ["CLAUDE_JSON"])
manifest_path = Path(os.environ["INSTALL_MANIFEST"])

def load_json(path):
    try:
        text = path.read_text().strip()
    except OSError:
        return {}
    if not text:
        return {}
    return json.loads(text)

config = load_json(config_path)
manifest = load_json(manifest_path)
if not isinstance(config, dict):
    config = {}
if not isinstance(manifest, dict):
    manifest = {}

added_servers = manifest.get("managedConfig", {}).get("mcpAddedServers", [])
if not isinstance(added_servers, list):
    added_servers = []

mcp = config.get("mcpServers", {})
if isinstance(mcp, dict):
    for server in added_servers:
        if isinstance(server, str):
            mcp.pop(server, None)
    if not mcp:
        config.pop("mcpServers", None)

print(json.dumps(config, indent=2))
PYEOF
}

merge_claude_settings() {
  [ -f "$SETTINGS_TEMPLATE_SRC" ] || die "Missing settings template: $SETTINGS_TEMPLATE_SRC"
  local merged
  SETTINGS_ADDED_PERMISSIONS_JSON="$(json_settings_added_permissions)"
  merged="$(json_merge_claude_settings)"
  write_text_file "$SETTINGS_DST" "$merged" "Claude settings" Y
  SETTINGS_BACKUP_PATH="$LAST_BACKUP_PATH"
  write_file_from_source "$SETTINGS_TEMPLATE_SRC" "$SETTINGS_SNAPSHOT_DST" "b-skills settings snapshot"
}

merge_mcp_config() {
  if ! wants_yes "$INSTALL_MCPS_VALUE"; then
    return 0
  fi
  local merged
  MCP_ADDED_SERVERS_JSON="$(json_mcp_added_servers)"
  merged="$(json_merge_mcp_config)"
  write_text_file "$CLAUDE_JSON" "$merged" "Claude MCP config" Y
  MCP_BACKUP_PATH="$LAST_BACKUP_PATH"
}

write_install_manifest() {
  local manifest_content
  manifest_content="$(env TIMESTAMP="$TIMESTAMP" DRY_RUN_VALUE="$DRY_RUN_VALUE" MEMORY_INSTALL_ACTION="$MEMORY_INSTALL_ACTION" RUNTIME_ACTIVATION_STATE="$RUNTIME_ACTIVATION_STATE" MEMORY_BACKUP_PATH="$MEMORY_BACKUP_PATH" SETTINGS_BACKUP_PATH="$SETTINGS_BACKUP_PATH" MCP_BACKUP_PATH="$MCP_BACKUP_PATH" INSTALL_MCPS_VALUE="$INSTALL_MCPS_VALUE" INSTALL_GITNEXUS_VALUE="$INSTALL_GITNEXUS_VALUE" SETTINGS_ADDED_PERMISSIONS_JSON="$SETTINGS_ADDED_PERMISSIONS_JSON" MCP_ADDED_SERVERS_JSON="$MCP_ADDED_SERVERS_JSON" CLAUDE_DIR="$CLAUDE_DIR" CLAUDE_JSON="$CLAUDE_JSON" MEMORY_DST="$MEMORY_DST" MEMORY_SNAPSHOT_DST="$MEMORY_SNAPSHOT_DST" SETTINGS_DST="$SETTINGS_DST" INSTALL_MANIFEST="$INSTALL_MANIFEST" python3 - <<'PYEOF'
import json
import os

def yes(value):
    return (value or "").strip().lower() in {"y", "yes"}

payload = {
    "suite": "b-skills",
    "runtime": "claude",
    "installedAt": os.environ["TIMESTAMP"],
    "dryRun": yes(os.environ.get("DRY_RUN_VALUE")),
    "memoryAction": os.environ.get("MEMORY_INSTALL_ACTION", "preserve"),
    "activationState": os.environ.get("RUNTIME_ACTIVATION_STATE", "active"),
    "managedPaths": {
        "claudeDir": os.environ["CLAUDE_DIR"],
        "skillsDir": os.environ["CLAUDE_DIR"] + "/skills",
        "agentsDir": os.environ["CLAUDE_DIR"] + "/agents",
        "hooksDir": os.environ["CLAUDE_DIR"] + "/hooks",
        "referencesDir": os.environ["CLAUDE_DIR"] + "/references/b-skills",
        "memory": os.environ["MEMORY_DST"],
        "memorySnapshot": os.environ["MEMORY_SNAPSHOT_DST"],
        "settings": os.environ["SETTINGS_DST"],
        "mcpConfig": os.environ["CLAUDE_JSON"],
        "installManifest": os.environ["INSTALL_MANIFEST"],
    },
    "backups": {
        "memory": os.environ.get("MEMORY_BACKUP_PATH", "none"),
        "settings": os.environ.get("SETTINGS_BACKUP_PATH", "none"),
        "mcpConfig": os.environ.get("MCP_BACKUP_PATH", "none"),
    },
    "managedConfig": {
        "settingsTemplate": True,
        "settingsAddedPermissions": json.loads(os.environ.get("SETTINGS_ADDED_PERMISSIONS_JSON") or "{}"),
        "mcpDefaults": yes(os.environ.get("INSTALL_MCPS_VALUE")),
        "mcpAddedServers": json.loads(os.environ.get("MCP_ADDED_SERVERS_JSON") or "[]"),
        "gitnexus": yes(os.environ.get("INSTALL_GITNEXUS_VALUE")),
    },
}
print(json.dumps(payload, indent=2))
PYEOF
)"
  write_text_file "$INSTALL_MANIFEST" "$manifest_content" "b-skills install manifest"
}

restore_memory_backup_if_available() {
  local backup_path=""
  [ -f "$INSTALL_MANIFEST" ] || return 1
  [ -f "$MEMORY_SNAPSHOT_DST" ] || return 1
  [ -f "$MEMORY_DST" ] || return 1
  cmp -s "$MEMORY_DST" "$MEMORY_SNAPSHOT_DST" || {
    log "Preserved Claude CLAUDE.md because it has changed since b-skills install"
    return 0
  }
  backup_path="$(env INSTALL_MANIFEST="$INSTALL_MANIFEST" python3 - <<'PYEOF'
import json
import os
from pathlib import Path
try:
    payload = json.loads(Path(os.environ["INSTALL_MANIFEST"]).read_text())
except Exception:
    raise SystemExit(0)
value = payload.get("backups", {}).get("memory", "")
if isinstance(value, str) and value and value != "none":
    print(value)
PYEOF
)"
  [ -n "$backup_path" ] || return 1
  [ -f "$backup_path" ] || return 1
  if dry_run_enabled; then
    log "[dry-run] restore $backup_path -> $MEMORY_DST"
    return 0
  fi
  cp "$backup_path" "$MEMORY_DST"
  log "OK: Claude CLAUDE.md restored from backup"
}

remove_memory_if_b_skills_managed() {
  [ -f "$MEMORY_DST" ] || {
    log "OK: Claude CLAUDE.md already absent"
    return 0
  }
  if [ -f "$MEMORY_SNAPSHOT_DST" ] && cmp -s "$MEMORY_DST" "$MEMORY_SNAPSHOT_DST"; then
    remove_path_if_exists "$MEMORY_DST" "Claude CLAUDE.md"
  else
    log "Preserved Claude CLAUDE.md because it does not match the b-skills snapshot"
  fi
}

unmerge_claude_settings() {
  [ -f "$SETTINGS_DST" ] || {
    log "OK: Claude settings already absent"
    return 0
  }
  local cleaned settings_template_path=""
  if [ -f "$SETTINGS_TEMPLATE_SRC" ]; then
    settings_template_path="$SETTINGS_TEMPLATE_SRC"
  elif [ -f "$SETTINGS_SNAPSHOT_DST" ]; then
    settings_template_path="$SETTINGS_SNAPSHOT_DST"
  else
    log "WARN: b-skills settings template unavailable; removing hook entries and recorded permissions only"
  fi
  cleaned="$(json_unmerge_claude_settings "$settings_template_path")"
  if [ "$cleaned" = "{}" ]; then
    remove_path_if_exists "$SETTINGS_DST" "Claude settings"
  else
    write_text_file "$SETTINGS_DST" "$cleaned" "Claude settings" Y
  fi
}

unmerge_mcp_config() {
  [ -f "$CLAUDE_JSON" ] || {
    log "OK: Claude MCP config already absent"
    return 0
  }
  local cleaned
  cleaned="$(json_unmerge_mcp_config)"
  if [ "$cleaned" = "{}" ]; then
    remove_path_if_exists "$CLAUDE_JSON" "Claude MCP config"
  else
    write_text_file "$CLAUDE_JSON" "$cleaned" "Claude MCP config" Y
  fi
}

sync_repo() {
  section "Sync b-skills repo"
  if [ -d "$LOCAL_REPO/.git" ]; then
    if [ -n "$(git -C "$LOCAL_REPO" status --porcelain)" ]; then
      die "Local changes detected in $LOCAL_REPO; commit or stash before re-running."
    fi
    log "Updating $LOCAL_REPO"
    git -C "$LOCAL_REPO" pull --ff-only || die "git pull --ff-only failed. Resolve in $LOCAL_REPO and re-run."
  else
    log "Cloning $REPO_URL -> $LOCAL_REPO"
    git clone "$REPO_URL" "$LOCAL_REPO"
  fi
  if [ -n "$REF" ]; then
    log "Checking out ref: $REF"
    git -C "$LOCAL_REPO" checkout "$REF"
  fi
}

install_assets() {
  preflight_install_targets

  section "Install Claude skills"
  [ -d "$SKILLS_SRC" ] || die "Missing skills source directory: $SKILLS_SRC"
  local synced_skills=0 skill_dir skill_name
  ensure_dir "$SKILLS_DST"
  for skill_dir in "$SKILLS_SRC"/*/; do
    [ -d "$skill_dir" ] || continue
    [ -f "$skill_dir/SKILL.md" ] || continue
    skill_name="$(basename "$skill_dir")"
    sync_directory "$skill_dir" "$SKILLS_DST/$skill_name" "skill $skill_name"
    synced_skills=$((synced_skills + 1))
  done
  log "OK: skills synced: $synced_skills"

  section "Install Claude agents"
  [ -d "$AGENTS_SRC" ] || die "Missing agents source directory: $AGENTS_SRC"
  ensure_dir "$AGENTS_DST"
  local agent_file agent_name synced_agents=0
  for agent_file in "$AGENTS_SRC"/*.md; do
    [ -f "$agent_file" ] || continue
    agent_name="$(basename "$agent_file")"
    sync_file "$agent_file" "$AGENTS_DST/$agent_name" "agent $agent_name"
    synced_agents=$((synced_agents + 1))
  done
  log "OK: agents synced: $synced_agents"

  section "Install Claude hooks"
  [ -d "$HOOKS_SRC" ] || die "Missing hooks source directory: $HOOKS_SRC"
  ensure_dir "$HOOKS_DST"
  local hook_file hook_name synced_hooks=0
  for hook_file in "$HOOKS_SRC"/*; do
    [ -f "$hook_file" ] || continue
    hook_name="$(basename "$hook_file")"
    sync_file "$hook_file" "$HOOKS_DST/$hook_name" "hook $hook_name"
    if [ "$hook_name" = "b-skills-guard.py" ] && ! dry_run_enabled; then
      chmod +x "$HOOKS_DST/$hook_name"
    fi
    synced_hooks=$((synced_hooks + 1))
  done
  log "OK: hooks synced: $synced_hooks"

  section "Install shared references"
  [ -d "$REFERENCES_SRC" ] || die "Missing references source directory: $REFERENCES_SRC"
  sync_directory "$REFERENCES_SRC" "$REFERENCES_DST" "shared references"

  section "Install Claude memory"
  decide_memory_install_action
  write_file_from_source "$MEMORY_SRC" "$MEMORY_SNAPSHOT_DST" "b-skills Claude memory snapshot"
  case "$MEMORY_INSTALL_ACTION" in
    replace)
      write_file_from_source "$MEMORY_SRC" "$MEMORY_DST" "Claude CLAUDE.md" Y
      MEMORY_BACKUP_PATH="$LAST_BACKUP_PATH"
      RUNTIME_ACTIVATION_STATE="active"
      ;;
    unchanged)
      log "OK: Claude CLAUDE.md already matches b-skills"
      RUNTIME_ACTIVATION_STATE="active"
      ;;
    preserve)
      log "Preserved existing Claude CLAUDE.md"
      log "b-skills memory snapshot: $MEMORY_SNAPSHOT_DST"
      RUNTIME_ACTIVATION_STATE="pending"
      ;;
  esac

  section "Install Claude settings"
  merge_claude_settings

  section "MCP setup"
  prompt_mcp_install_if_needed
  if wants_yes "$INSTALL_MCPS_VALUE"; then
    collect_mcp_api_keys
    prompt_gitnexus_install_if_needed
    merge_mcp_config
  else
    INSTALL_GITNEXUS_VALUE="N"
    log "MCP defaults skipped"
  fi

  write_install_manifest
}

uninstall_b_skills() {
  section "Uninstall b-skills"
  remove_skill_if_managed b-spec
  remove_skill_if_managed b-plan
  remove_skill_if_managed b-research
  remove_skill_if_managed b-implement
  remove_skill_if_managed b-refactor
  remove_skill_if_managed b-debug
  remove_skill_if_managed b-test
  remove_skill_if_managed b-review
  remove_skill_if_managed b-audit

  remove_agent_if_managed b-plan-agent
  remove_agent_if_managed b-research-agent
  remove_agent_if_managed b-review-agent
  remove_agent_if_managed b-audit-agent

  remove_hook_if_managed b-skills-guard.py
  remove_path_if_exists "$REFERENCES_DST" "shared references"
  unmerge_claude_settings
  unmerge_mcp_config

  if ! restore_memory_backup_if_available; then
    remove_memory_if_b_skills_managed
  fi

  remove_path_if_exists "$MEMORY_SNAPSHOT_DST" "Claude memory snapshot"
  remove_path_if_exists "$SETTINGS_SNAPSHOT_DST" "settings snapshot"
  remove_path_if_exists "$INSTALL_MANIFEST" "install manifest"
  remove_dir_if_empty "$B_SKILLS_BACKUPS_DIR" "b-skills backups directory"
  remove_dir_if_empty "$B_SKILLS_METADATA_DIR" "b-skills metadata directory"
  remove_dir_if_empty "$CLAUDE_DIR/references" "Claude references directory"
  remove_dir_if_empty "$CLAUDE_DIR" "Claude config directory"

  section "Done"
  if dry_run_enabled; then
    log "OK: b-skills uninstall preview completed"
  else
    log "OK: b-skills uninstalled from Claude Code"
  fi
}

if wants_yes "$UNINSTALL_VALUE"; then
  uninstall_b_skills
  trap - EXIT
  exit 0
fi

sync_repo
install_assets

section "MCP defaults"
if wants_yes "$INSTALL_MCPS_VALUE"; then
  log "OK: MCP defaults merged into $CLAUDE_JSON"
  log "Core servers: serena, context7, brave-search, firecrawl"
  wants_yes "$INSTALL_GITNEXUS_VALUE" && log "Optional servers: gitnexus" || log "Optional servers: gitnexus skipped"
  log "brave-search: $(api_key_status "$BRAVE_API_KEY_VALUE")"
  log "context7: $(api_key_status "$CONTEXT7_API_KEY_VALUE")"
  log "firecrawl: $(api_key_status "$FIRECRAWL_API_KEY_VALUE")"
else
  log "MCP defaults skipped"
fi

section "Done"
if [ "$RUNTIME_ACTIVATION_STATE" = "pending" ]; then
  log "WARN: b-skills files were installed, but Claude runtime memory is not active yet."
elif dry_run_enabled; then
  log "OK: b-skills install preview completed"
else
  log "OK: b-skills installed successfully for Claude Code"
fi
log "Skills:     $SKILLS_DST"
log "Agents:     $AGENTS_DST"
log "Hooks:      $HOOKS_DST"
log "References: $REFERENCES_DST"
log "Memory:     $MEMORY_DST ($MEMORY_INSTALL_ACTION)"
log "Settings:   $SETTINGS_DST"
log "MCP config: $CLAUDE_JSON"
if [ "$MEMORY_BACKUP_PATH" != "none" ]; then
  log "Memory backup: $MEMORY_BACKUP_PATH"
fi
if [ "$SETTINGS_BACKUP_PATH" != "none" ]; then
  log "Settings backup: $SETTINGS_BACKUP_PATH"
fi
if [ "$MCP_BACKUP_PATH" != "none" ]; then
  log "MCP backup: $MCP_BACKUP_PATH"
fi
if dry_run_enabled; then
  log "Manifest:   $INSTALL_MANIFEST (preview only; not written)"
else
  log "Manifest:   $INSTALL_MANIFEST"
fi

if [ "$RUNTIME_ACTIVATION_STATE" = "pending" ]; then
  log "Next step: rerun with --replace-memory, or manually merge $MEMORY_SNAPSHOT_DST into $MEMORY_DST"
  trap - EXIT
  exit 2
fi

trap - EXIT
