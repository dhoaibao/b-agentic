# Sourced by tests/smoke/install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by tests/smoke/install.sh" >&2
  exit 1
fi

run_runtime_smoke_cases() {
  local snapshot_repo="$1"
  local sandbox_kimi="$WORK_DIR/kimi"
  local sandbox_kimi_preserve="$WORK_DIR/kimi-preserve"
  local sandbox_kimi_replace="$WORK_DIR/kimi-replace"
  local sandbox_kimi_merge="$WORK_DIR/kimi-merge"
  local sandbox_kimi_install_report="$WORK_DIR/kimi-install-report"
  local kimi_stop_hook_expr="any(hook.get('event') == 'Stop' and 'check-runtime.py' in hook.get('command', '') and '--client kimi-code-cli' in hook.get('command', '') and '--event stop' in hook.get('command', '') for hook in data.get('hooks', []))"

  mkdir -p "$sandbox_kimi/home"
  expect_install_status 0 "$sandbox_kimi" "$snapshot_repo" --runtime=kimi-code-cli
  assert_file "$sandbox_kimi/home/.kimi-code/AGENTS.md"
  assert_contains "$sandbox_kimi/home/.kimi-code/AGENTS.md" '<!-- b-agentic-managed -->'
  assert_file "$sandbox_kimi/home/.kimi-code/skills/b-plan/SKILL.md"
  assert_file "$sandbox_kimi/home/.kimi-code/skills/b-plan/reference.md"
  assert_file "$sandbox_kimi/home/.kimi-code/skills/b-review/SKILL.md"
  assert_no_path "$sandbox_kimi/home/.kimi-code/commands"
  assert_file "$sandbox_kimi/home/.kimi-code/b-agentic/hooks/check-runtime.py"
  assert_file "$sandbox_kimi/home/.kimi-code/b-agentic/references/contract/index.md"
  assert_file "$sandbox_kimi/home/.kimi-code/b-agentic/templates/mcp.user.template.json"
  assert_file "$sandbox_kimi/home/.kimi-code/b-agentic/install.json"
  assert_contains "$sandbox_kimi/home/.kimi-code/b-agentic/install.json" '"runtime": "kimi-code-cli"'
  assert_contains "$sandbox_kimi/home/.kimi-code/b-agentic/install.json" '"activationState": "active"'
  assert_json_value "$sandbox_kimi/home/.kimi-code/b-agentic/install.json" "data['paths']['skills'].endswith('/.kimi-code/skills')"
  assert_json_value "$sandbox_kimi/home/.kimi-code/b-agentic/install.json" "data['paths']['kimiConfig'].endswith('/.kimi-code/config.toml')"
  assert_json_value "$sandbox_kimi/home/.kimi-code/b-agentic/install.json" "data['paths']['kimiMcp'].endswith('/.kimi-code/mcp.json')"
  assert_file "$sandbox_kimi/home/.kimi-code/config.toml"
  assert_contains "$sandbox_kimi/home/.kimi-code/config.toml" '# BEGIN b-agentic managed config'
  assert_contains "$sandbox_kimi/home/.kimi-code/config.toml" '[[hooks]]'
  assert_contains "$sandbox_kimi/home/.kimi-code/config.toml" 'event = "Stop"'
  assert_contains "$sandbox_kimi/home/.kimi-code/config.toml" 'check-runtime.py'
  assert_contains "$sandbox_kimi/home/.kimi-code/config.toml" ' --client kimi-code-cli'
  assert_toml_value "$sandbox_kimi/home/.kimi-code/config.toml" "$kimi_stop_hook_expr"
  assert_file "$sandbox_kimi/home/.kimi-code/mcp.json"
  assert_json_value "$sandbox_kimi/home/.kimi-code/mcp.json" "set(data['mcpServers']) == {'serena', 'context7', 'brave-search', 'firecrawl', 'playwright'}"
  assert_json_value "$sandbox_kimi/home/.kimi-code/mcp.json" "data['mcpServers']['serena']['args'] == ['start-mcp-server', '--context', 'kimi-code-cli', '--project-from-cwd']"
  assert_no_path "$sandbox_kimi/home/.claude"
  assert_no_path "$sandbox_kimi/home/.codex"
  assert_no_path "$sandbox_kimi/home/.config/opencode"

  mkdir -p "$sandbox_kimi_install_report/home"
  HOME="$sandbox_kimi_install_report/home" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox_kimi_install_report/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  bash "$ROOT_DIR/install.sh" --runtime=kimi-code-cli >"$sandbox_kimi_install_report/install.log" 2>&1
  assert_contains "$sandbox_kimi_install_report/install.log" '==> [1/8] Syncing skills'
  assert_contains "$sandbox_kimi_install_report/install.log" 'b-agentic install complete for Kimi Code CLI'
  assert_contains "$sandbox_kimi_install_report/install.log" 'hooks: active; Kimi hooks are fail-open'
  assert_contains "$sandbox_kimi_install_report/install.log" 'kimi-hooks: fail-open by design'
  assert_contains "$sandbox_kimi_install_report/install.log" 'runtime conformance hooks warn by default'

  mkdir -p "$sandbox_kimi_preserve/home/.kimi-code"
  printf '# User Kimi Memory\n' > "$sandbox_kimi_preserve/home/.kimi-code/AGENTS.md"
  expect_install_status 2 "$sandbox_kimi_preserve" "$snapshot_repo" --runtime=kimi-code-cli
  assert_contains "$sandbox_kimi_preserve/home/.kimi-code/AGENTS.md" '# User Kimi Memory'
  assert_contains "$sandbox_kimi_preserve/home/.kimi-code/b-agentic/install.json" '"activationState": "pending"'

  mkdir -p "$sandbox_kimi_replace/home/.kimi-code"
  printf '# User Kimi Memory\n' > "$sandbox_kimi_replace/home/.kimi-code/AGENTS.md"
  expect_install_status 0 "$sandbox_kimi_replace" "$snapshot_repo" --runtime=kimi-code-cli --replace-memory
  assert_contains "$sandbox_kimi_replace/home/.kimi-code/AGENTS.md" '<!-- b-agentic-managed -->'
  assert_contains "$sandbox_kimi_replace/home/.kimi-code/b-agentic/install.json" '"memoryAction": "replace"'
  assert_glob "$sandbox_kimi_replace/home/.kimi-code/b-agentic/backups/AGENTS.md.bak-*"

  mkdir -p "$sandbox_kimi_merge/home/.kimi-code"
  cat <<'EOF' > "$sandbox_kimi_merge/home/.kimi-code/config.toml"
default_model = "custom"

[[hooks]]
event = "Notification"
command = "custom-notify"
EOF
  cat <<'EOF' > "$sandbox_kimi_merge/home/.kimi-code/mcp.json"
{
  "mcpServers": {
    "context7": {
      "url": "https://example.com/context7"
    },
    "custom": {
      "command": "custom-mcp"
    }
  }
}
EOF
  expect_install_status 0 "$sandbox_kimi_merge" "$snapshot_repo" --runtime=kimi-code-cli
  assert_toml_value "$sandbox_kimi_merge/home/.kimi-code/config.toml" "data['default_model'] == 'custom'"
  assert_toml_value "$sandbox_kimi_merge/home/.kimi-code/config.toml" "any(hook.get('event') == 'Notification' and hook.get('command') == 'custom-notify' for hook in data.get('hooks', []))"
  assert_toml_value "$sandbox_kimi_merge/home/.kimi-code/config.toml" "$kimi_stop_hook_expr"
  assert_json_value "$sandbox_kimi_merge/home/.kimi-code/mcp.json" "data['mcpServers']['context7']['url'] == 'https://example.com/context7'"
  assert_json_value "$sandbox_kimi_merge/home/.kimi-code/mcp.json" "data['mcpServers']['custom']['command'] == 'custom-mcp'"
  assert_json_value "$sandbox_kimi_merge/home/.kimi-code/mcp.json" "'serena' in data['mcpServers']"
  expect_install_status 0 "$sandbox_kimi_merge" "$snapshot_repo" --runtime=kimi-code-cli --uninstall
  assert_toml_value "$sandbox_kimi_merge/home/.kimi-code/config.toml" "data == {'default_model': 'custom', 'hooks': [{'event': 'Notification', 'command': 'custom-notify'}]}"
  assert_json_value "$sandbox_kimi_merge/home/.kimi-code/mcp.json" "data == {'mcpServers': {'context7': {'url': 'https://example.com/context7'}, 'custom': {'command': 'custom-mcp'}}}"

  expect_install_status 0 "$sandbox_kimi" "$snapshot_repo" --runtime=kimi-code-cli --uninstall
  assert_no_path "$sandbox_kimi/home/.kimi-code/b-agentic"
  assert_no_path "$sandbox_kimi/home/.kimi-code/AGENTS.md"
  assert_no_path "$sandbox_kimi/home/.kimi-code/config.toml"
  assert_no_path "$sandbox_kimi/home/.kimi-code/mcp.json"
}
