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
  assert_no_path "$sandbox/home/.claude/b-agentic/references/contract/output.md"
  assert_file "$sandbox/home/.claude/settings.json"
  assert_file "$sandbox/home/.claude.json"
  assert_file "$sandbox/home/.claude/b-agentic/install.json"
  assert_contains "$sandbox/home/.claude/settings.json" 'mcp__serena__*'
  assert_contains "$sandbox/home/.claude.json" '"codegraph"'
  assert_contains "$sandbox/home/.claude/settings.json" 'Bash(git push *)'
  assert_contains "$sandbox/home/.claude/settings.json" 'Bash(git pull *)'
  assert_contains "$sandbox/home/.claude/settings.json" 'Bash(git revert *)'
  assert_contains "$sandbox/home/.claude/settings.json" 'Bash(git push --force-with-lease *)'
  assert_contains "$sandbox/home/.claude/settings.json" 'Bash(git branch -D *)'
  # Monitor tools may appear under ask, but must never be allowlisted.
  if python3 - "$sandbox/home/.claude/settings.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
allow = data.get("permissions", {}).get("allow", [])
sys.exit(1 if any("firecrawl_monitor" in str(item) for item in allow) else 0)
PY
  then
    :
  else
    fail "expected no Firecrawl monitor tools in Claude allowlist"
  fi
  assert_contains "$sandbox/home/.claude/settings.json" 'mcp__firecrawl__firecrawl_search'
  assert_contains "$sandbox/home/.claude/settings.json" 'mcp__playwright__browser_snapshot'
  assert_contains "$sandbox/home/.claude/settings.json" 'mcp__firecrawl__firecrawl_agent'
  assert_contains "$sandbox/home/.claude/settings.json" 'mcp__playwright__browser_click'
  assert_not_contains "$sandbox/home/.claude/settings.json" 'mcp__playwright__*'
  assert_not_contains "$sandbox/home/.claude/settings.json" 'check-runtime.py'
  assert_no_path "$sandbox/home/.claude/agents/b-explore.md"
}
