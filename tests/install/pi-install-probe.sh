#!/usr/bin/env bash
# Exercise tooling/install/pi_install.py (through install.sh --runtime=pi|both) in sandbox HOME
# directories. Needs python3, jq, and node: no network, credentials, Claude Code, or Codex. The
# last case also runs the installed extension in real Pi and is skipped when pi is absent. Every
# scenario owns a private HOME, so nothing outside the throwaway work directory is read or written.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT

fail() { echo "pi install probe failed: $*" >&2; exit 1; }

# fresh_home <name>: a sandbox HOME holding Claude Code files that a Pi run must never change.
fresh_home() {
  local home="$work/$1"
  mkdir -p "$home/.claude/skills/b-plan"
  printf 'claude skill\n' >"$home/.claude/skills/b-plan/SKILL.md"
  printf '{"claude":true}\n' >"$home/.claude/settings.json"
  printf '{"claudeJson":true}\n' >"$home/.claude.json"
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
  out=$(env -u CLAUDE_CONFIG_DIR -u B_AGENTIC_CLAUDE_DIR -u PI_CODING_AGENT_DIR HOME="$home" bash "$root/install.sh" "$@" 2>"$work/stderr") || rc=$?
  err=$(cat "$work/stderr")
}
expect_ok() { [ "$rc" = 0 ] || fail "$1 (exit $rc: $err $out)"; }
expect_refused() { [ "$rc" = 1 ] || fail "$1 (exit $rc, expected 1: $err $out)"; }
agent() { printf '%s/.pi/agent' "$1"; }
manifest() { printf '%s/b-agentic/install.json' "$(agent "$1")"; }
permission_file() { printf '%s/extensions/pi-permission-system/config.json' "$(agent "$1")"; }

# --- dry run writes nothing and names only Pi paths --------------------------------
home=$(fresh_home dry)
before=$(tree "$home")
run "$home" --runtime=pi --dry-run
expect_ok "dry run"
[ "$(tree "$home")" = "$before" ] || fail "a dry run changed files"
[ ! -e "$home/.pi" ] || fail "a dry run created ~/.pi"
! grep -Fq '.claude' <<<"$out$err" || fail "a Pi dry run mentioned a Claude path: $out"
grep -Fq "$home/.pi/agent" <<<"$out" || fail "a Pi dry run must name ~/.pi/agent"
echo "pi install probe passed: dry run"

# --- install, rerun, and the Claude tree stays byte-identical -----------------------
home=$(fresh_home fresh)
claude_before=$(tree "$home" .claude; tree "$home" .claude.json)
run "$home" --runtime=pi -y
expect_ok "install"
agent_dir=$(agent "$home")
[ "$(jq -r .target "$(manifest "$home")")" = pi ] || fail "the manifest must record target pi"
[ "$(jq '.files | length' "$(manifest "$home")")" = 50 ] || fail "expected 50 managed files, got $(jq '.files | length' "$(manifest "$home")")"
for file in skills/b-plan/SKILL.md prompts/b-plan.md agents/b-reviewer.md extensions/b-agentic/index.ts extensions/b-agentic/guard.mjs \
  b-agentic/hooks/b-path-guard.mjs b-agentic/bin/b-state.mjs b-agentic/bin/b_run.py b-agentic/references/artifacts.yaml; do
  [ -f "$agent_dir/$file" ] || fail "missing $file"
done
for absent in b-agentic/hooks/b-codex-guard.mjs b-agentic/bin/b-codex-review.mjs b-agentic/bin/b-statusline.mjs skills/b-datagrip/SKILL.md; do
  [ ! -e "$agent_dir/$absent" ] || fail "$absent must not be installed on Pi"
