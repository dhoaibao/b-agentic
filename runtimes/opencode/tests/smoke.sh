# Sourced by tests/smoke/install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by tests/smoke/install.sh" >&2
  exit 1
fi

run_runtime_smoke_cases() {
  local snapshot_repo="$1"
  local sandbox="$WORK_DIR/opencode"
  mkdir -p "$sandbox/home"

  expect_install_status 0 "$sandbox" "$snapshot_repo" --runtime=opencode
  assert_file "$sandbox/home/.config/opencode/AGENTS.md"
  assert_file "$sandbox/home/.config/opencode/skills/b-plan/SKILL.md"
  assert_file "$sandbox/home/.config/opencode/commands/b-plan.md"
  assert_file "$sandbox/home/.config/opencode/opencode.json"
  assert_file "$sandbox/home/.config/opencode/b-agentic/references/contract/runtime.md"
  assert_file "$sandbox/home/.config/opencode/b-agentic/install.json"
  assert_contains "$sandbox/home/.config/opencode/opencode.json" '"serena"'
  assert_contains "$sandbox/home/.config/opencode/opencode.json" '"codegraph"'
  assert_contains "$sandbox/home/.config/opencode/opencode.json" '"git push --force-with-lease *": "deny"'
  assert_contains "$sandbox/home/.config/opencode/opencode.json" '"git branch -D *": "deny"'
  assert_no_path "$sandbox/home/.config/opencode/agents/b-explore.md"
}
