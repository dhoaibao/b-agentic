# Sourced by tests/smoke/install.sh - do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by tests/smoke/install.sh" >&2
  exit 1
fi

run_runtime_smoke_cases() {
  local snapshot_repo="$1"
  local sandbox_cursor="$WORK_DIR/cursor"
  local sandbox_cursor_preserve="$WORK_DIR/cursor-preserve"
  local sandbox_cursor_replace="$WORK_DIR/cursor-replace"
  local sandbox_cursor_dry_run="$WORK_DIR/cursor-dry-run"
  local sandbox_cursor_prompt_keys="$WORK_DIR/cursor-prompt-keys"
  local sandbox_cursor_merge="$WORK_DIR/cursor-merge"
  local sandbox_cursor_cwd_repo="$WORK_DIR/cursor-cwd-repo"

  mkdir -p "$sandbox_cursor/home"
  expect_install_status 0 "$sandbox_cursor" "$snapshot_repo" --runtime=cursor
  assert_file "$sandbox_cursor/home/.cursor/AGENTS.md"
  assert_contains "$sandbox_cursor/home/.cursor/AGENTS.md" '<!-- b-agentic-managed -->'
  assert_file "$sandbox_cursor/home/.cursor/skills/b-plan/SKILL.md"
  assert_file "$sandbox_cursor/home/.cursor/skills/b-plan/reference.md"
  assert_file "$sandbox_cursor/home/.cursor/skills/b-review/SKILL.md"
  assert_contains "$sandbox_cursor/home/.cursor/skills/b-review/SKILL.md" 'self-audits when explicitly requested or invoked with `--audit-suite`'
  assert_contains "$sandbox_cursor/home/.cursor/skills/b-review/SKILL.md" 'with or without `--audit-suite`'
  assert_not_contains "$sandbox_cursor/home/.cursor/skills/b-review/SKILL.md" 'suite self-audit without `--audit-suite` -> ask'
  assert_not_contains "$sandbox_cursor/home/.cursor/skills/b-review/SKILL.md" 'Do NOT invoke for repo/suite audits'
  assert_contains "$sandbox_cursor/home/.cursor/AGENTS.md" 'Avoid common runtime rationalizations such as opportunistic scope expansion'
  assert_not_contains "$sandbox_cursor/home/.cursor/AGENTS.md" '"I'\''ll fix this adjacent thing while I'\''m here."'
  assert_contains "$sandbox_cursor/home/.cursor/skills/b-plan/reference.md" '../../b-agentic/references/contract/02-source-of-truth.md'
  assert_file "$sandbox_cursor/home/.cursor/b-agentic/install.json"
  assert_json_value "$sandbox_cursor/home/.cursor/b-agentic/install.json" "data['runtime'] == 'cursor'"
  assert_json_value "$sandbox_cursor/home/.cursor/b-agentic/install.json" "data['activationState'] == 'active'"
  assert_json_value "$sandbox_cursor/home/.cursor/b-agentic/install.json" "data['commands'] == []"
  assert_json_value "$sandbox_cursor/home/.cursor/b-agentic/install.json" "data['paths']['cursorMcp'].endswith('/.cursor/mcp.json')"
  assert_file "$sandbox_cursor/home/.cursor/mcp.json"
  assert_json_value "$sandbox_cursor/home/.cursor/mcp.json" "set(data['mcpServers']) == {'serena', 'context7', 'brave-search', 'firecrawl', 'playwright'}"
  assert_json_value "$sandbox_cursor/home/.cursor/mcp.json" "data['mcpServers']['context7']['url'] == 'https://mcp.context7.com/mcp'"
  assert_json_value "$sandbox_cursor/home/.cursor/mcp.json" "'serverUrl' not in data['mcpServers']['context7']"
  assert_json_value "$sandbox_cursor/home/.cursor/mcp.json" "data['mcpServers']['context7']['headers']['CONTEXT7_API_KEY'] == '\${CONTEXT7_API_KEY:-}'"
  assert_json_value "$sandbox_cursor/home/.cursor/mcp.json" "data['mcpServers']['brave-search']['command'] == 'pnpm'"
  assert_json_value "$sandbox_cursor/home/.cursor/mcp.json" "data['mcpServers']['firecrawl']['command'] == 'pnpm'"
  assert_json_value "$sandbox_cursor/home/.cursor/mcp.json" "data['mcpServers']['playwright']['args'][-1] == '--isolated'"
  assert_file "$sandbox_cursor/home/.cursor/b-agentic/references/contract/index.md"
  assert_file "$sandbox_cursor/home/.cursor/b-agentic/templates/mcp.user.template.json"
  assert_no_path "$sandbox_cursor/home/.claude"
  assert_no_path "$sandbox_cursor/home/.gemini"
  assert_no_path "$sandbox_cursor/home/.config/opencode"
  assert_no_path "$sandbox_cursor/home/.codex"

  mkdir -p "$sandbox_cursor_cwd_repo/home" "$sandbox_cursor_cwd_repo/current-repo"
  git -C "$sandbox_cursor_cwd_repo/current-repo" init -q
  expect_install_status_in_cwd 0 "$sandbox_cursor_cwd_repo/current-repo" "$sandbox_cursor_cwd_repo" "$snapshot_repo" --runtime=cursor
  assert_no_path "$sandbox_cursor_cwd_repo/current-repo/.b-agentic"
  expect_install_status_in_cwd 0 "$sandbox_cursor_cwd_repo/current-repo" "$sandbox_cursor_cwd_repo" "$snapshot_repo" --runtime=cursor --uninstall
  assert_no_path "$sandbox_cursor_cwd_repo/current-repo/.b-agentic"

  mkdir -p "$sandbox_cursor_preserve/home/.cursor"
  printf '# User Cursor Memory\n' > "$sandbox_cursor_preserve/home/.cursor/AGENTS.md"
  expect_install_status 2 "$sandbox_cursor_preserve" "$snapshot_repo" --runtime=cursor
  assert_contains "$sandbox_cursor_preserve/home/.cursor/AGENTS.md" '# User Cursor Memory'
  assert_json_value "$sandbox_cursor_preserve/home/.cursor/b-agentic/install.json" "data['activationState'] == 'pending'"

  mkdir -p "$sandbox_cursor_replace/home/.cursor"
  printf '# User Cursor Memory\n' > "$sandbox_cursor_replace/home/.cursor/AGENTS.md"
  expect_install_status 0 "$sandbox_cursor_replace" "$snapshot_repo" --runtime=cursor --replace-memory
  assert_contains "$sandbox_cursor_replace/home/.cursor/AGENTS.md" '<!-- b-agentic-managed -->'
  assert_json_value "$sandbox_cursor_replace/home/.cursor/b-agentic/install.json" "data['memoryAction'] == 'replace'"
  assert_glob "$sandbox_cursor_replace/home/.cursor/b-agentic/backups/AGENTS.md.bak-*"

  mkdir -p "$sandbox_cursor_dry_run/home"
  expect_install_status 0 "$sandbox_cursor_dry_run" "$snapshot_repo" --runtime=cursor --dry-run
  assert_no_path "$sandbox_cursor_dry_run/home/.cursor"
  assert_no_path "$sandbox_cursor_dry_run/source"

  mkdir -p "$sandbox_cursor_prompt_keys/home"
  expect_install_with_tty_status 0 "$sandbox_cursor_prompt_keys" "$snapshot_repo" $'ctx7-cursor-key\nbrave-cursor-key\nfirecrawl-cursor-key\n' --runtime=cursor --prompt-api-keys
  assert_json_value "$sandbox_cursor_prompt_keys/home/.cursor/mcp.json" "data['mcpServers']['context7']['headers']['CONTEXT7_API_KEY'] == 'ctx7-cursor-key'"
  assert_json_value "$sandbox_cursor_prompt_keys/home/.cursor/mcp.json" "data['mcpServers']['brave-search']['env']['BRAVE_API_KEY'] == 'brave-cursor-key'"
  assert_json_value "$sandbox_cursor_prompt_keys/home/.cursor/mcp.json" "data['mcpServers']['firecrawl']['env']['FIRECRAWL_API_KEY'] == 'firecrawl-cursor-key'"
  assert_contains "$sandbox_cursor_prompt_keys/home/.cursor/b-agentic/templates/mcp.user.template.json" '${BRAVE_API_KEY}'
  assert_not_contains "$sandbox_cursor_prompt_keys/home/.cursor/b-agentic/templates/mcp.user.template.json" 'brave-cursor-key'
  expect_install_status 0 "$sandbox_cursor_prompt_keys" "$snapshot_repo" --runtime=cursor --uninstall
  assert_no_path "$sandbox_cursor_prompt_keys/home/.cursor/mcp.json"

  mkdir -p "$sandbox_cursor_merge/home/.cursor"
  printf '{"mcpServers":{"custom":{"url":"https://example.com/mcp"}},"userOnly":true}\n' > "$sandbox_cursor_merge/home/.cursor/mcp.json"
  expect_install_status 0 "$sandbox_cursor_merge" "$snapshot_repo" --runtime=cursor
  assert_json_value "$sandbox_cursor_merge/home/.cursor/mcp.json" "'custom' in data['mcpServers']"
  assert_json_value "$sandbox_cursor_merge/home/.cursor/mcp.json" "data.get('userOnly') is True"
  expect_install_status 0 "$sandbox_cursor_merge" "$snapshot_repo" --runtime=cursor --uninstall
  assert_json_value "$sandbox_cursor_merge/home/.cursor/mcp.json" "set(data['mcpServers']) == {'custom'}"
  assert_json_value "$sandbox_cursor_merge/home/.cursor/mcp.json" "data.get('userOnly') is True"

  expect_install_status 0 "$sandbox_cursor" "$snapshot_repo" --runtime=cursor --uninstall
  assert_no_path "$sandbox_cursor/home/.cursor/b-agentic"
  assert_no_path "$sandbox_cursor/home/.cursor/AGENTS.md"
  assert_no_path "$sandbox_cursor/home/.cursor/mcp.json"
}
