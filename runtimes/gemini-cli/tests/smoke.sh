# Sourced by tests/smoke/install.sh - do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by tests/smoke/install.sh" >&2
  exit 1
fi

run_runtime_smoke_cases() {
  local snapshot_repo="$1"
  local sandbox_gemini="$WORK_DIR/gemini"
  local sandbox_gemini_preserve="$WORK_DIR/gemini-preserve"
  local sandbox_gemini_replace="$WORK_DIR/gemini-replace"
  local sandbox_gemini_dry_run="$WORK_DIR/gemini-dry-run"
  local sandbox_gemini_prompt_keys="$WORK_DIR/gemini-prompt-keys"
  local sandbox_gemini_merge="$WORK_DIR/gemini-merge"
  local sandbox_gemini_command_collision="$WORK_DIR/gemini-command-collision"
  local sandbox_gemini_modified_command="$WORK_DIR/gemini-modified-command"
  local sandbox_gemini_legacy_command="$WORK_DIR/gemini-legacy-command"
  local sandbox_gemini_install_report="$WORK_DIR/gemini-install-report"
  local sandbox_gemini_cwd_repo="$WORK_DIR/gemini-cwd-repo"

  mkdir -p "$sandbox_gemini/home"
  expect_install_status 0 "$sandbox_gemini" "$snapshot_repo" --runtime=gemini-cli
  assert_file "$sandbox_gemini/home/.gemini/GEMINI.md"
  assert_contains "$sandbox_gemini/home/.gemini/GEMINI.md" '<!-- b-agentic-managed -->'
  assert_file "$sandbox_gemini/home/.gemini/skills/b-plan/SKILL.md"
  assert_file "$sandbox_gemini/home/.gemini/skills/b-plan/reference.md"
  assert_contains "$sandbox_gemini/home/.gemini/skills/b-plan/reference.md" '../../b-agentic/references/contract/02-source-of-truth.md'
  assert_no_path "$sandbox_gemini/home/.gemini/commands/b-plan.toml"
  assert_file "$sandbox_gemini/home/.gemini/b-agentic/install.json"
  assert_json_value "$sandbox_gemini/home/.gemini/b-agentic/install.json" "data['runtime'] == 'gemini-cli'"
  assert_json_value "$sandbox_gemini/home/.gemini/b-agentic/install.json" "data['activationState'] == 'active'"
  assert_json_value "$sandbox_gemini/home/.gemini/b-agentic/install.json" "data['commands'] == []"
  assert_file "$sandbox_gemini/home/.gemini/settings.json"
  assert_json_value "$sandbox_gemini/home/.gemini/settings.json" "set(data['mcpServers']) == {'serena', 'context7', 'brave-search', 'firecrawl', 'playwright', 'gitnexus'}"
  assert_json_value "$sandbox_gemini/home/.gemini/settings.json" "data['mcpServers']['context7']['httpUrl'] == 'https://mcp.context7.com/mcp'"
  assert_json_value "$sandbox_gemini/home/.gemini/settings.json" "data['mcpServers']['context7']['headers']['CONTEXT7_API_KEY'] == '\$CONTEXT7_API_KEY'"
  assert_json_value "$sandbox_gemini/home/.gemini/settings.json" "data['mcpServers']['brave-search']['command'] == 'bunx'"
  assert_json_value "$sandbox_gemini/home/.gemini/settings.json" "data['mcpServers']['firecrawl']['command'] == 'bunx'"
  assert_json_value "$sandbox_gemini/home/.gemini/settings.json" "data['mcpServers']['playwright']['args'][-1] == '--isolated'"
  assert_json_value "$sandbox_gemini/home/.gemini/settings.json" "data['mcpServers']['gitnexus']['command'] == 'gitnexus'"
  assert_file "$sandbox_gemini/home/.gemini/b-agentic/references/contract/index.md"
  assert_file "$sandbox_gemini/home/.gemini/b-agentic/templates/settings.template.json"
  assert_no_path "$sandbox_gemini/home/.claude"
  assert_no_path "$sandbox_gemini/home/.config/opencode"
  assert_no_path "$sandbox_gemini/home/.codex"

  mkdir -p "$sandbox_gemini_install_report/home"
  HOME="$sandbox_gemini_install_report/home" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox_gemini_install_report/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  bash "$ROOT_DIR/install.sh" --runtime=gemini-cli >"$sandbox_gemini_install_report/install.log" 2>&1
  assert_contains "$sandbox_gemini_install_report/install.log" '==> [1/7] Syncing skills'
  assert_contains "$sandbox_gemini_install_report/install.log" 'Summary:'
  assert_contains "$sandbox_gemini_install_report/install.log" 'activation: active'
  assert_contains "$sandbox_gemini_install_report/install.log" 'commands: native Gemini skill commands; TOML wrappers disabled'
  assert_contains "$sandbox_gemini_install_report/install.log" 'settings: write ->'
  assert_contains "$sandbox_gemini_install_report/install.log" 'launch: start a new Gemini CLI session so it picks up'

  mkdir -p "$sandbox_gemini_cwd_repo/home" "$sandbox_gemini_cwd_repo/current-repo"
  git -C "$sandbox_gemini_cwd_repo/current-repo" init -q
  expect_install_status_in_cwd 0 "$sandbox_gemini_cwd_repo/current-repo" "$sandbox_gemini_cwd_repo" "$snapshot_repo" --runtime=gemini-cli
  assert_no_path "$sandbox_gemini_cwd_repo/current-repo/.b-agentic"
  expect_install_status_in_cwd 0 "$sandbox_gemini_cwd_repo/current-repo" "$sandbox_gemini_cwd_repo" "$snapshot_repo" --runtime=gemini-cli --uninstall
  assert_no_path "$sandbox_gemini_cwd_repo/current-repo/.b-agentic"

  mkdir -p "$sandbox_gemini_preserve/home/.gemini"
  printf '# User Gemini Memory\n' > "$sandbox_gemini_preserve/home/.gemini/GEMINI.md"
  expect_install_status 2 "$sandbox_gemini_preserve" "$snapshot_repo" --runtime=gemini-cli
  assert_contains "$sandbox_gemini_preserve/home/.gemini/GEMINI.md" '# User Gemini Memory'
  assert_json_value "$sandbox_gemini_preserve/home/.gemini/b-agentic/install.json" "data['activationState'] == 'pending'"

  mkdir -p "$sandbox_gemini_replace/home/.gemini"
  printf '# User Gemini Memory\n' > "$sandbox_gemini_replace/home/.gemini/GEMINI.md"
  expect_install_status 0 "$sandbox_gemini_replace" "$snapshot_repo" --runtime=gemini-cli --replace-memory
  assert_contains "$sandbox_gemini_replace/home/.gemini/GEMINI.md" '<!-- b-agentic-managed -->'
  assert_json_value "$sandbox_gemini_replace/home/.gemini/b-agentic/install.json" "data['memoryAction'] == 'replace'"
  assert_glob "$sandbox_gemini_replace/home/.gemini/b-agentic/backups/GEMINI.md.bak-*"

  mkdir -p "$sandbox_gemini_dry_run/home"
  expect_install_status 0 "$sandbox_gemini_dry_run" "$snapshot_repo" --runtime=gemini-cli --dry-run
  assert_no_path "$sandbox_gemini_dry_run/home/.gemini"
  assert_no_path "$sandbox_gemini_dry_run/source"

  mkdir -p "$sandbox_gemini_prompt_keys/home"
  expect_install_with_tty_status 0 "$sandbox_gemini_prompt_keys" "$snapshot_repo" $'ctx7-gemini-key\nbrave-gemini-key\nfirecrawl-gemini-key\n' --runtime=gemini-cli --prompt-api-keys
  assert_json_value "$sandbox_gemini_prompt_keys/home/.gemini/settings.json" "data['mcpServers']['context7']['headers']['CONTEXT7_API_KEY'] == 'ctx7-gemini-key'"
  assert_json_value "$sandbox_gemini_prompt_keys/home/.gemini/settings.json" "data['mcpServers']['brave-search']['env']['BRAVE_API_KEY'] == 'brave-gemini-key'"
  assert_json_value "$sandbox_gemini_prompt_keys/home/.gemini/settings.json" "data['mcpServers']['firecrawl']['env']['FIRECRAWL_API_KEY'] == 'firecrawl-gemini-key'"
  assert_contains "$sandbox_gemini_prompt_keys/home/.gemini/b-agentic/templates/settings.template.json" '$BRAVE_API_KEY'
  assert_not_contains "$sandbox_gemini_prompt_keys/home/.gemini/b-agentic/templates/settings.template.json" 'brave-gemini-key'
  expect_install_status 0 "$sandbox_gemini_prompt_keys" "$snapshot_repo" --runtime=gemini-cli --uninstall
  assert_no_path "$sandbox_gemini_prompt_keys/home/.gemini/settings.json"

  mkdir -p "$sandbox_gemini_merge/home/.gemini"
  printf '{"mcpServers":{"custom":{"httpUrl":"https://example.com/mcp"}},"userOnly":true}\n' > "$sandbox_gemini_merge/home/.gemini/settings.json"
  expect_install_status 0 "$sandbox_gemini_merge" "$snapshot_repo" --runtime=gemini-cli
  assert_json_value "$sandbox_gemini_merge/home/.gemini/settings.json" "'custom' in data['mcpServers']"
  assert_json_value "$sandbox_gemini_merge/home/.gemini/settings.json" "'gitnexus' in data['mcpServers']"
  assert_json_value "$sandbox_gemini_merge/home/.gemini/settings.json" "data.get('userOnly') is True"
  expect_install_status 0 "$sandbox_gemini_merge" "$snapshot_repo" --runtime=gemini-cli --uninstall
  assert_json_value "$sandbox_gemini_merge/home/.gemini/settings.json" "set(data['mcpServers']) == {'custom'}"
  assert_json_value "$sandbox_gemini_merge/home/.gemini/settings.json" "data.get('userOnly') is True"

  mkdir -p "$sandbox_gemini_command_collision/home/.gemini/commands"
  printf 'description = "User command"\nprompt = "user command"\n' > "$sandbox_gemini_command_collision/home/.gemini/commands/b-plan.toml"
  expect_install_status 0 "$sandbox_gemini_command_collision" "$snapshot_repo" --runtime=gemini-cli
  assert_contains "$sandbox_gemini_command_collision/home/.gemini/commands/b-plan.toml" 'user command'
  assert_json_value "$sandbox_gemini_command_collision/home/.gemini/b-agentic/install.json" "data['commands'] == []"
  expect_install_status 0 "$sandbox_gemini_command_collision" "$snapshot_repo" --runtime=gemini-cli --uninstall
  assert_contains "$sandbox_gemini_command_collision/home/.gemini/commands/b-plan.toml" 'user command'

  mkdir -p "$sandbox_gemini_modified_command/home"
  expect_install_status 0 "$sandbox_gemini_modified_command" "$snapshot_repo" --runtime=gemini-cli
  mkdir -p "$sandbox_gemini_modified_command/home/.gemini/commands" "$sandbox_gemini_modified_command/home/.gemini/b-agentic/commands"
  printf 'description = "Legacy managed command"\nprompt = "Load the `b-plan` skill and follow it for this request.\\n\\n{{args}}"\n' > "$sandbox_gemini_modified_command/home/.gemini/commands/b-plan.toml"
  cp "$sandbox_gemini_modified_command/home/.gemini/commands/b-plan.toml" "$sandbox_gemini_modified_command/home/.gemini/b-agentic/commands/b-plan.toml"
  printf '\n# user edit\n' >> "$sandbox_gemini_modified_command/home/.gemini/commands/b-plan.toml"
  python3 - "$sandbox_gemini_modified_command/home/.gemini/b-agentic/install.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data['commands'] = ['b-plan']
path.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')
PY
  expect_install_status 0 "$sandbox_gemini_modified_command" "$snapshot_repo" --runtime=gemini-cli
  expect_install_status 0 "$sandbox_gemini_modified_command" "$snapshot_repo" --runtime=gemini-cli --uninstall
  assert_file "$sandbox_gemini_modified_command/home/.gemini/commands/b-plan.toml"
  assert_contains "$sandbox_gemini_modified_command/home/.gemini/commands/b-plan.toml" 'user edit'

  mkdir -p "$sandbox_gemini_legacy_command/home/.gemini/commands" "$sandbox_gemini_legacy_command/home/.gemini/b-agentic/commands"
  printf 'description = "Legacy managed command"\nprompt = "Load the `b-plan` skill and follow it for this request.\\n\\n{{args}}"\n' > "$sandbox_gemini_legacy_command/home/.gemini/commands/b-plan.toml"
  cp "$sandbox_gemini_legacy_command/home/.gemini/commands/b-plan.toml" "$sandbox_gemini_legacy_command/home/.gemini/b-agentic/commands/b-plan.toml"
  cat > "$sandbox_gemini_legacy_command/home/.gemini/b-agentic/install.json" <<'JSON'
{
  "commands": ["b-plan"],
  "paths": {
    "commands": "__COMMANDS_DST__"
  }
}
JSON
  python3 - "$sandbox_gemini_legacy_command/home/.gemini/b-agentic/install.json" "$sandbox_gemini_legacy_command/home/.gemini/commands" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.write_text(path.read_text().replace('__COMMANDS_DST__', sys.argv[2]))
PY
  expect_install_status 0 "$sandbox_gemini_legacy_command" "$snapshot_repo" --runtime=gemini-cli
  assert_no_path "$sandbox_gemini_legacy_command/home/.gemini/commands/b-plan.toml"
  assert_json_value "$sandbox_gemini_legacy_command/home/.gemini/b-agentic/install.json" "data['commands'] == []"

  expect_install_status 0 "$sandbox_gemini" "$snapshot_repo" --runtime=gemini-cli --uninstall
  assert_no_path "$sandbox_gemini/home/.gemini/b-agentic"
  assert_no_path "$sandbox_gemini/home/.gemini/GEMINI.md"
  assert_no_path "$sandbox_gemini/home/.gemini/settings.json"
  assert_no_path "$sandbox_gemini/home/.gemini/commands/b-plan.toml"
}
