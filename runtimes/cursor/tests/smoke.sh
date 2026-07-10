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
  assert_contains "$sandbox/home/.cursor/cli-config.json" 'Mcp(firecrawl:firecrawl_search)'
  assert_contains "$sandbox/home/.cursor/cli-config.json" 'Mcp(playwright:browser_snapshot)'
  assert_not_contains "$sandbox/home/.cursor/cli-config.json" 'Mcp(playwright:*)'
  assert_not_contains "$sandbox/home/.cursor/cli-config.json" 'Mcp(firecrawl:firecrawl_agent)'
  assert_not_contains "$sandbox/home/.cursor/cli-config.json" 'Mcp(playwright:browser_click)'
  if python3 - "$sandbox/home/.cursor/cli-config.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
allow = data.get("permissions", {}).get("allow", [])
sys.exit(1 if any("firecrawl_monitor" in str(item) for item in allow) else 0)
PY
  then
    :
  else
    fail "expected no Firecrawl monitor tools in Cursor allowlist"
  fi
  assert_no_path "$sandbox/home/.cursor/agents/b-explore.md"
}
