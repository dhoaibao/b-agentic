# Sourced by tests/smoke/install.sh - do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by tests/smoke/install.sh" >&2
  exit 1
fi

run_runtime_smoke_cases() {
  local snapshot_repo="$1"
  local sandbox_antigravity="$WORK_DIR/antigravity"
  local sandbox_antigravity_preserve="$WORK_DIR/antigravity-preserve"
  local sandbox_antigravity_replace="$WORK_DIR/antigravity-replace"
  local sandbox_antigravity_dry_run="$WORK_DIR/antigravity-dry-run"
  local sandbox_antigravity_prompt_keys="$WORK_DIR/antigravity-prompt-keys"
  local sandbox_antigravity_merge="$WORK_DIR/antigravity-merge"
  local sandbox_antigravity_legacy_upgrade="$WORK_DIR/antigravity-legacy-upgrade"
  local sandbox_antigravity_cwd_repo="$WORK_DIR/antigravity-cwd-repo"

  mkdir -p "$sandbox_antigravity/home"
  expect_install_status 0 "$sandbox_antigravity" "$snapshot_repo" --runtime=antigravity-cli
  assert_file "$sandbox_antigravity/home/.gemini/GEMINI.md"
  assert_contains "$sandbox_antigravity/home/.gemini/GEMINI.md" '<!-- b-agentic-managed -->'
  assert_file "$sandbox_antigravity/home/.gemini/antigravity-cli/skills/b-plan/SKILL.md"
  assert_file "$sandbox_antigravity/home/.gemini/antigravity-cli/skills/b-plan/reference.md"
  assert_file "$sandbox_antigravity/home/.gemini/antigravity-cli/skills/b-review/SKILL.md"
  assert_contains "$sandbox_antigravity/home/.gemini/antigravity-cli/skills/b-review/SKILL.md" 'self-audits when explicitly requested or invoked with `--audit-suite`'
  assert_contains "$sandbox_antigravity/home/.gemini/antigravity-cli/skills/b-review/SKILL.md" 'with or without `--audit-suite`'
  assert_not_contains "$sandbox_antigravity/home/.gemini/antigravity-cli/skills/b-review/SKILL.md" 'suite self-audit without `--audit-suite` -> ask'
  assert_not_contains "$sandbox_antigravity/home/.gemini/antigravity-cli/skills/b-review/SKILL.md" 'Do NOT invoke for repo/suite audits'
  assert_contains "$sandbox_antigravity/home/.gemini/GEMINI.md" 'Avoid common runtime rationalizations such as opportunistic scope expansion'
  assert_not_contains "$sandbox_antigravity/home/.gemini/GEMINI.md" '"I'\''ll fix this adjacent thing while I'\''m here."'
  assert_contains "$sandbox_antigravity/home/.gemini/antigravity-cli/skills/b-plan/reference.md" '../../b-agentic/references/contract/02-source-of-truth.md'
  assert_file "$sandbox_antigravity/home/.gemini/antigravity-cli/b-agentic/install.json"
  assert_json_value "$sandbox_antigravity/home/.gemini/antigravity-cli/b-agentic/install.json" "data['runtime'] == 'antigravity-cli'"
  assert_json_value "$sandbox_antigravity/home/.gemini/antigravity-cli/b-agentic/install.json" "data['activationState'] == 'active'"
  assert_json_value "$sandbox_antigravity/home/.gemini/antigravity-cli/b-agentic/install.json" "data['commands'] == []"
  assert_json_value "$sandbox_antigravity/home/.gemini/antigravity-cli/b-agentic/install.json" "data['paths']['antigravityMcpConfig'].endswith('/.gemini/antigravity-cli/mcp_config.json')"
  assert_file "$sandbox_antigravity/home/.gemini/antigravity-cli/settings.json"
  assert_file "$sandbox_antigravity/home/.gemini/antigravity-cli/mcp_config.json"
  assert_json_value "$sandbox_antigravity/home/.gemini/antigravity-cli/settings.json" "data == {}"
  assert_json_value "$sandbox_antigravity/home/.gemini/antigravity-cli/mcp_config.json" "set(data['mcpServers']) == {'serena', 'context7', 'brave-search', 'firecrawl', 'playwright'}"
  assert_json_value "$sandbox_antigravity/home/.gemini/antigravity-cli/mcp_config.json" "data['mcpServers']['context7']['serverUrl'] == 'https://mcp.context7.com/mcp'"
  assert_json_value "$sandbox_antigravity/home/.gemini/antigravity-cli/mcp_config.json" "'httpUrl' not in data['mcpServers']['context7']"
  assert_json_value "$sandbox_antigravity/home/.gemini/antigravity-cli/mcp_config.json" "data['mcpServers']['context7']['headers']['CONTEXT7_API_KEY'] == '\$CONTEXT7_API_KEY'"
  assert_json_value "$sandbox_antigravity/home/.gemini/antigravity-cli/mcp_config.json" "data['mcpServers']['brave-search']['command'] == 'pnpm'"
  assert_json_value "$sandbox_antigravity/home/.gemini/antigravity-cli/mcp_config.json" "data['mcpServers']['firecrawl']['command'] == 'pnpm'"
  assert_json_value "$sandbox_antigravity/home/.gemini/antigravity-cli/mcp_config.json" "data['mcpServers']['playwright']['args'][-1] == '--isolated'"
  assert_file "$sandbox_antigravity/home/.gemini/antigravity-cli/b-agentic/references/contract/index.md"
  assert_file "$sandbox_antigravity/home/.gemini/antigravity-cli/b-agentic/templates/mcp_config.template.json"
  assert_no_path "$sandbox_antigravity/home/.gemini/settings.json"
  assert_no_path "$sandbox_antigravity/home/.gemini/skills"
  assert_no_path "$sandbox_antigravity/home/.claude"
  assert_no_path "$sandbox_antigravity/home/.config/opencode"
  assert_no_path "$sandbox_antigravity/home/.codex"

  mkdir -p "$sandbox_antigravity_cwd_repo/home" "$sandbox_antigravity_cwd_repo/current-repo"
  git -C "$sandbox_antigravity_cwd_repo/current-repo" init -q
  expect_install_status_in_cwd 0 "$sandbox_antigravity_cwd_repo/current-repo" "$sandbox_antigravity_cwd_repo" "$snapshot_repo" --runtime=antigravity-cli
  assert_no_path "$sandbox_antigravity_cwd_repo/current-repo/.b-agentic"
  expect_install_status_in_cwd 0 "$sandbox_antigravity_cwd_repo/current-repo" "$sandbox_antigravity_cwd_repo" "$snapshot_repo" --runtime=antigravity-cli --uninstall
  assert_no_path "$sandbox_antigravity_cwd_repo/current-repo/.b-agentic"

  mkdir -p "$sandbox_antigravity_preserve/home/.gemini"
  printf '# User Gemini Memory\n' > "$sandbox_antigravity_preserve/home/.gemini/GEMINI.md"
  expect_install_status 2 "$sandbox_antigravity_preserve" "$snapshot_repo" --runtime=antigravity-cli
  assert_contains "$sandbox_antigravity_preserve/home/.gemini/GEMINI.md" '# User Gemini Memory'
  assert_json_value "$sandbox_antigravity_preserve/home/.gemini/antigravity-cli/b-agentic/install.json" "data['activationState'] == 'pending'"

  mkdir -p "$sandbox_antigravity_replace/home/.gemini"
  printf '# User Gemini Memory\n' > "$sandbox_antigravity_replace/home/.gemini/GEMINI.md"
  expect_install_status 0 "$sandbox_antigravity_replace" "$snapshot_repo" --runtime=antigravity-cli --replace-memory
  assert_contains "$sandbox_antigravity_replace/home/.gemini/GEMINI.md" '<!-- b-agentic-managed -->'
  assert_json_value "$sandbox_antigravity_replace/home/.gemini/antigravity-cli/b-agentic/install.json" "data['memoryAction'] == 'replace'"
  assert_glob "$sandbox_antigravity_replace/home/.gemini/antigravity-cli/b-agentic/backups/GEMINI.md.bak-*"

  mkdir -p "$sandbox_antigravity_dry_run/home"
  expect_install_status 0 "$sandbox_antigravity_dry_run" "$snapshot_repo" --runtime=antigravity-cli --dry-run
  assert_no_path "$sandbox_antigravity_dry_run/home/.gemini"
  assert_no_path "$sandbox_antigravity_dry_run/source"

  mkdir -p "$sandbox_antigravity_prompt_keys/home"
  expect_install_with_tty_status 0 "$sandbox_antigravity_prompt_keys" "$snapshot_repo" $'ctx7-antigravity-key\nbrave-antigravity-key\nfirecrawl-antigravity-key\n' --runtime=antigravity-cli --prompt-api-keys
  assert_json_value "$sandbox_antigravity_prompt_keys/home/.gemini/antigravity-cli/mcp_config.json" "data['mcpServers']['context7']['headers']['CONTEXT7_API_KEY'] == 'ctx7-antigravity-key'"
  assert_json_value "$sandbox_antigravity_prompt_keys/home/.gemini/antigravity-cli/mcp_config.json" "data['mcpServers']['brave-search']['env']['BRAVE_API_KEY'] == 'brave-antigravity-key'"
  assert_json_value "$sandbox_antigravity_prompt_keys/home/.gemini/antigravity-cli/mcp_config.json" "data['mcpServers']['firecrawl']['env']['FIRECRAWL_API_KEY'] == 'firecrawl-antigravity-key'"
  assert_contains "$sandbox_antigravity_prompt_keys/home/.gemini/antigravity-cli/b-agentic/templates/mcp_config.template.json" '$BRAVE_API_KEY'
  assert_not_contains "$sandbox_antigravity_prompt_keys/home/.gemini/antigravity-cli/b-agentic/templates/mcp_config.template.json" 'brave-antigravity-key'
  expect_install_status 0 "$sandbox_antigravity_prompt_keys" "$snapshot_repo" --runtime=antigravity-cli --uninstall
  assert_no_path "$sandbox_antigravity_prompt_keys/home/.gemini/antigravity-cli/mcp_config.json"

  mkdir -p "$sandbox_antigravity_merge/home/.gemini/antigravity-cli"
  printf '{"mcpServers":{"custom":{"serverUrl":"https://example.com/mcp"}},"userOnly":true}\n' > "$sandbox_antigravity_merge/home/.gemini/antigravity-cli/mcp_config.json"
  expect_install_status 0 "$sandbox_antigravity_merge" "$snapshot_repo" --runtime=antigravity-cli
  assert_json_value "$sandbox_antigravity_merge/home/.gemini/antigravity-cli/mcp_config.json" "'custom' in data['mcpServers']"
  assert_json_value "$sandbox_antigravity_merge/home/.gemini/antigravity-cli/mcp_config.json" "data.get('userOnly') is True"
  expect_install_status 0 "$sandbox_antigravity_merge" "$snapshot_repo" --runtime=antigravity-cli --uninstall
  assert_json_value "$sandbox_antigravity_merge/home/.gemini/antigravity-cli/mcp_config.json" "set(data['mcpServers']) == {'custom'}"
  assert_json_value "$sandbox_antigravity_merge/home/.gemini/antigravity-cli/mcp_config.json" "data.get('userOnly') is True"

  mkdir -p "$sandbox_antigravity_legacy_upgrade/home/.gemini"
  printf '{"mcpServers":{"legacy":{"httpUrl":"https://legacy.example/mcp"}}}\n' > "$sandbox_antigravity_legacy_upgrade/home/.gemini/settings.json"
  expect_install_status 0 "$sandbox_antigravity_legacy_upgrade" "$snapshot_repo" --runtime=antigravity-cli
  assert_file "$sandbox_antigravity_legacy_upgrade/home/.gemini/settings.json"
  assert_json_value "$sandbox_antigravity_legacy_upgrade/home/.gemini/settings.json" "set(data['mcpServers']) == {'legacy'}"
  assert_json_value "$sandbox_antigravity_legacy_upgrade/home/.gemini/antigravity-cli/mcp_config.json" "'context7' in data['mcpServers']"
  assert_json_value "$sandbox_antigravity_legacy_upgrade/home/.gemini/antigravity-cli/mcp_config.json" "data['mcpServers']['context7']['serverUrl'] == 'https://mcp.context7.com/mcp'"

  expect_install_status 0 "$sandbox_antigravity" "$snapshot_repo" --runtime=antigravity-cli --uninstall
  assert_no_path "$sandbox_antigravity/home/.gemini/antigravity-cli/b-agentic"
  assert_no_path "$sandbox_antigravity/home/.gemini/GEMINI.md"
  assert_no_path "$sandbox_antigravity/home/.gemini/antigravity-cli/settings.json"
  assert_no_path "$sandbox_antigravity/home/.gemini/antigravity-cli/mcp_config.json"
}
