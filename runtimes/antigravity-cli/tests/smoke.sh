# Sourced by tests/smoke/install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by tests/smoke/install.sh" >&2
  exit 1
fi

run_runtime_smoke_cases() {
  local snapshot_repo="$1"
  local sandbox="$WORK_DIR/antigravity"
  mkdir -p "$sandbox/home"

  expect_install_status 0 "$sandbox" "$snapshot_repo" --runtime=antigravity-cli
  assert_file "$sandbox/home/.gemini/GEMINI.md"
  assert_file "$sandbox/home/.gemini/antigravity-cli/skills/b-plan/SKILL.md"
  assert_file "$sandbox/home/.gemini/antigravity-cli/b-agentic/references/contract/runtime.md"
  assert_file "$sandbox/home/.gemini/antigravity-cli/b-agentic/references/contract/safety-tools.md"
  assert_no_path "$sandbox/home/.gemini/antigravity-cli/b-agentic/references/contract/output.md"
  assert_file "$sandbox/home/.gemini/antigravity-cli/settings.json"
  assert_file "$sandbox/home/.gemini/antigravity-cli/mcp_config.json"
  assert_file "$sandbox/home/.gemini/antigravity-cli/b-agentic/install.json"
  assert_contains "$sandbox/home/.gemini/antigravity-cli/settings.json" 'mcp(serena/*)'
  assert_contains "$sandbox/home/.gemini/antigravity-cli/mcp_config.json" '"codegraph"'
  assert_contains "$sandbox/home/.gemini/antigravity-cli/settings.json" 'command(git push.*)'
  assert_contains "$sandbox/home/.gemini/antigravity-cli/settings.json" 'command(git pull.*)'
  assert_contains "$sandbox/home/.gemini/antigravity-cli/settings.json" 'command(git revert.*)'
  assert_contains "$sandbox/home/.gemini/antigravity-cli/settings.json" 'command(git push --force-with-lease.*)'
  assert_contains "$sandbox/home/.gemini/antigravity-cli/settings.json" 'command(git branch -D.*)'
  assert_not_contains "$sandbox/home/.gemini/antigravity-cli/settings.json" 'firecrawl_monitor'
  assert_json_value "$sandbox/home/.gemini/antigravity-cli/mcp_config.json" "data['mcpServers']['context7']['type'] == 'remote'"
  assert_json_value "$sandbox/home/.gemini/antigravity-cli/mcp_config.json" "data['mcpServers']['context7']['serverUrl'] == 'https://mcp.context7.com/mcp'"
  assert_no_path "$sandbox/home/.gemini/antigravity-cli/skills/b-explore.md"
}
