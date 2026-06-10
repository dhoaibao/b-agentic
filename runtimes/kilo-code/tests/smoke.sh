# Sourced by tests/smoke/install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by tests/smoke/install.sh" >&2
  exit 1
fi

run_runtime_smoke_cases() {
  local snapshot_repo="$1"
  local sandbox_kilo="$WORK_DIR/kilo"
  local sandbox_kilo_collision="$WORK_DIR/kilo-collision"
  local sandbox_kilo_identical="$WORK_DIR/kilo-identical"
  local sandbox_kilo_modified="$WORK_DIR/kilo-modified"
  local sandbox_kilo_merge="$WORK_DIR/kilo-merge"
  local sandbox_kilo_prompt_keys="$WORK_DIR/kilo-prompt-keys"
  local sandbox_kilo_install_report="$WORK_DIR/kilo-install-report"

  mkdir -p "$sandbox_kilo/home"
  expect_install_status 0 "$sandbox_kilo" "$snapshot_repo" --runtime=kilo-code
  assert_file "$sandbox_kilo/home/.config/kilo/AGENTS.md"
  assert_contains "$sandbox_kilo/home/.config/kilo/AGENTS.md" '<!-- b-agentic-managed -->'
  assert_file "$sandbox_kilo/home/.config/kilo/skills/b-plan/SKILL.md"
  assert_file "$sandbox_kilo/home/.config/kilo/skills/b-plan/reference.md"
  assert_file "$sandbox_kilo/home/.config/kilo/agents/b-explore.md"
  assert_file "$sandbox_kilo/home/.config/kilo/agents/b-research.md"
  assert_file "$sandbox_kilo/home/.config/kilo/agents/b-review.md"
  assert_file "$sandbox_kilo/home/.config/kilo/agents/b-verify.md"
  assert_file "$sandbox_kilo/home/.config/kilo/b-agentic/install.json"
  assert_contains "$sandbox_kilo/home/.config/kilo/b-agentic/install.json" '"runtime": "kilo-code"'
  assert_contains "$sandbox_kilo/home/.config/kilo/b-agentic/install.json" '"activationState": "active"'
  assert_contains "$sandbox_kilo/home/.config/kilo/b-agentic/install.json" '"mcpAction": "write"'
  assert_file "$sandbox_kilo/home/.config/kilo/kilo.jsonc"
  assert_json_value "$sandbox_kilo/home/.config/kilo/kilo.jsonc" "set(data['mcp']) == {'serena', 'context7', 'brave-search', 'firecrawl', 'playwright'}"
  assert_json_value "$sandbox_kilo/home/.config/kilo/kilo.jsonc" "data['mcp']['serena']['command'] == ['serena', 'start-mcp-server', '--context', 'ide', '--project-from-cwd']"
  assert_json_value "$sandbox_kilo/home/.config/kilo/kilo.jsonc" "data['mcp']['context7']['headers']['CONTEXT7_API_KEY'] == '{env:CONTEXT7_API_KEY}'"
  assert_json_value "$sandbox_kilo/home/.config/kilo/kilo.jsonc" "data['mcp']['brave-search']['command'][0] == 'pnpm'"
  assert_json_value "$sandbox_kilo/home/.config/kilo/kilo.jsonc" "data['mcp']['firecrawl']['command'][0] == 'pnpm'"
  assert_json_value "$sandbox_kilo/home/.config/kilo/kilo.jsonc" "data['mcp']['playwright']['command'][0] == 'pnpm'"
  assert_json_value "$sandbox_kilo/home/.config/kilo/kilo.jsonc" "data['mcp']['playwright']['command'][-1] == '--isolated'"
  assert_json_value "$sandbox_kilo/home/.config/kilo/kilo.jsonc" "'~/.config/kilo/skills' in data.get('skills', {}).get('paths', [])"
  assert_file "$sandbox_kilo/home/.config/kilo/b-agentic/references/contract/runtime.md"
  assert_file "$sandbox_kilo/home/.config/kilo/b-agentic/references/contract/safety-tools.md"
  assert_file "$sandbox_kilo/home/.config/kilo/b-agentic/references/contract/output.md"
  assert_file "$sandbox_kilo/home/.config/kilo/b-agentic/references/contract/decisions.md"

  mkdir -p "$sandbox_kilo_install_report/home"
  HOME="$sandbox_kilo_install_report/home" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox_kilo_install_report/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  bash "$ROOT_DIR/install.sh" --runtime=kilo-code >"$sandbox_kilo_install_report/install.log" 2>&1
  assert_contains "$sandbox_kilo_install_report/install.log" '==> [1/7] Syncing skills'
  assert_contains "$sandbox_kilo_install_report/install.log" 'Summary:'
  assert_contains "$sandbox_kilo_install_report/install.log" 'activation: active'
  assert_contains "$sandbox_kilo_install_report/install.log" 'agents: '
  assert_contains "$sandbox_kilo_install_report/install.log" 'Readiness:'
  assert_contains "$sandbox_kilo_install_report/install.log" 'serena: install/init separately; installer never runs onboarding'
  assert_contains "$sandbox_kilo_install_report/install.log" 'mcp-config: templates installed only; external MCP servers are not started or authenticated by installer'
  assert_contains "$sandbox_kilo_install_report/install.log" 'api-keys: Context7, Brave Search, and Firecrawl need user-scope keys'
  assert_contains "$sandbox_kilo_install_report/install.log" 'Next steps:'
  assert_contains "$sandbox_kilo_install_report/install.log" 'launch: start a new Kilo Code session so it picks up'

  expect_install_status 0 "$sandbox_kilo" "$snapshot_repo" --runtime=kilo-code --uninstall
  assert_no_path "$sandbox_kilo/home/.config/kilo/b-agentic"
  assert_no_path "$sandbox_kilo/home/.config/kilo/kilo.jsonc"
  assert_no_path "$sandbox_kilo/home/.config/kilo/agents/b-explore.md"

  mkdir -p "$sandbox_kilo_collision/home/.config/kilo/agents"
  printf 'user agent\n' > "$sandbox_kilo_collision/home/.config/kilo/agents/b-explore.md"
  expect_install_status 0 "$sandbox_kilo_collision" "$snapshot_repo" --runtime=kilo-code
  assert_contains "$sandbox_kilo_collision/home/.config/kilo/agents/b-explore.md" 'user agent'
  expect_install_status 0 "$sandbox_kilo_collision" "$snapshot_repo" --runtime=kilo-code --uninstall
  assert_contains "$sandbox_kilo_collision/home/.config/kilo/agents/b-explore.md" 'user agent'

  mkdir -p "$sandbox_kilo_identical/home/.config/kilo/agents"
  cp "$snapshot_repo/runtimes/kilo-code/agents/b-explore.md" "$sandbox_kilo_identical/home/.config/kilo/agents/b-explore.md"
  expect_install_status 0 "$sandbox_kilo_identical" "$snapshot_repo" --runtime=kilo-code
  assert_file "$sandbox_kilo_identical/home/.config/kilo/agents/b-explore.md"
  expect_install_status 0 "$sandbox_kilo_identical" "$snapshot_repo" --runtime=kilo-code --uninstall
  assert_file "$sandbox_kilo_identical/home/.config/kilo/agents/b-explore.md"

  mkdir -p "$sandbox_kilo_modified/home"
  expect_install_status 0 "$sandbox_kilo_modified" "$snapshot_repo" --runtime=kilo-code
  printf 'user edit\n' >> "$sandbox_kilo_modified/home/.config/kilo/agents/b-explore.md"
  expect_install_status 0 "$sandbox_kilo_modified" "$snapshot_repo" --runtime=kilo-code --uninstall
  assert_file "$sandbox_kilo_modified/home/.config/kilo/agents/b-explore.md"
  assert_contains "$sandbox_kilo_modified/home/.config/kilo/agents/b-explore.md" 'user edit'

  mkdir -p "$sandbox_kilo_merge/home/.config/kilo"
  printf '{"mcp":{"my-custom":{"type":"local","command":["my-tool"]}},"userOnly":true}\n' > "$sandbox_kilo_merge/home/.config/kilo/kilo.jsonc"
  expect_install_status 0 "$sandbox_kilo_merge" "$snapshot_repo" --runtime=kilo-code
  assert_json_value "$sandbox_kilo_merge/home/.config/kilo/kilo.jsonc" "'my-custom' in data['mcp']"
  assert_json_value "$sandbox_kilo_merge/home/.config/kilo/kilo.jsonc" "data.get('userOnly') is True"
  assert_contains "$sandbox_kilo_merge/home/.config/kilo/b-agentic/install.json" '"mcpAction": "merge"'
  expect_install_status 0 "$sandbox_kilo_merge" "$snapshot_repo" --runtime=kilo-code --uninstall
  assert_json_value "$sandbox_kilo_merge/home/.config/kilo/kilo.jsonc" "set(data['mcp']) == {'my-custom'}"
  assert_json_value "$sandbox_kilo_merge/home/.config/kilo/kilo.jsonc" "data.get('userOnly') is True"

  mkdir -p "$sandbox_kilo_prompt_keys/home"
  expect_install_with_tty_status 0 "$sandbox_kilo_prompt_keys" "$snapshot_repo" $'ctx7-kilo-key\nbrave-kilo-key\nfirecrawl-kilo-key\nhttps://firecrawl.kilo\n' --runtime=kilo-code --prompt-api-keys
  assert_json_value "$sandbox_kilo_prompt_keys/home/.config/kilo/kilo.jsonc" "data['mcp']['context7']['headers']['CONTEXT7_API_KEY'] == 'ctx7-kilo-key'"
  assert_json_value "$sandbox_kilo_prompt_keys/home/.config/kilo/kilo.jsonc" "data['mcp']['brave-search']['environment']['BRAVE_API_KEY'] == 'brave-kilo-key'"
  assert_json_value "$sandbox_kilo_prompt_keys/home/.config/kilo/kilo.jsonc" "data['mcp']['firecrawl']['environment']['FIRECRAWL_API_KEY'] == 'firecrawl-kilo-key'"
  assert_json_value "$sandbox_kilo_prompt_keys/home/.config/kilo/kilo.jsonc" "data['mcp']['firecrawl']['environment']['FIRECRAWL_API_URL'] == 'https://firecrawl.kilo'"
  assert_contains "$sandbox_kilo_prompt_keys/home/.config/kilo/b-agentic/templates/mcp.user.template.json" '{env:BRAVE_API_KEY}'
  assert_not_contains "$sandbox_kilo_prompt_keys/home/.config/kilo/b-agentic/templates/mcp.user.template.json" 'brave-kilo-key'
  expect_install_status 0 "$sandbox_kilo_prompt_keys" "$snapshot_repo" --runtime=kilo-code --uninstall
  assert_no_path "$sandbox_kilo_prompt_keys/home/.config/kilo/kilo.jsonc"
}
