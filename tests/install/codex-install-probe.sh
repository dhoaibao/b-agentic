#!/usr/bin/env bash
# Exercise tooling/install/codex_install.py (through install.sh) in sandbox HOME directories. Needs
# only python3 and jq: no network, credentials, Claude Code, or Codex. Every scenario owns a private
# HOME, so nothing outside the throwaway work directory is read or written.
# shellcheck disable=SC2016 # The single-quoted setup commands expand $home and $work when eval runs them.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT

fail() { echo "codex install probe failed: $*" >&2; exit 1; }

# fresh_home <name>: a sandbox HOME with a frozen Pi tree and a Claude Code tree that must never change.
fresh_home() {
  local home="$work/$1"
  mkdir -p "$home/.pi/agent/skills/b-plan" "$home/.claude"
  printf 'frozen pi skill\n' >"$home/.pi/agent/skills/b-plan/SKILL.md"
  printf '{"permissions":{"allow":["Read"]}}\n' >"$home/.claude/settings.json"
  printf '# my claude rules\n' >"$home/.claude/CLAUDE.md"
  printf '%s' "$home"
}
# tree <dir> [pattern]: sorted `sha256  relative-path` list of regular files and symlinks, minus backups.
tree() {
  # shellcheck disable=SC2016 # The inner script runs in sh and expands its own variables.
  ( cd "$1" && find . \( -type f -o -type l \) -not -path './.codex/b-agentic/backups/*' -print0 \
      | sort -z | xargs -0 -r sh -c 'for f; do if [ -L "$f" ]; then printf "link %s -> %s\n" "$f" "$(readlink "$f")"; else printf "%s  %s\n" "$(sha256sum "$f" | cut -d" " -f1)" "$f"; fi; done' _ )
}
out="" err="" rc=0
run() {
  local home=$1
  shift
  rc=0
  out=$(env -u CODEX_HOME -u CLAUDE_CONFIG_DIR -u B_AGENTIC_CLAUDE_DIR -u B_AGENTIC_CLICKUP_MCP HOME="$home" bash "$root/install.sh" "$@" 2>"$work/stderr") || rc=$?
  err=$(cat "$work/stderr")
}
runenv() {
  local home=$1 assignment=$2
  shift 2
  rc=0
  out=$(env -u CODEX_HOME -u CLAUDE_CONFIG_DIR -u B_AGENTIC_CLAUDE_DIR HOME="$home" "$assignment" bash "$root/install.sh" "$@" 2>"$work/stderr") || rc=$?
  err=$(cat "$work/stderr")
}
expect_ok() { [ "$rc" = 0 ] || fail "$1 (exit $rc: $err $out)"; }
expect_refused() { [ "$rc" = 1 ] || fail "$1 (exit $rc, expected 1: $err $out)"; }
same_tree() { [ "$(tree "$1")" = "$2" ] || fail "$3"; }

# --- fresh install, idempotence, and an untouched Claude tree --------------------------------
home=$(fresh_home fresh)
claude_before=$(tree "$home/.claude")
pi_before=$(tree "$home/.pi")
run "$home" --runtime=codex -y; expect_ok "fresh codex install"
for path in .agents/skills/b-plan/SKILL.md .codex/agents/b-reviewer.toml .codex/rules/b-agentic.rules \
  .codex/b-agentic/hooks/b-codex-hooks.mjs .codex/b-agentic/hooks/b-verify-gate.mjs \
  .codex/b-agentic/bin/b-candidate-snapshot.mjs .codex/b-agentic/references/specialist-tools.json \
  .codex/b-agentic/references/kernel.md .codex/b-agentic/install.json .codex/AGENTS.md .codex/hooks.json .codex/config.toml; do
  [ -f "$home/$path" ] || fail "missing $path after install"
