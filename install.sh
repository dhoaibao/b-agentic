#!/usr/bin/env bash
# install.sh — Bootstrap or update b-skills on any machine
# Usage:
#   First time / update:
#     curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-skills/main/install.sh | bash
#
# Optional environment overrides:
#   B_SKILLS_REPO  — git URL to clone (default: https://github.com/dhoaibao/b-skills.git)
#   B_SKILLS_DIR   — local clone path (default: $HOME/.b-skills)
#   B_SKILLS_REF   — git ref to check out after clone/pull (default: leave on default branch)

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
readonly REPO_URL="${B_SKILLS_REPO:-https://github.com/dhoaibao/b-skills.git}"
readonly LOCAL_REPO="${B_SKILLS_DIR:-$HOME/.b-skills}"
readonly REF="${B_SKILLS_REF:-}"

readonly CLAUDE_DIR="$HOME/.claude"
readonly SKILLS_SRC="$LOCAL_REPO/skills"
readonly SKILLS_DST="$CLAUDE_DIR/skills"
readonly GLOBAL_SRC="$LOCAL_REPO/skills/global/CLAUDE.md"
readonly GLOBAL_DST="$CLAUDE_DIR/CLAUDE.md"
readonly SETTINGS_FILE="$CLAUDE_DIR/settings.json"
readonly TIMESTAMP="$(date +%Y%m%d%H%M%S)"

# ── Logging helpers ──────────────────────────────────────────────────────────
log()     { printf '%s\n' "$*"; }
section() { printf '\n── %s %s\n' "$*" "$(printf '%.0s─' $(seq 1 $((60 - ${#1}))))"; }
warn()    { printf '⚠️  %s\n' "$*" >&2; }
die()     { printf '❌ %s\n' "$*" >&2; exit 1; }

trap 'rc=$?; [ $rc -ne 0 ] && warn "install.sh failed at line $LINENO (exit $rc)"' EXIT

# ── Pre-flight: required binaries ────────────────────────────────────────────
require_bin() {
  command -v "$1" >/dev/null 2>&1 || die "Required binary not found: $1"
}

require_bin git
require_bin python3
command -v claude >/dev/null 2>&1 || warn "claude CLI not found — MCP install step will be skipped if you opt in."

# ── Helpers ──────────────────────────────────────────────────────────────────
prompt_yes_no() {
  # Usage: prompt_yes_no "Question? [y/N] " — echoes the user reply (default N).
  local prompt="$1" reply
  if [ ! -t 0 ] && [ ! -e /dev/tty ]; then
    printf 'N'
    return
  fi
  read -rp "$prompt" reply </dev/tty
  printf '%s' "${reply:-N}"
}

sync_directory() {
  # Mirror $1 → $2 atomically (replace target).
  local source_dir="$1" target_dir="$2"
  [ -d "$source_dir" ] || die "sync_directory: source missing: $source_dir"
  [ "$source_dir" = "$target_dir" ] && die "sync_directory: source and target identical"

  mkdir -p "$(dirname "$target_dir")"
  rm -rf "$target_dir"
  mkdir -p "$target_dir"
  # `cp -R` is portable (GNU + BSD/macOS); preserve mode/timestamps where possible.
  cp -R "$source_dir"/. "$target_dir"/
}

backup_if_regular_file() {
  # If $1 exists and is NOT a symlink, move it to $1.backup-<timestamp>.
  local path="$1"
  if [ -e "$path" ] && [ ! -L "$path" ]; then
    local backup="${path}.backup-${TIMESTAMP}"
    mv "$path" "$backup"
    log "📦 Backed up existing $path → $backup"
  fi
}

