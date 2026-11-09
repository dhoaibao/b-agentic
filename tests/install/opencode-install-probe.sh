#!/usr/bin/env bash
# Exercise tooling/install/opencode_install.py (through install.sh) in sandbox HOME
# directories. Needs only python3, git, and jq: no network, credentials, OpenCode,
# Claude Code, or Codex. Every scenario owns a private HOME, so nothing outside the
# throwaway work directory is read or written.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT

fail() { echo "opencode install probe failed: $*" >&2; exit 1; }

# fresh_home <name>: a sandbox HOME with a frozen Pi tree that must never change.
fresh_home() {
  local home="$work/$1"
  mkdir -p "$home/.pi/agent/skills/b-plan"
  printf 'frozen pi skill\n' >"$home/.pi/agent/skills/b-plan/SKILL.md"
  printf '{"pi":true}\n' >"$home/.pi/agent/settings.json"
  printf '%s' "$home"
}
# tree <dir>: sorted `sha256  relative-path` list, symlinks included, backups excluded.
tree() {
  # shellcheck disable=SC2016 # The inner script runs in sh and expands its own variables.
  ( cd "$1" && find . \( -type f -o -type l \) -not -path '*/b-agentic/backups/*' -print0 \
      | sort -z | xargs -0 -r sh -c 'for f; do if [ -L "$f" ]; then printf "link %s -> %s\n" "$f" "$(readlink "$f")"; else printf "%s  %s\n" "$(sha256sum "$f" | cut -d" " -f1)" "$f"; fi; done' _ )
}
# run <home> [args...]: stdout to $out, stderr to $err, exit code to $rc.
out="" err="" rc=0
run() {
  local home=$1
  shift
  rc=0
  out=$(env -u XDG_CONFIG_HOME -u OPENCODE_CONFIG_DIR -u B_AGENTIC_OPENCODE_DIR -u B_AGENTIC_CLICKUP_MCP \
    -u CLAUDE_CONFIG_DIR -u B_AGENTIC_CLAUDE_DIR HOME="$home" bash "$root/install.sh" --runtime=opencode "$@" 2>"$work/stderr") || rc=$?
  err=$(cat "$work/stderr")
}
# runenv <home> <NAME=value> [args...]: like run, with one extra environment assignment.
runenv() {
  local home=$1 assignment=$2
  shift 2
  rc=0
  out=$(env -u XDG_CONFIG_HOME -u OPENCODE_CONFIG_DIR -u B_AGENTIC_OPENCODE_DIR -u B_AGENTIC_CLICKUP_MCP \
    -u CLAUDE_CONFIG_DIR -u B_AGENTIC_CLAUDE_DIR HOME="$home" "$assignment" bash "$root/install.sh" --runtime=opencode "$@" 2>"$work/stderr") || rc=$?
  err=$(cat "$work/stderr")
}
# run_both <home> [args...]: install.sh --runtime=both.
run_both() {
  local home=$1
  shift
  rc=0
  out=$(env -u XDG_CONFIG_HOME -u OPENCODE_CONFIG_DIR -u B_AGENTIC_OPENCODE_DIR -u B_AGENTIC_CLICKUP_MCP \
    -u CLAUDE_CONFIG_DIR -u B_AGENTIC_CLAUDE_DIR HOME="$home" bash "$root/install.sh" --runtime=both "$@" 2>"$work/stderr") || rc=$?
  err=$(cat "$work/stderr")
}
expect_ok() { [ "$rc" = 0 ] || fail "$1 (exit $rc: $err $out)"; }
expect_refused() { [ "$rc" = 1 ] || fail "$1 (exit $rc, expected 1: $err $out)"; }

# Optional components are never part of a default install: skills, rules, and servers they own are excluded.
skills_expected=$(jq -r '(.skills | length) - ([.optional_components[].skills[]] | length)' "$root/skills/registry.yaml")
optional_servers=$(jq -c '[.optional_components[].mcp_servers[]]' "$root/skills/registry.yaml")
rules_expected=$(jq -r --argjson s "$optional_servers" '[.permissions[] | select((.effect == "allow" and (.action as $a | $s | any(. as $n | $a | startswith($n + "_")))) | not)] | length' "$root/opencode/configs/opencode.template.json")
servers_expected=$(jq -r --argjson s "$optional_servers" '[.mcp.servers | keys[] | select(. as $k | ($s | index($k)) == null)] | length' "$root/opencode/configs/opencode.template.json")

