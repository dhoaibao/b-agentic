# Sourced by tests/smoke/install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by tests/smoke/install.sh" >&2
  exit 1
fi

run_runtime_smoke_cases() {
  local snapshot_repo="$1"
  local sandbox_opencode="$WORK_DIR/opencode"
  local sandbox_opencode_command_collision="$WORK_DIR/opencode-command-collision"
  local sandbox_opencode_identical_collision="$WORK_DIR/opencode-identical-collision"
  local sandbox_opencode_modified_command="$WORK_DIR/opencode-modified-command"
  local sandbox_opencode_prompt_keys="$WORK_DIR/opencode-prompt-keys"
  local sandbox_opencode_merge="$WORK_DIR/opencode-merge"
  local sandbox_opencode_mcp_migration="$WORK_DIR/opencode-mcp-migration"
  local sandbox_opencode_install_report="$WORK_DIR/opencode-install-report"
  local sandbox_opencode_cwd_repo="$WORK_DIR/opencode-cwd-repo"

  mkdir -p "$sandbox_opencode/home"
  expect_install_status 0 "$sandbox_opencode" "$snapshot_repo" --runtime=opencode
  assert_file "$sandbox_opencode/home/.config/opencode/AGENTS.md"
  assert_contains "$sandbox_opencode/home/.config/opencode/AGENTS.md" '<!-- b-agentic-managed -->'
  assert_file "$sandbox_opencode/home/.claude/skills/b-plan/SKILL.md"
  assert_file "$sandbox_opencode/home/.config/opencode/commands/b-plan.md"
  assert_contains "$sandbox_opencode/home/.config/opencode/commands/b-plan.md" 'Load the `b-plan` skill'
  assert_file "$sandbox_opencode/home/.config/opencode/b-agentic/install.json"
  assert_contains "$sandbox_opencode/home/.config/opencode/b-agentic/install.json" '"runtime": "opencode"'
  assert_contains "$sandbox_opencode/home/.config/opencode/b-agentic/install.json" '"activationState": "active"'
  assert_contains "$sandbox_opencode/home/.config/opencode/b-agentic/install.json" '"mcpAction": "write"'
  assert_json_value "$sandbox_opencode/home/.config/opencode/b-agentic/install.json" "'b-plan' in data['commands']"
  assert_json_value "$sandbox_opencode/home/.config/opencode/b-agentic/install.json" "data['paths']['commands'].endswith('/.config/opencode/commands')"
  assert_no_path "$sandbox_opencode/home/.claude.json"
  assert_no_path "$sandbox_opencode/home/.claude/settings.json"
  assert_file "$sandbox_opencode/home/.config/opencode/opencode.json"
  assert_json_value "$sandbox_opencode/home/.config/opencode/opencode.json" "set(data['mcp']) == {'serena', 'context7', 'brave-search', 'firecrawl', 'playwright', 'gitnexus'}"
  assert_json_value "$sandbox_opencode/home/.config/opencode/opencode.json" "data['mcp']['serena']['command'] == ['serena', 'start-mcp-server', '--context', 'ide', '--project-from-cwd']"
  assert_json_value "$sandbox_opencode/home/.config/opencode/opencode.json" "data['mcp']['context7']['headers']['CONTEXT7_API_KEY'] == '{env:CONTEXT7_API_KEY}'"
  assert_json_value "$sandbox_opencode/home/.config/opencode/opencode.json" "data['mcp']['brave-search']['command'][0] == 'bunx'"
  assert_json_value "$sandbox_opencode/home/.config/opencode/opencode.json" "data['mcp']['firecrawl']['command'][0] == 'bunx'"
  assert_json_value "$sandbox_opencode/home/.config/opencode/opencode.json" "data['mcp']['playwright']['command'][0] == 'bunx'"
  assert_json_value "$sandbox_opencode/home/.config/opencode/opencode.json" "data['mcp']['playwright']['command'][-1] == '--isolated'"
  assert_json_value "$sandbox_opencode/home/.config/opencode/opencode.json" "data['mcp']['gitnexus']['command'] == ['gitnexus', 'mcp']"
  assert_file "$sandbox_opencode/home/.config/opencode/b-agentic/references/contract/index.md"
  assert_not_contains "$sandbox_opencode/home/.config/opencode/b-agentic/references/contract/index.md" 'The active runtime kernel lives in `CLAUDE.md` (Claude Code) or `AGENTS.md` (OpenCode)'
  assert_not_contains "$sandbox_opencode/home/.config/opencode/b-agentic/references/contract/00-kernel.md" 'runtimes/claude-code/kernel.md'
  assert_not_contains "$sandbox_opencode/home/.config/opencode/b-agentic/references/contract/05-evidence.md" 'active `CLAUDE.md`'
  assert_not_contains "$sandbox_opencode/home/.config/opencode/b-agentic/references/contract/06-safety.md" 'Use `~/.claude/b-agentic/...` or `/tmp/claude-code/b-agentic/...` instead by default.'
  assert_not_contains "$sandbox_opencode/home/.config/opencode/b-agentic/references/contract/07-execution.md" 'save the full output under `/tmp/claude-code/b-agentic/<skill>/<slug>.log`'
  assert_not_contains "$sandbox_opencode/home/.config/opencode/b-agentic/references/contract/08-artifacts.md" 'auth/session state and similar secrets default to `~/.claude/b-agentic/<skill>/<run-id>/` or `/tmp/claude-code/b-agentic/<skill>/<run-id>/`'
  assert_not_contains "$sandbox_opencode/home/.config/opencode/b-agentic/references/contract/10-decisions.md" 'capture the failing output under `/tmp/claude-code/b-agentic/b-test/`'
  assert_not_contains "$sandbox_opencode/home/.claude/skills/b-plan/SKILL.md" 'CLAUDE.md section 3'
  assert_not_contains "$sandbox_opencode/home/.claude/skills/b-plan/SKILL.md" 'per `CLAUDE.md` §3'
  assert_not_contains "$sandbox_opencode/home/.claude/skills/b-implement/SKILL.md" 'CLAUDE.md section 3'
  assert_not_contains "$sandbox_opencode/home/.claude/skills/b-research/SKILL.md" 'approval-gated by `CLAUDE.md`'
  assert_not_contains "$sandbox_opencode/home/.claude/skills/b-plan/references/b-agentic/contract/index.md" 'The active runtime kernel lives in `CLAUDE.md` (Claude Code) or `AGENTS.md` (OpenCode)'
  assert_not_contains "$sandbox_opencode/home/.claude/skills/b-plan/references/b-agentic/contract/00-kernel.md" 'runtimes/claude-code/kernel.md'
  assert_not_contains "$sandbox_opencode/home/.claude/skills/b-plan/references/b-agentic/contract/05-evidence.md" 'active `CLAUDE.md`'
  assert_not_contains "$sandbox_opencode/home/.claude/skills/b-plan/references/b-agentic/contract/06-safety.md" 'Use `~/.claude/b-agentic/...` or `/tmp/claude-code/b-agentic/...` instead by default.'
  assert_not_contains "$sandbox_opencode/home/.claude/skills/b-plan/references/b-agentic/contract/07-execution.md" 'save the full output under `/tmp/claude-code/b-agentic/<skill>/<slug>.log`'
  assert_not_contains "$sandbox_opencode/home/.claude/skills/b-plan/references/b-agentic/contract/08-artifacts.md" 'auth/session state and similar secrets default to `~/.claude/b-agentic/<skill>/<run-id>/` or `/tmp/claude-code/b-agentic/<skill>/<run-id>/`'
  assert_not_contains "$sandbox_opencode/home/.claude/skills/b-plan/references/b-agentic/contract/10-decisions.md" 'capture the failing output under `/tmp/claude-code/b-agentic/b-test/`'

  mkdir -p "$sandbox_opencode_install_report/home"
  HOME="$sandbox_opencode_install_report/home" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox_opencode_install_report/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  bash "$ROOT_DIR/install.sh" --runtime=opencode >"$sandbox_opencode_install_report/install.log" 2>&1
  assert_contains "$sandbox_opencode_install_report/install.log" 'mcpReadiness:'
  assert_contains "$sandbox_opencode_install_report/install.log" 'serena: install/init separately; installer never runs onboarding'
  assert_contains "$sandbox_opencode_install_report/install.log" 'gitnexus: install/index separately if you want graph radar'
  assert_contains "$sandbox_opencode_install_report/install.log" 'api-keys: Context7, Brave Search, and Firecrawl need user-scope keys'

  mkdir -p "$sandbox_opencode_cwd_repo/home" "$sandbox_opencode_cwd_repo/current-repo"
  git -C "$sandbox_opencode_cwd_repo/current-repo" init -q
  expect_install_status_in_cwd 0 "$sandbox_opencode_cwd_repo/current-repo" "$sandbox_opencode_cwd_repo" "$snapshot_repo" --runtime=opencode
  assert_no_path "$sandbox_opencode_cwd_repo/current-repo/.b-agentic"
  expect_install_status_in_cwd 0 "$sandbox_opencode_cwd_repo/current-repo" "$sandbox_opencode_cwd_repo" "$snapshot_repo" --runtime=opencode --uninstall
  assert_no_path "$sandbox_opencode_cwd_repo/current-repo/.b-agentic"

  expect_install_status 0 "$sandbox_opencode" "$snapshot_repo" --runtime=opencode --uninstall
  assert_no_path "$sandbox_opencode/home/.config/opencode/b-agentic"
  assert_no_path "$sandbox_opencode/home/.config/opencode/opencode.json"
  assert_no_path "$sandbox_opencode/home/.config/opencode/commands/b-plan.md"

  mkdir -p "$sandbox_opencode_command_collision/home/.config/opencode/commands"
  printf 'user command\n' > "$sandbox_opencode_command_collision/home/.config/opencode/commands/b-plan.md"
  expect_install_status 0 "$sandbox_opencode_command_collision" "$snapshot_repo" --runtime=opencode
  assert_contains "$sandbox_opencode_command_collision/home/.config/opencode/commands/b-plan.md" 'user command'
  assert_json_value "$sandbox_opencode_command_collision/home/.config/opencode/b-agentic/install.json" "'b-plan' not in data['commands']"
  expect_install_status 0 "$sandbox_opencode_command_collision" "$snapshot_repo" --runtime=opencode --uninstall
  assert_contains "$sandbox_opencode_command_collision/home/.config/opencode/commands/b-plan.md" 'user command'

  mkdir -p "$sandbox_opencode_identical_collision/home/.config/opencode/commands"
  cp "$snapshot_repo/runtimes/opencode/commands/b-plan.md" "$sandbox_opencode_identical_collision/home/.config/opencode/commands/b-plan.md"
  expect_install_status 0 "$sandbox_opencode_identical_collision" "$snapshot_repo" --runtime=opencode
  assert_json_value "$sandbox_opencode_identical_collision/home/.config/opencode/b-agentic/install.json" "'b-plan' not in data['commands']"
  expect_install_status 0 "$sandbox_opencode_identical_collision" "$snapshot_repo" --runtime=opencode --uninstall
  assert_file "$sandbox_opencode_identical_collision/home/.config/opencode/commands/b-plan.md"
  assert_contains "$sandbox_opencode_identical_collision/home/.config/opencode/commands/b-plan.md" 'Load the `b-plan` skill'

  mkdir -p "$sandbox_opencode_modified_command/home"
  expect_install_status 0 "$sandbox_opencode_modified_command" "$snapshot_repo" --runtime=opencode
  printf 'user edit\n' >> "$sandbox_opencode_modified_command/home/.config/opencode/commands/b-plan.md"
  expect_install_status 0 "$sandbox_opencode_modified_command" "$snapshot_repo" --runtime=opencode --uninstall
  assert_file "$sandbox_opencode_modified_command/home/.config/opencode/commands/b-plan.md"
  assert_contains "$sandbox_opencode_modified_command/home/.config/opencode/commands/b-plan.md" 'user edit'

  mkdir -p "$sandbox_opencode_prompt_keys/home"
  expect_install_with_tty_status 0 "$sandbox_opencode_prompt_keys" "$snapshot_repo" $'ctx7-oc-key\nbrave-oc-key\nfirecrawl-oc-key\n' --runtime=opencode --prompt-api-keys
  assert_json_value "$sandbox_opencode_prompt_keys/home/.config/opencode/opencode.json" "data['mcp']['context7']['headers']['CONTEXT7_API_KEY'] == 'ctx7-oc-key'"
  assert_json_value "$sandbox_opencode_prompt_keys/home/.config/opencode/opencode.json" "data['mcp']['brave-search']['environment']['BRAVE_API_KEY'] == 'brave-oc-key'"
  assert_json_value "$sandbox_opencode_prompt_keys/home/.config/opencode/opencode.json" "data['mcp']['firecrawl']['environment']['FIRECRAWL_API_KEY'] == 'firecrawl-oc-key'"
  assert_contains "$sandbox_opencode_prompt_keys/home/.config/opencode/b-agentic/templates/mcp.user.template.json" '{env:BRAVE_API_KEY}'
  assert_not_contains "$sandbox_opencode_prompt_keys/home/.config/opencode/b-agentic/templates/mcp.user.template.json" 'brave-oc-key'
  expect_install_status 0 "$sandbox_opencode_prompt_keys" "$snapshot_repo" --runtime=opencode --uninstall
  assert_no_path "$sandbox_opencode_prompt_keys/home/.config/opencode/opencode.json"

  mkdir -p "$sandbox_opencode_merge/home/.config/opencode"
  printf '{"mcp":{"my-custom":{"type":"local","command":["my-tool"]}},"userOnly":true}\n' > "$sandbox_opencode_merge/home/.config/opencode/opencode.json"
  expect_install_status 0 "$sandbox_opencode_merge" "$snapshot_repo" --runtime=opencode
  assert_json_value "$sandbox_opencode_merge/home/.config/opencode/opencode.json" "'my-custom' in data['mcp']"
  assert_json_value "$sandbox_opencode_merge/home/.config/opencode/opencode.json" "'gitnexus' in data['mcp']"
  assert_json_value "$sandbox_opencode_merge/home/.config/opencode/opencode.json" "data.get('userOnly') is True"
  assert_contains "$sandbox_opencode_merge/home/.config/opencode/b-agentic/install.json" '"mcpAction": "merge"'
  expect_install_status 0 "$sandbox_opencode_merge" "$snapshot_repo" --runtime=opencode --uninstall
  assert_json_value "$sandbox_opencode_merge/home/.config/opencode/opencode.json" "set(data['mcp']) == {'my-custom'}"
  assert_json_value "$sandbox_opencode_merge/home/.config/opencode/opencode.json" "data.get('userOnly') is True"

  mkdir -p "$sandbox_opencode_mcp_migration/home/.config/opencode"
  printf '{"mcp":{"brave-search":{"type":"local","command":["npx","-y","@brave/brave-search-mcp-server","--transport","stdio"],"environment":{"BRAVE_API_KEY":"{env:BRAVE_API_KEY}"}},"firecrawl":{"type":"local","command":["npx","-y","firecrawl-mcp"],"environment":{"FIRECRAWL_API_KEY":"{env:FIRECRAWL_API_KEY}"}},"playwright":{"type":"local","command":["npx","-y","@playwright/mcp@latest","--isolated"]}}}\n' > "$sandbox_opencode_mcp_migration/home/.config/opencode/opencode.json"
  expect_install_status 0 "$sandbox_opencode_mcp_migration" "$snapshot_repo" --runtime=opencode
  assert_json_value "$sandbox_opencode_mcp_migration/home/.config/opencode/opencode.json" "data['mcp']['brave-search']['command'] == ['bunx', '@brave/brave-search-mcp-server', '--transport', 'stdio']"
  assert_json_value "$sandbox_opencode_mcp_migration/home/.config/opencode/opencode.json" "data['mcp']['firecrawl']['command'] == ['bunx', 'firecrawl-mcp']"
  assert_json_value "$sandbox_opencode_mcp_migration/home/.config/opencode/opencode.json" "data['mcp']['playwright']['command'] == ['bunx', '@playwright/mcp@latest', '--isolated']"
}
