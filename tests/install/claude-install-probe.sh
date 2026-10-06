#!/usr/bin/env bash
# Exercise tooling/install/claude_install.py (through install.sh) in sandbox HOME
# directories. Needs only python3, git, and jq: no network, credentials, Claude
# Code, or Codex. Every scenario owns a private HOME, so nothing outside the
# throwaway work directory is read or written.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT

fail() { echo "install probe failed: $*" >&2; exit 1; }

# fresh_home <name>: a sandbox HOME with a frozen Pi tree that must never change.
fresh_home() {
  local home="$work/$1"
  mkdir -p "$home/.pi/agent/skills/b-plan"
  printf 'frozen pi skill\n' >"$home/.pi/agent/skills/b-plan/SKILL.md"
  printf '{"pi":true}\n' >"$home/.pi/agent/settings.json"
  printf '%s' "$home"
}
# tree <dir> [exclude-backups]: sorted `sha256  relative-path` list, symlinks included.
tree() {
  # shellcheck disable=SC2016 # The inner script runs in sh and expands its own variables.
  ( cd "$1" && find . \( -type f -o -type l \) -not -path './.claude/b-agentic/backups/*' -print0 \
      | sort -z | xargs -0 -r sh -c 'for f; do if [ -L "$f" ]; then printf "link %s -> %s\n" "$f" "$(readlink "$f")"; else printf "%s  %s\n" "$(sha256sum "$f" | cut -d" " -f1)" "$f"; fi; done' _ )
}
# run <home> [args...]: stdout to $out, stderr to $err, exit code to $rc.
out="" err="" rc=0
run() {
  local home=$1
  shift
  rc=0
  out=$(env -u CLAUDE_CONFIG_DIR -u B_AGENTIC_CLAUDE_DIR -u B_AGENTIC_CLICKUP_MCP HOME="$home" bash "$root/install.sh" "$@" 2>"$work/stderr") || rc=$?
  err=$(cat "$work/stderr")
}
# copy_source <dest>: a private copy of the tracked and untracked source tree.
copy_source() {
  mkdir -p "$1"
  ( cd "$root" && git ls-files -co --exclude-standard -z | tar --null -T - -cf - ) | tar -xf - -C "$1"
}
# run_from <home> <source> [args...]: like run, installing from another source tree.
run_from() {
  local home=$1 source=$2
  shift 2
  rc=0
  out=$(env -u CLAUDE_CONFIG_DIR -u B_AGENTIC_CLAUDE_DIR -u B_AGENTIC_CLICKUP_MCP HOME="$home" bash "$source/install.sh" "$@" 2>"$work/stderr") || rc=$?
  err=$(cat "$work/stderr")
}
# runenv <home> <NAME=value> [args...]: like run, with one extra environment assignment.
runenv() {
  local home=$1 assignment=$2
  shift 2
  rc=0
  out=$(env -u CLAUDE_CONFIG_DIR -u B_AGENTIC_CLAUDE_DIR -u B_AGENTIC_CLICKUP_MCP HOME="$home" "$assignment" bash "$root/install.sh" "$@" 2>"$work/stderr") || rc=$?
  err=$(cat "$work/stderr")
}
expect_ok() { [ "$rc" = 0 ] || fail "$1 (exit $rc: $err $out)"; }
expect_refused() { [ "$rc" = 1 ] || fail "$1 (exit $rc, expected 1: $err $out)"; }

pi_before=""
skills_expected=$(jq -r '.skills | length' "$root/skills/registry.yaml")

# --- fresh install -------------------------------------------------------------
home=$(fresh_home fresh)
pi_before=$(tree "$home/.pi")
run "$home"; expect_ok "fresh install"
claude="$home/.claude"
[ "$(find "$claude/skills" -name SKILL.md | wc -l | tr -d ' ')" = "$skills_expected" ] || fail "skill count"
[ "$(find "$claude/agents" -name 'b-*.md' | wc -l | tr -d ' ')" = 4 ] || fail "agent count"
for file in bin/b-candidate-snapshot.mjs bin/b-codex-verdict.mjs hooks/b-path-guard.mjs hooks/b-codex-guard.mjs hooks/b-verify-gate.mjs references/kernel.template.md references/mcp_operations.yaml references/capabilities.yaml; do
  [ -f "$claude/b-agentic/$file" ] || fail "missing b-agentic/$file"
done
cmp -s "$root/skills/b-plan/SKILL.md" "$claude/skills/b-plan/SKILL.md" || fail "skill content differs from source"
grep -Fq '<!-- b-agentic:start -->' "$claude/CLAUDE.md" || fail "kernel block missing"
grep -Fq 'Claude Code Workflow Kernel' "$claude/CLAUDE.md" || fail "kernel text missing"
[ "$(jq -r '.permissions.deny | index("Bash(git push *)") != null' "$claude/settings.json")" = true ] || fail "deny rule missing"
[ "$(jq -r '.permissions.allow | index("mcp__codegraph__codegraph_explore") != null' "$claude/settings.json")" = true ] || fail "allow rule missing"
[ "$(jq -r '.hooks.Stop | length' "$claude/settings.json")" = 1 ] || fail "Stop hook missing"
[ "$(jq -r '.hooks.PreToolUse | length' "$claude/settings.json")" = 2 ] || fail "PreToolUse hooks missing"
[ "$(jq -r '.mcpServers | keys | length' "$home/.claude.json")" = 10 ] || fail "base MCP servers: $(jq -c '.mcpServers | keys' "$home/.claude.json")"
[ "$(jq -r '.mcpServers | has("clickup")' "$home/.claude.json")" = false ] || fail "ClickUp must be opt-in"
[ "$(jq -r .target "$claude/b-agentic/install.json")" = claude ] || fail "manifest target"
grep -Fq '/plugin install codex@openai-codex' <<<"$out" || fail "plugin commands not printed"
grep -Fq '/codex:setup' <<<"$out" || fail "setup command not printed"
[ "$pi_before" = "$(tree "$home/.pi")" ] || fail "install changed the Pi tree"
echo "install probe passed: fresh"