done
grep -Fq '<!-- b-agentic:start -->' "$agent_dir/AGENTS.md" || fail "the kernel block is missing"
[ "$(jq -r '.packages | length' "$agent_dir/settings.json")" = 3 ] || fail "settings.json must carry the three pins"
jq -e '.packages | all(test("^npm:.+@[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$agent_dir/settings.json" >/dev/null || fail "every package must be pinned exactly"
[ "$(jq -r '.mcpServers.codegraph.exposure' "$agent_dir/mcp.json")" = direct ] || fail "mcp.json must set exposure"
[ "$(jq -r '.yoloMode' "$(permission_file "$home")")" = false ] || fail "yoloMode must be false"
[ "$(jq -r '.permission.subagent' "$(permission_file "$home")")" = allow ] || fail "subagent must be allowed"
[ "$(jq -r '.permission.bash | keys_unsorted | .[0]' "$(permission_file "$home")")" = '*' ] || fail "the bash map must start with the allow-all rule"
cmp -s "$(permission_file "$home")" "$agent_dir/b-agentic/permission.json" || fail "the permission config must equal the shipped copy"
[ "$(tree "$home" .claude; tree "$home" .claude.json)" = "$claude_before" ] || fail "a Pi install changed Claude Code files"
snapshot=$(tree "$home" .pi)
run "$home" --runtime=pi -y
expect_ok "rerun"
[ "$(tree "$home" .pi)" = "$snapshot" ] || fail "a rerun changed files"
grep -Fq '50 unchanged' <<<"$out" || fail "a rerun must report unchanged files: $out"
echo "pi install probe passed: install and rerun"

# --- uninstall removes exactly what was installed ----------------------------------
run "$home" --runtime=pi --uninstall
expect_ok "uninstall"
[ -z "$(tree "$home" .pi)" ] || fail "uninstall left files: $(tree "$home" .pi)"
[ "$(tree "$home" .claude; tree "$home" .claude.json)" = "$claude_before" ] || fail "uninstall changed Claude Code files"
echo "pi install probe passed: uninstall"

# --- user-owned content is merged, never replaced ----------------------------------
home=$(fresh_home merge)
agent_dir=$(agent "$home")
mkdir -p "$agent_dir/extensions/pi-permission-system"
printf '# my notes\n' >"$agent_dir/AGENTS.md"
printf '{"theme":"dark","packages":["npm:pi-subagents@0.80.0","npm:other-pkg@1.0.0"]}\n' >"$agent_dir/settings.json"
printf '{"mcpServers":{"mine":{"command":"mine"},"codegraph":{"command":"custom"}}}\n' >"$agent_dir/mcp.json"
printf '{"yoloMode":true,"permission":{"read":"ask","bash":{"*":"ask","make *":"allow"}}}\n' >"$(permission_file "$home")"
perm_before=$(sha256sum "$(permission_file "$home")")
run "$home" --runtime=pi -y
expect_ok "merge install"
[ "$(head -1 "$agent_dir/AGENTS.md")" = '# my notes' ] || fail "the user's AGENTS.md text must stay first"
[ "$(jq -r .theme "$agent_dir/settings.json")" = dark ] || fail "a user settings key was lost"
jq -e '.packages | index("npm:other-pkg@1.0.0") != null and index("npm:pi-subagents@0.80.0") != null' "$agent_dir/settings.json" >/dev/null || fail "user package entries must be kept"
grep -Fq 'pi-subagents' <<<"$err" || fail "a differing package entry must be reported: $err"
[ "$(jq -r '.mcpServers.mine.command' "$agent_dir/mcp.json")" = mine ] || fail "a user MCP server was lost"
[ "$(jq -r '.mcpServers.codegraph.command' "$agent_dir/mcp.json")" = custom ] || fail "a user MCP server was replaced"
[ "$(sha256sum "$(permission_file "$home")")" = "$perm_before" ] || fail "a user's permission config must not be edited"
grep -Fq 'untouched' <<<"$err" || fail "the untouched permission config must be reported: $err"
[ -f "$agent_dir/b-agentic/permission.json" ] || fail "the generated permission copy must still ship"
run "$home" --runtime=pi -y
expect_ok "merge rerun"
[ "$(sha256sum "$(permission_file "$home")")" = "$perm_before" ] || fail "a rerun edited the user's permission config"
run "$home" --runtime=pi --uninstall
expect_ok "merge uninstall"
[ "$(cat "$agent_dir/AGENTS.md")" = '# my notes' ] || fail "uninstall must restore the user's AGENTS.md"
jq -e '.theme == "dark" and (.packages | sort == ["npm:other-pkg@1.0.0","npm:pi-subagents@0.80.0"])' "$agent_dir/settings.json" >/dev/null || fail "uninstall must keep user settings"
jq -e '.mcpServers | keys == ["codegraph","mine"]' "$agent_dir/mcp.json" >/dev/null || fail "uninstall must keep user MCP servers"
[ "$(sha256sum "$(permission_file "$home")")" = "$perm_before" ] || fail "uninstall edited the user's permission config"
[ ! -e "$agent_dir/b-agentic/permission.json" ] || fail "uninstall must remove the permission copy"
echo "pi install probe passed: merge and uninstall"