# --- fresh install ---------------------------------------------------------------
home=$(fresh_home fresh)
pi_before=$(tree "$home/.pi")
run "$home"; expect_ok "fresh install"
oc="$home/.config/opencode"
[ "$(find "$oc/skills" -name SKILL.md | wc -l | tr -d ' ')" = "$skills_expected" ] || fail "skill count"
[ "$(find "$oc/agents" -name 'b-*.md' | wc -l | tr -d ' ')" = 5 ] || fail "agent count"
[ -f "$oc/plugins/b-agentic.js" ] || fail "plugin missing"
[ -f "$oc/b-agentic/hooks/b-path-guard.mjs" ] || fail "hooks missing"
[ ! -e "$oc/b-agentic/hooks/b-codex-guard.mjs" ] || fail "the retired Codex guard must not be installed"
[ -f "$oc/b-agentic/install.json" ] || fail "manifest missing"
[ ! -e "$home/.claude" ] || fail "an OpenCode-only install must not create ~/.claude"
[ "$(tree "$home/.pi")" = "$pi_before" ] || fail "the Pi tree changed"
grep -Fq '<!-- b-agentic:start -->' "$oc/AGENTS.md" || fail "kernel block missing"
grep -Fq 'OpenCode Workflow Kernel' "$oc/AGENTS.md" || fail "kernel is not the OpenCode rendering"
[ "$(jq '.permissions | length' "$oc/opencode.json")" = "$rules_expected" ] || fail "permission rule count"
[ "$(jq '.mcp.servers | length' "$oc/opencode.json")" = "$servers_expected" ] || fail "MCP server count"
[ "$(jq -r '.mcp.servers.clickup // "none"' "$oc/opencode.json")" = none ] || fail "ClickUp must not be installed"
[ ! -e "$oc/skills/b-clickup/SKILL.md" ] || fail "ClickUp skill must not be installed"
if grep -Rqs 'mcp__\|AskUserQuestion' "$oc/skills" "$oc/agents" "$oc/AGENTS.md"; then fail "Claude-only wording leaked into the install"; fi
for profile in "$root"/opencode/agents/*.md; do
  cmp -s "$profile" "$oc/agents/$(basename "$profile")" || fail "installed specialist differs from generated profile"
done
for name in capabilities.yaml mcp_operations.yaml; do
  cmp -s "$root/opencode/references/$name" "$oc/b-agentic/references/$name" || fail "reference must use the OpenCode rendering: $name"
done
policy="$oc/b-agentic/references/mcp_operations.yaml"
[ "$(jq -r '.classes["trusted-mutation"].native_permission' "$policy")" = ask ] || fail "installed policy must ask for trusted mutations"
[ "$(jq -r '.classes["conditional-read"].native_permission' "$policy")" = allow ] || fail "conditional reads must stay allowed"
[ "$(jq -r '.runtime_enforcement | keys | join(",")' "$policy")" = opencode ] || fail "installed policy must describe OpenCode enforcement only"
if grep -Eq "pre-approved|without a prompt|\`b-clickup-guard\` hook" "$oc/AGENTS.md" "$oc/b-agentic/references/capabilities.yaml"; then
  fail "installed guidance must not promise unprompted task changes or Claude-only safeguards"
fi
if grep -Eq "\`/b-([a-z][a-z0-9-]*|<name>)\`" "$oc/AGENTS.md" "$oc/skills/b-commit/SKILL.md"; then fail "OpenCode must not recommend skill slash commands"; fi
jq -e '[.capabilities[].id] | index("plugin.codex-review") == null' "$oc/b-agentic/references/capabilities.yaml" >/dev/null || fail "the retired Codex plugin capability must not be installed"
[ -f "$oc/agents/b-reviewer.md" ] || fail "the b-reviewer specialist must be installed"
jq -e '.capabilities[] | select(.id == "agent.b-agentic-subagents") | .agent.names | index("b-reviewer") != null' "$oc/b-agentic/references/capabilities.yaml" >/dev/null || fail "the subagent capability must name b-reviewer"

# --- the doctors read the OpenCode install without connecting to anything -------------------------------
doctor=$(python3 "$root/tooling/validate/skill_doctor.py" --runtime opencode --home "$home") || fail "skill doctor must pass on a fresh install: $doctor"
grep -Fq 'agent: OpenCode' <<<"$doctor" || fail "skill doctor must name OpenCode: $doctor"
grep -Fq 'discovery: ready' <<<"$doctor" || fail "skill doctor must report discovery ready: $doctor"
mcp=$(env -u B_AGENTIC_OPENCODE_DIR python3 "$root/tooling/validate/mcp_doctor.py" --runtime opencode --home "$home" --allow-degraded) || fail "mcp doctor failed: $mcp"
grep -Fq 'runtime: OpenCode' <<<"$mcp" || fail "mcp doctor must name OpenCode: $mcp"
grep -Fq 'context7: ' <<<"$mcp" || fail "mcp doctor must report context7: $mcp"
printf 'drift\n' >>"$oc/skills/b-plan/SKILL.md"
if python3 "$root/tooling/validate/skill_doctor.py" --runtime opencode --home "$home" >"$work/doctor.txt"; then fail "skill doctor must flag a drifted skill"; fi
grep -Fq 'stale: skill b-plan' "$work/doctor.txt" || fail "skill doctor must name the stale skill: $(cat "$work/doctor.txt")"
run "$home" --force; expect_ok "restore the drifted skill"
snapshot=$(tree "$home")

# --- idempotent and dry-run --------------------------------------------------------
run "$home"; expect_ok "second install"
[ "$(tree "$home")" = "$snapshot" ] || fail "a repeat install changed files"
run "$home" --dry-run; expect_ok "dry run"
[ "$(tree "$home")" = "$snapshot" ] || fail "a dry run changed files"

# --- modified managed file is kept, --force replaces it --------------------------------
printf 'local edit\n' >>"$oc/agents/b-planner.md"
run "$home"; expect_ok "install over a modified agent"
grep -Fq 'local edit' "$oc/agents/b-planner.md" || fail "a modified managed file was overwritten"
grep -Fq 'kept' <<<"$err" || fail "the kept file was not reported"
run "$home" --force; expect_ok "forced install"
if grep -Fq 'local edit' "$oc/agents/b-planner.md"; then fail "--force did not restore the managed file"; fi

# --- uninstall removes only what was recorded -----------------------------------------------
run "$home" --uninstall; expect_ok "uninstall"
[ ! -e "$oc/skills" ] && [ ! -e "$oc/agents" ] && [ ! -e "$oc/plugins" ] || fail "managed directories left behind"
[ ! -e "$oc/AGENTS.md" ] || fail "an AGENTS.md created by the installer must be removed"
[ "$(jq -c . "$oc/opencode.json")" = '{}' ] || fail "opencode.json must be restored to empty: $(cat "$oc/opencode.json")"
[ "$(tree "$home/.pi")" = "$pi_before" ] || fail "the Pi tree changed on uninstall"

# --- user config is preserved and the managed rules stay last -----------------------------------
home=$(fresh_home merge)
oc="$home/.config/opencode"
mkdir -p "$oc/skills/my-skill" "$oc/plugins"
printf 'mine\n' >"$oc/skills/my-skill/SKILL.md"
printf '// user plugin\n' >"$oc/plugins/theirs.js"
printf '# My rules\n\nBe kind.\n' >"$oc/AGENTS.md"
cat >"$oc/opencode.json" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "plugins": ["@scope/their-plugin"],
  "providers": {"openai": {}},
  "permissions": [{"action": "read", "resource": "*", "effect": "allow"}],
  "mcp": {"servers": {"theirs": {"type": "remote", "url": "https://example.invalid/mcp"}}}
}
JSON
original_config=$(jq -S . "$oc/opencode.json")
original_user_files=$(tree "$home" | rg 'my-skill|theirs.js' || true)
run "$home"; expect_ok "install over user config"
[ "$(jq -c '.plugins' "$oc/opencode.json")" = '["@scope/their-plugin"]' ] || fail "user plugins changed"
[ "$(jq -c '.providers' "$oc/opencode.json")" = '{"openai":{}}' ] || fail "user providers changed"
[ "$(jq -c '.permissions[0]' "$oc/opencode.json")" = '{"action":"read","resource":"*","effect":"allow"}' ] || fail "the user rule must stay first"
default_rules=$(jq -c --argjson s "$optional_servers" '[.permissions[] | select((.effect == "allow" and (.action as $a | $s | any(. as $n | $a | startswith($n + "_")))) | not)]' "$root/opencode/configs/opencode.template.json")
[ "$(jq -c '.permissions[1:]' "$oc/opencode.json")" = "$default_rules" ] || fail "the managed rules must be the final block"
[ "$(jq -r '.mcp.servers.theirs.url' "$oc/opencode.json")" = 'https://example.invalid/mcp' ] || fail "user MCP server changed"
head -n 3 "$oc/AGENTS.md" | grep -Fq 'My rules' || fail "user AGENTS.md content must stay first"
printf '{"action":"shell","resource":"echo late","effect":"ask"}' >"$work/late.json"
jq --slurpfile late "$work/late.json" '.permissions += $late' "$oc/opencode.json" >"$work/late-config.json"
cp "$work/late-config.json" "$oc/opencode.json"
run "$home"; expect_ok "reinstall after a user rule was appended"
[ "$(jq -c '.permissions[-1]' "$oc/opencode.json")" = "$(jq -c '.[-1]' <<<"$default_rules")" ] || fail "the managed block must move back to the end"
[ "$(jq '[.permissions[] | select(.resource == "echo late")] | length' "$oc/opencode.json")" = 1 ] || fail "the late user rule must be kept once"
jq '.mcp.servers.clickup = {"type":"local","command":["legacy"]}' "$oc/opencode.json" >"$work/legacy.json" && mv "$work/legacy.json" "$oc/opencode.json"
jq '.mcp.servers.clickup = {"type":"local","command":["legacy"]}' "$oc/b-agentic/install.json" >"$work/manifest.json" && mv "$work/manifest.json" "$oc/b-agentic/install.json"
run "$home"; expect_ok "retire managed ClickUp"
[ "$(jq -r '.mcp.servers | has("clickup")' "$oc/opencode.json")" = false ] || fail "owned ClickUp server not retired"
run "$home" --uninstall; expect_ok "uninstall over user config"
jq 'del(.permissions[] | select(.resource == "echo late"))' "$oc/opencode.json" >"$work/restored.json"
[ "$(jq -S . "$work/restored.json")" = "$original_config" ] || fail "user config not restored: $(cat "$oc/opencode.json")"
[ "$(cat "$oc/AGENTS.md")" = "$(printf '# My rules\n\nBe kind.')" ] || fail "user AGENTS.md not restored"
[ "$(tree "$home" | rg 'my-skill|theirs.js' || true)" = "$original_user_files" ] || fail "user-owned files changed"

# A retired server edited by the user must survive upgrade and uninstall.
home=$(fresh_home retired-clickup-edited)
oc="$home/.config/opencode"
run "$home"; expect_ok "install before edited ClickUp retirement"
jq '.mcp.servers.clickup = {"type":"local","command":["user"]}' "$oc/opencode.json" >"$work/user.json" && mv "$work/user.json" "$oc/opencode.json"
jq '.mcp.servers.clickup = {"type":"local","command":["legacy"]}' "$oc/b-agentic/install.json" >"$work/manifest.json" && mv "$work/manifest.json" "$oc/b-agentic/install.json"
run "$home"; expect_ok "preserve edited ClickUp on upgrade"
[ "$(jq -r '.mcp.servers.clickup.command[0]' "$oc/opencode.json")" = user ] || fail "edited ClickUp server removed"
run "$home" --uninstall; expect_ok "preserve edited ClickUp on uninstall"
[ "$(jq -r '.mcp.servers.clickup.command[0]' "$oc/opencode.json")" = user ] || fail "uninstall removed edited ClickUp server"

# --- both runtimes: each uninstall leaves the other byte-identical -----------------------------------
home=$(fresh_home both)
run_both "$home"; expect_ok "install both"
[ -f "$home/.claude/b-agentic/install.json" ] && [ -f "$home/.config/opencode/b-agentic/install.json" ] || fail "both manifests expected"
claude_before=$(tree "$home/.claude")
claude_json_before=$(sha256sum "$home/.claude.json")
run "$home" --uninstall; expect_ok "uninstall OpenCode only"
[ "$(tree "$home/.claude")" = "$claude_before" ] || fail "an OpenCode uninstall changed ~/.claude"
[ "$(sha256sum "$home/.claude.json")" = "$claude_json_before" ] || fail "an OpenCode uninstall changed ~/.claude.json"
run_both "$home"; expect_ok "reinstall both"
opencode_before=$(tree "$home/.config")
rc=0
out=$(env -u CLAUDE_CONFIG_DIR -u B_AGENTIC_CLAUDE_DIR -u B_AGENTIC_CLICKUP_MCP HOME="$home" bash "$root/install.sh" --uninstall 2>"$work/stderr") || rc=$?
expect_ok "uninstall the default (Claude) runtime"
[ "$(tree "$home/.config")" = "$opencode_before" ] || fail "a Claude uninstall changed ~/.config/opencode"
[ ! -e "$home/.claude/b-agentic/install.json" ] || fail "the Claude install was not removed"

# --- refusals happen before the first write -------------------------------------------------------------
home=$(fresh_home jsonc)
oc="$home/.config/opencode"
mkdir -p "$oc"
printf '{ // comment\n}\n' >"$oc/opencode.jsonc"
before=$(tree "$home")
run "$home"; expect_refused "opencode.jsonc"
grep -Fq 'opencode.jsonc' <<<"$err" || fail "jsonc refusal must name the file: $err"
[ "$(tree "$home")" = "$before" ] || fail "a jsonc refusal wrote files"

home=$(fresh_home malformed)
oc="$home/.config/opencode"
mkdir -p "$oc"
printf '{ not json\n' >"$oc/opencode.json"
before=$(tree "$home")
run "$home"; expect_refused "malformed opencode.json"
[ "$(tree "$home")" = "$before" ] || fail "a malformed-config refusal wrote files"

home=$(fresh_home v1map)
oc="$home/.config/opencode"
mkdir -p "$oc"
printf '{"permissions": {"bash": "ask"}}\n' >"$oc/opencode.json"
before=$(tree "$home")
run "$home"; expect_refused "a permissions map instead of an array"
[ "$(tree "$home")" = "$before" ] || fail "a permissions-shape refusal wrote files"

home=$(fresh_home xdg)
runenv "$home" "XDG_CONFIG_HOME=$work/elsewhere"; expect_refused "a different XDG_CONFIG_HOME"
[ ! -e "$home/.config" ] && [ ! -e "$work/elsewhere" ] || fail "an XDG refusal wrote files"
runenv "$home" "OPENCODE_CONFIG_DIR=$work/elsewhere"; expect_refused "a different OPENCODE_CONFIG_DIR"

home=$(fresh_home symlinked)
oc="$home/.config/opencode"
mkdir -p "$oc" "$work/real-skills"
ln -s "$work/real-skills" "$oc/skills"
run "$home"; expect_refused "a symlinked managed directory"
[ ! -e "$oc/b-agentic" ] || fail "a symlink refusal wrote files"

# --- an interrupted run is finished by a retry or removed by an uninstall ---------------------------------
if [ "$(id -u)" != 0 ]; then
  home=$(fresh_home interrupted)
  oc="$home/.config/opencode"
  mkdir -p "$oc/plugins"
  chmod 555 "$oc/plugins"
  run "$home"; expect_refused "a write failure partway through"
  grep -Fq 'manifest records the interrupted run' <<<"$err" || fail "the interruption message is missing: $err"
  [ "$(jq -r '.pending.files | length' "$oc/b-agentic/install.json")" -gt 0 ] || fail "the manifest must record the pending run"
  chmod 755 "$oc/plugins"
  run "$home"; expect_ok "retry after an interruption"
  [ "$(jq -r '.pending.files // {} | length' "$oc/b-agentic/install.json")" = 0 ] || fail "a completed retry must clear pending"
  [ -f "$oc/plugins/b-agentic.js" ] || fail "the retry did not finish the install"
  run "$home" --uninstall; expect_ok "uninstall after a retry"
  [ ! -e "$oc/b-agentic/install.json" ] || fail "uninstall left the manifest"
fi

# --- an upgrade retires the Codex guard's shell rules and script but keeps the user's approval store ---------
home=$(fresh_home guard-retire)
oc="$home/.config/opencode"
run "$home"; expect_ok "install before retiring the Codex guard"
if grep -Fq 'no longer read' <<<"$out"; then fail "a note about the approval file needs the file to exist"; fi
printf 'old guard\n' >"$oc/b-agentic/hooks/b-codex-guard.mjs"
guard_digest=$(sha256sum "$oc/b-agentic/hooks/b-codex-guard.mjs" | cut -d' ' -f1)
old_rules='[{"action":"shell","resource":"*b-codex-guard.mjs* --approve*","effect":"ask"},{"action":"shell","resource":"*codex-approved-repos.json*","effect":"ask"},{"action":"shell","resource":"*B_AGENTIC_STATE_DIR*","effect":"ask"}]'
# The previous release recorded the rules in the manifest and appended them to the managed block;
# a user-owned identical rule placed earlier must survive.
jq --argjson r "$old_rules" '.permissions = [{"action":"shell","resource":"*B_AGENTIC_STATE_DIR*","effect":"ask"}] + .permissions + $r' "$oc/opencode.json" >"$work/c.json" && mv "$work/c.json" "$oc/opencode.json"
jq --argjson r "$old_rules" --arg d "$guard_digest" '.permissions += $r | .files["b-agentic/hooks/b-codex-guard.mjs"] = $d' "$oc/b-agentic/install.json" >"$work/m.json" && mv "$work/m.json" "$oc/b-agentic/install.json"
printf '["/repo"]\n' >"$oc/b-agentic/codex-approved-repos.json"
run "$home"; expect_ok "upgrade over the Codex guard"
[ ! -e "$oc/b-agentic/hooks/b-codex-guard.mjs" ] || fail "the Codex guard script was not removed"
[ "$(jq '.permissions | length' "$oc/opencode.json")" = "$((rules_expected + 1))" ] || fail "managed rules plus the user's rule expected: $(jq '.permissions | length' "$oc/opencode.json")"
[ "$(jq '[.permissions[] | select(.resource | contains("b-codex-guard") or contains("codex-approved"))] | length' "$oc/opencode.json")" = 0 ] || fail "a retired Codex rule survived"
[ "$(jq '[.permissions[] | select(.resource == "*B_AGENTIC_STATE_DIR*")] | length' "$oc/opencode.json")" = 1 ] || fail "the user's identical rule did not survive exactly once"
[ "$(jq -r '.permissions | map(select(.resource | contains("codex"))) | length' "$oc/b-agentic/install.json")" = 0 ] || fail "the manifest still records a Codex rule"
[ "$(cat "$oc/b-agentic/codex-approved-repos.json")" = '["/repo"]' ] || fail "the user's approval store was touched"
grep -Fq 'no longer read' <<<"$out" || fail "no note about the leftover approval file: $out"
before=$(tree "$home")
run "$home"; expect_ok "second upgrade after the Codex guard retirement"
[ "$before" = "$(tree "$home")" ] || fail "a re-run after retiring the Codex guard changed files"
echo "opencode install probe passed: guard-retire"

# --- optional components: flags, persistence, removal, legacy inference ------------------------------------
opt_state() { jq -c '.optional_components' "$1/.config/opencode/b-agentic/install.json"; }
# opt_present <home> <id>: skill, routing line, rules, and server of one component are all installed.
opt_present() {
  local dir="$1/.config/opencode" skill server
  skill=$(jq -r --arg i "$2" '.optional_components[$i].skills[0]' "$root/skills/registry.yaml")
  server=$(jq -r --arg i "$2" '.optional_components[$i].mcp_servers[0]' "$root/skills/registry.yaml")
  [ -f "$dir/skills/$skill/SKILL.md" ] && grep -Fq "\`$skill\`" "$dir/AGENTS.md" \
    && { ! jq -e --arg s "$server" '.mcp.servers | has($s)' "$root/opencode/configs/opencode.template.json" >/dev/null \
         || [ "$(jq -r --arg s "$server" '.mcp.servers | has($s)' "$dir/opencode.json")" = true ]; } \
    && jq -e --arg s "$server" '[.permissions[] | select(.effect == "allow" and (.action | startswith($s + "_")))] | length > 0' "$dir/opencode.json" >/dev/null
}
# opt_absent <home> <id>: none of the four is installed.
opt_absent() {
  local dir="$1/.config/opencode" skill server
  skill=$(jq -r --arg i "$2" '.optional_components[$i].skills[0]' "$root/skills/registry.yaml")
  server=$(jq -r --arg i "$2" '.optional_components[$i].mcp_servers[0]' "$root/skills/registry.yaml")
  [ ! -e "$dir/skills/$skill" ] && ! grep -Fq "\`$skill\`" "$dir/AGENTS.md" \
    && [ "$(jq -r --arg s "$server" '.mcp.servers | has($s)' "$dir/opencode.json")" = false ] \
    && ! jq -e --arg s "$server" '[.permissions[] | select(.effect == "allow" and (.action | startswith($s + "_")))] | length > 0' "$dir/opencode.json" >/dev/null
}
home=$(fresh_home optional)
run "$home" -y; expect_ok "default install"
for id in datagrip tablepro excalidraw drawio; do opt_absent "$home" "$id" || fail "$id must be absent by default"; done
[ "$(opt_state "$home")" = '{"datagrip":false,"tablepro":false,"excalidraw":false,"drawio":false}' ] || fail "default selection not recorded"
run "$home" -y --with=tablepro,drawio; expect_ok "select two components"
{ opt_present "$home" tablepro && opt_present "$home" drawio; } || fail "selected components must be installed"
{ opt_absent "$home" datagrip && opt_absent "$home" excalidraw; } || fail "unselected components must stay absent"
run "$home" -y; expect_ok "plain re-run keeps the recorded choice"
{ opt_present "$home" tablepro && opt_present "$home" drawio; } || fail "a plain re-run must not drop components"
before=$(tree "$home")
run "$home" -y; expect_ok "idempotent re-run"
[ "$before" = "$(tree "$home")" ] || fail "re-run changed files"
run "$home" --dry-run --with=datagrip; expect_ok "dry-run"
[ "$before" = "$(tree "$home")" ] || fail "dry-run changed files"
run "$home" -y --without=tablepro; expect_ok "deselect tablepro"
{ opt_absent "$home" tablepro && opt_present "$home" drawio; } || fail "deselecting must remove only that component"
# Deselecting drops only allow rules: the ask rules of a server stay, so a user-managed or kept server still prompts.
jq -e '[.permissions[] | select(.effect == "ask" and .action == "datagrip_*")] | length == 1' "$home/.config/opencode/opencode.json" >/dev/null || fail "the datagrip ask rule must stay when the component is off"
# A modified skill and an edited server survive deselection (the server with a warning).
oc="$home/.config/opencode"
printf 'mine\n' >>"$oc/skills/b-drawio/SKILL.md"
jq '.mcp.servers.drawio.timeout.startup = 1' "$oc/opencode.json" >"$work/edited.json"
cp "$work/edited.json" "$oc/opencode.json"
run "$home" -y --without=drawio; expect_ok "deselect an edited component"
[ -f "$oc/skills/b-drawio/SKILL.md" ] || fail "an edited skill must be kept"
[ "$(jq -r '.mcp.servers | has("drawio")' "$oc/opencode.json")" = true ] || fail "an edited server must be kept"
grep -Fq "although its optional component is not selected" <<<"$err" || fail "a kept edited server must warn: $err"
if grep -Fq "\`b-drawio\`" "$oc/AGENTS.md"; then fail "the routing line must go even when the skill is kept"; fi
# Invalid combinations refuse without changing anything.
before=$(tree "$home")
run "$home" -y --with=nope; expect_refused "unknown id"
run "$home" -y --with=drawio --without=drawio; expect_refused "same id in both flags"
run "$home" --uninstall --with=drawio; expect_refused "flag with uninstall"
[ "$before" = "$(tree "$home")" ] || fail "refusals changed files"
# A manifest that predates the choice is inferred from what it owns.
home=$(fresh_home optional-legacy)
run "$home" -y --with=datagrip,tablepro,excalidraw,drawio; expect_ok "full install"
jq 'del(.optional_components)' "$home/.config/opencode/b-agentic/install.json" >"$work/legacy-manifest.json"
cp "$work/legacy-manifest.json" "$home/.config/opencode/b-agentic/install.json"
run "$home" -y; expect_ok "upgrade a manifest without a recorded choice"
for id in datagrip tablepro excalidraw drawio; do opt_present "$home" "$id" || fail "$id must be kept for an existing install"; done
[ "$(opt_state "$home")" = '{"datagrip":true,"tablepro":true,"excalidraw":true,"drawio":true}' ] || fail "inferred selection must be recorded"
# The doctors accept a partial selection, report a missing selected server, and ignore a kept modified skill.
home=$(fresh_home optional-doctors)
run "$home" -y --with=drawio; expect_ok "doctor install"
python3 "$root/tooling/validate/skill_doctor.py" --runtime opencode --home "$home" >"$work/doctor.txt" || fail "skill doctor must pass for a partial selection: $(cat "$work/doctor.txt")"
mcp=$(env -u B_AGENTIC_OPENCODE_DIR python3 "$root/tooling/validate/mcp_doctor.py" --runtime opencode --home "$home" --allow-degraded)
grep -Fq 'tablepro: not installed: optional' <<<"$mcp" || fail "an unselected server must be optional: $mcp"
jq 'del(.mcp.servers.drawio)' "$home/.config/opencode/opencode.json" >"$work/no-drawio.json"
cp "$work/no-drawio.json" "$home/.config/opencode/opencode.json"
mcp=$(env -u B_AGENTIC_OPENCODE_DIR python3 "$root/tooling/validate/mcp_doctor.py" --runtime opencode --home "$home" --allow-degraded)
grep -Fq 'drawio: missing:' <<<"$mcp" || fail "a selected but missing server must be reported missing: $mcp"
home=$(fresh_home optional-kept-skill)
run "$home" -y --with=drawio; expect_ok "kept-skill install"
printf 'mine\n' >>"$home/.config/opencode/skills/b-drawio/SKILL.md"
run "$home" -y --without=drawio; expect_ok "deselect a modified skill"
python3 "$root/tooling/validate/skill_doctor.py" --runtime opencode --home "$home" >"$work/doctor.txt" || fail "a kept modified skill must not fail the doctor: $(cat "$work/doctor.txt")"
echo "opencode install probe passed: optional-components"

# Skills never point at an optional sibling that is not installed; a full install keeps the source bytes.
home=$(fresh_home optional-siblings)
run "$home" -y; expect_ok "default install"
for installed in "$home"/.config/opencode/skills/*/SKILL.md; do
  if grep -Eq '\*\*b-(datagrip|tablepro|excalidraw|drawio)\*\*' "$installed"; then fail "a default install must not reference an uninstalled optional skill: $installed"; fi