merge_settings_json() {
  # Merge JSON payload into ~/.claude/settings.json under the given kind.
  # kind ∈ {hooks, permissions}. Deduplicates by command set / pattern.
  local merge_payload="$1" merge_kind="$2"

  mkdir -p "$(dirname "$SETTINGS_FILE")"
  local existing
  existing=$(cat "$SETTINGS_FILE" 2>/dev/null || echo '{}')

  local merged
  if ! merged=$(
    MERGE_PAYLOAD="$merge_payload" MERGE_KIND="$merge_kind" EXISTING="$existing" \
    SETTINGS_FILE="$SETTINGS_FILE" TIMESTAMP="$TIMESTAMP" \
    python3 - <<'PYEOF'
import json, os, sys
from pathlib import Path

settings_file = Path(os.environ["SETTINGS_FILE"])
existing_raw  = os.environ.get("EXISTING", "{}")
merge_payload = json.loads(os.environ.get("MERGE_PAYLOAD", "{}"))
merge_kind    = os.environ.get("MERGE_KIND")
timestamp     = os.environ.get("TIMESTAMP")

try:
    existing = json.loads(existing_raw) if existing_raw.strip() else {}
except json.JSONDecodeError:
    backup = settings_file.with_suffix(f".json.invalid-{timestamp}")
    if settings_file.exists():
        backup.write_text(settings_file.read_text())
    print(f"Invalid JSON in {settings_file}. Backed it up to {backup}.", file=sys.stderr)
    existing = {}

if merge_kind == "hooks":
    hooks_new      = merge_payload.get("hooks", {})
    hooks_existing = existing.setdefault("hooks", {})

    def hook_commands(entry):
        return {
            hook.get("command")
            for hook in entry.get("hooks", [])
            if hook.get("type") == "command" and hook.get("command")
        }

    for hook_type, new_entries in hooks_new.items():
        existing_entries = hooks_existing.setdefault(hook_type, [])
        existing_cmds = set()
        for entry in existing_entries:
            existing_cmds.update(hook_commands(entry))
        for entry in new_entries:
            new_cmds = hook_commands(entry)
            if new_cmds and new_cmds.issubset(existing_cmds):
                continue
            existing_entries.append(entry)
            existing_cmds.update(new_cmds)

elif merge_kind == "permissions":
    permissions_new      = merge_payload.get("permissions", {})
    permissions_existing = existing.setdefault("permissions", {})
    for bucket in ("allow", "deny"):
        existing_list = permissions_existing.setdefault(bucket, [])
        for pattern in permissions_new.get(bucket, []):
            if pattern not in existing_list:
                existing_list.append(pattern)

else:
    raise SystemExit(f"Unsupported MERGE_KIND: {merge_kind}")

print(json.dumps(existing, indent=2))
PYEOF
  ); then
    return 1
  fi

  # Atomic write: temp file in the same dir, then mv.
  local tmp="${SETTINGS_FILE}.tmp-${TIMESTAMP}"
  printf '%s\n' "$merged" > "$tmp"
  mv "$tmp" "$SETTINGS_FILE"
}

mcp_already_added() {
  # Returns 0 if the named MCP is already configured for this user.
  local name="$1"
  command -v claude >/dev/null 2>&1 || return 1
  claude mcp list 2>/dev/null | awk '{print $1}' | grep -Fxq "$name"
}

# ── 1. Clone or update the repo ──────────────────────────────────────────────
section "Sync b-skills repo"
if [ -d "$LOCAL_REPO/.git" ]; then
  if [ -n "$(git -C "$LOCAL_REPO" status --porcelain)" ]; then
    die "Local changes detected in $LOCAL_REPO — commit or stash before re-running."
  fi
  log "🔄 Updating $LOCAL_REPO"
  if ! git -C "$LOCAL_REPO" pull --ff-only; then
    die "git pull --ff-only failed (branch may have diverged). Resolve in $LOCAL_REPO and re-run."
  fi
else
  log "📦 Cloning $REPO_URL → $LOCAL_REPO"
  git clone "$REPO_URL" "$LOCAL_REPO"
fi

if [ -n "$REF" ]; then
  log "🏷  Checking out ref: $REF"
  git -C "$LOCAL_REPO" checkout "$REF"
fi