# --- a user's own permission config is never edited, whatever it holds -----------------
for user_config in '{"permission":{"*":"deny"}}' '{"permission":{"*":"ask","read":"allow"}}' '{"permission":{"mcp":"deny"}}' \
  '{"permission":{"mcp":{"*":"deny","codegraph_explore":"allow"}}}' '{"permission":{"bash":"ask"}}' '{"permission":{"path":{"*.example":"deny"}}}'; do
  home=$(fresh_home own-permission)
  agent_dir=$(agent "$home")
  mkdir -p "$agent_dir/extensions/pi-permission-system"
  printf '%s\n' "$user_config" >"$(permission_file "$home")"
  perm_before=$(sha256sum "$(permission_file "$home")")
  run "$home" --runtime=pi -y
  expect_ok "install beside $user_config"
  [ "$(sha256sum "$(permission_file "$home")")" = "$perm_before" ] || fail "install edited $user_config"
  run "$home" --runtime=pi -y
  expect_ok "rerun beside $user_config"
  [ "$(sha256sum "$(permission_file "$home")")" = "$perm_before" ] || fail "a rerun edited $user_config"
  run "$home" --runtime=pi --uninstall
  expect_ok "uninstall beside $user_config"
  [ "$(sha256sum "$(permission_file "$home")")" = "$perm_before" ] || fail "uninstall edited $user_config"
  rm -r "$home"
done
echo "pi install probe passed: user permission config untouched"

# --- refusals happen before the first write -----------------------------------------
home=$(fresh_home bad-json)
mkdir -p "$(agent "$home")"
printf '{not json' >"$(agent "$home")/settings.json"
before=$(tree "$home")
run "$home" --runtime=pi -y
expect_refused "malformed settings.json"
[ "$(tree "$home")" = "$before" ] || fail "a refused install wrote files"
home=$(fresh_home other-dir)
before=$(tree "$home")
rc=0
out=$(env -u CLAUDE_CONFIG_DIR HOME="$home" PI_CODING_AGENT_DIR="$work/elsewhere" bash "$root/install.sh" --runtime=pi -y 2>"$work/stderr") || rc=$?
err=$(cat "$work/stderr")
expect_refused "another PI_CODING_AGENT_DIR"
grep -Fq 'PI_CODING_AGENT_DIR' <<<"$err" || fail "the refusal must name PI_CODING_AGENT_DIR: $err"
[ "$(tree "$home")" = "$before" ] || fail "a refused install wrote files"
home=$(fresh_home shadow)
mkdir -p "$(agent "$home")"
printf '# claude style\n' >"$(agent "$home")/CLAUDE.md"
before=$(tree "$home")
run "$home" --runtime=pi -y
expect_refused "a CLAUDE.md that a new AGENTS.md would hide"
grep -Fq 'CLAUDE.md' <<<"$err" || fail "the refusal must name CLAUDE.md: $err"
[ "$(tree "$home")" = "$before" ] || fail "a refused install wrote files"
home=$(fresh_home symlink)
mkdir -p "$(agent "$home")" "$work/real-skills"
ln -s "$work/real-skills" "$(agent "$home")/skills"
run "$home" --runtime=pi -y
expect_refused "a symlinked skills directory"
[ -z "$(find "$work/real-skills" -type f)" ] || fail "an install wrote through a symlinked directory"
run "$home" --runtime=bogus -y
expect_refused "an unknown runtime"
run "$home" --runtime=pi --statusline-only
expect_refused "--statusline-only with --runtime=pi"
echo "pi install probe passed: refusals"

