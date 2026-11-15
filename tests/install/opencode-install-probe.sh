#!/usr/bin/env bash
# Exercise tooling/install/opencode_install.py (through install.sh --runtime=opencode|both) in sandbox
# HOME directories. Needs python3, jq, and bun: no network, credentials, OpenCode, or Codex. Every
# scenario owns a private HOME, so nothing outside the throwaway work directory is read or written.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT

fail() { echo "opencode install probe failed: $*" >&2; exit 1; }

# fresh_home <name>: a sandbox HOME holding Claude Code and Pi files that an OpenCode run must never change.
fresh_home() {
  local home="$work/$1"
  mkdir -p "$home/.claude/skills/b-plan" "$home/.pi/agent"
  printf 'claude skill\n' >"$home/.claude/skills/b-plan/SKILL.md"
  printf '{"claude":true}\n' >"$home/.claude/settings.json"
  printf '{"claudeJson":true}\n' >"$home/.claude.json"
  printf '{"pi":true}\n' >"$home/.pi/agent/settings.json"
  printf '%s' "$home"
}
# tree <dir> [prefix]: sorted `sha256  relative-path` list for the files under dir/prefix, backups excluded.
tree() {
  # shellcheck disable=SC2016 # The inner script runs in sh and expands its own variables.
  ( cd "$1" && find "${2:-.}" \( -type f -o -type l \) -not -path '*/b-agentic/backups/*' -print0 \
      | sort -z | xargs -0 -r sh -c 'for f; do if [ -L "$f" ]; then printf "link %s -> %s\n" "$f" "$(readlink "$f")"; else printf "%s  %s\n" "$(sha256sum "$f" | cut -d" " -f1)" "$f"; fi; done' _ )
}
# run <home> [args...]: stdout to $out, stderr to $err, exit code to $rc.
out="" err="" rc=0
run() {
  local home=$1
  shift
  rc=0
  out=$(env -u CLAUDE_CONFIG_DIR -u B_AGENTIC_CLAUDE_DIR -u XDG_CONFIG_HOME -u OPENCODE_CONFIG_DIR -u B_AGENTIC_OPENCODE_DIR \
    HOME="$home" bash "$root/install.sh" "$@" 2>"$work/stderr") || rc=$?
  err=$(cat "$work/stderr")
}
expect_ok() { [ "$rc" = 0 ] || fail "$1 (exit $rc: $err $out)"; }
expect_refused() { [ "$rc" = 1 ] || fail "$1 (exit $rc, expected 1: $err $out)"; }
oc() { printf '%s/.config/opencode' "$1"; }
manifest() { printf '%s/b-agentic/install.json' "$(oc "$1")"; }
others() { tree "$1" .claude; tree "$1" .claude.json; tree "$1" .pi; }

# --- pi is refused and names ADR-019 -------------------------------------------------------
home=$(fresh_home pi-refused)
before=$(tree "$home")
run "$home" --runtime=pi -y
expect_refused "--runtime=pi must be refused"
grep -Fq 'ADR-019' <<<"$err" || fail "the pi refusal must name ADR-019: $err"
[ "$(tree "$home")" = "$before" ] || fail "a refused pi run changed files"
echo "opencode install probe passed: pi refused"

# --- dry run writes nothing and names only OpenCode paths -----------------------------------
home=$(fresh_home dry)
before=$(tree "$home")
run "$home" --runtime=opencode --dry-run
expect_ok "dry run"
[ "$(tree "$home")" = "$before" ] || fail "a dry run changed files"
[ ! -e "$home/.config/opencode" ] || fail "a dry run created ~/.config/opencode"
grep -Fq "$home/.config/opencode" <<<"$out" || fail "an OpenCode dry run must name ~/.config/opencode: $out"
echo "opencode install probe passed: dry run"

# --- install, rerun, and the other runtimes stay byte-identical ------------------------------
home=$(fresh_home fresh)
others_before=$(others "$home")
run "$home" --runtime=opencode -y
expect_ok "install"
dir=$(oc "$home")
[ "$(jq -r .target "$(manifest "$home")")" = opencode ] || fail "the manifest must record target opencode"
for file in skills/b-plan/SKILL.md skills/b-flow/SKILL.md commands/b-plan.md agents/b-reviewer.md agents/b-worker.md \
  plugins/b-agentic.js b-agentic/guard.mjs b-agentic/hooks/b-path-guard.mjs b-agentic/hooks/b-codex-guard.mjs \
  b-agentic/bin/b-state.mjs b-agentic/bin/b-codex-review.mjs b-agentic/bin/b_run.py b-agentic/references/artifacts.yaml; do
  [ -f "$dir/$file" ] || fail "missing $file"
