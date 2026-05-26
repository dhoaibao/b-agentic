# Sourced by tests/smoke/install.sh - do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by tests/smoke/install.sh" >&2
  exit 1
fi

run_runtime_smoke_cases() {
  local snapshot_repo="$1"
  local sandbox_kimi="$WORK_DIR/kimi"
  local sandbox_kimi_preserve="$WORK_DIR/kimi-preserve"
  local sandbox_kimi_replace="$WORK_DIR/kimi-replace"
  local sandbox_kimi_dry_run="$WORK_DIR/kimi-dry-run"
  local sandbox_kimi_prompt_keys="$WORK_DIR/kimi-prompt-keys"
  local sandbox_kimi_merge="$WORK_DIR/kimi-merge"
  local sandbox_kimi_cwd_repo="$WORK_DIR/kimi-cwd-repo"

  mkdir -p "$sandbox_kimi/home"
  expect_install_status 0 "$sandbox_kimi" "$snapshot_repo" --runtime=kimi-cli
  assert_file "$sandbox_kimi/home/.kimi/AGENTS.md"
  assert_contains "$sandbox_kimi/home/.kimi/AGENTS.md" '<!-- b-agentic-managed -->'
  assert_file "$sandbox_kimi/home/.kimi/skills/b-plan/SKILL.md"
  assert_file "$sandbox_kimi/home/.kimi/skills/b-plan/reference.md"
  assert_contains "$sandbox_kimi/home/.kimi/skills/b-plan/reference.md" '../../b-agentic/references/contract/02-source-of-truth.md'
  assert_file "$sandbox_kimi/home/.kimi/b-agentic/install.json"
  assert_json_value "$sandbox_kimi/home/.kimi/b-agentic/install.json" "data['runtime'] == 'kimi-cli'"
  assert_json_value "$sandbox_kimi/home/.kimi/b-agentic/install.json" "data['activationState'] == 'active'"
  assert_json_value "$sandbox_kimi/home/.kimi/b-agentic/install.json" "data['commands'] == []"
  assert_json_value "$sandbox_kimi/home/.kimi/b-agentic/install.json" "data['paths']['kimiMcpConfig'].endswith('/.kimi/mcp.json')"
  assert_file "$sandbox_kimi/home/.kimi/mcp.json"
  assert_json_value "$sandbox_kimi/home/.kimi/mcp.json" "set(data['mcpServers']) == {'serena', 'context7', 'brave-search', 'firecrawl', 'playwright', 'gitnexus'}"
  assert_json_value "$sandbox_kimi/home/.kimi/mcp.json" "data['mcpServers']['context7']['serverUrl'] == 'https://mcp.context7.com/mcp'"
  assert_json_value "$sandbox_kimi/home/.kimi/mcp.json" "'httpUrl' not in data['mcpServers']['context7']"
  assert_json_value "$sandbox_kimi/home/.kimi/mcp.json" "data['mcpServers']['context7']['headers']['CONTEXT7_API_KEY'] == '\$CONTEXT7_API_KEY'"
  assert_json_value "$sandbox_kimi/home/.kimi/mcp.json" "data['mcpServers']['brave-search']['command'] == 'pnpm'"
  assert_json_value "$sandbox_kimi/home/.kimi/mcp.json" "data['mcpServers']['firecrawl']['command'] == 'pnpm'"
  assert_json_value "$sandbox_kimi/home/.kimi/mcp.json" "data['mcpServers']['playwright']['args'][-1] == '--isolated'"
  assert_json_value "$sandbox_kimi/home/.kimi/mcp.json" "data['mcpServers']['gitnexus']['command'] == 'gitnexus'"
  assert_file "$sandbox_kimi/home/.kimi/b-agentic/references/contract/index.md"
  assert_file "$sandbox_kimi/home/.kimi/b-agentic/templates/mcp_config.template.json"
  assert_no_path "$sandbox_kimi/home/.kimi/config.toml"
  assert_no_path "$sandbox_kimi/home/.claude"
  assert_no_path "$sandbox_kimi/home/.config/opencode"
  assert_no_path "$sandbox_kimi/home/.codex"
  assert_no_path "$sandbox_kimi/home/.gemini"

  mkdir -p "$sandbox_kimi_cwd_repo/home" "$sandbox_kimi_cwd_repo/current-repo"
  git -C "$sandbox_kimi_cwd_repo/current-repo" init -q
  expect_install_status_in_cwd 0 "$sandbox_kimi_cwd_repo/current-repo" "$sandbox_kimi_cwd_repo" "$snapshot_repo" --runtime=kimi-cli
  assert_no_path "$sandbox_kimi_cwd_repo/current-repo/.b-agentic"
  expect_install_status_in_cwd 0 "$sandbox_kimi_cwd_repo/current-repo" "$sandbox_kimi_cwd_repo" "$snapshot_repo" --runtime=kimi-cli --uninstall
  assert_no_path "$sandbox_kimi_cwd_repo/current-repo/.b-agentic"

  mkdir -p "$sandbox_kimi_preserve/home/.kimi"
  printf '# User Kimi Memory\n' > "$sandbox_kimi_preserve/home/.kimi/AGENTS.md"
  expect_install_status 2 "$sandbox_kimi_preserve" "$snapshot_repo" --runtime=kimi-cli
  assert_contains "$sandbox_kimi_preserve/home/.kimi/AGENTS.md" '# User Kimi Memory'
  assert_json_value "$sandbox_kimi_preserve/home/.kimi/b-agentic/install.json" "data['activationState'] == 'pending'"

  mkdir -p "$sandbox_kimi_replace/home/.kimi"
  printf '# User Kimi Memory\n' > "$sandbox_kimi_replace/home/.kimi/AGENTS.md"
  expect_install_status 0 "$sandbox_kimi_replace" "$snapshot_repo" --runtime=kimi-cli --replace-memory
  assert_contains "$sandbox_kimi_replace/home/.kimi/AGENTS.md" '<!-- b-agentic-managed -->'
  assert_json_value "$sandbox_kimi_replace/home/.kimi/b-agentic/install.json" "data['memoryAction'] == 'replace'"
  assert_glob "$sandbox_kimi_replace/home/.kimi/b-agentic/backups/AGENTS.md.bak-*"

  mkdir -p "$sandbox_kimi_dry_run/home"
  expect_install_status 0 "$sandbox_kimi_dry_run" "$snapshot_repo" --runtime=kimi-cli --dry-run
  assert_no_path "$sandbox_kimi_dry_run/home/.kimi"
  assert_no_path "$sandbox_kimi_dry_run/source"

  mkdir -p "$sandbox_kimi_prompt_keys/home"
  expect_install_with_tty_status 0 "$sandbox_kimi_prompt_keys" "$snapshot_repo" $'ctx7-kimi-key\nbrave-kimi-key\nfirecrawl-kimi-key\n' --runtime=kimi-cli --prompt-api-keys
  assert_json_value "$sandbox_kimi_prompt_keys/home/.kimi/mcp.json" "data['mcpServers']['context7']['headers']['CONTEXT7_API_KEY'] == 'ctx7-kimi-key'"
  assert_json_value "$sandbox_kimi_prompt_keys/home/.kimi/mcp.json" "data['mcpServers']['brave-search']['env']['BRAVE_API_KEY'] == 'brave-kimi-key'"
  assert_json_value "$sandbox_kimi_prompt_keys/home/.kimi/mcp.json" "data['mcpServers']['firecrawl']['env']['FIRECRAWL_API_KEY'] == 'firecrawl-kimi-key'"
  assert_contains "$sandbox_kimi_prompt_keys/home/.kimi/b-agentic/templates/mcp_config.template.json" '$BRAVE_API_KEY'
  assert_not_contains "$sandbox_kimi_prompt_keys/home/.kimi/b-agentic/templates/mcp_config.template.json" 'brave-kimi-key'
  expect_install_status 0 "$sandbox_kimi_prompt_keys" "$snapshot_repo" --runtime=kimi-cli --uninstall
  assert_no_path "$sandbox_kimi_prompt_keys/home/.kimi/mcp.json"

  mkdir -p "$sandbox_kimi_merge/home/.kimi"
  printf '{"mcpServers":{"custom":{"serverUrl":"https://example.com/mcp"}},"userOnly":true}\n' > "$sandbox_kimi_merge/home/.kimi/mcp.json"
  expect_install_status 0 "$sandbox_kimi_merge" "$snapshot_repo" --runtime=kimi-cli
  assert_json_value "$sandbox_kimi_merge/home/.kimi/mcp.json" "'custom' in data['mcpServers']"
  assert_json_value "$sandbox_kimi_merge/home/.kimi/mcp.json" "'gitnexus' in data['mcpServers']"
  assert_json_value "$sandbox_kimi_merge/home/.kimi/mcp.json" "data.get('userOnly') is True"
  expect_install_status 0 "$sandbox_kimi_merge" "$snapshot_repo" --runtime=kimi-cli --uninstall
  assert_json_value "$sandbox_kimi_merge/home/.kimi/mcp.json" "set(data['mcpServers']) == {'custom'}"
  assert_json_value "$sandbox_kimi_merge/home/.kimi/mcp.json" "data.get('userOnly') is True"

  expect_install_status 0 "$sandbox_kimi" "$snapshot_repo" --runtime=kimi-cli --uninstall
  assert_no_path "$sandbox_kimi/home/.kimi/b-agentic"
  assert_no_path "$sandbox_kimi/home/.kimi/AGENTS.md"
  assert_no_path "$sandbox_kimi/home/.kimi/mcp.json"
}
