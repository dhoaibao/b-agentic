# Sourced by tests/smoke/install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by tests/smoke/install.sh" >&2
  exit 1
fi

run_runtime_smoke_cases() {
  local snapshot_repo="$1"
  local sandbox="$WORK_DIR/kilo"
  mkdir -p "$sandbox/home"

  expect_install_status 0 "$sandbox" "$snapshot_repo" --runtime=kilo-code
  assert_file "$sandbox/home/.config/kilo/AGENTS.md"
  assert_file "$sandbox/home/.config/kilo/skills/b-plan/SKILL.md"
  assert_file "$sandbox/home/.config/kilo/kilo.jsonc"
  assert_file "$sandbox/home/.config/kilo/b-agentic/references/contract/runtime.md"
  assert_file "$sandbox/home/.config/kilo/b-agentic/install.json"
  assert_contains "$sandbox/home/.config/kilo/kilo.jsonc" '"serena"'
  assert_no_path "$sandbox/home/.config/kilo/agents/b-explore.md"
}