# --- idempotent re-run ------------------------------------------------------------
before=$(tree "$home")
run "$home"; expect_ok "second install"
[ "$before" = "$(tree "$home")" ] || fail "a re-run changed files"
grep -Fq 'no changes' <<<"$out" || grep -Fq 'unchanged' <<<"$out" || fail "re-run should report nothing to do: $out"
run "$home" --dry-run; expect_ok "dry-run"
grep -Fq '[dry-run]' <<<"$out" || fail "dry-run label missing"
[ "$before" = "$(tree "$home")" ] || fail "dry-run changed files"
echo "install probe passed: idempotent"

# --- uninstall restores a pristine home -----------------------------------------
run "$home" --uninstall; expect_ok "uninstall"
[ ! -e "$claude/skills" ] || fail "skills left after uninstall: $(ls "$claude/skills")"
[ ! -e "$claude/CLAUDE.md" ] || fail "created CLAUDE.md must be removed"
[ ! -e "$claude/b-agentic/install.json" ] || fail "manifest left"
[ "$(jq -c . "$claude/settings.json")" = '{}' ] || fail "settings entries left: $(cat "$claude/settings.json")"
[ "$(jq -c . "$home/.claude.json")" = '{}' ] || fail "MCP servers left: $(cat "$home/.claude.json")"
[ "$pi_before" = "$(tree "$home/.pi")" ] || fail "uninstall changed the Pi tree"
run "$home" --uninstall; expect_ok "second uninstall"
grep -Fq 'nothing to uninstall' <<<"$out" || fail "second uninstall should be a no-op"
echo "install probe passed: uninstall"

