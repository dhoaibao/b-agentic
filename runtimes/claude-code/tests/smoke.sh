# Sourced by tests/smoke/install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by tests/smoke/install.sh" >&2
  exit 1
fi

run_runtime_smoke_cases() {
  local snapshot_repo="$1"
  local sandbox="$WORK_DIR/claude"
  mkdir -p "$sandbox/home"

  expect_install_status 0 "$sandbox" "$snapshot_repo" --runtime=claude-code
  assert_file "$sandbox/home/.claude/CLAUDE.md"
  assert_file "$sandbox/home/.claude/skills/b-plan/SKILL.md"
  assert_file "$sandbox/home/.claude/b-agentic/references/contract/runtime.md"
  assert_file "$sandbox/home/.claude/b-agentic/references/contract/safety-tools.md"
  assert_file "$sandbox/home/.claude/b-agentic/references/contract/output.md"
  assert_file "$sandbox/home/.claude/settings.json"
  assert_file "$sandbox/home/.claude.json"
  assert_file "$sandbox/home/.claude/b-agentic/install.json"
  assert_contains "$sandbox/home/.claude/settings.json" 'mcp__serena__*'
  assert_not_contains "$sandbox/home/.claude/settings.json" 'firecrawl_monitor'
  assert_not_contains "$sandbox/home/.claude/settings.json" 'check-runtime.py'
  assert_no_path "$sandbox/home/.claude/agents/b-explore.md"
}
