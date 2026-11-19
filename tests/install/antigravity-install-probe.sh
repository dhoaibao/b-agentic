#!/usr/bin/env bash
# Exercise tooling/install/antigravity_install.py (through install.sh) in sandbox HOME
# directories. Needs only python3, bun, git, and jq: no network, credentials, agy, Claude
# Code, or Codex. Every scenario owns a private HOME with made-up fixture files, so nothing
# outside the throwaway work directory is read or written and no real agy config is touched.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT

fail() { echo "agy install probe failed: $*" >&2; exit 1; }

# The managed hooks run with Bun, so the installer needs a real bun on PATH.
command -v bun >/dev/null 2>&1 || fail "this probe needs bun on PATH (the installer refuses without it)"

# tree <dir>: sorted `sha256  relative-path` list, symlinks included, backups excluded.
tree() {
  # shellcheck disable=SC2016 # The inner script runs in sh and expands its own variables.
  ( cd "$1" && find . \( -type f -o -type l \) -not -path './.gemini/config/b-agentic/backups/*' -print0 \
      | sort -z | xargs -0 -r sh -c 'for f; do if [ -L "$f" ]; then printf "link %s -> %s\n" "$f" "$(readlink "$f")"; else printf "%s  %s\n" "$(sha256sum "$f" | cut -d" " -f1)" "$f"; fi; done' _ )
}
# run <home> [args...]: stdout to $out, stderr to $err, exit code to $rc.
out="" err="" rc=0
run() {
  local home=$1
  shift
  rc=0
  out=$(env -u CLAUDE_CONFIG_DIR -u B_AGENTIC_CLAUDE_DIR -u ANTIGRAVITY_CONVERSATION_ID HOME="$home" bash "$root/install.sh" "$@" 2>"$work/stderr") || rc=$?
  err=$(cat "$work/stderr")
}
expect_ok() { [ "$rc" = 0 ] || fail "$1 (exit $rc: $err $out)"; }
expect_refused() { [ "$rc" = 1 ] || fail "$1 (exit $rc, expected 1: $err $out)"; }
same_json() { [ "$(jq -S . "$1")" = "$(jq -S . "$2")" ]; }

# user_home <name>: a sandbox HOME that already holds other tools' agy configuration.
user_home() {
  local home="$work/$1" gemini="$work/$1/.gemini"
  mkdir -p "$gemini/config/skills/mine" "$gemini/config/rules" "$gemini/antigravity-cli"
  printf 'my own skill\n' >"$gemini/config/skills/mine/SKILL.md"
  printf 'my own rule\n' >"$gemini/config/rules/mine.md"
  cat >"$gemini/config/hooks.json" <<'JSON'
{
  "herdr": {"Stop": [{"type": "command", "command": "herdr-report", "timeout": 5}]},
  "orca": {"PreToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": "orca-guard", "timeout": 5}]}]}
}
JSON
  cat >"$gemini/config/mcp_config.json" <<'JSON'
{"mcpServers": {"mine": {"command": "my-server", "args": ["--x"]}}, "theme": "dark"}
JSON
  cat >"$gemini/antigravity-cli/settings.json" <<'JSON'
{"model": "m-1", "agentMode": "agent", "trustedWorkspaces": ["/w/one"], "permissions": {"allow": ["command(ls)"], "ask": ["command(my-tool)"]}}
JSON
  mkdir -p "$work/$1.before"
  cp -R "$gemini/." "$work/$1.before/"
  printf '%s' "$home"
}

# The routing line the kernel rule carries for an optional skill.
# shellcheck disable=SC2016 # The backticks are literal Markdown.
routing='`b-excalidraw`'
# Optional components are never part of a default install.
skills_expected=$(jq -r '(.skills | length) - ([.optional_components[].skills[]] | length)' "$root/skills/registry.yaml")
servers_expected=$(jq -r '(.mcpServers | length)' "$root/antigravity/configs/mcp.template.json")
optional_servers=$(jq -r '[.optional_components[].mcp_servers[]] | map(select(. != "datagrip"))' "$root/skills/registry.yaml")
servers_expected=$((servers_expected - $(jq -r 'length' <<<"$optional_servers")))