done
[ ! -e "$dir/b-agentic/bin/b-statusline.mjs" ] || fail "the status line is not ported"
[ ! -e "$dir/skills/b-datagrip/SKILL.md" ] || fail "an unselected optional skill must not be installed"
grep -Fq '<!-- b-agentic:start -->' "$dir/AGENTS.md" || fail "the kernel block is missing"
grep -Fq 'OpenCode Workflow Kernel' "$dir/AGENTS.md" || fail "the kernel must be the OpenCode kernel"
[ "$(jq -r '.experimental.todo' "$dir/opencode.json")" = true ] || fail "experimental.todo must be set"
[ "$(jq -r '.mcp.servers.codegraph.codemode' "$dir/opencode.json")" = false ] || fail "MCP servers must be direct (codemode false)"
[ "$(jq -r '.permissions[0].action' "$dir/opencode.json")" = '*_*' ] || fail "the unclassified MCP fallback must come first"
[ "$(jq -r '.permissions[-1].action' "$dir/opencode.json")" = edit ] || fail "the protections must be the last block"
[ ! -e "$home/.pi/agent/b-agentic" ] || fail "an OpenCode run wrote under ~/.pi"
[ "$(others "$home")" = "$others_before" ] || fail "an OpenCode run changed the Claude Code or Pi tree"
after=$(tree "$home" .config)
run "$home" --runtime=opencode -y
expect_ok "rerun"
[ "$(tree "$home" .config)" = "$after" ] || fail "a rerun changed files"
echo "opencode install probe passed: install and rerun"

# --- uninstall restores the user's files ------------------------------------------------------
home=$(fresh_home user-owned)
dir=$(oc "$home")
mkdir -p "$dir/plugins"
printf '// user plugin\n' >"$dir/plugins/mine.js"
printf '# My notes\n' >"$dir/AGENTS.md"
cat >"$dir/opencode.json" <<'EOF'
{
  "theme": "mine",
  "permissions": [{"action": "webfetch", "resource": "*", "effect": "ask"}],
  "mcp": {"servers": {"mine": {"type": "local", "command": ["true"]}}}
}
EOF
user_config=$(cat "$dir/opencode.json")
original=$(tree "$home" .config)
run "$home" --runtime=opencode -y
expect_ok "install over user files"
[ "$(jq -r '.theme' "$dir/opencode.json")" = mine ] || fail "a user key was lost"
[ "$(jq -r '.permissions[0].action' "$dir/opencode.json")" = webfetch ] || fail "a user rule must stay first"
[ "$(jq -r '.mcp.servers.mine.command[0]' "$dir/opencode.json")" = true ] || fail "a user MCP server was lost"
grep -Fq '# My notes' "$dir/AGENTS.md" || fail "user instructions were lost"
[ -f "$dir/plugins/mine.js" ] || fail "a user plugin was removed"
run "$home" --runtime=opencode --uninstall
expect_ok "uninstall"
# opencode.json is rewritten as formatted JSON, so it is compared by content and the rest byte for byte.
[ "$(tree "$home" .config | grep -v 'opencode.json$')" = "$(grep -v 'opencode.json$' <<<"$original")" ] || fail "uninstall did not restore the user's files: $(diff <(grep -v 'opencode.json$' <<<"$original") <(tree "$home" .config | grep -v 'opencode.json$') | head -5)"
[ "$(jq -S . "$dir/opencode.json")" = "$(jq -S . <<<"$user_config")" ] || fail "uninstall did not restore opencode.json content"
echo "opencode install probe passed: user files preserved and restored"

# --- a schema-1 manifest from the earlier OpenCode release is adopted -------------------------
home=$(fresh_home legacy)
dir=$(oc "$home")
mkdir -p "$dir/b-agentic" "$dir/skills/b-tablepro" "$dir/plugins"
printf 'old tablepro skill\n' >"$dir/skills/b-tablepro/SKILL.md"
printf '// user plugin\n' >"$dir/plugins/herdr.js"
printf '{"approved":["x"]}\n' >"$dir/b-agentic/codex-approved-repos.json"
old_rule='{"action":"tablepro_query","resource":"*","effect":"allow"}'
digest=$(sha256sum "$dir/skills/b-tablepro/SKILL.md" | cut -d' ' -f1)
jq -n --arg digest "$digest" --argjson rule "$old_rule" '{schema: 1, target: "opencode", files: {"skills/b-tablepro/SKILL.md": $digest}, permissions: [$rule], mcp: {file: "x", servers: {}}}' >"$dir/b-agentic/install.json"
jq -n --argjson rule "$old_rule" '{permissions: [{action: "webfetch", resource: "*", effect: "ask"}, $rule]}' >"$dir/opencode.json"
run "$home" --runtime=opencode -y
expect_ok "adopt the earlier install"
[ ! -e "$dir/skills/b-tablepro/SKILL.md" ] || fail "the retired tablepro skill must be removed"
! jq -e '.permissions[] | select(.action == "tablepro_query")' "$dir/opencode.json" >/dev/null || fail "the retired rule must be removed"
[ "$(jq -r '.permissions[0].action' "$dir/opencode.json")" = webfetch ] || fail "a user rule must stay first"
[ -f "$dir/plugins/herdr.js" ] || fail "a user plugin was removed"
[ -f "$dir/b-agentic/codex-approved-repos.json" ] || fail "the Codex approval file must be left in place"
[ -f "$dir/agents/b-worker.md" ] || fail "the upgrade must install the worker"
echo "opencode install probe passed: earlier install adopted"

