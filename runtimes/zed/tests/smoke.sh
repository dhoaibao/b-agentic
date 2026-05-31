# Sourced by tests/smoke/install.sh - do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by tests/smoke/install.sh" >&2
  exit 1
fi

run_runtime_smoke_cases() {
  local snapshot_repo="$1"
  local sandbox_zed="$WORK_DIR/zed"
  local sandbox_zed_preserve="$WORK_DIR/zed-preserve"
  local sandbox_zed_replace="$WORK_DIR/zed-replace"
  local sandbox_zed_dry_run="$WORK_DIR/zed-dry-run"
  local sandbox_zed_prompt_keys="$WORK_DIR/zed-prompt-keys"
  local sandbox_zed_merge="$WORK_DIR/zed-merge"
  local sandbox_zed_cwd_repo="$WORK_DIR/zed-cwd-repo"

  mkdir -p "$sandbox_zed/home"
  expect_install_status 0 "$sandbox_zed" "$snapshot_repo" --runtime=zed
  assert_file "$sandbox_zed/home/.config/zed/AGENTS.md"
  assert_contains "$sandbox_zed/home/.config/zed/AGENTS.md" '<!-- b-agentic-managed -->'
  assert_file "$sandbox_zed/home/.agents/skills/b-plan/SKILL.md"
  assert_file "$sandbox_zed/home/.agents/skills/b-plan/reference.md"
  assert_file "$sandbox_zed/home/.agents/skills/b-review/SKILL.md"
  assert_contains "$sandbox_zed/home/.agents/skills/b-review/SKILL.md" 'self-audits when explicitly requested or invoked with `--audit-suite`'
  assert_contains "$sandbox_zed/home/.agents/skills/b-review/SKILL.md" 'with or without `--audit-suite`'
  assert_not_contains "$sandbox_zed/home/.agents/skills/b-review/SKILL.md" 'suite self-audit without `--audit-suite` -> ask'
  assert_not_contains "$sandbox_zed/home/.agents/skills/b-review/SKILL.md" 'Do NOT invoke for repo/suite audits'
  assert_contains "$sandbox_zed/home/.config/zed/AGENTS.md" 'Avoid common runtime rationalizations such as opportunistic scope expansion'
  assert_not_contains "$sandbox_zed/home/.config/zed/AGENTS.md" '"I'\''ll fix this adjacent thing while I'\''m here."'
  assert_contains "$sandbox_zed/home/.agents/skills/b-plan/reference.md" '../../b-agentic/references/contract/02-source-of-truth.md'
  assert_file "$sandbox_zed/home/.agents/b-agentic/install.json"
  assert_json_value "$sandbox_zed/home/.agents/b-agentic/install.json" "data['runtime'] == 'zed'"
  assert_json_value "$sandbox_zed/home/.agents/b-agentic/install.json" "data['activationState'] == 'active'"
  assert_json_value "$sandbox_zed/home/.agents/b-agentic/install.json" "data['commands'] == []"
  assert_json_value "$sandbox_zed/home/.agents/b-agentic/install.json" "data['paths']['zedSettings'].endswith('/.config/zed/settings.json')"
  assert_file "$sandbox_zed/home/.config/zed/settings.json"
  assert_json_value "$sandbox_zed/home/.config/zed/settings.json" "set(data['context_servers']) == {'serena', 'context7', 'brave-search', 'firecrawl', 'playwright'}"
  assert_json_value "$sandbox_zed/home/.config/zed/settings.json" "data['context_servers']['context7']['url'] == 'https://mcp.context7.com/mcp'"
  assert_json_value "$sandbox_zed/home/.config/zed/settings.json" "'serverUrl' not in data['context_servers']['context7']"
  assert_json_value "$sandbox_zed/home/.config/zed/settings.json" "data['context_servers']['context7']['headers']['CONTEXT7_API_KEY'] == '\$CONTEXT7_API_KEY'"
  assert_json_value "$sandbox_zed/home/.config/zed/settings.json" "data['context_servers']['brave-search']['command'] == 'pnpm'"
  assert_json_value "$sandbox_zed/home/.config/zed/settings.json" "data['context_servers']['firecrawl']['command'] == 'pnpm'"
  assert_json_value "$sandbox_zed/home/.config/zed/settings.json" "data['context_servers']['playwright']['args'][-1] == '--isolated'"
  assert_file "$sandbox_zed/home/.agents/b-agentic/references/contract/index.md"
  assert_file "$sandbox_zed/home/.agents/b-agentic/templates/mcp.user.template.json"
  assert_no_path "$sandbox_zed/home/.claude"
  assert_no_path "$sandbox_zed/home/.gemini"
  assert_no_path "$sandbox_zed/home/.config/opencode"
  assert_no_path "$sandbox_zed/home/.codex"

  mkdir -p "$sandbox_zed_cwd_repo/home" "$sandbox_zed_cwd_repo/current-repo"
  git -C "$sandbox_zed_cwd_repo/current-repo" init -q
  expect_install_status_in_cwd 0 "$sandbox_zed_cwd_repo/current-repo" "$sandbox_zed_cwd_repo" "$snapshot_repo" --runtime=zed
  assert_no_path "$sandbox_zed_cwd_repo/current-repo/.b-agentic"
  expect_install_status_in_cwd 0 "$sandbox_zed_cwd_repo/current-repo" "$sandbox_zed_cwd_repo" "$snapshot_repo" --runtime=zed --uninstall
  assert_no_path "$sandbox_zed_cwd_repo/current-repo/.b-agentic"

  mkdir -p "$sandbox_zed_preserve/home/.config/zed"
  printf '# User Zed Memory\n' > "$sandbox_zed_preserve/home/.config/zed/AGENTS.md"
  expect_install_status 2 "$sandbox_zed_preserve" "$snapshot_repo" --runtime=zed
  assert_contains "$sandbox_zed_preserve/home/.config/zed/AGENTS.md" '# User Zed Memory'
  assert_json_value "$sandbox_zed_preserve/home/.agents/b-agentic/install.json" "data['activationState'] == 'pending'"

  mkdir -p "$sandbox_zed_replace/home/.config/zed"
  printf '# User Zed Memory\n' > "$sandbox_zed_replace/home/.config/zed/AGENTS.md"
  expect_install_status 0 "$sandbox_zed_replace" "$snapshot_repo" --runtime=zed --replace-memory
  assert_contains "$sandbox_zed_replace/home/.config/zed/AGENTS.md" '<!-- b-agentic-managed -->'
  assert_json_value "$sandbox_zed_replace/home/.agents/b-agentic/install.json" "data['memoryAction'] == 'replace'"
  assert_glob "$sandbox_zed_replace/home/.agents/b-agentic/backups/AGENTS.md.bak-*"

  mkdir -p "$sandbox_zed_dry_run/home"
  expect_install_status 0 "$sandbox_zed_dry_run" "$snapshot_repo" --runtime=zed --dry-run
  assert_no_path "$sandbox_zed_dry_run/home/.config/zed"
  assert_no_path "$sandbox_zed_dry_run/source"

  mkdir -p "$sandbox_zed_prompt_keys/home"
  expect_install_with_tty_status 0 "$sandbox_zed_prompt_keys" "$snapshot_repo" $'ctx7-zed-key\nbrave-zed-key\nfirecrawl-zed-key\n' --runtime=zed --prompt-api-keys
  assert_json_value "$sandbox_zed_prompt_keys/home/.config/zed/settings.json" "data['context_servers']['context7']['headers']['CONTEXT7_API_KEY'] == 'ctx7-zed-key'"
  assert_json_value "$sandbox_zed_prompt_keys/home/.config/zed/settings.json" "data['context_servers']['brave-search']['env']['BRAVE_API_KEY'] == 'brave-zed-key'"
  assert_json_value "$sandbox_zed_prompt_keys/home/.config/zed/settings.json" "data['context_servers']['firecrawl']['env']['FIRECRAWL_API_KEY'] == 'firecrawl-zed-key'"
  assert_contains "$sandbox_zed_prompt_keys/home/.agents/b-agentic/templates/mcp.user.template.json" '$BRAVE_API_KEY'
  assert_not_contains "$sandbox_zed_prompt_keys/home/.agents/b-agentic/templates/mcp.user.template.json" 'brave-zed-key'
  expect_install_status 0 "$sandbox_zed_prompt_keys" "$snapshot_repo" --runtime=zed --uninstall
  assert_no_path "$sandbox_zed_prompt_keys/home/.config/zed/settings.json"

  mkdir -p "$sandbox_zed_merge/home/.config/zed"
  printf '{"context_servers":{"custom":{"url":"https://example.com/mcp"}},"userOnly":true}\n' > "$sandbox_zed_merge/home/.config/zed/settings.json"
  expect_install_status 0 "$sandbox_zed_merge" "$snapshot_repo" --runtime=zed
  assert_json_value "$sandbox_zed_merge/home/.config/zed/settings.json" "'custom' in data['context_servers']"
  assert_json_value "$sandbox_zed_merge/home/.config/zed/settings.json" "data.get('userOnly') is True"
  expect_install_status 0 "$sandbox_zed_merge" "$snapshot_repo" --runtime=zed --uninstall
  assert_json_value "$sandbox_zed_merge/home/.config/zed/settings.json" "set(data['context_servers']) == {'custom'}"
  assert_json_value "$sandbox_zed_merge/home/.config/zed/settings.json" "data.get('userOnly') is True"

  expect_install_status 0 "$sandbox_zed" "$snapshot_repo" --runtime=zed --uninstall
  assert_no_path "$sandbox_zed/home/.agents/b-agentic"
  assert_no_path "$sandbox_zed/home/.config/zed/AGENTS.md"
  assert_no_path "$sandbox_zed/home/.config/zed/settings.json"
}