# --- fresh install over other tools' configuration (AC-1, AC-2) --------------------
home=$(user_home user)
gemini="$home/.gemini" config="$home/.gemini/config"
run "$home" -y --runtime=antigravity; expect_ok "fresh agy install"
[ ! -e "$home/.claude" ] && [ ! -e "$home/.claude.json" ] || fail "an agy install must not touch ~/.claude"
[ "$(find "$config/skills" -name SKILL.md | wc -l | tr -d ' ')" = "$((skills_expected + 1))" ] || fail "skill count (the user's own skill stays)"
[ ! -L "$config/skills/b-plan" ] && [ -d "$config/skills/b-plan" ] || fail "skills must be real directories"
cmp -s "$root/antigravity/skills/b-plan/SKILL.md" "$config/skills/b-plan/SKILL.md" || fail "skill content differs from source"
[ "$(find "$config/agents" -name 'b-*.md' | wc -l | tr -d ' ')" = 6 ] || fail "agent count"
cmp -s "$root/antigravity/agents/b-worker.md" "$config/agents/b-worker.md" || fail "the installed b-worker differs from the source"
rule="$config/rules/b-agentic.md"
grep -Fq 'trigger: always_on' "$rule" || fail "the kernel rule needs trigger: always_on"
[ "$(wc -c <"$rule")" -le 16000 ] || fail "the kernel rule exceeds its size budget"
if grep -Fq "$routing" "$rule"; then fail "an optional skill must not be routed by default"; fi
for file in bin/b-state.mjs bin/b_run.py bin/b-candidate-snapshot.mjs bin/b-protected.mjs bin/b-codex-review.mjs references/artifacts.yaml references/capabilities.yaml references/mcp_operations.yaml hooks/b-agy-hook.mjs hooks/b-path-guard.mjs hooks/b-codex-guard.mjs hooks/b-alexandria-guard.mjs hooks/b-verify-gate.mjs hooks/b-run-context.mjs hooks/b-spec-context.mjs; do
  [ -f "$config/b-agentic/$file" ] || fail "missing b-agentic/$file"
done
for module in "$root"/claude/bin/b-state-*.mjs; do
  [ -f "$config/b-agentic/bin/$(basename "$module")" ] || fail "missing b-agentic/bin/$(basename "$module")"