done
[ "$(tree "$home/.claude")" = "$claude_before" ] || fail "the Codex install changed ~/.claude"
[ "$(tree "$home/.pi")" = "$pi_before" ] || fail "the Codex install changed ~/.pi"
grep -Fq 'Codex Workflow Kernel' "$home/.codex/AGENTS.md" || fail "kernel block missing from AGENTS.md"
grep -Fq '[mcp_servers.codegraph]' "$home/.codex/config.toml" || fail "managed MCP servers missing from config.toml"
python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$home/.codex/config.toml" || fail "config.toml is not valid TOML"
jq -e '.hooks.PreToolUse and .hooks.PostToolUse and .hooks.Stop' "$home/.codex/hooks.json" >/dev/null || fail "hooks.json lacks the managed events"
grep -Fq "$home/.codex/b-agentic/hooks/b-codex-hooks.mjs" "$home/.codex/hooks.json" || fail "hook commands must use the absolute installed path"
! grep -Fq 'sandbox_mode' "$home/.codex/config.toml" || fail "the installer must not write sandbox_mode"
! grep -Fq 'approval_policy' "$home/.codex/config.toml" || fail "the installer must not write approval_policy"
! grep -Fq 'clickup' "$home/.codex/config.toml" || fail "ClickUp must be opt-in"
first=$(tree "$home")
run "$home" --runtime=codex -y; expect_ok "second codex install"
same_tree "$home" "$first" "an unchanged re-run must write nothing"
run "$home" --runtime=codex -y --with-clickup; expect_ok "enable ClickUp"
grep -Fq '[mcp_servers.clickup]' "$home/.codex/config.toml" || fail "ClickUp table missing after opt-in"
run "$home" --runtime=codex -y --without-clickup; expect_ok "disable ClickUp"
! grep -Fq '[mcp_servers.clickup]' "$home/.codex/config.toml" || fail "ClickUp table must go after opting out"
run "$home" --runtime=codex --uninstall; expect_ok "uninstall"
[ ! -e "$home/.codex/AGENTS.md" ] || fail "an AGENTS.md this install created must be removed"
[ ! -e "$home/.codex/hooks.json" ] || fail "a hooks.json this install created must be removed"
[ ! -e "$home/.codex/config.toml" ] || fail "a config.toml this install created must be removed"
[ ! -e "$home/.agents/skills/b-plan" ] || fail "uninstall left a skill behind"
[ "$(tree "$home/.claude")" = "$claude_before" ] || fail "the uninstall changed ~/.claude"
echo "codex install probe passed: fresh"

# --- user content survives install and uninstall ------------------------------------------------
home=$(fresh_home merge)
mkdir -p "$home/.codex" "$home/.agents/skills/mine"
printf 'model = "example"\n\n[mcp_servers.context7]\nurl = "https://example.invalid/mcp"\n' >"$home/.codex/config.toml"
printf '# my codex rules\nBe kind.\n' >"$home/.codex/AGENTS.md"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/true"}]}]}}\n' >"$home/.codex/hooks.json"
printf 'my skill\n' >"$home/.agents/skills/mine/SKILL.md"
cp "$home/.codex/config.toml" "$work/config.before"
cp "$home/.codex/AGENTS.md" "$work/agents.before"
run "$home" --runtime=codex -y; expect_ok "install over user files"
grep -Fq "kept your MCP server 'context7'" <<<"$err" || fail "a colliding user MCP server must be reported"
[ "$(grep -c '^\[mcp_servers.context7\]$' "$home/.codex/config.toml")" = 1 ] || fail "the user's context7 table must stay the only one"
grep -Fq 'model = "example"' "$home/.codex/config.toml" || fail "user config keys must survive"
grep -Fq 'Be kind.' "$home/.codex/AGENTS.md" || fail "user AGENTS.md text must survive"
[ "$(jq '.hooks.Stop | length' "$home/.codex/hooks.json")" = 2 ] || fail "the user's Stop hook must stay beside the managed one"
[ "$(cat "$home/.agents/skills/mine/SKILL.md")" = "my skill" ] || fail "an unrelated user skill changed"
run "$home" --runtime=codex --uninstall; expect_ok "uninstall over user files"
cmp -s "$home/.codex/config.toml" "$work/config.before" || fail "uninstall must restore config.toml byte for byte"
cmp -s "$home/.codex/AGENTS.md" "$work/agents.before" || fail "uninstall must restore AGENTS.md byte for byte"
[ "$(jq -c . "$home/.codex/hooks.json")" = '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/true"}]}]}}' ] || fail "uninstall must leave only the user's hook"
[ "$(cat "$home/.agents/skills/mine/SKILL.md")" = "my skill" ] || fail "uninstall removed a user skill"
echo "codex install probe passed: merge"

