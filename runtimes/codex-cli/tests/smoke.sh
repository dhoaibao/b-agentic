# Sourced by tests/smoke/install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by tests/smoke/install.sh" >&2
  exit 1
fi

run_runtime_smoke_cases() {
  local snapshot_repo="$1"
  local sandbox="$WORK_DIR/codex"
  mkdir -p "$sandbox/home"

  expect_install_status 0 "$sandbox" "$snapshot_repo" --runtime=codex-cli
  assert_file "$sandbox/home/.codex/AGENTS.md"
  assert_file "$sandbox/home/.codex/skills/b-plan/SKILL.md"
  assert_file "$sandbox/home/.codex/rules/b-agentic.rules"
  assert_file "$sandbox/home/.codex/config.toml"
  assert_file "$sandbox/home/.codex/b-agentic/references/contract/runtime.md"
  assert_file "$sandbox/home/.codex/b-agentic/install.json"
  assert_contains "$sandbox/home/.codex/config.toml" '[mcp_servers.serena]'
  assert_not_contains "$sandbox/home/.codex/config.toml" '[[hooks'
  assert_no_path "$sandbox/home/.codex/agents/b-explore.toml"
  assert_no_path "$sandbox/home/.codex/b-agentic/hooks/check-runtime.py"
}