done
[ ! -e "$config/b-agentic/bin/b-statusline.mjs" ] || fail "the status line is not ported to agy"
[ -f "$config/b-agentic/install.json" ] || fail "manifest missing"
# Hook group: absolute commands, no $HOME, other tools' groups intact.
hooks="$config/hooks.json"
[ "$(jq -r 'has("b-agentic") and has("herdr") and has("orca")' "$hooks")" = true ] || fail "hook groups: $(jq -c 'keys' "$hooks")"
[ "$(jq -c '.herdr' "$hooks")" = "$(jq -c '.herdr' "$work/user.before/config/hooks.json")" ] || fail "the herdr group changed"
[ "$(jq -r '[.. | .command? // empty] | map(select(contains("$HOME"))) | length' <<<"$(jq '."b-agentic"' "$hooks")")" = 0 ] || fail "no managed hook command may use \$HOME"
[ "$(jq -r '."b-agentic" | keys | sort | join(",")' "$hooks")" = "PostToolUse,PreToolUse,SessionStart,Stop" ] || fail "managed hook events"
hook_command=$(jq -r '."b-agentic".PreToolUse[0].hooks[0].command' "$hooks")
case "$hook_command" in /*"$config/b-agentic/hooks/b-agy-hook.mjs") ;; *) fail "hook command: $hook_command" ;; esac
# The installed command must run: a secret read is denied and a plain read prints nothing.
event='{"conversationId":"probe","cwd":"/tmp","hookEventName":"PreToolUse","toolCall":{"id":"1","name":"read_file","args":{"Path":"/proj/.env"}}}'
decision=$(printf '%s' "$event" | env HOME="$home" bash -c "$hook_command" | jq -r '.decision')
[ "$decision" = deny ] || fail "the installed hook must deny a secret read (got '$decision')"
event='{"conversationId":"probe","cwd":"/tmp","hookEventName":"PreToolUse","toolCall":{"id":"1","name":"read_file","args":{"Path":"/proj/src/app.mjs"}}}'
[ -z "$(printf '%s' "$event" | env HOME="$home" bash -c "$hook_command")" ] || fail "a plain read must print nothing"
# MCP servers and permissions.
mcp="$config/mcp_config.json"
[ "$(jq -r '.mcpServers | length' "$mcp")" = "$((servers_expected + 1))" ] || fail "mcp servers: $(jq -c '.mcpServers | keys' "$mcp")"
[ "$(jq -c '.mcpServers.mine' "$mcp")" = '{"command":"my-server","args":["--x"]}' ] || fail "the user's MCP server changed"
[ "$(jq -r '.theme' "$mcp")" = dark ] || fail "an unknown top-level key must survive"
for server in excalidraw drawio datagrip notion; do
  [ "$(jq -r --arg s "$server" '.mcpServers | has($s)' "$mcp")" = false ] || fail "optional MCP server $server must not be installed by default"
done
settings="$gemini/antigravity-cli/settings.json"
[ "$(jq -r '.model + .agentMode + .trustedWorkspaces[0]' "$settings")" = "m-1agent/w/one" ] || fail "unrelated settings keys changed"
[ "$(jq -r '.permissions.allow | index("command(ls)") == 0' "$settings")" = true ] || fail "the user's allow rule must stay first"
[ "$(jq -r '.permissions.ask | index("command(my-tool)") == 0' "$settings")" = true ] || fail "the user's ask rule must stay first"
[ "$(jq -r '.permissions.allow | index("mcp(codegraph/codegraph_explore)") != null' "$settings")" = true ] || fail "allow rule missing"
[ "$(jq -r '.permissions.ask | index("command(git push)") != null' "$settings")" = true ] || fail "git push ask rule missing"
[ "$(jq -r '.permissions.deny | index("command(git pull)") != null' "$settings")" = true ] || fail "git pull deny rule missing"
if jq -e '[.permissions.allow[]] | map(select(test("^mcp\\((datagrip|excalidraw|drawio|notion)/"))) | length > 0' "$settings" >/dev/null; then fail "optional component allow rules must not be installed by default"; fi
[ -f "$gemini/config/skills/mine/SKILL.md" ] && [ -f "$config/rules/mine.md" ] || fail "the user's own skill and rule must stay"

# --- a second run changes nothing; --dry-run writes nothing ------------------------
before=$(tree "$home")
run "$home" -y --runtime=antigravity; expect_ok "second install"
[ "$(tree "$home")" = "$before" ] || fail "a second install changed files"
run "$home" --dry-run --runtime=antigravity; expect_ok "dry run"
[ "$(tree "$home")" = "$before" ] || fail "--dry-run changed files"
run "$home" --dry-run --uninstall --runtime=antigravity; expect_ok "dry-run uninstall"
[ "$(tree "$home")" = "$before" ] || fail "--dry-run --uninstall changed files"

# --- uninstall removes only what was recorded (AC-3) ---------------------------------
run "$home" --uninstall --runtime=antigravity; expect_ok "uninstall"
[ ! -e "$config/b-agentic/install.json" ] && [ ! -e "$rule" ] && [ ! -e "$config/skills/b-plan" ] && [ ! -e "$config/agents/b-planner.md" ] || fail "managed files must be removed"
same_json "$hooks" "$work/user.before/config/hooks.json" || fail "hooks.json differs from before the install"
same_json "$mcp" "$work/user.before/config/mcp_config.json" || fail "mcp_config.json differs from before the install"
same_json "$settings" "$work/user.before/antigravity-cli/settings.json" || fail "settings.json differs from before the install"
[ -f "$config/skills/mine/SKILL.md" ] && [ -f "$config/rules/mine.md" ] || fail "the user's own files must stay"
[ -d "$config/b-agentic/backups" ] || fail "backups must be kept"
run "$home" --uninstall --runtime=antigravity; expect_ok "second uninstall"

# --- a file the user modified is kept; --force replaces it after a backup ------------
home=$(user_home edited)
config="$home/.gemini/config"
run "$home" -y --runtime=antigravity; expect_ok "install before editing"
printf 'my edit\n' >>"$config/rules/b-agentic.md"
run "$home" -y --runtime=antigravity; expect_ok "reinstall over an edited rule"
grep -Fq 'my edit' "$config/rules/b-agentic.md" || fail "a modified rule must be kept"
grep -Fq 'modified since install' <<<"$err" || fail "a kept file must be reported: $err"
run "$home" --uninstall --runtime=antigravity; expect_ok "uninstall with an edited rule"
grep -Fq 'modified since install' <<<"$err" || fail "uninstall must report the kept rule: $err"
grep -Fq 'my edit' "$config/rules/b-agentic.md" || fail "uninstall must keep a modified rule"
run "$home" -y --force --runtime=antigravity; expect_ok "forced reinstall"
if grep -Fq 'my edit' "$config/rules/b-agentic.md"; then fail "--force must replace a modified rule"; fi
grep -rFq 'my edit' "$config/b-agentic/backups" || fail "--force must back up the replaced file"

# --- an edited hook group stays, so its scripts stay and keep working (a failing hook blocks every tool) ---
home=$(user_home grouped)
config="$home/.gemini/config"
run "$home" -y --runtime=antigravity; expect_ok "install before editing the hook group"
jq '."b-agentic".PreToolUse[0].hooks[0].timeout = 99' "$config/hooks.json" >"$work/hooks.tmp" && mv "$work/hooks.tmp" "$config/hooks.json"
run "$home" --uninstall --runtime=antigravity; expect_ok "uninstall with an edited hook group"
grep -Fq "kept b-agentic/" <<<"$err" || fail "the kept runtime files must be reported: $err"
[ ! -e "$config/rules/b-agentic.md" ] && [ ! -e "$config/skills/b-plan" ] || fail "skills, agents, and the rule must still be removed"
for file in hooks/b-agy-hook.mjs hooks/b-path-guard.mjs bin/b-protected.mjs bin/b-candidate-snapshot.mjs install.json; do
  [ -f "$config/b-agentic/$file" ] || fail "b-agentic/$file must stay while the hook group runs it"
done
hook_command=$(jq -r '."b-agentic".PreToolUse[0].hooks[0].command' "$config/hooks.json")
event='{"conversationId":"probe","cwd":"/tmp","hookEventName":"PreToolUse","toolCall":{"id":"1","name":"read_file","args":{"Path":"/proj/.env"}}}'
[ "$(printf '%s' "$event" | env HOME="$home" bash -c "$hook_command" | jq -r '.decision')" = deny ] || fail "the kept hook group must still run"
before=$(tree "$home")
run "$home" --dry-run --uninstall --runtime=antigravity; expect_ok "dry-run uninstall with the kept group"
[ "$(tree "$home")" = "$before" ] || fail "--dry-run --uninstall must not write while the group is kept"
jq 'del(."b-agentic")' "$config/hooks.json" >"$work/hooks.tmp" && mv "$work/hooks.tmp" "$config/hooks.json"
run "$home" --uninstall --runtime=antigravity; expect_ok "second uninstall after removing the group"
[ ! -e "$config/b-agentic/install.json" ] && [ ! -e "$config/b-agentic/hooks" ] && [ ! -e "$config/b-agentic/bin" ] || fail "the second uninstall must remove the runtime files"
same_json "$config/hooks.json" "$work/grouped.before/config/hooks.json" || fail "hooks.json must end as before the install"

# --- collisions: a same-named server and an unrecorded hook group stay user-owned -----
home=$(user_home collide)
config="$home/.gemini/config"
jq '.mcpServers.codegraph = {"command": "my-codegraph"} | ."b-agentic-note" = 1' "$config/mcp_config.json" >"$work/mcp.tmp" && mv "$work/mcp.tmp" "$config/mcp_config.json"
jq '."b-agentic" = {"Stop": [{"type": "command", "command": "my-stop", "timeout": 5}]}' "$config/hooks.json" >"$work/hooks.tmp" && mv "$work/hooks.tmp" "$config/hooks.json"
cp "$config/mcp_config.json" "$work/collide.mcp.before"
cp "$config/hooks.json" "$work/collide.hooks.before"
run "$home" -y --runtime=antigravity; expect_ok "install over collisions"
[ "$(jq -c '.mcpServers.codegraph' "$config/mcp_config.json")" = '{"command":"my-codegraph"}' ] || fail "a same-named user server must be kept"
grep -Fq "kept your existing MCP server 'codegraph'" <<<"$err" || fail "the kept server must be reported: $err"
[ "$(jq -c '."b-agentic"' "$config/hooks.json")" = '{"Stop":[{"type":"command","command":"my-stop","timeout":5}]}' ] || fail "an unrecorded hook group must be kept"
grep -Fq "kept your existing 'b-agentic' hook group" <<<"$err" || fail "the kept hook group must be reported: $err"
run "$home" -y --force --runtime=antigravity; expect_ok "forced install over collisions"
[ "$(jq -c '.mcpServers.codegraph' "$config/mcp_config.json")" = '{"command":"my-codegraph"}' ] || fail "--force must not replace a user server"
[ "$(jq -c '."b-agentic".Stop[0].command' "$config/hooks.json")" = '"my-stop"' ] || fail "--force must not replace a user hook group"
run "$home" --uninstall --runtime=antigravity; expect_ok "uninstall over collisions"
same_json "$config/mcp_config.json" "$work/collide.mcp.before" || fail "the user's mcp_config.json must be restored"
same_json "$config/hooks.json" "$work/collide.hooks.before" || fail "the user's hooks.json must be restored"

# --- uninstall parses every user file before its first write ---------------------------
home=$(user_home corrupt)
config="$home/.gemini/config"
jq '."b-agentic" = {"Stop": [{"type": "command", "command": "my-stop", "timeout": 5}]}' "$config/hooks.json" >"$work/hooks.tmp" && mv "$work/hooks.tmp" "$config/hooks.json"
run "$home" -y --runtime=antigravity; expect_ok "install over a user hook group"
printf '{bad json' >"$config/hooks.json"
before=$(tree "$home")
run "$home" --uninstall --runtime=antigravity; expect_refused "uninstall with a malformed hooks.json"
[ "$(tree "$home")" = "$before" ] || fail "a refused uninstall must not write"
run "$home" --dry-run --uninstall --runtime=antigravity; expect_refused "dry-run uninstall with a malformed hooks.json"

# --- refusals happen before any write (AC-4) ---------------------------------------
refuse() { # refuse <label> <home> <pattern> [args...]
  local label=$1 home=$2 pattern=$3
  shift 3
  local before
  before=$(tree "$home")
  run "$home" "$@"; expect_refused "$label"
  grep -Fq -- "$pattern" <<<"$err" || fail "$label: expected '$pattern' in: $err"
  [ "$(tree "$home")" = "$before" ] || fail "$label wrote files"
}
home="$work/linked"; mkdir -p "$home" "$work/elsewhere"
ln -s "$work/elsewhere" "$home/.gemini"
refuse "symlinked ~/.gemini" "$home" "is a symlink" -y --runtime=antigravity
home="$work/linked-config"; mkdir -p "$home/.gemini" "$work/elsewhere2"
ln -s "$work/elsewhere2" "$home/.gemini/config"
refuse "symlinked config dir" "$home" "is a symlink" -y --runtime=antigravity
home="$work/linked-skills"; mkdir -p "$home/.gemini/config" "$work/elsewhere3"
ln -s "$work/elsewhere3" "$home/.gemini/config/skills"
refuse "symlinked managed dir" "$home" "is a symlink" -y --runtime=antigravity
home="$work/linked-file"; mkdir -p "$home/.gemini/config"
printf '{}\n' >"$work/outside.json"
ln -s "$work/outside.json" "$home/.gemini/config/mcp_config.json"
refuse "a config file linked outside ~/.gemini" "$home" "outside" -y --runtime=antigravity
home="$work/malformed"; mkdir -p "$home/.gemini/config"
printf '{bad json' >"$home/.gemini/config/hooks.json"
refuse "malformed hooks.json" "$home" "not valid JSON" -y --runtime=antigravity
home="$work/badshape"; mkdir -p "$home/.gemini/antigravity-cli"
printf '{"permissions":{"allow":"nope"}}\n' >"$home/.gemini/antigravity-cli/settings.json"
refuse "settings permissions of the wrong shape" "$home" "permissions.allow must be an array" -y --runtime=antigravity
home="$work/flags"; mkdir -p "$home"
refuse "an unknown runtime" "$home" "ADR-025" -y --runtime=gemini
refuse "--statusline-only with antigravity" "$home" "ADR-025" -y --runtime=antigravity --statusline-only
refuse "--statusline-only with both" "$home" "ADR-025" -y --runtime=both --statusline-only
refuse "--with together with --uninstall" "$home" "cannot be combined" --uninstall --runtime=antigravity --with=excalidraw
[ ! -e "$home/.gemini" ] && [ ! -e "$home/.claude" ] || fail "refused runs must create nothing"
# A write through a refused link would land outside the home tree, which `tree` does not follow.
for target in elsewhere elsewhere2 elsewhere3; do
  [ -z "$(ls -A "$work/$target")" ] || fail "a refused run wrote through a link into $target"
done
[ "$(cat "$work/outside.json")" = '{}' ] || fail "a refused run changed the file behind a config link"
# A symlinked config file that stays under ~/.gemini is written through, not replaced.
home="$work/linked-inside"; mkdir -p "$home/.gemini/config" "$home/.gemini/dotfiles"
printf '{"mcpServers":{}}\n' >"$home/.gemini/dotfiles/mcp.json"
ln -s ../dotfiles/mcp.json "$home/.gemini/config/mcp_config.json"
run "$home" -y --runtime=antigravity; expect_ok "a config symlink inside ~/.gemini"
[ -L "$home/.gemini/config/mcp_config.json" ] && [ "$(jq -r '.mcpServers | has("codegraph")' "$home/.gemini/dotfiles/mcp.json")" = true ] || fail "the symlinked config must be written through"

# --- optional components (AC-4) ----------------------------------------------------
home=$(user_home optional)
config="$home/.gemini/config"
run "$home" -y --runtime=antigravity --with=excalidraw; expect_ok "install with excalidraw"
[ -f "$config/skills/b-excalidraw/SKILL.md" ] || fail "--with=excalidraw must install b-excalidraw"
grep -Fq "$routing" "$config/rules/b-agentic.md" || fail "--with=excalidraw must route b-excalidraw in the rule"
[ "$(jq -r '.mcpServers | has("excalidraw")' "$config/mcp_config.json")" = true ] || fail "--with=excalidraw must add the server"
[ "$(jq -r '.permissions.allow | map(select(startswith("mcp(excalidraw/"))) | length > 0' "$home/.gemini/antigravity-cli/settings.json")" = true ] || fail "--with=excalidraw must add its allow rules"
run "$home" -y --runtime=antigravity; expect_ok "reinstall keeps the recorded choice"
[ -f "$config/skills/b-excalidraw/SKILL.md" ] || fail "the recorded optional choice must persist"
run "$home" -y --runtime=antigravity --without=excalidraw; expect_ok "install without excalidraw"
[ ! -e "$config/skills/b-excalidraw" ] || fail "--without=excalidraw must remove the skill"
if grep -Fq "$routing" "$config/rules/b-agentic.md"; then fail "--without=excalidraw must drop the routing line"; fi
[ "$(jq -r '.mcpServers | has("excalidraw")' "$config/mcp_config.json")" = false ] || fail "--without=excalidraw must remove the server"
[ "$(jq -r '.permissions.allow | map(select(startswith("mcp(excalidraw/"))) | length' "$home/.gemini/antigravity-cli/settings.json")" = 0 ] || fail "--without=excalidraw must remove its allow rules"

# --- the runtime switch (AC-5) --------------------------------------------------------
home="$work/default"; mkdir -p "$home"
run "$home" -y; expect_ok "default runtime"
[ -d "$home/.claude/skills" ] && [ ! -e "$home/.gemini" ] || fail "the default runtime must be Claude Code only"
home="$work/claude"; mkdir -p "$home"
run "$home" -y --runtime=claude; expect_ok "explicit claude runtime"
[ -d "$home/.claude/skills" ] && [ ! -e "$home/.gemini" ] || fail "--runtime=claude must not touch ~/.gemini"
home="$work/both"; mkdir -p "$home"
run "$home" -y --runtime=both; expect_ok "both runtimes"
[ -f "$home/.claude/b-agentic/install.json" ] && [ -f "$home/.gemini/config/b-agentic/install.json" ] || fail "--runtime=both must install both runtimes"
run "$home" --uninstall; expect_ok "plain uninstall"
[ ! -e "$home/.claude/b-agentic/install.json" ] && [ -f "$home/.gemini/config/b-agentic/install.json" ] || fail "a plain --uninstall must remove only the Claude Code install"
run "$home" --uninstall --runtime=both; expect_ok "both uninstall"
[ ! -e "$home/.gemini/config/b-agentic/install.json" ] && [ ! -e "$home/.gemini/config/rules/b-agentic.md" ] || fail "--runtime=both --uninstall must remove the agy install"
[ ! -e "$home/.claude/skills/b-plan" ] || fail "--runtime=both --uninstall must remove the Claude Code install"
home="$work/both-claude-fails"; mkdir -p "$home/.claude"
printf '{bad' >"$home/.claude/settings.json"
run "$home" -y --runtime=both; expect_refused "both with a broken Claude Code file"
[ ! -e "$home/.gemini" ] || fail "--runtime=both must stop before the agy side when the Claude side fails"

echo "agy install probe: ok"
