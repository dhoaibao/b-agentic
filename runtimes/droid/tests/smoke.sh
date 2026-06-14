# Sourced by tests/smoke/install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by tests/smoke/install.sh" >&2
  exit 1
fi

run_runtime_smoke_cases() {
  local snapshot_repo="$1"
  local sandbox="$WORK_DIR/droid"
  mkdir -p "$sandbox/home"

  expect_install_status 0 "$sandbox" "$snapshot_repo" --runtime=droid
  assert_file "$sandbox/home/.factory/AGENTS.md"
  assert_file "$sandbox/home/.factory/skills/b-plan/SKILL.md"
  assert_file "$sandbox/home/.factory/settings.json"
  assert_file "$sandbox/home/.factory/mcp.json"
  assert_file "$sandbox/home/.factory/b-agentic/references/contract/runtime.md"
  assert_file "$sandbox/home/.factory/b-agentic/install.json"
  assert_contains "$sandbox/home/.factory/mcp.json" '"mcpServers"'
  assert_contains "$sandbox/home/.factory/mcp.json" '"serena"'
  assert_contains "$sandbox/home/.factory/settings.json" '"commandDenylist"'
  assert_no_path "$sandbox/home/.factory/commands/b-plan.md"
  assert_no_path "$sandbox/home/.factory/agents/b-explore.md"
}