# --- an interrupted run never makes a rule the user already had look like ours -----------------
rule='{"action":"shell","resource":"git pull","effect":"deny"}'
key=$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1]), sort_keys=True))' "$rule")
interrupted() { # HOME COPIES: an intent recorded before the write, with COPIES identical rules in the config
  local dir
  dir=$(oc "$1")
  mkdir -p "$dir/b-agentic"
  jq -n --argjson rule "$rule" --arg key "$key" '{schema: 1, target: "opencode", files: {}, permissions: [], mcp: {file: "x", servers: {}}, pending: {permissions: [{rules: [$rule], baseline: {($key): 1}}]}}' >"$dir/b-agentic/install.json"
  jq -n --argjson rule "$rule" --argjson copies "$2" '{permissions: [range($copies) | $rule]}' >"$dir/opencode.json"
}
count_rule() { jq --argjson rule "$rule" '[.permissions[] | select(. == $rule)] | length' "$(oc "$1")/opencode.json"; }
home=$(fresh_home interrupted-uninstall)
interrupted "$home" 1
run "$home" --runtime=opencode --uninstall
expect_ok "uninstall after an interrupted run"
[ "$(count_rule "$home")" = 1 ] || fail "uninstall after an interruption removed a rule the user already had"
home=$(fresh_home interrupted-applied)
interrupted "$home" 2
run "$home" --runtime=opencode --uninstall
expect_ok "uninstall after an interrupted run that wrote"
[ "$(count_rule "$home")" = 1 ] || fail "an applied pending rule must be removed down to the user's copy"
home=$(fresh_home interrupted-retry)
interrupted "$home" 1
run "$home" --runtime=opencode -y
expect_ok "retry after an interrupted run"
run "$home" --runtime=opencode --uninstall
expect_ok "uninstall after the retry"
[ "$(count_rule "$home")" = 1 ] || fail "retry then uninstall removed a rule the user already had"
# An interruption after the config was rewritten but before the manifest changed: the retry must not strip again.
stripped() { # HOME: the config already lost our copy; the user's identical rule remains; the manifest still owns the rule
  local dir
  dir=$(oc "$1")
  mkdir -p "$dir/b-agentic"
  jq -n --argjson rule "$rule" --arg key "$key" '{schema: 1, target: "opencode", files: {}, permissions: [$rule], mcp: {file: "x", servers: {}}, strip: {($key): 1}}' >"$dir/b-agentic/install.json"
  jq -n --argjson rule "$rule" '{permissions: [$rule]}' >"$dir/opencode.json"
}
home=$(fresh_home retried-uninstall)
stripped "$home"
run "$home" --runtime=opencode --uninstall
expect_ok "retried uninstall"
[ "$(count_rule "$home")" = 1 ] || fail "a retried uninstall removed a rule the user already had"
home=$(fresh_home retried-install)
stripped "$home"
run "$home" --runtime=opencode -y
expect_ok "install retried after an interrupted run"
run "$home" --runtime=opencode --uninstall
expect_ok "uninstall after the retried install"
[ "$(count_rule "$home")" = 1 ] || fail "retried install then uninstall removed a rule the user already had"
echo "opencode install probe passed: interrupted runs"

# --- the first OpenCode manifest (no schema) and opencode.jsonc are refused -------------------
home=$(fresh_home first-manifest)
dir=$(oc "$home")
mkdir -p "$dir/b-agentic"
printf '{"suite":"b-agentic","skills":["b-plan"]}\n' >"$dir/b-agentic/install.json"
before=$(tree "$home")
run "$home" --runtime=opencode -y
expect_refused "the first OpenCode manifest must be refused"
[ "$(tree "$home")" = "$before" ] || fail "a refused run changed files"
home=$(fresh_home jsonc)
mkdir -p "$(oc "$home")"
printf '{ // comment\n}\n' >"$(oc "$home")/opencode.jsonc"
run "$home" --runtime=opencode -y
expect_refused "opencode.jsonc must be refused"
grep -Fq 'opencode.jsonc' <<<"$err" || fail "the jsonc refusal must name the file: $err"
echo "opencode install probe passed: refusals"

# --- both installs both runtimes, and a Claude Code run leaves the OpenCode tree alone ---------
home=$(fresh_home both)
run "$home" --runtime=both -y
expect_ok "both"
[ -f "$home/.claude/b-agentic/install.json" ] && [ -f "$(manifest "$home")" ] || fail "both must install both runtimes"
oc_before=$(tree "$home" .config)
run "$home" --runtime=claude -y
expect_ok "claude rerun"
[ "$(tree "$home" .config)" = "$oc_before" ] || fail "a Claude Code run changed the OpenCode tree"
[ ! -e "$home/.pi/agent/b-agentic" ] || fail "a run wrote under ~/.pi"
echo "opencode install probe passed: both runtimes"
echo "opencode install probe passed"