# --- Codex rewrites config.toml itself: managed servers are owned by name and value, not by position -----
# servers <file>: the managed server names left in a config file.
servers() { python3 -c 'import sys,tomllib; print(" ".join(sorted(tomllib.load(open(sys.argv[1],"rb")).get("mcp_servers",{}))))' "$1"; }
home=$(fresh_home codex-writes)
run "$home" --runtime=codex -y; expect_ok "install"
# What `codex features enable` and the /hooks trust prompt append: tables after the managed servers.
printf '\n[features]\nhooks = true\n\n[hooks.state."x"]\ntrusted_hash = "sha256:abc"\n\n[projects."/tmp/p"]\ntrust_level = "trusted"\n' >>"$home/.codex/config.toml"
run "$home" --runtime=codex -y; expect_ok "re-install after Codex wrote its own tables"
! grep -Fq 'kept' <<<"$err" || fail "Codex's own tables must not make managed servers look modified: $err"
run "$home" --runtime=codex -y --force; expect_ok "force after Codex wrote its own tables"
grep -Fq 'hooks = true' "$home/.codex/config.toml" || fail "--force must not delete tables Codex wrote"
run "$home" --runtime=codex --uninstall; expect_ok "uninstall after Codex wrote its own tables"
[ "$(servers "$home/.codex/config.toml")" = "" ] || fail "uninstall left managed servers behind: $(servers "$home/.codex/config.toml")"
for fragment in '[features]' 'hooks = true' '[hooks.state."x"]' 'trusted_hash = "sha256:abc"' '[projects."/tmp/p"]'; do
  grep -Fq "$fragment" "$home/.codex/config.toml" || fail "uninstall removed a table Codex wrote: $fragment"
done
echo "codex install probe passed: codex-writes"
# What `codex mcp add` does: re-serializes the whole mcp_servers table in its own order and adds a server.
home=$(fresh_home codex-mcp-add)
run "$home" --runtime=codex -y; expect_ok "install"
python3 - "$home/.codex/config.toml" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
tables = [t for t in re.split(r"(?m)^(?=\[)", text) if t.strip()]
open(sys.argv[1], "w").write("".join(reversed(tables)) + '\n[mcp_servers.myserver]\ncommand = "echo"\nargs = ["hi"]\n')
PY
run "$home" --runtime=codex -y; expect_ok "re-install after the tables were reordered"
! grep -Fq 'kept' <<<"$err" || fail "reordered tables must still be recognized as managed: $err"
run "$home" --runtime=codex --uninstall; expect_ok "uninstall after the tables were reordered"
[ "$(servers "$home/.codex/config.toml")" = "myserver" ] || fail "uninstall must leave only the user's server: $(servers "$home/.codex/config.toml")"
echo "codex install probe passed: codex-mcp-add"
# A partial override of a managed server makes it the user's: kept on re-install and uninstall.
home=$(fresh_home partial-override)
run "$home" --runtime=codex -y; expect_ok "install"
python3 - "$home/.codex/config.toml" <<'PY'
import sys
text = open(sys.argv[1]).read()
old = '[mcp_servers.context7.tools.query-docs]\napproval_mode = "approve"'
assert old in text
open(sys.argv[1], "w").write(text.replace(old, old.replace("approve", "prompt")))
PY
run "$home" --runtime=codex -y; expect_ok "re-install with a user override"
grep -Fq "kept your MCP server 'context7'" <<<"$err" || fail "a modified managed server must be reported: $err"
run "$home" --runtime=codex --uninstall; expect_ok "uninstall with a user override"
grep -Fq 'https://mcp.context7.com/mcp' "$home/.codex/config.toml" || fail "a user-modified managed server must survive uninstall"
echo "codex install probe passed: partial-override"

# --- user comments and tables around the managed servers are never swallowed -----------------------
home=$(fresh_home comments)
mkdir -p "$home/.codex"
printf 'model = "m"\n' >"$home/.codex/config.toml"
run "$home" --runtime=codex -y --with-clickup; expect_ok "install with ClickUp"
printf '\n# --- my profiles (keep) ---\n[profiles.work]\nmodel = "o3"\n\n# trailing note (keep)\n' >>"$home/.codex/config.toml"
run "$home" --runtime=codex -y --without-clickup; expect_ok "drop ClickUp beside user comments"
[ -z "$err" ] || fail "retiring ClickUp beside user comments must be silent: $err"
grep -Fq '# --- my profiles (keep) ---' "$home/.codex/config.toml" || fail "retiring a server deleted the comment after it"
grep -Fq '# trailing note (keep)' "$home/.codex/config.toml" || fail "retiring a server deleted a trailing comment"
run "$home" --runtime=codex --uninstall; expect_ok "uninstall beside user comments"
for fragment in 'model = "m"' '# --- my profiles (keep) ---' '[profiles.work]' 'model = "o3"' '# trailing note (keep)'; do
  grep -Fq "$fragment" "$home/.codex/config.toml" || fail "uninstall deleted user text: $fragment"
done
[ "$(servers "$home/.codex/config.toml")" = "" ] || fail "uninstall left managed servers behind"
# A config.toml the install created, then given a comment, must survive uninstall.
home=$(fresh_home created-comment)
run "$home" --runtime=codex -y; expect_ok "install into a missing config.toml"
printf '# remember: add profiles later\n' >>"$home/.codex/config.toml"
run "$home" --runtime=codex --uninstall; expect_ok "uninstall a created config.toml with a user comment"
[ "$(cat "$home/.codex/config.toml")" = "# remember: add profiles later" ] || fail "the user's comment must survive in a created config.toml"
echo "codex install probe passed: comments"