# ── 2. Sync skills to ~/.claude/skills/ ───────────────────────────────────────
section "Sync skills"
if [ -d "$SKILLS_SRC" ]; then
  mkdir -p "$SKILLS_DST"

  # Remove stale skills that no longer exist in the repo.
  stale_count=0
  if compgen -G "$SKILLS_DST"/*/SKILL.md > /dev/null; then
    for existing in "$SKILLS_DST"/*/SKILL.md; do
      skill_dir_name=$(basename "$(dirname "$existing")")
      if [ ! -d "$SKILLS_SRC/$skill_dir_name" ]; then
        rm -rf "$(dirname "$existing")"
        stale_count=$((stale_count + 1))
      fi
    done
  fi

  # Sync every skill except the `global` directory (handled below).
  synced_count=0
  for skill_dir in "$SKILLS_SRC"/*/; do
    [ -d "$skill_dir" ] || continue
    skill_name=$(basename "$skill_dir")
    [ "$skill_name" = "global" ] && continue
    [ -f "$skill_dir/SKILL.md" ] || continue
    sync_directory "$skill_dir" "$SKILLS_DST/$skill_name"
    synced_count=$((synced_count + 1))
  done

  removed_summary=""
  [ "$stale_count" -gt 0 ] && removed_summary=", $stale_count removed"
  log "✅ Skills: $synced_count synced$removed_summary → $SKILLS_DST"
else
  warn "No skills/ folder found in $LOCAL_REPO — skipping skill sync."
fi

# ── 3. Sync global CLAUDE.md to ~/.claude/CLAUDE.md ──────────────────────────
section "Link global CLAUDE.md"
if [ -f "$GLOBAL_SRC" ]; then
  mkdir -p "$(dirname "$GLOBAL_DST")"
  backup_if_regular_file "$GLOBAL_DST"
  ln -sfn "$GLOBAL_SRC" "$GLOBAL_DST"
  log "🔗 $GLOBAL_DST → $GLOBAL_SRC"
else
  warn "Global CLAUDE.md not found at $GLOBAL_SRC — skipping link step."
fi

# ── 4. Auto-setup Claude Code hooks for Serena ───────────────────────────────
section "Install Serena hooks"
HOOKS_CONFIG='{
  "hooks": {
    "PreToolUse": [
      { "matcher": "",            "hooks": [{ "type": "command", "command": "serena-hooks remind --client=claude-code" }] },
      { "matcher": "mcp__serena__*", "hooks": [{ "type": "command", "command": "serena-hooks auto-approve --client=claude-code" }] }
    ],
    "SessionStart": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "serena-hooks activate --client=claude-code" }] }
    ],
    "Stop": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "serena-hooks cleanup --client=claude-code" }] }
    ]
  }
}'

if merge_settings_json "$HOOKS_CONFIG" hooks; then
  log "✅ Serena hooks merged into $SETTINGS_FILE"
  log "   Restart Claude Code for hooks to take effect."
else
  die "Failed to merge Serena hooks into $SETTINGS_FILE"
fi

# ── 5. Auto-setup MCP tool permissions ───────────────────────────────────────
section "Install MCP permissions"
PERMISSIONS_CONFIG='{
  "permissions": {
    "allow": [
      "mcp__serena__*",
      "mcp__context7__*",
      "mcp__brave-search__*",
      "mcp__firecrawl__*",
      "mcp__sequential-thinking__*",
      "mcp__playwright__*"
    ],
    "deny": [
      "Read(**/.env)",
      "Read(**/.env.*)",
      "Read(**/*.env)",
      "Read(**/.envrc)",
      "Read(**/.npmrc)",
      "Read(**/.pypirc)",
      "Read(**/.netrc)",
      "Read(**/credentials.json)",
      "Read(**/settings.local.json)",
      "Read(**/secrets.yml)",
      "Read(**/secrets.yaml)",
      "Read(**/*.tfvars)",
      "Read(**/terraform.tfstate*)",
      "Read(**/*.pem)",
      "Read(**/*.key)",
      "Read(**/*.p12)",
      "Read(**/*.pfx)",
      "Read(**/id_rsa)",
      "Read(**/id_ed25519)",
      "Read(**/.ssh/*)",
      "Read(**/.gnupg/*)",
      "Read(**/.aws/*)",
      "Read(**/.config/gcloud/*)",
      "Read(**/kubeconfig)",
      "Read(**/.kube/config)",
      "Edit(**/.env)",
      "Edit(**/.env.*)",
      "Edit(**/*.env)",
      "Write(**/.env)",
      "Write(**/.env.*)",
      "Write(**/*.env)"
    ]
  }
}'