done
run "$home" -y --with=drawio; expect_ok "only drawio"
if grep -Eq '\*\*b-excalidraw\*\*|requires: b-excalidraw' "$home/.config/opencode/skills/b-drawio/SKILL.md"; then fail "b-drawio must drop its excalidraw reference when excalidraw is absent"; fi
python3 "$root/tooling/validate/skill_doctor.py" --runtime opencode --home "$home" >"$work/doctor.txt" || fail "skill doctor must pass for the filtered skill: $(cat "$work/doctor.txt")"
run "$home" -y --with=drawio,excalidraw; expect_ok "drawio and excalidraw"
cmp -s "$root/opencode/skills/b-drawio/SKILL.md" "$home/.config/opencode/skills/b-drawio/SKILL.md" || fail "a full install must keep the generated b-drawio skill byte for byte"
run "$home" -y --without=excalidraw; expect_ok "deselect excalidraw"
if grep -Fq '**b-excalidraw**' "$home/.config/opencode/skills/b-drawio/SKILL.md"; then fail "deselecting must rewrite the sibling reference away"; fi
backed_up=0
for backup in "$home"/.config/opencode/b-agentic/backups/*/*__skills__b-drawio__SKILL.md; do
  if [ -f "$backup" ] && cmp -s "$root/opencode/skills/b-drawio/SKILL.md" "$backup"; then backed_up=1; fi
done
[ "$backed_up" = 1 ] || fail "deselecting must back up the full b-drawio skill before rewriting it"
before=$(tree "$home")
run "$home" -y; expect_ok "re-run after deselect"
[ "$before" = "$(tree "$home")" ] || fail "a plain re-run after deselect must change nothing"
# A marker naming a skill that is not optional is refused before anything is written.
home=$(fresh_home optional-bad-marker)
src_bad="$work/src-bad-marker"
mkdir -p "$src_bad"
( cd "$root" && git ls-files -co --exclude-standard -z | while IFS= read -r -d '' file; do if [[ -e "$file" || -L "$file" ]]; then printf '%s\0' "$file"; fi; done | tar --null -T - -cf - ) | tar -xf - -C "$src_bad"
printf '\nbad <!-- requires: b-plan -->\n' >>"$src_bad/opencode/skills/b-drawio/SKILL.md"
before=$(tree "$home")
rc=0
out=$(env -u XDG_CONFIG_HOME -u OPENCODE_CONFIG_DIR -u B_AGENTIC_OPENCODE_DIR -u B_AGENTIC_CLICKUP_MCP \
  -u CLAUDE_CONFIG_DIR -u B_AGENTIC_CLAUDE_DIR HOME="$home" bash "$src_bad/install.sh" --runtime=opencode -y --with=drawio 2>"$work/stderr") || rc=$?
err=$(cat "$work/stderr")
expect_refused "a marker naming a non-optional skill"
grep -Fq 'skill marker names a skill that is not optional: b-plan' <<<"$err$out" || fail "the refusal must name the bad marker: $err $out"
[ "$before" = "$(tree "$home")" ] || fail "a refused marker must not write anything"
echo "opencode install probe passed: sibling-references"

# --- the retired OpenCode install is refused, then migrated on request ------------------------------------
home=$(fresh_home legacy)
oc="$home/.config/opencode"
mkdir -p "$oc/b-agentic/commands" "$oc/b-agentic/skills" "$oc/skills/b-diagram" "$oc/skills/b-plan" "$oc/agents" "$oc/commands" "$oc/skills/my-skill"
printf 'legacy skill\n' >"$oc/skills/b-diagram/SKILL.md"
printf 'legacy skill\n' >"$oc/skills/b-plan/SKILL.md"
printf 'mine\n' >"$oc/skills/my-skill/SKILL.md"
printf 'legacy agent\n' >"$oc/agents/b-retired-agent.md"
printf 'legacy command\n' >"$oc/commands/b-plan.md"
printf '<!-- b-agentic-managed -->\n\nlegacy kernel body\n' >"$oc/AGENTS.md"
printf '{"suite":"b-agentic","runtime":"opencode","skills":["b-diagram","b-plan"],"agents":["b-retired-agent"],"commands":["b-plan"]}\n' >"$oc/b-agentic/install.json"
printf '{"providers":{"zai":{}}}\n' >"$oc/opencode.json"
before=$(tree "$home")
run "$home"; expect_refused "a legacy install without --migrate-legacy"
grep -Fq -- '--migrate-legacy' <<<"$err" || fail "the refusal must name --migrate-legacy: $err"
[ "$(tree "$home")" = "$before" ] || fail "a legacy refusal wrote files"
run "$home" --migrate-legacy --dry-run; expect_ok "legacy migration dry run"
[ "$(tree "$home")" = "$before" ] || fail "a legacy dry run wrote files"
run "$home" --migrate-legacy; expect_ok "legacy migration"
[ ! -e "$oc/skills/b-diagram" ] || fail "a retired skill was not removed"
[ ! -e "$oc/agents/b-retired-agent.md" ] && [ ! -e "$oc/commands/b-plan.md" ] || fail "retired agent or command left behind"
[ -f "$oc/skills/b-plan/SKILL.md" ] || fail "b-plan must be installed"
if grep -Fq 'legacy skill' "$oc/skills/b-plan/SKILL.md"; then fail "b-plan must be the new skill"; fi
[ "$(cat "$oc/skills/my-skill/SKILL.md")" = mine ] || fail "a user skill was removed"
if grep -Fq 'legacy kernel body' "$oc/AGENTS.md"; then fail "the retired kernel must be replaced"; fi
if head -n 1 "$oc/AGENTS.md" | grep -Fq 'b-agentic-managed'; then fail "the retired whole-file kernel marker must be gone"; fi
grep -Fq '<!-- b-agentic:start -->' "$oc/AGENTS.md" || fail "the new kernel block is missing"
[ "$(jq -c '.providers' "$oc/opencode.json")" = '{"zai":{}}' ] || fail "user providers changed during migration"
[ "$(jq -r .schema "$oc/b-agentic/install.json")" = 1 ] || fail "the new manifest was not written"
[ -n "$(find "$oc/b-agentic/backups" -type f 2>/dev/null | head -n 1)" ] || fail "legacy files must be backed up"
run "$home"; expect_ok "install after migration"

# --- migration validates everything before deleting, and never follows a symlinked parent ------------------
legacy_home() {
  local home oc
  home=$(fresh_home "$1")
  oc="$home/.config/opencode"
  mkdir -p "$oc/b-agentic" "$oc/agents"
  printf 'legacy agent\n' >"$oc/agents/b-retired-agent.md"
  printf '{"suite":"b-agentic","runtime":"opencode","skills":["b-plan"],"agents":["b-retired-agent"],"commands":[]}\n' >"$oc/b-agentic/install.json"
  printf '%s' "$home"
}

home=$(legacy_home legacy-symlink)
oc="$home/.config/opencode"
mkdir -p "$work/elsewhere/b-plan"
printf 'precious\n' >"$work/elsewhere/b-plan/SKILL.md"
ln -s "$work/elsewhere" "$oc/skills"
before=$(tree "$home")
run "$home" --migrate-legacy; expect_refused "a legacy migration through a symlinked skills directory"
[ "$(cat "$work/elsewhere/b-plan/SKILL.md")" = precious ] || fail "a legacy deletion followed a symlinked parent"
[ "$(tree "$home")" = "$before" ] || fail "a refused migration changed files"

home=$(legacy_home legacy-malformed)
oc="$home/.config/opencode"
printf '{ not json\n' >"$oc/opencode.json"
before=$(tree "$home")
run "$home" --migrate-legacy; expect_refused "a legacy migration with a malformed opencode.json"
[ "$(tree "$home")" = "$before" ] || fail "a migration deleted the legacy install before validating the replacement"
printf '{}\n' >"$oc/opencode.json"
run "$home" --migrate-legacy; expect_ok "the migration retry once the config is valid"
[ ! -e "$oc/agents/b-retired-agent.md" ] || fail "the retry did not remove the retired agent"

home=$(legacy_home legacy-config-in-tree)
oc="$home/.config/opencode"
mkdir -p "$oc/b-agentic/templates"
printf '{"providers":{"keep":{}}}\n' >"$oc/b-agentic/templates/opencode.json"
ln -s b-agentic/templates/opencode.json "$oc/opencode.json"
before=$(tree "$home")
run "$home" --migrate-legacy; expect_refused "opencode.json linked into a legacy tree the migration deletes"
grep -Fq 'is a symlink' <<<"$err" || fail "the refusal must name the symlink: $err"
[ "$(tree "$home")" = "$before" ] || fail "a refused migration changed files"

home=$(legacy_home legacy-config-chain)
oc="$home/.config/opencode"
mkdir -p "$oc/b-agentic/templates"
printf '{"providers":{"keep":{}}}\n' >"$work/outside-config.json"
ln -s "$work/outside-config.json" "$oc/b-agentic/templates/config-link"
ln -s b-agentic/templates/config-link "$oc/opencode.json"
before=$(tree "$home")
run "$home" --migrate-legacy; expect_refused "opencode.json reaching outside through a link inside a legacy tree"
[ "$(tree "$home")" = "$before" ] || fail "a refused chain migration changed files"
[ "$(cat "$work/outside-config.json")" = '{"providers":{"keep":{}}}' ] || fail "the user config was touched"

home=$(legacy_home legacy-kernel-chain)
oc="$home/.config/opencode"
mkdir -p "$oc/b-agentic/templates"
printf 'user rules\n' >"$work/outside-agents.md"
ln -s "$work/outside-agents.md" "$oc/b-agentic/templates/agents-link"
ln -s b-agentic/templates/agents-link "$oc/AGENTS.md"
before=$(tree "$home")
run "$home" --migrate-legacy; expect_refused "AGENTS.md reaching outside through a link inside a legacy tree"
[ "$(tree "$home")" = "$before" ] || fail "a refused kernel-chain migration changed files"

home=$(legacy_home legacy-config-alias)
oc="$home/.config/opencode"
mkdir -p "$oc/agents"
printf 'user agent\n' >"$oc/agents/b-planner.md"
ln "$oc/agents/b-planner.md" "$oc/opencode.json"
before=$(tree "$home")
run "$home" --migrate-legacy; expect_refused "opencode.json aliasing a managed payload file"
[ "$(tree "$home")" = "$before" ] || fail "an alias refusal happened after the legacy install was deleted"

home=$(fresh_home legacy-base-symlink)
realbase="$work/realconfig"
mkdir -p "$realbase/opencode/b-agentic/templates" "$realbase/opencode/agents"
ln -s "$realbase" "$home/.config"
oc="$home/.config/opencode"
printf 'legacy agent\n' >"$oc/agents/b-retired-agent.md"
printf '{"suite":"b-agentic","runtime":"opencode","skills":[],"agents":["b-retired-agent"],"commands":[]}\n' >"$oc/b-agentic/install.json"
printf '{"providers":{"keep":{}}}\n' >"$oc/b-agentic/templates/opencode.json"
ln -s b-agentic/templates/opencode.json "$oc/opencode.json"
before=$(tree "$realbase")
run "$home" --migrate-legacy; expect_refused "opencode.json linked into a legacy tree under a symlinked ~/.config"
grep -Fq 'is a symlink' <<<"$err" || fail "the refusal must name the symlink: $err"
[ "$(tree "$realbase")" = "$before" ] || fail "a refused migration under a symlinked base changed files"

# --- the two runtimes never write into each other, even through symlinks -------------------------------------
home=$(fresh_home isolation)
oc="$home/.config/opencode"
mkdir -p "$oc" "$home/.claude"
printf 'claude rules\n' >"$home/.claude/CLAUDE.md"
ln -s "$home/.claude/CLAUDE.md" "$oc/AGENTS.md"
before=$(tree "$home/.claude")
run "$home"; expect_refused "AGENTS.md linked into ~/.claude"
grep -Fq "another runtime" <<<"$err" || fail "the isolation refusal must say why: $err"
[ "$(tree "$home/.claude")" = "$before" ] || fail "an OpenCode install wrote into ~/.claude"
rm "$oc/AGENTS.md"
printf '{"x":1}\n' >"$home/.claude.json"
ln -s "$home/.claude.json" "$oc/opencode.json"
run "$home"; expect_refused "opencode.json linked to ~/.claude.json"
[ "$(cat "$home/.claude.json")" = '{"x":1}' ] || fail "an OpenCode install wrote ~/.claude.json"

home=$(fresh_home isolation-claude)
oc="$home/.config/opencode"
mkdir -p "$oc" "$home/.claude"
printf 'opencode rules\n' >"$oc/AGENTS.md"
ln -s "$oc/AGENTS.md" "$home/.claude/CLAUDE.md"
rc=0
out=$(env -u CLAUDE_CONFIG_DIR -u B_AGENTIC_CLAUDE_DIR -u B_AGENTIC_CLICKUP_MCP HOME="$home" bash "$root/install.sh" -y 2>"$work/stderr") || rc=$?
err=$(cat "$work/stderr")
expect_refused "CLAUDE.md linked into ~/.config/opencode"
[ "$(cat "$oc/AGENTS.md")" = 'opencode rules' ] || fail "a Claude Code install wrote into ~/.config/opencode"

# --- the v1 permission map is refused where it really lives ---------------------------------------------------
home=$(fresh_home v1key)
oc="$home/.config/opencode"
mkdir -p "$oc"
printf '{"permission": {"bash": {"git push *": "deny"}}}\n' >"$oc/opencode.json"
before=$(tree "$home")
run "$home"; expect_refused "the v1 singular permission key"
grep -Fq "'permission'" <<<"$err" || fail "the refusal must name the permission key: $err"
[ "$(tree "$home")" = "$before" ] || fail "a v1-key refusal wrote files"

# --- terminal UI: /dev/tty answers work even when stdin is a pipe ----------------------
cat >"$work/pty-run.py" <<'PY'
import errno, os, pty, select, signal, subprocess, sys, time

home, *answers = sys.argv[1:]
excluded = {"XDG_CONFIG_HOME", "OPENCODE_CONFIG_DIR", "B_AGENTIC_OPENCODE_DIR",
            "B_AGENTIC_CLICKUP_MCP", "CLAUDE_CONFIG_DIR", "B_AGENTIC_CLAUDE_DIR", "NO_COLOR"}
env = {k: v for k, v in os.environ.items() if k not in excluded}
env.update(HOME=home, TERM=env.get("PROBE_TERM", "xterm-256color"))
if "PROBE_NO_COLOR" in env:
    env["NO_COLOR"] = "1"
pid, fd = pty.fork()
if pid == 0:
    os.execvpe("bash", ["bash", "-c", env["PROBE_CMD"]], env)
buf, pending, deadline = b"", b"", time.monotonic() + 30
failure = None
try:
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if not ready:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError as exc:
            if exc.errno != errno.EIO:
                raise
            break
        if not chunk:
            break
        buf += chunk
        pending += chunk
        if b"[y/N] " in pending or b"[Y/n] " in pending or b"Enter confirms" in pending:
            if not answers:
                raise RuntimeError("unexpected installer prompt")
            while answers and answers[0].startswith("!"):
                subprocess.run(answers.pop(0)[1:], shell=True, env=env, check=True)
            if not answers:
                raise RuntimeError("missing answer after prompt action")
            os.write(fd, (answers.pop(0) + "\n").encode())
            pending = b""
    else:
        raise RuntimeError("installer timed out")
except Exception as exc:
    failure = str(exc)
    os.kill(pid, signal.SIGKILL)
finally:
    os.close(fd)
    _, status = os.waitpid(pid, 0)
    sys.stdout.write(buf.decode(errors="replace"))
if failure or answers:
    print(failure or "installer exited before consuming the expected answers", file=sys.stderr)
    sys.exit(2)
sys.exit(os.waitstatus_to_exitcode(status))
PY
# shellcheck disable=SC2016 # expanded by the child shell, not this probe
piped_install='echo ignored | bash "$PROBE_ROOT/install.sh" --runtime=opencode'
tui_run() {
  local home=$1 command=$2
  shift 2
  rc=0
  out=$(PROBE_ROOT="$root" PROBE_CMD="$command" python3 "$work/pty-run.py" "$home" "$@") || rc=$?
  err="$out"
}
home=$(fresh_home tui)
before=$(tree "$home")
tui_run "$home" "$piped_install" "" n; expect_refused "decline terminal install"
grep -Fq 'Installation Summary' <<<"$out" || fail "TUI summary missing: $out"
grep -Fq 'Runtime: OpenCode' <<<"$out" || fail "TUI must identify its runtime: $out"
grep -Fq 'Proceed with installation?' <<<"$out" || fail "TUI confirmation missing: $out"
[ "$(tree "$home")" = "$before" ] || fail "declining the TUI changed files"
tui_run "$home" "$piped_install" "" y; expect_ok "accept terminal install"
grep -Fq 'Installation complete' <<<"$out" || fail "TUI completion missing: $out"
grep -Fq 'Next steps' <<<"$out" || fail "TUI next steps missing: $out"
oc="$home/.config/opencode"
[ -f "$oc/b-agentic/install.json" ] || fail "accepting must install"
tui_run "$home" "$piped_install" "" y; expect_ok "terminal reinstall"
if grep -Fq 'Add the optional ClickUp' <<<"$out"; then fail "a saved ClickUp choice must not be asked again"; fi
printf 'local edit\n' >>"$oc/agents/b-planner.md"
tui_run "$home" "$piped_install" "" y; expect_ok "terminal preserved-file warning"
grep -Fq 'Warnings' <<<"$out" || fail "TUI warning box missing: $out"
grep -Fq 'local edit' "$oc/agents/b-planner.md" || fail "TUI overwrote a modified file"
for mode in --dry-run --yes --uninstall; do
  tui_run "$home" "$piped_install $mode"; expect_ok "terminal $mode"
  if grep -Fq 'Installation Summary' <<<"$out" || grep -Fq 'Proceed with installation?' <<<"$out"; then
    fail "$mode must remain plain and non-interactive: $out"
  fi
done
home=$(fresh_home tui-no-color)
PROBE_NO_COLOR=1 tui_run "$home" "$piped_install" "" n; expect_refused "NO_COLOR terminal UI"
if [[ "$out" == *$'\033['* ]]; then fail "NO_COLOR must suppress ANSI styling"; fi
home=$(fresh_home tui-dumb)
PROBE_TERM=dumb tui_run "$home" "$piped_install"; expect_ok "dumb terminal fallback"
if grep -Fq 'Installation Summary' <<<"$out"; then fail "TERM=dumb must remain plain"; fi
home=$(fresh_home tui-notes)
srcrepo="$work/srcrepo"
mkdir -p "$srcrepo"
( cd "$root" && git ls-files -co --exclude-standard -z -- install.sh tooling/install skills/registry.yaml opencode claude/bin claude/hooks | while IFS= read -r -d '' file; do if [[ -e "$file" || -L "$file" ]]; then printf '%s\0' "$file"; fi; done | tar --null -T - -cf - ) | tar -xf - -C "$srcrepo"
git -C "$srcrepo" init -q .
git -C "$srcrepo" add -A
git -C "$srcrepo" -c user.email=probe@example.invalid -c user.name=probe commit -qm source
# shellcheck disable=SC2016
piped_bootstrap='cat "$PROBE_ROOT/install.sh" | bash -s -- --runtime=opencode'
for expected in 'Cloning source' 'Updating source'; do
  B_AGENTIC_REPO="$srcrepo" B_AGENTIC_DIR="$home/src" tui_run "$home" "$piped_bootstrap" "" n
  expect_refused "terminal bootstrap notes"
  grep -Fq "$expected" <<<"$out" || fail "bootstrap notes lost: $out"
  note_line=$(grep -nF "$expected" <<<"$out" | head -1 | cut -d: -f1)
  header_line=$(grep -nF '┌' <<<"$out" | head -1 | cut -d: -f1)
  [ -n "$header_line" ] && [ "$header_line" -lt "$note_line" ] || fail "bootstrap notes must follow the header"
  [ ! -e "$home/.config/opencode" ] || fail "declined bootstrap wrote OpenCode config"
done

# Replan after confirmation: retain edits and refuse newly unsafe destinations before writes.
home=$(fresh_home tui-edit)
# shellcheck disable=SC2016 # HOME belongs to the sandbox child
edit_cmd='!mkdir -p "$HOME/.config/opencode" && printf '\''{"providers":{"late":{}}}\n'\'' >"$HOME/.config/opencode/opencode.json"'
tui_run "$home" "$piped_install" "" "$edit_cmd" y; expect_ok "edit during confirmation"
jq -e '.providers.late == {}' "$home/.config/opencode/opencode.json" >/dev/null || fail "late user edit lost"
home=$(fresh_home tui-alias)
# shellcheck disable=SC2016
alias_cmd='!mkdir -p "$HOME/.config/opencode" && ln -s AGENTS.md "$HOME/.config/opencode/opencode.json"'
tui_run "$home" "$piped_install" "" "$alias_cmd" y; expect_refused "alias during confirmation"
[ ! -e "$home/.config/opencode/b-agentic" ] && [ ! -e "$home/.config/opencode/AGENTS.md" ] || fail "late alias refusal wrote files"

home=$(legacy_home tui-legacy)
before=$(tree "$home")
tui_run "$home" "$piped_install --migrate-legacy" "" n; expect_refused "decline legacy migration"
grep -Fq 'Legacy migration' <<<"$out" || fail "migration deletions must be shown: $out"
grep -Fq 'agents/b-retired-agent.md' <<<"$out" || fail "migration summary must name removal paths: $out"
[ "$(tree "$home")" = "$before" ] || fail "declining migration changed the legacy install"
[ ! -e "$home/.config/opencode/b-agentic/backups" ] || fail "declining migration created backups"
tui_run "$home" "$piped_install --migrate-legacy" "" y; expect_ok "accept legacy migration"
[ ! -e "$home/.config/opencode/agents/b-retired-agent.md" ] || fail "accepted migration left the retired agent"
[ -f "$home/.config/opencode/agents/b-planner.md" ] || fail "accepted migration did not install"

home=$(legacy_home tui-legacy-late-link)
# shellcheck disable=SC2016
link_cmd='!mkdir -p "$HOME/dotfiles" && ln -s "$HOME/dotfiles" "$HOME/.config/opencode/skills"'
tui_run "$home" "$piped_install --migrate-legacy" "" "$link_cmd" y
expect_refused "unsafe migration destination during confirmation"
oc="$home/.config/opencode"
[ "$(cat "$oc/agents/b-retired-agent.md")" = 'legacy agent' ] || fail "late refusal removed legacy files"
[ ! -e "$oc/b-agentic/backups" ] && [ ! -e "$home/dotfiles/b-plan" ] || fail "late refusal wrote files"

# --runtime=both remains sequential: declining OpenCode does not undo Claude.
home=$(fresh_home tui-both)
# shellcheck disable=SC2016
piped_both='echo ignored | bash "$PROBE_ROOT/install.sh" --runtime=both'
tui_run "$home" "$piped_both" "" y "" n; expect_refused "decline second runtime"
[ -f "$home/.claude/b-agentic/install.json" ] || fail "the first runtime was not installed"
[ ! -e "$home/.config/opencode" ] || fail "the declined second runtime was installed"


# The checkbox list: nothing is checked on a fresh install; Space toggles the highlighted item.
home=$(fresh_home tui-checkbox)
tui_run "$home" "$piped_install" " " y; expect_ok "toggle the first component in the checkbox"
grep -Fq 'Enter confirms' <<<"$out" || fail "the checkbox list must be shown: $out"
grep -Fq '[ ] TablePro' <<<"$out" || fail "unselected components must show an empty box: $out"
opt_present "$home" datagrip || fail "the toggled component must be installed"
opt_absent "$home" tablepro || fail "an untouched component must stay absent"
tui_run "$home" "$piped_install" "" y; expect_ok "accept the pre-checked selection"
opt_present "$home" datagrip || fail "Enter on a re-sync must keep the installed component"
tui_run "$home" "$piped_install" " " y; expect_ok "uncheck the installed component"
opt_absent "$home" datagrip || fail "unchecking an installed component must remove it"
tui_run "$home" "$piped_install --with=drawio" y; expect_ok "flags skip the checkbox"
if grep -Fq 'Enter confirms' <<<"$out"; then fail "--with must skip the checkbox: $out"; fi
opt_present "$home" drawio || fail "--with must install the component"
echo "opencode install probe passed: checkbox"
echo "opencode install probe passed"
