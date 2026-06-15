# Sourced by tests/smoke/install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by tests/smoke/install.sh" >&2
  exit 1
fi

run_runtime_smoke_cases() {
  local snapshot_repo="$1"
  local sandbox="$WORK_DIR/kimi"
  mkdir -p "$sandbox/home"

  expect_install_status 0 "$sandbox" "$snapshot_repo" --runtime=kimi-code-cli
  assert_file "$sandbox/home/.kimi-code/AGENTS.md"
  assert_file "$sandbox/home/.kimi-code/skills/b-plan/SKILL.md"
  assert_file "$sandbox/home/.kimi-code/config.toml"
  assert_file "$sandbox/home/.kimi-code/mcp.json"
  assert_file "$sandbox/home/.kimi-code/b-agentic/references/contract/runtime.md"
  assert_file "$sandbox/home/.kimi-code/b-agentic/install.json"
  assert_contains "$sandbox/home/.kimi-code/mcp.json" '"mcpServers"'
  assert_contains "$sandbox/home/.kimi-code/mcp.json" '"serena"'
  assert_contains "$sandbox/home/.kimi-code/config.toml" 'pattern = "Bash(git push*)"'
  assert_contains "$sandbox/home/.kimi-code/config.toml" 'pattern = "Bash(git reset --hard*)"'
  assert_no_path "$sandbox/home/.kimi-code/agents/b-explore.md"
}