# --- ownership: edits are kept, --force replaces after a backup -------------------------------
home=$(fresh_home own)
run "$home" --runtime=codex -y; expect_ok "install"
printf '\n# my edit\n' >>"$home/.codex/agents/b-planner.toml"
run "$home" --runtime=codex -y; expect_ok "re-run with an edited agent"
grep -Fq 'my edit' "$home/.codex/agents/b-planner.toml" || fail "an edited managed file must be kept"
grep -Fq 'kept' <<<"$err" || fail "a kept file must be reported"
run "$home" --runtime=codex -y --force; expect_ok "force"
! grep -Fq 'my edit' "$home/.codex/agents/b-planner.toml" || fail "--force must replace the edited file"
[ -n "$(find "$home/.codex/b-agentic/backups" -name '*b-planner.toml' 2>/dev/null)" ] || fail "--force must back up the replaced file"
echo "codex install probe passed: ownership"

# --- dry run -------------------------------------------------------------------------------------
home=$(fresh_home dry)
before=$(tree "$home")
run "$home" --runtime=codex --dry-run; expect_ok "dry run"
same_tree "$home" "$before" "--dry-run must change nothing"
echo "codex install probe passed: dry-run"

# --- refusals happen before the first write ---------------------------------------------------
refuses() { # <name> <setup command> <expected message fragment>
  local home
  home=$(fresh_home "$1")
  mkdir -p "$home/.codex"
  eval "$2"
  local before
  before=$(tree "$home")
  run "$home" --runtime=codex -y; expect_refused "$1 must be refused"
  grep -Fq "$3" <<<"$err" || fail "$1: expected '$3' in: $err"
  same_tree "$home" "$before" "$1: a refused install must write nothing"
}
refuses invalid-toml 'printf "not = [valid\n" >"$home/.codex/config.toml"' 'not valid TOML'
refuses invalid-hooks 'printf "{nope\n" >"$home/.codex/hooks.json"' 'not valid JSON'
refuses duplicate-kernel-markers 'printf "<!-- b-agentic:start -->\n<!-- b-agentic:start -->\n<!-- b-agentic:end -->\n" >"$home/.codex/AGENTS.md"' 'markers'
refuses symlinked-managed-dir 'mkdir -p "$work/elsewhere"; ln -s "$work/elsewhere" "$home/.codex/agents"' 'symlink'
refuses into-claude-tree 'ln -s "$home/.claude" "$home/.codex/b-agentic"' 'symlink'
home=$(fresh_home codex-home)
runenv "$home" "CODEX_HOME=$work/elsewhere" --runtime=codex -y; expect_refused "a custom CODEX_HOME must be refused"
grep -Fq 'CODEX_HOME' <<<"$err" || fail "the CODEX_HOME refusal must name the variable"
[ ! -e "$home/.codex" ] || fail "a refused CODEX_HOME run must not create ~/.codex"
echo "codex install probe passed: refusals"

# --- both runtimes leave each other alone ---------------------------------------------------------
home=$(fresh_home both)
run "$home" --runtime=both -y; expect_ok "install both"
[ -f "$home/.claude/b-agentic/install.json" ] && [ -f "$home/.codex/b-agentic/install.json" ] || fail "both manifests must exist"
claude_tree=$(tree "$home/.claude")
run "$home" --runtime=codex --uninstall; expect_ok "uninstall codex only"
[ "$(tree "$home/.claude")" = "$claude_tree" ] || fail "uninstalling Codex changed ~/.claude"
[ ! -e "$home/.codex/b-agentic/install.json" ] || fail "the Codex manifest must be gone"
codex_state=$(tree "$home/.codex")
run "$home" --runtime=claude --uninstall; expect_ok "uninstall claude"
[ "$(tree "$home/.codex")" = "$codex_state" ] || fail "uninstalling Claude changed ~/.codex"
echo "codex install probe passed: both"

# --- the removed and unknown runtimes ---------------------------------------------------------------
home=$(fresh_home flags)
before=$(tree "$home")
run "$home" --runtime=opencode -y; expect_refused "--runtime=opencode must be refused"
grep -Fq 'ADR-004' <<<"$err" || fail "the opencode refusal must point to ADR-004"
run "$home" --runtime=nonsense -y; expect_refused "an unknown runtime must be refused"
run "$home" --runtime= -y; expect_refused "an empty runtime must be refused"
run "$home" --migrate-legacy -y; expect_refused "--migrate-legacy is gone"
same_tree "$home" "$before" "a refused flag must write nothing"
echo "codex install probe passed: flags"
