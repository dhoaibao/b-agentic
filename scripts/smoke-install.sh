#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d /tmp/b-skills-smoke.XXXXXX)"

cleanup() {
  rm -rf "$WORK_DIR"
}

trap cleanup EXIT

fail() {
  printf 'smoke-install.sh: %s\n' "$*" >&2
  exit 1
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || fail "required binary not found: $1"
}

assert_file() {
  local path="$1"
  [ -f "$path" ] || fail "expected file: $path"
}

assert_no_file() {
  local path="$1"
  [ ! -e "$path" ] || fail "unexpected file: $path"
}

assert_executable() {
  local path="$1"
  [ -x "$path" ] || fail "expected executable file: $path"
}

assert_contains() {
  local path="$1" needle="$2"
  grep -Fq "$needle" "$path" || fail "expected '$needle' in $path"
}

assert_not_contains() {
  local path="$1" needle="$2"
  ! grep -Fq "$needle" "$path" || fail "did not expect '$needle' in $path"
}

assert_equal_files() {
  local left="$1" right="$2"
  cmp -s "$left" "$right" || fail "expected files to match: $left vs $right"
}

assert_text_equals() {
  local path="$1" expected="$2"
  local expected_file
  expected_file="$(mktemp)"
  printf '%s' "$expected" > "$expected_file"
  cmp -s "$path" "$expected_file" || fail "unexpected content in $path"
  rm -f "$expected_file"
}

write_mixed_hook_settings() {
  local path="$1"
  cat > "$path" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "custom-hook.sh", "timeout": 7 },
          { "type": "command", "command": "python3 ${HOME}/.claude/hooks/b-skills-guard.py", "timeout": 5 }
        ]
      }
    ]
  },
  "permissions": {
    "ask": ["Bash(custom *)", "Bash(git commit*)"],
    "deny": ["Bash(custom-deny *)"]
  },
  "env": {
    "USER_ENV": "keep"
  }
}
JSON
}

assert_hook_decision() {
  local hook_path="$1" command_text="$2" expected_decision="$3" output
  output="$(COMMAND_TEXT="$command_text" python3 - <<'PY' | python3 "$hook_path"
import json
import os

print(json.dumps({"hook_event_name": "PreToolUse", "tool_input": {"command": os.environ["COMMAND_TEXT"]}}))
PY
)"
  [[ "$output" == *"\"permissionDecision\": \"$expected_decision\""* ]] || fail "expected hook decision $expected_decision for command: $command_text"
}

make_repo_snapshot() {
  local snapshot_dir="$1"
  mkdir -p "$snapshot_dir"
  cp -R "$ROOT_DIR"/. "$snapshot_dir"/
  rm -rf "$snapshot_dir/.git" "$snapshot_dir/.opencode" "$snapshot_dir/.serena"
  git -C "$snapshot_dir" init -q
  git -C "$snapshot_dir" add .
  git -C "$snapshot_dir" -c user.name='b-skills smoke' -c user.email='smoke@example.com' commit -qm 'snapshot'
}

run_install_status() {
  local sandbox="$1" repo_snapshot="$2" install_mcp="$3"
  shift 3
  local rc=0
  set +e
  HOME="$sandbox/home" \
  B_SKILLS_REPO="$repo_snapshot" \
  B_SKILLS_DIR="$sandbox/source" \
  B_SKILLS_INSTALL_MCP="$install_mcp" \
  B_SKILLS_INSTALL_GITNEXUS=N \
  BRAVE_API_KEY=brave-key \
  CONTEXT7_API_KEY=context7-key \
  FIRECRAWL_API_KEY=firecrawl-key \
  bash "$ROOT_DIR/install.sh" "$@" >/dev/null 2>&1
  rc=$?
  set -e
  printf '%s' "$rc"
}