# --- user-owned content survives install and uninstall -----------------------------
home=$(fresh_home owned)
claude="$home/.claude"
mkdir -p "$claude/skills/synced/mine" "$claude/agents" "$claude/hooks"
printf 'user skill\n' >"$claude/skills/synced/mine/SKILL.md"
printf 'user agent\n' >"$claude/agents/mine.md"
printf '# My notes\n' >"$claude/CLAUDE.md"
cat >"$claude/settings.json" <<'JSON'
{
  "theme": "dark",
  "permissions": {
    "allow": [
      "Bash(ls *)"
    ],
    "deny": [
      "Bash(curl *)"
    ]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "echo user-hook"
          }
        ]
      }
    ]
  }
}
JSON
cat >"$home/.claude.json" <<'JSON'
{
  "numStartups": 7,
  "mcpServers": {
    "mine": {
      "type": "stdio",
      "command": "mine",
      "args": []
    }
  }
}
JSON
before=$(tree "$home")
run "$home"; expect_ok "install over user content"
[ "$(jq -r .theme "$claude/settings.json")" = dark ] || fail "user key lost"
[ "$(jq -r '.permissions.allow | index("Bash(ls *)") != null' "$claude/settings.json")" = true ] || fail "user allow rule lost"
[ "$(jq -r '.permissions.deny | index("Bash(curl *)") != null' "$claude/settings.json")" = true ] || fail "user deny rule lost"
[ "$(jq -r '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command] | index("echo user-hook") != null' "$claude/settings.json")" = true ] || fail "user hook lost"
[ "$(jq -r '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command] | length' "$claude/settings.json")" = 2 ] || fail "managed hook not appended to the user's Bash matcher"
[ "$(jq -r .numStartups "$home/.claude.json")" = 7 ] || fail "user key lost in .claude.json"
[ "$(jq -r '.mcpServers | has("mine")' "$home/.claude.json")" = true ] || fail "user MCP server lost"
grep -Fq '# My notes' "$claude/CLAUDE.md" || fail "user CLAUDE.md text lost"
[ -f "$claude/skills/synced/mine/SKILL.md" ] || fail "user skill lost"
[ -f "$claude/agents/mine.md" ] || fail "user agent lost"
ls "$claude/b-agentic/backups"/*/* >/dev/null 2>&1 || fail "no backups of the modified user files"
run "$home" --uninstall; expect_ok "uninstall over user content"
[ "$before" = "$(tree "$home")" ] || fail "uninstall did not restore user content byte for byte: $(diff <(printf '%s\n' "$before") <(tree "$home"))"
echo "install probe passed: user-content"

# --- modified, unmanaged, and symlinked files -----------------------------------------
home=$(fresh_home guarded)
claude="$home/.claude"
mkdir -p "$claude/skills/b-plan" "$claude/skills/b-debug"
printf 'someone elses b-plan\n' >"$claude/skills/b-plan/SKILL.md"
ln -s "$work/outside-target" "$claude/skills/b-debug/SKILL.md"
printf 'outside\n' >"$work/outside-target"
run "$home"; expect_ok "install beside conflicting files"
[ "$(cat "$claude/skills/b-plan/SKILL.md")" = 'someone elses b-plan' ] || fail "unmanaged file was overwritten"
grep -Fq 'not installed by b-agentic' <<<"$err" || fail "no warning for the unmanaged file"
[ -L "$claude/skills/b-debug/SKILL.md" ] || fail "symlink replaced"
[ "$(cat "$work/outside-target")" = outside ] || fail "wrote through a symlink"
grep -Fq 'symlink' <<<"$err" || fail "no warning for the symlink"
run "$home" --force; expect_ok "forced install"
cmp -s "$root/skills/b-plan/SKILL.md" "$claude/skills/b-plan/SKILL.md" || fail "--force did not replace the unmanaged file"
[ -L "$claude/skills/b-debug/SKILL.md" ] || fail "--force must not replace a symlink"
find "$claude/b-agentic/backups" -type f | grep -q 'b-plan' || fail "--force made no backup"
# A managed file edited by the user is kept on sync and on uninstall.
printf 'edited\n' >>"$claude/skills/b-research/SKILL.md"
run "$home"; expect_ok "sync with an edited managed file"
grep -Fq 'modified since install' <<<"$err" || fail "no warning for the edited file"
grep -Fq 'edited' "$claude/skills/b-research/SKILL.md" || fail "edited file was overwritten"
run "$home" --uninstall; expect_ok "uninstall with an edited managed file"
[ -f "$claude/skills/b-research/SKILL.md" ] || fail "edited file removed by uninstall"
echo "install probe passed: guarded-files"

# --- refusals leave the home untouched ---------------------------------------------------
home=$(fresh_home refusals)
pi_before=$(tree "$home/.pi")
runenv "$home" "CLAUDE_CONFIG_DIR=$home/.pi/agent"; expect_refused "installing into the Pi directory"
grep -Fq 'not supported' <<<"$err" || fail "custom directory refusal reason missing: $err"
[ "$pi_before" = "$(tree "$home/.pi")" ] || fail "Pi tree changed by a refused install"
run "$home" --claude-dir="$home/x"; expect_refused "the removed --claude-dir flag"
mkdir -p "$home/.claude"
printf '{broken' >"$home/.claude/settings.json"
before=$(tree "$home")
run "$home"; expect_refused "invalid settings.json"
grep -Fq 'settings.json is not valid JSON' <<<"$err" || fail "invalid JSON reason missing: $err"
[ "$before" = "$(tree "$home")" ] || fail "an invalid settings.json left a partial install"
printf '{}\n' >"$home/.claude/settings.json"
printf '[1]' >"$home/.claude.json"
run "$home"; expect_refused "non-object .claude.json"
run "$home" --bogus; expect_refused "unknown argument"
echo "install probe passed: refusals"

# --- optional ClickUp server and recorded choice ---------------------------------------------
home=$(fresh_home clickup)
claude="$home/.claude"
run "$home" --with-clickup; expect_ok "install with ClickUp"
[ "$(jq -r '.mcpServers | has("clickup")' "$home/.claude.json")" = true ] || fail "ClickUp server not added"
# shellcheck disable=SC2016 # The literal ${VAR} reference is the expected value.
[ "$(jq -r '.mcpServers.clickup.env.CLICKUP_API_KEY' "$home/.claude.json")" = '${CLICKUP_API_KEY}' ] || fail "ClickUp credential must stay an environment reference"
run "$home"; expect_ok "sync keeps the recorded choice"
[ "$(jq -r '.mcpServers | has("clickup")' "$home/.claude.json")" = true ] || fail "recorded ClickUp choice lost"
run "$home" --without-clickup; expect_ok "drop ClickUp"
[ "$(jq -r '.mcpServers | has("clickup")' "$home/.claude.json")" = false ] || fail "ClickUp server not removed"
# A user-edited server of the same name is kept, with a warning.
jq '.mcpServers.context7.url = "https://example.invalid/mcp"' "$home/.claude.json" >"$work/edited.json" && mv "$work/edited.json" "$home/.claude.json"
run "$home"; expect_ok "sync with an edited server"
[ "$(jq -r '.mcpServers.context7.url' "$home/.claude.json")" = "https://example.invalid/mcp" ] || fail "user-edited MCP server overwritten"
grep -Fq "kept your existing MCP server 'context7'" <<<"$err" || fail "no warning for the edited server"
run "$home" --uninstall; expect_ok "uninstall with an edited server"
[ "$(jq -r '.mcpServers | keys | join(",")' "$home/.claude.json")" = context7 ] || fail "uninstall must keep only the user-edited server"
echo "install probe passed: clickup"

# --- only the default ~/.claude directory is supported ------------------------------------
home=$(fresh_home custom)
runenv "$home" "CLAUDE_CONFIG_DIR=$work/custom-config"; expect_refused "custom CLAUDE_CONFIG_DIR"
grep -Fq 'not supported' <<<"$err" || fail "custom directory refusal reason missing: $err"
[ ! -e "$work/custom-config" ] && [ ! -e "$home/.claude" ] && [ ! -e "$home/.claude.json" ] || fail "a refused custom directory wrote files"
runenv "$home" "CLAUDE_CONFIG_DIR=$home/.claude"; expect_ok "CLAUDE_CONFIG_DIR equal to the default"
[ -f "$home/.claude/skills/b-plan/SKILL.md" ] || fail "default directory install failed"
echo "install probe passed: default-dir-only"

# --- hook identity: matcher, fields, and ownership -----------------------------------------------
home=$(fresh_home hooks)
claude="$home/.claude"
run "$home"; expect_ok "install for hook identity"
jq '(.hooks.PreToolUse[] | select(.matcher == "Bash")) |= (.matcher = "Read" | .hooks[0].timeout = 5)' "$claude/settings.json" >"$work/moved.json" && mv "$work/moved.json" "$claude/settings.json"
run "$home"; expect_ok "reinstall after the user moved a hook"
grep -Fq 'different matcher or fields' <<<"$err" || fail "no warning for a moved safety hook: $err"
[ "$(jq -r '[.. | objects | select(.command? != null and (.command | contains("b-codex-guard.mjs")))] | length' "$claude/settings.json")" = 1 ] || fail "a moved hook was duplicated"
run "$home" --uninstall; expect_ok "uninstall with a moved hook"
[ "$(jq -r '[.. | objects | select(.command? != null and (.command | contains("b-codex-guard.mjs")))] | length' "$claude/settings.json")" = 1 ] || fail "uninstall removed a user-modified hook"
[ "$(jq -r '[.. | objects | select(.command? != null and (.command | contains("b-path-guard.mjs")))] | length' "$claude/settings.json")" = 0 ] || fail "uninstall left an unmodified managed hook"

home=$(fresh_home identical-hook)
claude="$home/.claude"
mkdir -p "$claude"
cat >"$claude/settings.json" <<'JSON'
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "node \"$HOME/.claude/b-agentic/hooks/b-verify-gate.mjs\""
          }
        ]
      }
    ]
  }
}
JSON
run "$home"; expect_ok "install beside an identical user hook"
[ "$(jq -r '.hooks.Stop | length' "$claude/settings.json")" = 1 ] || fail "an identical user hook was duplicated"
run "$home"; expect_ok "second install beside an identical user hook"
run "$home" --uninstall; expect_ok "uninstall beside an identical user hook"
[ "$(jq -r '.hooks.Stop | length' "$claude/settings.json")" = 1 ] || fail "uninstall removed an identical user-owned hook"
echo "install probe passed: hook-identity"

# --- byte equality is not ownership ------------------------------------------------------------------
home=$(fresh_home identical-file)
claude="$home/.claude"
mkdir -p "$claude/agents"
cp "$root/claude/agents/b-planner.md" "$claude/agents/b-planner.md"
run "$home"; expect_ok "install beside an identical file"
run "$home"; expect_ok "second install beside an identical file"
[ "$(jq -r '.files | has("agents/b-planner.md")' "$claude/b-agentic/install.json")" = false ] || fail "an identical unmanaged file was recorded as owned"
run "$home" --uninstall; expect_ok "uninstall beside an identical file"
cmp -s "$root/claude/agents/b-planner.md" "$claude/agents/b-planner.md" || fail "uninstall deleted an identical user-owned file"
echo "install probe passed: identical-file"

# --- kernel markers: malformed refuse, modified blocks are preserved -----------------------------
for label in orphan-start duplicate-start reversed; do
  home=$(fresh_home "markers-$label")
  claude="$home/.claude"
  mkdir -p "$claude"
  case "$label" in
    orphan-start) printf '<!-- b-agentic:start -->\nmy notes\n' >"$claude/CLAUDE.md" ;;
    duplicate-start) printf '<!-- b-agentic:start -->\n<!-- b-agentic:start -->\nx\n<!-- b-agentic:end -->\n' >"$claude/CLAUDE.md" ;;
    reversed) printf '<!-- b-agentic:end -->\nx\n<!-- b-agentic:start -->\n' >"$claude/CLAUDE.md" ;;
  esac
  before=$(tree "$home")
  run "$home"; expect_refused "malformed markers ($label)"
  grep -Fq 'markers' <<<"$err" || fail "marker refusal reason missing ($label): $err"
  [ "$before" = "$(tree "$home")" ] || fail "malformed markers left a partial install ($label)"
done
home=$(fresh_home markers-edited)
claude="$home/.claude"
run "$home"; expect_ok "install for an edited kernel block"
printf 'MY LOCAL RULE\n' >"$work/rule.txt"
sed -i '/<!-- b-agentic:end -->/e cat "'"$work"'/rule.txt"' "$claude/CLAUDE.md"
grep -Fq 'MY LOCAL RULE' "$claude/CLAUDE.md" || fail "could not edit the kernel block fixture"
run "$home"; expect_ok "reinstall with an edited kernel block"
grep -Fq 'kept the kernel block' <<<"$err" || fail "no warning for the edited kernel block: $err"
grep -Fq 'MY LOCAL RULE' "$claude/CLAUDE.md" || fail "an edited kernel block was replaced without --force"
run "$home" --uninstall; expect_ok "uninstall with an edited kernel block"
grep -Fq 'MY LOCAL RULE' "$claude/CLAUDE.md" || fail "uninstall removed an edited kernel block"
run "$home" --force; expect_ok "forced install over an edited kernel block"
run "$home" --force; expect_ok "second forced install"
grep -Fq 'MY LOCAL RULE' "$claude/CLAUDE.md" && fail "--force did not replace the edited kernel block"
echo "install probe passed: kernel-markers"

# --- symlinks: config files are written through, managed parents are refused -----------------
home=$(fresh_home symlinked-config)
claude="$home/.claude"
mkdir -p "$claude" "$home/dotfiles"
printf '{"theme":"dark"}\n' >"$home/dotfiles/settings.json"
printf '# dotfile notes\n' >"$home/dotfiles/CLAUDE.md"
ln -s "$home/dotfiles/settings.json" "$claude/settings.json"
ln -s "$home/dotfiles/CLAUDE.md" "$claude/CLAUDE.md"
run "$home"; expect_ok "install with symlinked config files"
[ -L "$claude/settings.json" ] && [ -L "$claude/CLAUDE.md" ] || fail "a symlinked config file was replaced"
[ "$(jq -r '.permissions.deny | length > 0' "$home/dotfiles/settings.json")" = true ] || fail "settings were not written through the symlink"
grep -Fq 'Claude Code Workflow Kernel' "$home/dotfiles/CLAUDE.md" || fail "the kernel was not written through the symlink"
[ "$(jq -r .theme "$home/dotfiles/settings.json")" = dark ] || fail "user key lost behind the symlink"
run "$home" --uninstall; expect_ok "uninstall with symlinked config files"
[ -L "$claude/settings.json" ] && [ -L "$claude/CLAUDE.md" ] || fail "uninstall replaced a symlinked config file"
[ "$(jq -c . "$home/dotfiles/settings.json")" = '{"theme":"dark"}' ] || fail "uninstall did not restore the symlinked settings: $(cat "$home/dotfiles/settings.json")"
[ "$(cat "$home/dotfiles/CLAUDE.md")" = '# dotfile notes' ] || fail "uninstall did not restore the symlinked CLAUDE.md"

home=$(fresh_home symlinked-parent)
claude="$home/.claude"
mkdir -p "$claude" "$work/elsewhere"
ln -s "$work/elsewhere" "$claude/skills"
run "$home"; expect_refused "a symlinked managed parent"
grep -Fq 'is a symlink' <<<"$err" || fail "symlink refusal reason missing: $err"
[ -z "$(ls -A "$work/elsewhere")" ] || fail "wrote through a symlinked managed parent"
[ ! -e "$home/.claude/b-agentic/install.json" ] || fail "a refused install wrote a manifest"

home=$(fresh_home symlinked-pi)
mv "$home/.pi" "$work/realpi"
ln -s "$work/realpi" "$home/.pi"
ln -s "$home/.pi/agent" "$home/.claude"
pi_before=$(tree "$work/realpi")
run "$home"; expect_refused "a ~/.claude that resolves into a symlinked ~/.pi"
grep -Fq 'Pi runtime' <<<"$err" || fail "Pi refusal reason missing: $err"
[ "$pi_before" = "$(tree "$work/realpi")" ] || fail "a symlinked Pi tree was changed"
echo "install probe passed: symlinks"

# --- structural refusals happen before the first write, uninstall included ---------------------
for label in permissions-array hooks-event-object mcp-array; do
  home=$(fresh_home "shape-$label")
  mkdir -p "$home/.claude"
  case "$label" in
    permissions-array) printf '{"permissions":[]}\n' >"$home/.claude/settings.json" ;;
    hooks-event-object) printf '{"hooks":{"Stop":{}}}\n' >"$home/.claude/settings.json" ;;
    mcp-array) printf '{"mcpServers":[]}\n' >"$home/.claude.json" ;;
  esac
  before=$(tree "$home")
  run "$home"; expect_refused "invalid nested shape ($label)"
  [ "$before" = "$(tree "$home")" ] || fail "an invalid nested shape left a partial install ($label)"
  [ ! -e "$home/.claude/skills" ] && [ ! -e "$home/.claude/b-agentic" ] || fail "assets were written before the refusal ($label)"
done
home=$(fresh_home uninstall-malformed)
claude="$home/.claude"
run "$home"; expect_ok "install before a malformed uninstall"
cp "$claude/settings.json" "$work/settings.good.json"
printf '{broken' >"$claude/settings.json"
before=$(tree "$home")
run "$home" --uninstall; expect_refused "uninstall with a malformed settings.json"
[ "$before" = "$(tree "$home")" ] || fail "a refused uninstall changed files"
cp "$work/settings.good.json" "$claude/settings.json"
run "$home" --uninstall; expect_ok "uninstall retry after repairing settings.json"
[ ! -e "$claude/skills" ] || fail "retry left skills behind"
echo "install probe passed: structural-refusals"

# --- backups never collide across rapid runs ------------------------------------------------------
home=$(fresh_home backups)
claude="$home/.claude"
mkdir -p "$claude"
printf '{"theme":"a"}\n' >"$claude/settings.json"
run "$home"; expect_ok "first install for backups"
printf '{"theme":"b"}\n' >"$work/theme-b.json"
jq -s '.[0] * .[1]' "$claude/settings.json" "$work/theme-b.json" >"$work/merged.json" && mv "$work/merged.json" "$claude/settings.json"
run "$home" --force; expect_ok "second install for backups"
[ "$(find "$claude/b-agentic/backups" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -ge 1 ] || fail "no backup directory"
find "$claude/b-agentic/backups" -type f -name '*settings.json' | grep -q . || fail "settings backup missing"
echo "install probe passed: backups"

# --- identical unmanaged kernel content is not ownership -------------------------------------------
home=$(fresh_home kernel-source)
run "$home"; expect_ok "install to capture the kernel block"
cp "$home/.claude/CLAUDE.md" "$work/identical-claude.md"
home=$(fresh_home kernel-identical)
mkdir -p "$home/.claude"
cp "$work/identical-claude.md" "$home/.claude/CLAUDE.md"
run "$home"; expect_ok "install beside an identical kernel block"
run "$home"; expect_ok "second install beside an identical kernel block"
[ "$(jq -r '.kernel_sha256' "$home/.claude/b-agentic/install.json")" = null ] || fail "an identical unmanaged kernel block was recorded as owned"
run "$home" --uninstall; expect_ok "uninstall beside an identical kernel block"
cmp -s "$work/identical-claude.md" "$home/.claude/CLAUDE.md" || fail "uninstall changed an identical user-owned kernel block"
echo "install probe passed: kernel-identical"

# --- every destination is validated before the first write ---------------------------------------------
home=$(fresh_home preflight-backups)
mkdir -p "$home/.claude/b-agentic"
ln -s "$home/.pi/agent" "$home/.claude/b-agentic/backups"
before=$(tree "$home")
run "$home"; expect_refused "a symlinked backups directory"
[ "$before" = "$(tree "$home")" ] || fail "a symlinked backups directory left a partial install"
[ ! -e "$home/.claude/skills" ] || fail "assets were written before the backups refusal"

home=$(fresh_home preflight-manifest-leaf)
mkdir -p "$home/.claude/b-agentic"
printf '{"schema":1}\n' >"$home/real-manifest.json"
ln -s "$home/real-manifest.json" "$home/.claude/b-agentic/install.json"
before=$(tree "$home")
run "$home"; expect_refused "a symlinked manifest file"
[ "$before" = "$(tree "$home")" ] || fail "a symlinked manifest left a partial install"

home=$(fresh_home preflight-uninstall)
mkdir -p "$home/.pi/agent/ba" "$home/.claude"
printf '{"schema":1,"files":{}}\n' >"$home/.pi/agent/ba/install.json"
ln -s "$home/.pi/agent/ba" "$home/.claude/b-agentic"
pi_before=$(tree "$home/.pi")
run "$home" --uninstall; expect_refused "uninstall with the assets directory behind a Pi symlink"
[ -f "$home/.pi/agent/ba/install.json" ] && [ "$pi_before" = "$(tree "$home/.pi")" ] || fail "uninstall removed or changed a protected manifest"

home=$(fresh_home preflight-ancestor)
mkdir -p "$home/.claude"
printf 'not a directory\n' >"$home/.claude/agents"
before=$(tree "$home")
run "$home"; expect_refused "a regular file where a managed directory belongs"
[ "$before" = "$(tree "$home")" ] || fail "a file ancestor left a partial install"
[ ! -e "$home/.claude/skills" ] && [ ! -e "$home/.claude/b-agentic" ] || fail "assets were written before the ancestor refusal"
echo "install probe passed: preflight"

# --- an interrupted update is recoverable by a retry and by an uninstall --------------------------------
if [ "$(id -u)" = 0 ]; then
  echo "install probe skipped: interrupted-update (root ignores directory modes)"
else
  src2="$work/src2"
  copy_source "$src2"
  printf '\n<!-- v2 -->\n' >>"$src2/skills/b-plan/SKILL.md"
  printf '\n<!-- v2 -->\n' >>"$src2/claude/agents/b-planner.md"
  printf '\n<!-- v2 kernel -->\n' >>"$src2/references/kernel.template.md"
  jq '.mcpServers |= with_entries(if .key == "shadcn" then .value.args += ["--v2"] else . end)' "$src2/claude/configs/mcp.base.json" >"$work/mcp2.json"
  mv "$work/mcp2.json" "$src2/claude/configs/mcp.base.json"
  old_skill=$(sha256sum "$root/skills/b-plan/SKILL.md" | cut -d' ' -f1)
  for mode in retry uninstall; do
    home=$(fresh_home "interrupted-$mode")
    claude="$home/.claude"
    run "$home"; expect_ok "install v1 ($mode)"
    chmod 555 "$claude/agents"
    run_from "$home" "$src2"; expect_refused "an update interrupted by an unwritable agents directory ($mode)"
    grep -Fq 'interrupted' <<<"$err" || fail "the interruption message is missing ($mode): $err"
    [ "$(jq -r '.files["skills/b-plan/SKILL.md"]' "$claude/b-agentic/install.json")" = "$old_skill" ] || fail "the committed ownership was overwritten by the intent ($mode)"
    [ "$(jq -r '.pending.files["skills/b-plan/SKILL.md"] | length' "$claude/b-agentic/install.json")" -ge 1 ] || fail "the pending update was not recorded ($mode)"
    chmod 755 "$claude/agents"
    if [ "$mode" = retry ]; then
      run_from "$home" "$src2"; expect_ok "retry after an interrupted update"
      grep -Eq 'kept|modified since install' <<<"$err" && fail "the retry treated its own interrupted update as user changes: $err"
      cmp -s "$src2/skills/b-plan/SKILL.md" "$claude/skills/b-plan/SKILL.md" || fail "the retry did not finish the skill update"
      cmp -s "$src2/claude/agents/b-planner.md" "$claude/agents/b-planner.md" || fail "the retry did not finish the agent update"
      grep -Fq '<!-- v2 kernel -->' "$claude/CLAUDE.md" || fail "the retry did not update the kernel block"
      [ "$(jq -r '.mcpServers.shadcn.args | index("--v2") != null' "$home/.claude.json")" = true ] || fail "the retry did not update the MCP server"
      [ "$(jq -r 'has("pending")' "$claude/b-agentic/install.json")" = false ] || fail "a committed manifest still carries pending state"
      run_from "$home" "$src2" --uninstall; expect_ok "uninstall after a recovered update"
    else
      run_from "$home" "$src2" --uninstall; expect_ok "uninstall of an interrupted update"
      grep -Fq 'modified since install' <<<"$err" && fail "uninstall treated its own interrupted update as user changes: $err"
    fi
    [ ! -e "$claude/skills" ] && [ ! -e "$claude/agents" ] && [ ! -e "$claude/b-agentic/install.json" ] && [ ! -e "$claude/b-agentic/hooks" ] || fail "uninstall left managed assets behind ($mode)"
    [ ! -e "$claude/CLAUDE.md" ] || fail "uninstall left the kernel behind ($mode)"
    [ "$(jq -r '.mcpServers // {} | length' "$home/.claude.json")" = 0 ] || fail "uninstall left MCP servers behind ($mode)"
  done
  echo "install probe passed: interrupted-update"
fi

# --- a second interruption keeps older pending ownership (retired file, pending-only server) -------
if [ "$(id -u)" = 0 ]; then
  echo "install probe skipped: repeated-interruption (root ignores directory modes)"
else
  src_new="$work/src-new"
  copy_source "$src_new"
  printf '# extra agent\n' >"$src_new/claude/agents/b-extra.md"
  printf '\n// v2\n' >>"$src_new/claude/hooks/b-verify-gate.mjs"
  src_gone="$work/src-gone"
  copy_source "$src_gone"
  printf '\n// v3\n' >>"$src_gone/claude/hooks/b-verify-gate.mjs"
  clickup_entry=$(jq -c '.mcpServers.clickup' "$root/claude/configs/mcp.clickup.json")
  home=$(fresh_home repeated-interruption)
  claude="$home/.claude"
  run "$home"; expect_ok "install the base payload"
  # Interruption 1: b-extra.md is written, then the read-only hooks directory stops the run.
  chmod 555 "$claude/b-agentic/hooks"
  run_from "$home" "$src_new" --with-clickup; expect_refused "first interruption"
  [ -f "$claude/agents/b-extra.md" ] || fail "the first run should have written the extra agent before stopping"
  [ "$(jq -r '.pending.files["agents/b-extra.md"] | length' "$claude/b-agentic/install.json")" -ge 1 ] || fail "the extra agent was not recorded as pending"
  [ "$(jq -r '.pending.mcp_servers | has("clickup")' "$claude/b-agentic/install.json")" = true ] || fail "the pending-only server was not recorded"
  # The server write happens after the payload, so simulate it having landed before a crash.
  jq --argjson entry "$clickup_entry" '.mcpServers.clickup = $entry' "$home/.claude.json" >"$work/with-clickup.json" && mv "$work/with-clickup.json" "$home/.claude.json"
  # Interruption 2: the next run schedules both for removal but stops before it gets there.
  run_from "$home" "$src_gone" --without-clickup; expect_refused "second interruption"
  [ -f "$claude/agents/b-extra.md" ] || fail "the second run removed the extra agent despite stopping early"
  [ "$(jq -r '.pending.files["agents/b-extra.md"] | length' "$claude/b-agentic/install.json")" -ge 1 ] || fail "the second interruption dropped the pending ownership of the retired file"
  [ "$(jq -r '.pending.mcp_servers | has("clickup")' "$claude/b-agentic/install.json")" = true ] || fail "the second interruption dropped the pending-only server"
  chmod 755 "$claude/b-agentic/hooks"
  run_from "$home" "$src_gone" --uninstall; expect_ok "uninstall after two interruptions"
  grep -Fq 'modified since install' <<<"$err" && fail "uninstall treated its own pending files as user changes: $err"
  [ ! -e "$claude/agents/b-extra.md" ] || fail "uninstall left the retired file behind"
  [ "$(jq -r '.mcpServers // {} | has("clickup")' "$home/.claude.json")" = false ] || fail "uninstall left the pending-only server behind"
  [ ! -e "$claude/b-agentic/install.json" ] && [ ! -e "$claude/skills" ] || fail "uninstall left managed assets behind"
  echo "install probe passed: repeated-interruption"
fi

# --- a config symlink that resolves beneath a regular file is refused before any write ----------------
for leaf in CLAUDE.md settings.json claude.json; do
  home=$(fresh_home "config-ancestor-$leaf")
  claude="$home/.claude"
  mkdir -p "$claude"
  printf 'not a directory\n' >"$home/blocker"
  case "$leaf" in
    claude.json) ln -s "$home/blocker/claude.json" "$home/.claude.json" ;;
    *) ln -s "$home/blocker/$leaf" "$claude/$leaf" ;;
  esac
  before=$(tree "$home")
  run "$home"; expect_refused "a $leaf symlink resolving beneath a regular file"
  grep -Fq 'not a directory' <<<"$err" || fail "ancestor refusal reason missing ($leaf): $err"
  [ "$before" = "$(tree "$home")" ] || fail "a bad $leaf topology left a partial install"
  [ ! -e "$claude/skills" ] && [ ! -e "$claude/b-agentic" ] || fail "assets were written before the $leaf refusal"
done
# The same topology introduced after an install must stop an uninstall before it removes anything.
for leaf in CLAUDE.md settings.json claude.json; do
  home=$(fresh_home "uninstall-ancestor-$leaf")
  claude="$home/.claude"
  run "$home"; expect_ok "install before the $leaf topology changes"
  printf 'not a directory\n' >"$home/blocker"
  case "$leaf" in
    claude.json) rm "$home/.claude.json"; ln -s "$home/blocker/claude.json" "$home/.claude.json" ;;
    *) rm "$claude/$leaf"; ln -s "$home/blocker/$leaf" "$claude/$leaf" ;;
  esac
  before=$(tree "$home")
  run "$home" --uninstall; expect_refused "uninstall with a $leaf symlink beneath a regular file"
  [ "$before" = "$(tree "$home")" ] || fail "a refused uninstall changed files ($leaf)"
done
home=$(fresh_home claude-dir-file)
printf 'a file\n' >"$home/.claude"
run "$home"; expect_refused "the Claude directory being a regular file"
echo "install probe passed: config-ancestors"

# --- destinations that resolve to the same file are refused (each is planned independently) ---------
# alias_case <name> <setup-body>: a sandbox where two destinations alias one file before install.
for alias in settings-mcp claudemd-settings settings-manifest settings-payload hardlink; do
  home=$(fresh_home "alias-$alias")
  claude="$home/.claude"
  mkdir -p "$claude/b-agentic"
  printf '{}\n' >"$home/shared.json"
  case "$alias" in
    settings-mcp) ln -s "$home/shared.json" "$claude/settings.json"; ln -s "$home/shared.json" "$home/.claude.json" ;;
    claudemd-settings) ln -s "$home/shared.json" "$claude/CLAUDE.md"; ln -s "$home/shared.json" "$claude/settings.json" ;;
    settings-manifest) ln -s "$claude/b-agentic/install.json" "$claude/settings.json" ;;
    settings-payload) ln -s "$claude/skills/b-plan/SKILL.md" "$claude/settings.json" ;;
    hardlink) printf '{}\n' >"$claude/settings.json"; ln "$claude/settings.json" "$home/.claude.json" ;;
  esac
  before=$(tree "$home")
  run "$home"; expect_refused "install with aliased destinations ($alias)"
  grep -Fq 'resolve to the same file' <<<"$err" || fail "alias refusal reason missing ($alias): $err"
  [ "$before" = "$(tree "$home")" ] || fail "an alias left a partial install ($alias)"
  [ ! -e "$claude/skills" ] && [ ! -e "$claude/agents" ] || fail "assets were written before the alias refusal ($alias)"
done
# An alias introduced after a clean install must stop an uninstall before it removes anything.
for alias in settings-mcp claudemd-settings hardlink; do
  home=$(fresh_home "uninstall-alias-$alias")
  claude="$home/.claude"
  run "$home"; expect_ok "install before the $alias alias appears"
  case "$alias" in
    settings-mcp) rm "$home/.claude.json"; ln -s "$claude/settings.json" "$home/.claude.json" ;;
    claudemd-settings) rm "$claude/CLAUDE.md"; ln -s "$claude/settings.json" "$claude/CLAUDE.md" ;;
    hardlink) rm "$home/.claude.json"; ln "$claude/settings.json" "$home/.claude.json" ;;
  esac
  before=$(tree "$home")
  run "$home" --uninstall; expect_refused "uninstall with aliased destinations ($alias)"
  grep -Fq 'resolve to the same file' <<<"$err" || fail "uninstall alias refusal reason missing ($alias): $err"
  [ "$before" = "$(tree "$home")" ] || fail "an alias let an uninstall change files ($alias)"
done
# Distinct targets behind symlinks keep working.
home=$(fresh_home alias-distinct)
mkdir -p "$home/.claude" "$home/dotfiles"
printf '{}\n' >"$home/dotfiles/a.json"
printf '{}\n' >"$home/dotfiles/b.json"
ln -s "$home/dotfiles/a.json" "$home/.claude/settings.json"
ln -s "$home/dotfiles/b.json" "$home/.claude.json"
run "$home"; expect_ok "install with distinct symlinked config files"
run "$home" --uninstall; expect_ok "uninstall with distinct symlinked config files"
echo "install probe passed: config-aliases"

# --- a pending-only retired file that is also a config target is refused (interrupted-update state) ----
for leaf in CLAUDE.md settings.json claude.json; do
  home=$(fresh_home "pending-alias-$leaf")
  claude="$home/.claude"
  run "$home"; expect_ok "install before the pending-alias fixture ($leaf)"
  case "$leaf" in claude.json) config="$home/.claude.json" ;; *) config="$claude/$leaf" ;; esac
  retired="$claude/b-agentic/retired.json"
  cp "$config" "$retired"
  rm "$config"
  ln -s "$retired" "$config"
  digest=$(sha256sum "$retired" | cut -d' ' -f1)
  jq --arg d "$digest" '.pending = {files: {"b-agentic/retired.json": [$d]}, kernel: [], mcp_servers: {}}' "$claude/b-agentic/install.json" >"$work/pending-manifest.json" && mv "$work/pending-manifest.json" "$claude/b-agentic/install.json"
  before=$(tree "$home")
  run "$home"; expect_refused "install with a pending-only retired file aliasing $leaf"
  grep -Fq 'resolve to the same file' <<<"$err" || fail "pending alias refusal reason missing ($leaf): $err"
  [ "$before" = "$(tree "$home")" ] || fail "a pending-only alias let an install change files ($leaf)"
  [ -e "$retired" ] || fail "the config target was removed as a retired file ($leaf)"
  run "$home" --uninstall; expect_refused "uninstall with a pending-only retired file aliasing $leaf"
  [ "$before" = "$(tree "$home")" ] || fail "a pending-only alias let an uninstall change files ($leaf)"
done
echo "install probe passed: pending-aliases"

# --- bootstrap: dry-run mutates nothing, clones stay out of ~/.pi --------------------------------
home=$(fresh_home bootstrap)
run "$home" --dry-run --ref='bad ref'; expect_refused "invalid ref"
run "$home" --dry-run; expect_ok "checkout dry-run"
[ ! -e "$home/.claude" ] || fail "a checkout dry-run wrote files"
srcrepo="$work/srcrepo"
mkdir -p "$srcrepo"
( cd "$root" && git ls-files -co --exclude-standard -z | tar --null -T - -cf - ) | tar -xf - -C "$srcrepo"
git -C "$srcrepo" init -q .
git -C "$srcrepo" add -A
git -C "$srcrepo" -c user.email=probe@example.invalid -c user.name=probe commit -qm source
clone="$work/clone"
piped() {
  local home=$1
  shift
  rc=0
  out=$(cat "$root/install.sh" | env -u CLAUDE_CONFIG_DIR HOME="$home" B_AGENTIC_REPO="$srcrepo" B_AGENTIC_DIR="$clone" bash -s -- "$@" 2>"$work/stderr") || rc=$?
  err=$(cat "$work/stderr")
}
piped "$home" --dry-run; expect_refused "piped dry-run without a checkout"
[ ! -e "$clone" ] && [ ! -e "$home/.claude" ] || fail "a piped dry-run cloned or wrote files"
piped "$home" --uninstall; expect_refused "piped uninstall without a checkout"
[ ! -e "$clone" ] || fail "a piped uninstall cloned the source"
piped "$home"; expect_ok "piped install"
[ -d "$clone/.git" ] && [ -f "$home/.claude/skills/b-plan/SKILL.md" ] || fail "piped install did not clone and install"
head_before=$(git -C "$clone" rev-parse HEAD)
printf 'next\n' >"$srcrepo/NEXT.md"
git -C "$srcrepo" add NEXT.md
git -C "$srcrepo" -c user.email=probe@example.invalid -c user.name=probe commit -qm next
piped "$home" --update --dry-run; expect_ok "piped update dry-run"
[ "$(git -C "$clone" rev-parse HEAD)" = "$head_before" ] || fail "an update dry-run advanced the checkout"
piped "$home" --update; expect_ok "piped update"
[ -f "$clone/NEXT.md" ] || fail "an update did not fast-forward the checkout"
home=$(fresh_home bootstrap-pi)
pi_before=$(tree "$home/.pi")
rc=0
out=$(cat "$root/install.sh" | env -u CLAUDE_CONFIG_DIR HOME="$home" B_AGENTIC_REPO="$srcrepo" B_AGENTIC_DIR="$home/.pi/agent/src" bash -s 2>"$work/stderr") || rc=$?
[ "$rc" = 1 ] || fail "a clone destination under ~/.pi must be refused (exit $rc)"
[ ! -e "$home/.pi/agent/src" ] && [ "$pi_before" = "$(tree "$home/.pi")" ] || fail "a refused bootstrap touched the Pi tree"
mv "$home/.pi" "$work/realpi2"
ln -s "$work/realpi2" "$home/.pi"
rc=0
out=$(cat "$root/install.sh" | env -u CLAUDE_CONFIG_DIR HOME="$home" B_AGENTIC_REPO="$srcrepo" B_AGENTIC_DIR="$home/.pi/agent/src" bash -s 2>"$work/stderr") || rc=$?
[ "$rc" = 1 ] && [ ! -e "$work/realpi2/agent/src" ] || fail "a clone destination under a symlinked ~/.pi must be refused (exit $rc)"
echo "install probe passed: bootstrap"

# --- git destination overrides and a protected .git cannot redirect an update ------------------------
home=$(fresh_home bootstrap-env)
pi_before=$(tree "$home/.pi")
rc=0
out=$(cat "$root/install.sh" | env -u CLAUDE_CONFIG_DIR HOME="$home" B_AGENTIC_REPO="$srcrepo" B_AGENTIC_DIR="$clone" GIT_DIR="$home/.pi/agent/gd" GIT_WORK_TREE="$home/.pi/agent/wt" bash -s -- --update 2>"$work/stderr") || rc=$?
[ "$rc" = 0 ] || fail "an update with GIT_DIR and GIT_WORK_TREE in the environment failed (exit $rc): $(cat "$work/stderr")"
[ ! -e "$home/.pi/agent/gd" ] && [ ! -e "$home/.pi/agent/wt" ] && [ "$pi_before" = "$(tree "$home/.pi")" ] || fail "inherited git overrides redirected an update into the Pi tree"
clone3="$work/clone3"
cp -r "$clone" "$clone3"
mv "$clone3/.git" "$home/.pi/agent/realgit"
ln -s "$home/.pi/agent/realgit" "$clone3/.git"
pi_before=$(tree "$home/.pi")
rc=0
out=$(cat "$root/install.sh" | env -u CLAUDE_CONFIG_DIR HOME="$home" B_AGENTIC_REPO="$srcrepo" B_AGENTIC_DIR="$clone3" bash -s -- --update 2>"$work/stderr") || rc=$?
[ "$rc" = 1 ] || fail "an update whose .git lives under ~/.pi must be refused (exit $rc)"
[ "$pi_before" = "$(tree "$home/.pi")" ] || fail "a refused update touched the Pi tree"
echo "install probe passed: bootstrap-git"
