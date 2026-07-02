# Sourced by tests/smoke/install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by tests/smoke/install.sh" >&2
  exit 1
fi

run_runtime_smoke_cases() {
  local snapshot_repo="$1"
  local sandbox="$WORK_DIR/copilot-cli"
  mkdir -p "$sandbox/home"

  expect_install_status 0 "$sandbox" "$snapshot_repo" --runtime=copilot-cli
  assert_file "$sandbox/home/.copilot/copilot-instructions.md"
  assert_file "$sandbox/home/.copilot/skills/b-plan/SKILL.md"
  assert_file "$sandbox/home/.copilot/b-agentic/references/contract/runtime.md"
  assert_file "$sandbox/home/.copilot/b-agentic/references/contract/safety-tools.md"
  assert_no_path "$sandbox/home/.copilot/b-agentic/references/contract/output.md"
  assert_file "$sandbox/home/.copilot/mcp-config.json"
  assert_file "$sandbox/home/.copilot/b-agentic/install.json"
  assert_contains "$sandbox/home/.copilot/mcp-config.json" '"codegraph"'
  assert_json_value "$sandbox/home/.copilot/mcp-config.json" "data['mcpServers']['context7']['type'] == 'http'"
  assert_json_value "$sandbox/home/.copilot/mcp-config.json" "data['mcpServers']['context7']['url'] == 'https://mcp.context7.com/mcp'"
  assert_no_path "$sandbox/home/.copilot/skills/b-explore.md"
}