run_install_output() {
  local sandbox="$1" repo_snapshot="$2" install_mcp="$3"
  shift 3
  HOME="$sandbox/home" \
  B_SKILLS_REPO="$repo_snapshot" \
  B_SKILLS_DIR="$sandbox/source" \
  B_SKILLS_INSTALL_MCP="$install_mcp" \
  B_SKILLS_INSTALL_GITNEXUS=N \
  BRAVE_API_KEY=brave-key \
  CONTEXT7_API_KEY=context7-key \
  FIRECRAWL_API_KEY=firecrawl-key \
  bash "$ROOT_DIR/install.sh" "$@"
}

expect_install_status() {
  local expected="$1" sandbox="$2" repo_snapshot="$3" install_mcp="$4"
  shift 4
  local rc
  rc="$(run_install_status "$sandbox" "$repo_snapshot" "$install_mcp" "$@")"
  [ "$rc" -eq "$expected" ] || fail "expected install exit $expected, got $rc"
}

main() {
  local snapshot_repo="$WORK_DIR/repo-snapshot"
  local sandbox_fresh="$WORK_DIR/fresh"
  local sandbox_preserve="$WORK_DIR/preserve"
  local sandbox_replace="$WORK_DIR/replace"
  local sandbox_dry_run="$WORK_DIR/dry-run"
  local sandbox_conflict_skill="$WORK_DIR/conflict-skill"
  local sandbox_conflict_agent="$WORK_DIR/conflict-agent"
  local sandbox_conflict_hook="$WORK_DIR/conflict-hook"
  local sandbox_uninstall="$WORK_DIR/uninstall"
  local sandbox_uninstall_modified="$WORK_DIR/uninstall-modified"
  local sandbox_uninstall_custom="$WORK_DIR/uninstall-custom"
  local sandbox_mcp_existing="$WORK_DIR/mcp-existing"

  require_bin git
  make_repo_snapshot "$snapshot_repo"

  mkdir -p "$sandbox_fresh/home"
  expect_install_status 0 "$sandbox_fresh" "$snapshot_repo" N
  assert_file "$sandbox_fresh/home/.claude/skills/b-plan/SKILL.md"
  assert_file "$sandbox_fresh/home/.claude/skills/b-review/reference.md"
  assert_file "$sandbox_fresh/home/.claude/skills/b-test/reference.md"
  assert_file "$sandbox_fresh/home/.claude/agents/b-plan-agent.md"
  assert_file "$sandbox_fresh/home/.claude/agents/b-research-agent.md"
  assert_file "$sandbox_fresh/home/.claude/agents/b-review-agent.md"
  assert_file "$sandbox_fresh/home/.claude/agents/b-audit-agent.md"
  assert_file "$sandbox_fresh/home/.claude/hooks/b-skills-guard.py"
  assert_executable "$sandbox_fresh/home/.claude/hooks/b-skills-guard.py"
  assert_file "$sandbox_fresh/home/.claude/references/b-skills/runtime-contract.md"
  assert_file "$sandbox_fresh/home/.claude/CLAUDE.md"
  assert_equal_files "$sandbox_fresh/home/.claude/CLAUDE.md" "$snapshot_repo/global/CLAUDE.md"
  assert_file "$sandbox_fresh/home/.claude/b-skills/CLAUDE.md"
  assert_equal_files "$sandbox_fresh/home/.claude/b-skills/CLAUDE.md" "$snapshot_repo/global/CLAUDE.md"
  assert_file "$sandbox_fresh/home/.claude/b-skills/b-skills.settings.json"
  assert_file "$sandbox_fresh/home/.claude/settings.json"
  assert_contains "$sandbox_fresh/home/.claude/settings.json" 'b-skills-guard.py'
  assert_contains "$sandbox_fresh/home/.claude/settings.json" '"PreToolUse"'
  assert_hook_decision "$sandbox_fresh/home/.claude/hooks/b-skills-guard.py" 'rm -r /' deny
  assert_hook_decision "$sandbox_fresh/home/.claude/hooks/b-skills-guard.py" 'rm -rf /*' deny
  assert_hook_decision "$sandbox_fresh/home/.claude/hooks/b-skills-guard.py" 'rm -rf /.*' deny
  assert_hook_decision "$sandbox_fresh/home/.claude/hooks/b-skills-guard.py" '/bin/rm -rf /' deny
  assert_hook_decision "$sandbox_fresh/home/.claude/hooks/b-skills-guard.py" 'command rm -rf /' deny
  assert_hook_decision "$sandbox_fresh/home/.claude/hooks/b-skills-guard.py" 'rm -R ~/' deny
  assert_hook_decision "$sandbox_fresh/home/.claude/hooks/b-skills-guard.py" 'rm -r "$HOME"' deny
  assert_hook_decision "$sandbox_fresh/home/.claude/hooks/b-skills-guard.py" 'rm -rf "$HOME"' deny
  assert_hook_decision "$sandbox_fresh/home/.claude/hooks/b-skills-guard.py" 'rm -rf ${HOME}' deny
  assert_hook_decision "$sandbox_fresh/home/.claude/hooks/b-skills-guard.py" 'rm -rf ${HOME:?}' deny
  assert_hook_decision "$sandbox_fresh/home/.claude/hooks/b-skills-guard.py" 'rm -rf ~/' deny
  assert_hook_decision "$sandbox_fresh/home/.claude/hooks/b-skills-guard.py" 'git reset --hard HEAD' ask
  assert_contains "$sandbox_fresh/home/.claude/b-skills/install.json" '"runtime": "claude"'
  assert_contains "$sandbox_fresh/home/.claude/b-skills/install.json" '"memoryAction": "replace"'
  assert_contains "$sandbox_fresh/home/.claude/b-skills/install.json" '"activationState": "active"'
  expect_install_status 0 "$sandbox_fresh" "$snapshot_repo" N
  assert_file "$sandbox_fresh/home/.claude/b-skills/install.json"
  run_install_output "$sandbox_fresh" "$snapshot_repo" N --uninstall >/dev/null
  assert_no_file "$sandbox_fresh/home/.claude/settings.json"

  mkdir -p "$sandbox_preserve/home/.claude"
  printf 'user-memory\n' > "$sandbox_preserve/home/.claude/CLAUDE.md"
  expect_install_status 2 "$sandbox_preserve" "$snapshot_repo" N
  assert_text_equals "$sandbox_preserve/home/.claude/CLAUDE.md" $'user-memory\n'
  assert_file "$sandbox_preserve/home/.claude/b-skills/CLAUDE.md"
  assert_contains "$sandbox_preserve/home/.claude/b-skills/install.json" '"memoryAction": "preserve"'
  assert_contains "$sandbox_preserve/home/.claude/b-skills/install.json" '"activationState": "pending"'

  mkdir -p "$sandbox_replace/home/.claude"
  printf 'legacy-memory\n' > "$sandbox_replace/home/.claude/CLAUDE.md"
  write_mixed_hook_settings "$sandbox_replace/home/.claude/settings.json"
  expect_install_status 0 "$sandbox_replace" "$snapshot_repo" Y --replace-memory
  assert_file "$sandbox_replace/home/.claude/CLAUDE.md"
  assert_contains "$sandbox_replace/home/.claude/settings.json" 'custom-hook.sh'
  assert_contains "$sandbox_replace/home/.claude/settings.json" 'b-skills-guard.py'
  assert_contains "$sandbox_replace/home/.claude.json" '"mcpServers"'
  assert_contains "$sandbox_replace/home/.claude.json" '"serena"'
  assert_contains "$sandbox_replace/home/.claude.json" 'brave-key'
  compgen -G "$sandbox_replace/home/.claude/b-skills/backups/CLAUDE.md.bak-*" >/dev/null || fail 'expected CLAUDE.md backup after replacement'
  compgen -G "$sandbox_replace/home/.claude/b-skills/backups/settings.json.bak-*" >/dev/null || fail 'expected settings backup after merge'
  run_install_output "$sandbox_replace" "$snapshot_repo" N --uninstall >/dev/null
  assert_no_file "$sandbox_replace/home/.claude.json"
  assert_contains "$sandbox_replace/home/.claude/settings.json" 'custom-hook.sh'
  assert_not_contains "$sandbox_replace/home/.claude/settings.json" 'b-skills-guard.py'

  mkdir -p "$sandbox_dry_run/home/.claude"
  printf 'keep-memory\n' > "$sandbox_dry_run/home/.claude/CLAUDE.md"
  printf '{"dryRun": false}\n' > "$sandbox_dry_run/home/.claude/settings.json"
  expect_install_status 0 "$sandbox_dry_run" "$snapshot_repo" Y --dry-run --replace-memory
  assert_text_equals "$sandbox_dry_run/home/.claude/CLAUDE.md" $'keep-memory\n'
  assert_text_equals "$sandbox_dry_run/home/.claude/settings.json" $'{"dryRun": false}\n'
  assert_no_file "$sandbox_dry_run/home/.claude/b-skills/install.json"

  mkdir -p "$sandbox_conflict_skill/home/.claude/skills/b-plan"
  printf '%s\n' 'custom skill' > "$sandbox_conflict_skill/home/.claude/skills/b-plan/SKILL.md"
  expect_install_status 1 "$sandbox_conflict_skill" "$snapshot_repo" N --replace-memory
  assert_text_equals "$sandbox_conflict_skill/home/.claude/skills/b-plan/SKILL.md" $'custom skill\n'
  assert_no_file "$sandbox_conflict_skill/home/.claude/skills/b-audit/SKILL.md"

  mkdir -p "$sandbox_conflict_agent/home/.claude/agents"
  printf '%s\n' 'custom agent' > "$sandbox_conflict_agent/home/.claude/agents/b-plan-agent.md"
  expect_install_status 1 "$sandbox_conflict_agent" "$snapshot_repo" N --replace-memory
  assert_text_equals "$sandbox_conflict_agent/home/.claude/agents/b-plan-agent.md" $'custom agent\n'
  assert_no_file "$sandbox_conflict_agent/home/.claude/skills/b-audit/SKILL.md"

  mkdir -p "$sandbox_conflict_hook/home/.claude/hooks"
  printf '%s\n' 'custom hook' > "$sandbox_conflict_hook/home/.claude/hooks/b-skills-guard.py"
  expect_install_status 1 "$sandbox_conflict_hook" "$snapshot_repo" N --replace-memory
  assert_text_equals "$sandbox_conflict_hook/home/.claude/hooks/b-skills-guard.py" $'custom hook\n'
  assert_no_file "$sandbox_conflict_hook/home/.claude/skills/b-audit/SKILL.md"

  mkdir -p "$sandbox_uninstall/home/.claude"
  printf 'legacy-memory\n' > "$sandbox_uninstall/home/.claude/CLAUDE.md"
  write_mixed_hook_settings "$sandbox_uninstall/home/.claude/settings.json"
  expect_install_status 0 "$sandbox_uninstall" "$snapshot_repo" N --replace-memory
  compgen -G "$sandbox_uninstall/home/.claude/b-skills/backups/CLAUDE.md.bak-*" >/dev/null || fail 'expected CLAUDE.md backup before uninstall'
  printf 'dirty\n' > "$sandbox_uninstall/source/dirty.txt"
  run_install_output "$sandbox_uninstall" "$snapshot_repo" N --uninstall >/dev/null
  assert_no_file "$sandbox_uninstall/home/.claude/skills/b-plan/SKILL.md"
  assert_no_file "$sandbox_uninstall/home/.claude/agents/b-plan-agent.md"
  assert_no_file "$sandbox_uninstall/home/.claude/hooks/b-skills-guard.py"
  assert_no_file "$sandbox_uninstall/home/.claude/references/b-skills/runtime-contract.md"
  assert_no_file "$sandbox_uninstall/home/.claude/b-skills/CLAUDE.md"
  assert_no_file "$sandbox_uninstall/home/.claude/b-skills/install.json"
  assert_text_equals "$sandbox_uninstall/home/.claude/CLAUDE.md" $'legacy-memory\n'
  assert_contains "$sandbox_uninstall/home/.claude/settings.json" 'custom-hook.sh'
  assert_contains "$sandbox_uninstall/home/.claude/settings.json" 'Bash(git commit*)'
  assert_not_contains "$sandbox_uninstall/home/.claude/settings.json" 'Bash(npm install*)'
  assert_not_contains "$sandbox_uninstall/home/.claude/settings.json" 'b-skills-guard.py'

  mkdir -p "$sandbox_uninstall_modified/home/.claude"
  printf 'legacy-memory\n' > "$sandbox_uninstall_modified/home/.claude/CLAUDE.md"
  expect_install_status 0 "$sandbox_uninstall_modified" "$snapshot_repo" N --replace-memory
  printf 'user-edited-memory\n' > "$sandbox_uninstall_modified/home/.claude/CLAUDE.md"
  run_install_output "$sandbox_uninstall_modified" "$snapshot_repo" N --uninstall >/dev/null
  assert_text_equals "$sandbox_uninstall_modified/home/.claude/CLAUDE.md" $'user-edited-memory\n'

  mkdir -p "$sandbox_uninstall_custom/home/.claude/skills/b-plan" "$sandbox_uninstall_custom/home/.claude/agents" "$sandbox_uninstall_custom/home/.claude/hooks"
  printf '%s\n' 'custom skill' > "$sandbox_uninstall_custom/home/.claude/skills/b-plan/SKILL.md"
  printf '%s\n' 'custom agent' > "$sandbox_uninstall_custom/home/.claude/agents/b-plan-agent.md"
  printf '%s\n' 'custom hook' > "$sandbox_uninstall_custom/home/.claude/hooks/b-skills-guard.py"
  run_install_output "$sandbox_uninstall_custom" "$snapshot_repo" N --uninstall >/dev/null
  assert_text_equals "$sandbox_uninstall_custom/home/.claude/skills/b-plan/SKILL.md" $'custom skill\n'
  assert_text_equals "$sandbox_uninstall_custom/home/.claude/agents/b-plan-agent.md" $'custom agent\n'
  assert_text_equals "$sandbox_uninstall_custom/home/.claude/hooks/b-skills-guard.py" $'custom hook\n'

  mkdir -p "$sandbox_mcp_existing/home"
  cat > "$sandbox_mcp_existing/home/.claude.json" <<'JSON'
{
  "mcpServers": {
    "custom": { "type": "stdio", "command": "custom-mcp" },
    "serena": { "type": "stdio", "command": "custom-serena" }
  }
}
JSON
  expect_install_status 0 "$sandbox_mcp_existing" "$snapshot_repo" Y --replace-memory
  assert_contains "$sandbox_mcp_existing/home/.claude.json" 'custom-mcp'
  assert_contains "$sandbox_mcp_existing/home/.claude.json" 'custom-serena'
  assert_not_contains "$sandbox_mcp_existing/home/.claude.json" 'start-mcp-server'
  assert_contains "$sandbox_mcp_existing/home/.claude/b-skills/install.json" '"mcpAddedServers": ['
  assert_contains "$sandbox_mcp_existing/home/.claude/b-skills/install.json" '"context7"'
  assert_contains "$sandbox_mcp_existing/home/.claude/b-skills/install.json" '"brave-search"'
  assert_contains "$sandbox_mcp_existing/home/.claude/b-skills/install.json" '"firecrawl"'
  run_install_output "$sandbox_mcp_existing" "$snapshot_repo" N --uninstall >/dev/null
  assert_contains "$sandbox_mcp_existing/home/.claude.json" 'custom-mcp'
  assert_contains "$sandbox_mcp_existing/home/.claude.json" 'custom-serena'
  assert_not_contains "$sandbox_mcp_existing/home/.claude.json" 'brave-search'
  assert_not_contains "$sandbox_mcp_existing/home/.claude.json" 'firecrawl'

  printf 'smoke-install.sh: PASS\n'
}

main "$@"