# --- modified managed files are kept unless forced -----------------------------------
home=$(fresh_home modified)
agent_dir=$(agent "$home")
run "$home" --runtime=pi -y
expect_ok "install"
printf 'edited\n' >>"$agent_dir/agents/b-reviewer.md"
printf '{"permission":{"read":"deny"}}\n' >"$(permission_file "$home")"
run "$home" --runtime=pi -y
expect_ok "reinstall over an edited file"
grep -Fq '"read": "deny"' "$(permission_file "$home")" || grep -Fq '"read":"deny"' "$(permission_file "$home")" || fail "an edited permission config must be kept"
tail -1 "$agent_dir/agents/b-reviewer.md" | grep -Fq edited || fail "an edited managed file must be kept"
grep -Fq 'modified since install' <<<"$err" || fail "the kept file must be reported: $err"
run "$home" --runtime=pi -y --force
expect_ok "forced reinstall"
! grep -Fq edited "$agent_dir/agents/b-reviewer.md" || fail "--force must replace the edited file"
cmp -s "$(permission_file "$home")" "$agent_dir/b-agentic/permission.json" || fail "--force must replace the edited permission config"
[ -n "$(find "$agent_dir/b-agentic/backups" -type f -name '*config.json')" ] || fail "--force must back the permission config up"
[ -n "$(find "$agent_dir/b-agentic/backups" -type f -name '*b-reviewer*')" ] || fail "--force must back the file up"
echo "pi install probe passed: modified files"

# --- optional components --------------------------------------------------------------
home=$(fresh_home optional)
agent_dir=$(agent "$home")
run "$home" --runtime=pi -y --with=excalidraw
expect_ok "install with excalidraw"
[ -f "$agent_dir/skills/b-excalidraw/SKILL.md" ] || fail "--with=excalidraw must install the skill"
jq -e '.mcpServers.excalidraw' "$agent_dir/mcp.json" >/dev/null || fail "--with=excalidraw must add the server"
jq -e '.permission.mcp | has("mcp__excalidraw__create_view")' "$(permission_file "$home")" >/dev/null || fail "--with=excalidraw must add its permission rule"
run "$home" --runtime=pi -y --without=excalidraw
expect_ok "removing excalidraw"
[ ! -e "$agent_dir/skills/b-excalidraw/SKILL.md" ] || fail "--without=excalidraw must remove the skill"
! jq -e '.mcpServers.excalidraw' "$agent_dir/mcp.json" >/dev/null || fail "--without=excalidraw must remove the server"
! jq -e '.permission.mcp | has("mcp__excalidraw__create_view")' "$(permission_file "$home")" >/dev/null || fail "--without=excalidraw must remove its permission rule"
echo "pi install probe passed: optional components"

# --- old skills in ~/.agents/skills are reported, never touched ----------------------
home=$(fresh_home foreign)
mkdir -p "$home/.agents/skills/b-plan"
printf 'old\n' >"$home/.agents/skills/b-plan/SKILL.md"
run "$home" --runtime=pi -y
expect_ok "install beside old skills"
grep -Fq '.agents/skills' <<<"$err" || fail "old b-* skills must be reported: $err"
[ "$(cat "$home/.agents/skills/b-plan/SKILL.md")" = old ] || fail "an old skill was touched"
echo "pi install probe passed: foreign skills"