if merge_settings_json "$PERMISSIONS_CONFIG" permissions; then
  log "✅ MCP permissions merged into $SETTINGS_FILE"
else
  die "Failed to merge MCP permissions into $SETTINGS_FILE"
fi

# ── 6. Install / update MCP servers (optional, interactive) ──────────────────
section "Install MCP servers (optional)"
if ! command -v claude >/dev/null 2>&1; then
  warn "claude CLI not found — skipping MCP install. Install Claude Code first, then re-run."
else
  log "Adds: context7, brave-search, firecrawl, serena, sequential-thinking, playwright"
  install_mcps=$(prompt_yes_no "Install MCPs? [y/N] (default: N): ")

  if [[ "$install_mcps" =~ ^[Yy]$ ]]; then
    log ""
    log "Enter API keys (leave blank to skip a given MCP):"
    read -rsp "  BRAVE_API_KEY: "      brave_key      </dev/tty; echo ""
    read -rp  "  FIRECRAWL_API_URL (default: https://api.firecrawl.dev/): " firecrawl_url </dev/tty
    firecrawl_url="${firecrawl_url:-https://api.firecrawl.dev/}"
    read -rsp "  FIRECRAWL_API_KEY: "  firecrawl_key  </dev/tty; echo ""
    log ""

    # sequential-thinking
    if mcp_already_added sequential-thinking; then
      log "✅ sequential-thinking already configured — skipping"
    else
      log "➕ Adding sequential-thinking..."
      claude mcp add -s user sequential-thinking npx -- -y @modelcontextprotocol/server-sequential-thinking \
        && log "✅ sequential-thinking added" \
        || warn "Failed to add sequential-thinking"
    fi

    # playwright
    if mcp_already_added playwright; then
      log "✅ playwright already configured — skipping"
    else
      log "➕ Adding playwright..."
      claude mcp add -s user playwright npx -- -y @playwright/mcp@latest \
        && log "✅ playwright added" \
        || warn "Failed to add playwright"
    fi

    # brave-search
    if [ -n "$brave_key" ]; then
      if mcp_already_added brave-search; then
        log "✅ brave-search already configured — skipping (key not updated)"
      else
        log "➕ Adding brave-search..."
        claude mcp add brave-search -s user -e BRAVE_API_KEY="$brave_key" -- npx -y @brave/brave-search-mcp-server \
          && log "✅ brave-search added" \
          || warn "Failed to add brave-search"
      fi
    else
      log "⏭  Skipping brave-search (no API key provided)"
    fi

    # firecrawl
    if [ -n "$firecrawl_key" ]; then
      if mcp_already_added firecrawl; then
        log "✅ firecrawl already configured — skipping (key not updated)"
      else
        log "➕ Adding firecrawl..."
        claude mcp add firecrawl -s user \
          -e FIRECRAWL_API_URL="$firecrawl_url" \
          -e FIRECRAWL_API_KEY="$firecrawl_key" \
          -- npx -y firecrawl-mcp \
          && log "✅ firecrawl added" \
          || warn "Failed to add firecrawl"
      fi
    else
      log "⏭  Skipping firecrawl (no API key provided)"
    fi

    # context7 — needs interactive setup
    log ""
    log "ℹ️  Context7: run interactively to finish setup:"
    log "     npx ctx7@latest setup"

    # serena — needs uv + serena CLI
    log ""
    log "ℹ️  Serena: run the following to install and register:"
    log "     uv tool install -p 3.13 serena-agent@latest --prerelease=allow"
    log "     serena init"
    log "     claude mcp add --scope user serena -- serena start-mcp-server --context claude-code --project-from-cwd"
    log "     (If uv is not installed: curl -LsSf https://astral.sh/uv/install.sh | sh)"
  else
    log "⏭  Skipping MCP server install."
  fi
fi

# ── 7. Done ──────────────────────────────────────────────────────────────────
section "Done"
log "✅ b-skills installed successfully."
log "   Skills:    $SKILLS_DST/"
log "   Global:    $GLOBAL_DST"
log "   Settings:  $SETTINGS_FILE"
log ""
log "   Restart Claude Code to load the skills."

trap - EXIT
