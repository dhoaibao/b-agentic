# Sourced by tests/smoke/install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by tests/smoke/install.sh" >&2
  exit 1
fi

run_runtime_smoke_cases() {
  local snapshot_repo="$1"
  local sandbox_fresh="$WORK_DIR/fresh"
  local sandbox_preserve="$WORK_DIR/preserve"
  local sandbox_replace="$WORK_DIR/replace"
  local sandbox_dry_run="$WORK_DIR/dry-run"
  local sandbox_config="$WORK_DIR/config"
  local sandbox_uninstall="$WORK_DIR/uninstall"
  local sandbox_mcp_migration="$WORK_DIR/mcp-migration"
  local sandbox_prompt_keys="$WORK_DIR/prompt-keys"
  local sandbox_prompt_reinstall="$WORK_DIR/prompt-reinstall"
  local sandbox_settings_merge="$WORK_DIR/settings-merge"
  local sandbox_fresh_modified="$WORK_DIR/fresh-modified"
  local sandbox_invalid_json="$WORK_DIR/invalid-json"
  local sandbox_profile_dry_run="$WORK_DIR/profile-dry-run"
  local sandbox_install_report="$WORK_DIR/install-report"

  mkdir -p "$sandbox_fresh/home"
  expect_install_status 0 "$sandbox_fresh" "$snapshot_repo"
  assert_file "$sandbox_fresh/home/.claude/skills/b-plan/SKILL.md"
  assert_file "$sandbox_fresh/home/.claude/skills/b-browser/SKILL.md"
  assert_file "$sandbox_fresh/home/.claude/skills/b-review/reference.md"
  assert_file "$sandbox_fresh/home/.claude/skills/b-plan/references/b-agentic/contract/index.md"
  assert_file "$sandbox_fresh/home/.claude/skills/b-plan/references/b-agentic/performance-checklist.md"
  assert_file "$sandbox_fresh/home/.claude/CLAUDE.md"
  assert_file "$sandbox_fresh/home/.claude/b-agentic/CLAUDE.md"
  assert_file "$sandbox_fresh/home/.claude/b-agentic/references/contract/index.md"
  assert_file "$sandbox_fresh/home/.claude/b-agentic/templates/settings.template.json"
  assert_file "$sandbox_fresh/home/.claude/b-agentic/templates/mcp.user.template.json"
  assert_file "$sandbox_fresh/home/.claude/b-agentic/install.json"
  assert_no_path "$sandbox_fresh/home/.claude/commands"
  assert_no_path "$sandbox_fresh/home/.config/opencode"
  assert_equal_files "$sandbox_fresh/home/.claude/CLAUDE.md" "$sandbox_fresh/home/.claude/b-agentic/CLAUDE.md"
  assert_contains "$sandbox_fresh/home/.claude/b-agentic/install.json" '"runtime": "claude-code"'
  assert_contains "$sandbox_fresh/home/.claude/b-agentic/install.json" '"activationState": "active"'
  assert_file "$sandbox_fresh/home/.claude/settings.json"
  assert_file "$sandbox_fresh/home/.claude.json"
  assert_json_value "$sandbox_fresh/home/.claude.json" "set(data['mcpServers']) == {'serena', 'context7', 'brave-search', 'firecrawl', 'playwright', 'gitnexus'}"
  assert_json_value "$sandbox_fresh/home/.claude.json" "data['mcpServers']['context7']['headers']['CONTEXT7_API_KEY'] == '\${CONTEXT7_API_KEY:-}'"
  assert_json_value "$sandbox_fresh/home/.claude.json" "data['mcpServers']['brave-search']['command'] == 'bunx'"
  assert_json_value "$sandbox_fresh/home/.claude.json" "data['mcpServers']['firecrawl']['command'] == 'bunx'"
  assert_json_value "$sandbox_fresh/home/.claude.json" "data['mcpServers']['playwright']['command'] == 'bunx'"
  assert_json_value "$sandbox_fresh/home/.claude.json" "data['mcpServers']['playwright']['args'][-1] == '--isolated'"
  assert_json_value "$sandbox_fresh/home/.claude.json" "data['mcpServers']['gitnexus']['command'] == 'gitnexus'"
  assert_json_value "$sandbox_fresh/home/.claude.json" "data['mcpServers']['gitnexus']['args'] == ['mcp']"
  assert_contains "$sandbox_fresh/home/.claude/b-agentic/install.json" '"settingsAction": "write"'
  assert_contains "$sandbox_fresh/home/.claude/b-agentic/install.json" '"mcpAction": "write"'
  assert_contains "$sandbox_fresh/home/.claude/b-agentic/install.json" '"skills"'

  mkdir -p "$sandbox_install_report/home"
  HOME="$sandbox_install_report/home" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox_install_report/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  bash "$ROOT_DIR/install.sh" >"$sandbox_install_report/install.log" 2>&1
  assert_contains "$sandbox_install_report/install.log" 'mcpReadiness:'
  assert_contains "$sandbox_install_report/install.log" 'serena: install/init separately; installer never runs onboarding'
  assert_contains "$sandbox_install_report/install.log" 'gitnexus: install/index separately if you want graph radar'
  assert_contains "$sandbox_install_report/install.log" 'api-keys: Context7, Brave Search, and Firecrawl need user-scope keys'

  expect_install_status 0 "$sandbox_fresh" "$snapshot_repo"

  mkdir -p "$sandbox_prompt_keys/home"
  expect_install_with_tty_status 0 "$sandbox_prompt_keys" "$snapshot_repo" $'ctx7-test-key\nbrave-test-key\nfirecrawl-test-key\n' --prompt-api-keys
  assert_json_value "$sandbox_prompt_keys/home/.claude.json" "data['mcpServers']['context7']['headers']['CONTEXT7_API_KEY'] == 'ctx7-test-key'"
  assert_json_value "$sandbox_prompt_keys/home/.claude.json" "data['mcpServers']['brave-search']['env']['BRAVE_API_KEY'] == 'brave-test-key'"
  assert_json_value "$sandbox_prompt_keys/home/.claude.json" "data['mcpServers']['firecrawl']['env']['FIRECRAWL_API_KEY'] == 'firecrawl-test-key'"
  assert_contains "$sandbox_prompt_keys/home/.claude/b-agentic/templates/mcp.user.template.json" '${BRAVE_API_KEY}'
  assert_not_contains "$sandbox_prompt_keys/home/.claude/b-agentic/templates/mcp.user.template.json" 'brave-test-key'
  expect_install_status 0 "$sandbox_prompt_keys" "$snapshot_repo" --uninstall
  assert_no_path "$sandbox_prompt_keys/home/.claude.json"

  mkdir -p "$sandbox_prompt_reinstall/home"
  expect_install_status 0 "$sandbox_prompt_reinstall" "$snapshot_repo"
  expect_install_with_tty_status 0 "$sandbox_prompt_reinstall" "$snapshot_repo" $'ctx7-reinstall-key\nbrave-reinstall-key\nfirecrawl-reinstall-key\n' --prompt-api-keys
  expect_install_status 0 "$sandbox_prompt_reinstall" "$snapshot_repo" --uninstall
  assert_no_path "$sandbox_prompt_reinstall/home/.claude.json"

  mkdir -p "$sandbox_mcp_migration/home"
  printf '{"mcpServers":{"context7":{"type":"http","url":"https://mcp.context7.com/mcp","headers":{"CONTEXT7_API_KEY":"${CONTEXT7_API_KEY}"}},"brave-search":{"type":"stdio","command":"npx","args":["-y","@brave/brave-search-mcp-server","--transport","stdio"],"env":{"BRAVE_API_KEY":"${BRAVE_API_KEY}"}},"firecrawl":{"type":"stdio","command":"npx","args":["-y","firecrawl-mcp"],"env":{"FIRECRAWL_API_KEY":"${FIRECRAWL_API_KEY}"}},"playwright":{"type":"stdio","command":"npx","args":["-y","@playwright/mcp@latest","--isolated"],"env":{}},"gitnexus":{"type":"stdio","command":"npx","args":["-y","gitnexus@latest","mcp"],"env":{}}}}\n' > "$sandbox_mcp_migration/home/.claude.json"
  expect_install_status 0 "$sandbox_mcp_migration" "$snapshot_repo"
  assert_json_value "$sandbox_mcp_migration/home/.claude.json" "data['mcpServers']['context7']['headers']['CONTEXT7_API_KEY'] == '\${CONTEXT7_API_KEY:-}'"
  assert_json_value "$sandbox_mcp_migration/home/.claude.json" "data['mcpServers']['brave-search']['command'] == 'bunx'"
  assert_json_value "$sandbox_mcp_migration/home/.claude.json" "data['mcpServers']['brave-search']['args'] == ['@brave/brave-search-mcp-server', '--transport', 'stdio']"
  assert_json_value "$sandbox_mcp_migration/home/.claude.json" "data['mcpServers']['firecrawl']['command'] == 'bunx'"
  assert_json_value "$sandbox_mcp_migration/home/.claude.json" "data['mcpServers']['firecrawl']['args'] == ['firecrawl-mcp']"
  assert_json_value "$sandbox_mcp_migration/home/.claude.json" "data['mcpServers']['playwright']['command'] == 'bunx'"
  assert_json_value "$sandbox_mcp_migration/home/.claude.json" "data['mcpServers']['playwright']['args'] == ['@playwright/mcp@latest', '--isolated']"
  assert_json_value "$sandbox_mcp_migration/home/.claude.json" "data['mcpServers']['gitnexus']['command'] == 'gitnexus'"
  assert_json_value "$sandbox_mcp_migration/home/.claude.json" "data['mcpServers']['gitnexus']['args'] == ['mcp']"

  mkdir -p "$sandbox_preserve/home/.claude"
  printf '# User Claude Memory\n' > "$sandbox_preserve/home/.claude/CLAUDE.md"
  expect_install_status 2 "$sandbox_preserve" "$snapshot_repo"
  assert_contains "$sandbox_preserve/home/.claude/CLAUDE.md" '# User Claude Memory'
  assert_file "$sandbox_preserve/home/.claude/b-agentic/CLAUDE.md"
  assert_contains "$sandbox_preserve/home/.claude/b-agentic/install.json" '"activationState": "pending"'

  mkdir -p "$sandbox_replace/home/.claude"
  printf '# User Claude Memory\n' > "$sandbox_replace/home/.claude/CLAUDE.md"
  expect_install_status 0 "$sandbox_replace" "$snapshot_repo" --replace-memory
  assert_contains "$sandbox_replace/home/.claude/CLAUDE.md" '<!-- b-agentic-managed -->'
  assert_contains "$sandbox_replace/home/.claude/b-agentic/install.json" '"memoryAction": "replace"'
  assert_glob "$sandbox_replace/home/.claude/b-agentic/backups/CLAUDE.md.bak-*"

  mkdir -p "$sandbox_dry_run/home"
  expect_install_status 0 "$sandbox_dry_run" "$snapshot_repo" --dry-run
  assert_no_path "$sandbox_dry_run/home/.claude"
  assert_no_path "$sandbox_dry_run/home/.claude.json"
  assert_no_path "$sandbox_dry_run/source"

  mkdir -p "$sandbox_config/home"
  expect_install_status 0 "$sandbox_config" "$snapshot_repo"
  assert_file "$sandbox_config/home/.claude/settings.json"
  assert_file "$sandbox_config/home/.claude.json"
  assert_json_value "$sandbox_config/home/.claude.json" "'serena' in data['mcpServers']"
  assert_json_value "$sandbox_config/home/.claude.json" "'context7' in data['mcpServers']"
  assert_json_value "$sandbox_config/home/.claude.json" "'brave-search' in data['mcpServers']"
  assert_json_value "$sandbox_config/home/.claude.json" "'firecrawl' in data['mcpServers']"
  assert_json_value "$sandbox_config/home/.claude.json" "'playwright' in data['mcpServers']"
  assert_json_value "$sandbox_config/home/.claude.json" "'gitnexus' in data['mcpServers']"
  expect_install_status 0 "$sandbox_config" "$snapshot_repo" --uninstall
  assert_no_path "$sandbox_config/home/.claude/settings.json"
  assert_no_path "$sandbox_config/home/.claude.json"

  mkdir -p "$sandbox_settings_merge/home/.claude"
  printf '{"mcpServers":{"custom":{"type":"http","url":"https://example.com/mcp"}},"userOnly":true}\n' > "$sandbox_settings_merge/home/.claude.json"
  printf '{"disableSkillShellExecution":false,"permissions":{"ask":["Bash(custom *)"],"allow":["Read(README.md)"]},"userOnly":true}\n' > "$sandbox_settings_merge/home/.claude/settings.json"
  expect_install_status 0 "$sandbox_settings_merge" "$snapshot_repo"
  assert_json_value "$sandbox_settings_merge/home/.claude/settings.json" "data['disableSkillShellExecution'] is False"
  assert_json_value "$sandbox_settings_merge/home/.claude/settings.json" "data['userOnly'] is True"
  assert_json_value "$sandbox_settings_merge/home/.claude/settings.json" "'Read(README.md)' in data['permissions']['allow']"
  assert_json_value "$sandbox_settings_merge/home/.claude/settings.json" "'Bash(custom *)' in data['permissions']['ask']"
  assert_json_value "$sandbox_settings_merge/home/.claude/settings.json" "'Bash(git commit *)' in data['permissions']['ask']"
  assert_json_value "$sandbox_settings_merge/home/.claude/settings.json" "'Read(./.env)' in data['permissions']['deny']"
  assert_json_value "$sandbox_settings_merge/home/.claude.json" "data['userOnly'] is True"
  assert_json_value "$sandbox_settings_merge/home/.claude.json" "'custom' in data['mcpServers']"
  assert_json_value "$sandbox_settings_merge/home/.claude.json" "'gitnexus' in data['mcpServers']"
  assert_contains "$sandbox_settings_merge/home/.claude/b-agentic/install.json" '"settingsAction": "merge"'
  assert_contains "$sandbox_settings_merge/home/.claude/b-agentic/install.json" '"mcpAction": "merge"'
  assert_glob "$sandbox_settings_merge/home/.claude/b-agentic/backups/settings.json.bak-*"
  assert_glob "$sandbox_settings_merge/home/.claude/b-agentic/backups/.claude.json.bak-*"
  expect_install_status 0 "$sandbox_settings_merge" "$snapshot_repo" --uninstall
  assert_json_value "$sandbox_settings_merge/home/.claude/settings.json" "data == {'disableSkillShellExecution': False, 'permissions': {'allow': ['Read(README.md)'], 'ask': ['Bash(custom *)']}, 'userOnly': True}"
  assert_json_value "$sandbox_settings_merge/home/.claude.json" "set(data['mcpServers']) == {'custom'}"
  assert_json_value "$sandbox_settings_merge/home/.claude.json" "data['userOnly'] is True"

  mkdir -p "$sandbox_fresh_modified/home"
  expect_install_status 0 "$sandbox_fresh_modified" "$snapshot_repo"
  python3 - "$sandbox_fresh_modified/home/.claude.json" "$sandbox_fresh_modified/home/.claude/settings.json" <<'PY'
import json
import sys
from pathlib import Path

mcp_path = Path(sys.argv[1])
settings_path = Path(sys.argv[2])
mcp = json.loads(mcp_path.read_text())
mcp['userOnly'] = True
mcp['mcpServers']['custom'] = {'type': 'http', 'url': 'https://example.com/mcp'}
mcp_path.write_text(json.dumps(mcp, indent=2) + '\n')
settings = json.loads(settings_path.read_text())
settings['userOnly'] = True
settings['permissions']['ask'].append('Bash(custom *)')
settings_path.write_text(json.dumps(settings, indent=2) + '\n')
PY
  expect_install_status 0 "$sandbox_fresh_modified" "$snapshot_repo" --uninstall
  assert_json_value "$sandbox_fresh_modified/home/.claude.json" "data == {'mcpServers': {'custom': {'type': 'http', 'url': 'https://example.com/mcp'}}, 'userOnly': True}"
  assert_json_value "$sandbox_fresh_modified/home/.claude/settings.json" "data == {'permissions': {'ask': ['Bash(custom *)']}, 'userOnly': True}"

  mkdir -p "$sandbox_invalid_json/home"
  printf '{bad json}\n' > "$sandbox_invalid_json/home/.claude.json"
  expect_install_status 1 "$sandbox_invalid_json" "$snapshot_repo"
  assert_contains "$sandbox_invalid_json/home/.claude.json" '{bad json}'

  mkdir -p "$sandbox_profile_dry_run/home"
  expect_install_status 0 "$sandbox_profile_dry_run" "$snapshot_repo" --dry-run
  assert_no_path "$sandbox_profile_dry_run/home/.claude"
  assert_no_path "$sandbox_profile_dry_run/home/.claude.json"
  assert_no_path "$sandbox_profile_dry_run/source"

  mkdir -p "$sandbox_uninstall/home"
  expect_install_status 0 "$sandbox_uninstall" "$snapshot_repo"
  expect_install_status 0 "$sandbox_uninstall" "$snapshot_repo" --uninstall
  assert_no_path "$sandbox_uninstall/home/.claude/skills/b-plan"
  assert_no_path "$sandbox_uninstall/home/.claude/CLAUDE.md"
  assert_no_path "$sandbox_uninstall/home/.claude/b-agentic"
}