# --- both runtimes -------------------------------------------------------------------
home=$(fresh_home both)
run "$home" --runtime=both -y
expect_ok "install both"
[ -f "$home/.claude/b-agentic/install.json" ] && [ -f "$(manifest "$home")" ] || fail "--runtime=both must install both runtimes"
claude_tree=$(tree "$home" .claude)
run "$home" --runtime=pi --uninstall
expect_ok "uninstall pi only"
[ "$(tree "$home" .claude)" = "$claude_tree" ] || fail "uninstalling Pi changed Claude Code files"
[ ! -e "$(manifest "$home")" ] || fail "Pi uninstall left its manifest"
pi_tree=$(tree "$home" .pi)
run "$home" --runtime=pi -y
expect_ok "reinstall pi"
pi_tree=$(tree "$home" .pi)
run "$home" --uninstall
expect_ok "default uninstall (Claude Code only)"
[ "$(tree "$home" .pi)" = "$pi_tree" ] || fail "a Claude Code uninstall changed Pi files"
[ ! -e "$home/.claude/b-agentic/install.json" ] || fail "the Claude Code uninstall left its manifest"
run "$home" --runtime=both --uninstall
expect_ok "uninstall both"
[ -z "$(tree "$home" .pi)" ] || fail "uninstall both left Pi files"
home=$(fresh_home both-refused)
mkdir -p "$(agent "$home")"
printf '{not json' >"$(agent "$home")/settings.json"
before=$(tree "$home")
run "$home" --runtime=both -y
expect_refused "both with a malformed Pi file"
[ "$(tree "$home")" = "$before" ] || fail "a refused --runtime=both wrote files (Claude Code half installed)"
echo "pi install probe passed: both runtimes"

# --- the installed extension in real Pi -----------------------------------------------
if command -v pi >/dev/null 2>&1; then
  home=$(fresh_home live)
  run "$home" --runtime=pi -y
  expect_ok "install for the live run"
  mkdir -p "$work/live-cwd"
  printf 'SECRET=1\n' >"$work/live-cwd/.env"
  live_rc=0
  # Pi now and then stalls at startup on a cold cache (exit 124 from timeout); retry, and skip the case rather
  # than fail when it never starts, since a stall says nothing about the installed layout.
  for _ in 1 2 3; do
    live_rc=0
    ( cd "$work/live-cwd" && env HOME="$home" PI_CODING_AGENT_DIR="$(agent "$home")" PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0 \
        PI_PROBE_STEPS='[{"name":"read","arguments":{"path":".env"}},"text"]' PI_PROBE_LOG="$work/live.log" timeout 45 pi \
        -e "$root/tests/pi/stub-provider.ts" --model probe/probe-1 --mode json --no-session --no-mcp go >"$work/live.jsonl" 2>"$work/live.err" ) || live_rc=$?
    [ "$live_rc" = 0 ] && break
    [ "$live_rc" = 124 ] || fail "pi exited $live_rc: $(head -c 300 "$work/live.err")"
  done
  if [ "$live_rc" = 124 ]; then
    echo "pi install probe skipped: installed extension in Pi (pi did not start within 45s three times)"
  else
    jq -rs '[.[] | select(.type == "tool_execution_end" and .toolName == "read")][0] | .result.content[0].text' "$work/live.jsonl" | grep -Fq 'likely-secret path' \
      || fail "the installed extension did not guard .env in Pi"
    echo "pi install probe passed: installed extension in Pi"
  fi
else
  echo "pi install probe skipped: installed extension in Pi (pi is not installed)"
fi

echo "Pi install probe passed."
