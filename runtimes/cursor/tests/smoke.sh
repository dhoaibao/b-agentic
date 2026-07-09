# Sourced by tests/smoke/install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by tests/smoke/install.sh" >&2
  exit 1
fi

run_runtime_smoke_cases() {
  local snapshot_repo="$1"
  local sandbox="$WORK_DIR/cursor"
  mkdir -p "$sandbox/home"

  expect_install_status 0 "$sandbox" "$snapshot_repo" --runtime=cursor
  assert_file "$sandbox/home/.cursor/AGENTS.md"
  assert_file "$sandbox/home/.cursor/skills/b-plan/SKILL.md"
  assert_file "$sandbox/home/.cursor/b-agentic/references/contract/runtime.md"
  assert_file "$sandbox/home/.cursor/b-agentic/references/contract/safety-tools.md"
  assert_no_path "$sandbox/home/.cursor/b-agentic/references/contract/output.md"
  assert_file "$sandbox/home/.cursor/mcp.json"
  assert_file "$sandbox/home/.cursor/cli-config.json"
  assert_file "$sandbox/home/.cursor/b-agentic/install.json"
  assert_contains "$sandbox/home/.cursor/mcp.json" '"codegraph"'
  assert_contains "$sandbox/home/.cursor/cli-config.json" 'Mcp(serena:*)'
  assert_contains "$sandbox/home/.cursor/cli-config.json" 'Shell(git reset --hard *)'
  assert_no_path "$sandbox/home/.cursor/agents/b-explore.md"
}
