# Sourced by tests/smoke/install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by tests/smoke/install.sh" >&2
  exit 1
fi

run_runtime_smoke_cases() {
  local snapshot_repo="$1"
  local sandbox_kimi="$WORK_DIR/kimi"
  local sandbox_kimi_report="$WORK_DIR/kimi-report"
  local sandbox_kimi_merge="$WORK_DIR/kimi-merge"
  local sandbox_kimi_prompt_keys="$WORK_DIR/kimi-prompt-keys"
  local sandbox_kimi_manifest_only="$WORK_DIR/kimi-manifest-only"
  local sandbox_kimi_preserve="$WORK_DIR/kimi-preserve"
  local sandbox_kimi_replace="$WORK_DIR/kimi-replace"

  mkdir -p "$sandbox_kimi/home"
  expect_install_status 0 "$sandbox_kimi" "$snapshot_repo" --runtime=kimi-code-cli
  assert_file "$sandbox_kimi/home/.kimi-code/b-agentic-kernel.md"
  assert_contains "$sandbox_kimi/home/.kimi-code/b-agentic-kernel.md" '<!-- b-agentic-managed -->'
  assert_contains "$sandbox_kimi/home/.kimi-code/b-agentic-kernel.md" 'Kimi Code CLI'
  assert_file "$sandbox_kimi/home/.kimi-code/skills/b-plan/SKILL.md"
  assert_file "$sandbox_kimi/home/.kimi-code/skills/b-plan/reference.md"
  assert_file "$sandbox_kimi/home/.kimi-code/b-agentic/hooks/inject-kernel.py"
  assert_file "$sandbox_kimi/home/.kimi-code/config.toml"
  assert_contains "$sandbox_kimi/home/.kimi-code/config.toml" '# BEGIN b-agentic managed config'
  assert_contains "$sandbox_kimi/home/.kimi-code/config.toml" 'event = "UserPromptSubmit"'
  assert_contains "$sandbox_kimi/home/.kimi-code/config.toml" 'inject-kernel.py'
  assert_contains "$sandbox_kimi/home/.kimi-code/config.toml" 'pattern = "Bash(rm -rf*)"'
  assert_file "$sandbox_kimi/home/.kimi-code/mcp.json"
  assert_json_value "$sandbox_kimi/home/.kimi-code/mcp.json" "'mcpServers' in data"
  assert_json_value "$sandbox_kimi/home/.kimi-code/mcp.json" "data['mcpServers']['serena']['args'] == ['start-mcp-server', '--context', 'ide', '--project-from-cwd']"
  assert_file "$sandbox_kimi/home/.kimi-code/b-agentic/install.json"
  assert_contains "$sandbox_kimi/home/.kimi-code/b-agentic/install.json" '"runtime": "kimi-code-cli"'
  assert_json_value "$sandbox_kimi/home/.kimi-code/b-agentic/install.json" "data['paths']['kimiDir'].endswith('/.kimi-code')"
  assert_json_value "$sandbox_kimi/home/.kimi-code/b-agentic/install.json" "data['hooks'] == ['inject-kernel']"
  assert_no_path "$sandbox_kimi/home/.claude"
  assert_no_path "$sandbox_kimi/home/.codex"
  assert_no_path "$sandbox_kimi/home/.config/opencode"

  mkdir -p "$sandbox_kimi_report/home"
  HOME="$sandbox_kimi_report/home" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox_kimi_report/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  bash "$ROOT_DIR/install.sh" --runtime=kimi-code-cli >"$sandbox_kimi_report/install.log" 2>&1
  assert_contains "$sandbox_kimi_report/install.log" 'Summary:'
  assert_contains "$sandbox_kimi_report/install.log" 'activation: active'
  assert_contains "$sandbox_kimi_report/install.log" 'kernel-hook: active'
  assert_contains "$sandbox_kimi_report/install.log" 'kimi-hooks: UserPromptSubmit is fail-open'
  assert_contains "$sandbox_kimi_report/install.log" 'launch: start a new Kimi Code CLI session so it picks up'

  mkdir -p "$sandbox_kimi_merge/home/.kimi-code"
  cat <<'EOF' > "$sandbox_kimi_merge/home/.kimi-code/config.toml"
default_model = "custom"

[[hooks]]
event = "Notification"
matcher = "task\\.completed"
command = "custom-notify"
EOF
  printf '{"mcpServers":{"custom":{"url":"https://example.com/mcp"}},"userOnly":true}\n' > "$sandbox_kimi_merge/home/.kimi-code/mcp.json"
  expect_install_status 0 "$sandbox_kimi_merge" "$snapshot_repo" --runtime=kimi-code-cli
  assert_toml_value "$sandbox_kimi_merge/home/.kimi-code/config.toml" "data['default_model'] == 'custom'"
  assert_toml_value "$sandbox_kimi_merge/home/.kimi-code/config.toml" "any(hook.get('event') == 'Notification' and hook.get('command') == 'custom-notify' for hook in data['hooks'])"
  assert_toml_value "$sandbox_kimi_merge/home/.kimi-code/config.toml" "any(hook.get('event') == 'UserPromptSubmit' and 'inject-kernel.py' in hook.get('command', '') for hook in data['hooks'])"
  assert_json_value "$sandbox_kimi_merge/home/.kimi-code/mcp.json" "'custom' in data['mcpServers']"
  assert_json_value "$sandbox_kimi_merge/home/.kimi-code/mcp.json" "'serena' in data['mcpServers']"
  expect_install_status 0 "$sandbox_kimi_merge" "$snapshot_repo" --runtime=kimi-code-cli --uninstall
  assert_toml_value "$sandbox_kimi_merge/home/.kimi-code/config.toml" "data == {'default_model': 'custom', 'hooks': [{'event': 'Notification', 'matcher': 'task\\\\.completed', 'command': 'custom-notify'}]}"
  assert_json_value "$sandbox_kimi_merge/home/.kimi-code/mcp.json" "'custom' in data['mcpServers']"

  mkdir -p "$sandbox_kimi_prompt_keys/home"
  expect_install_with_tty_status 0 "$sandbox_kimi_prompt_keys" "$snapshot_repo" $'ctx7-kimi-key\nbrave-kimi-key\nfirecrawl-kimi-key\n' --runtime=kimi-code-cli --prompt-api-keys
  assert_json_value "$sandbox_kimi_prompt_keys/home/.kimi-code/mcp.json" "data['mcpServers']['context7']['headers']['CONTEXT7_API_KEY'] == 'ctx7-kimi-key'"
  assert_json_value "$sandbox_kimi_prompt_keys/home/.kimi-code/mcp.json" "data['mcpServers']['brave-search']['env']['BRAVE_API_KEY'] == 'brave-kimi-key'"
  assert_json_value "$sandbox_kimi_prompt_keys/home/.kimi-code/mcp.json" "data['mcpServers']['firecrawl']['env']['FIRECRAWL_API_KEY'] == 'firecrawl-kimi-key'"
  assert_contains "$sandbox_kimi_prompt_keys/home/.kimi-code/b-agentic/templates/mcp.user.template.json" '${BRAVE_API_KEY}'
  assert_not_contains "$sandbox_kimi_prompt_keys/home/.kimi-code/b-agentic/templates/mcp.user.template.json" 'brave-kimi-key'
  expect_install_status 0 "$sandbox_kimi_prompt_keys" "$snapshot_repo" --runtime=kimi-code-cli --uninstall
  assert_no_path "$sandbox_kimi_prompt_keys/home/.kimi-code/config.toml"

  mkdir -p "$sandbox_kimi_manifest_only/home"
  expect_install_status 0 "$sandbox_kimi_manifest_only" "$snapshot_repo" --runtime=kimi-code-cli
  python3 - "$sandbox_kimi_manifest_only/home/.kimi-code/mcp.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["userOnly"] = True
data["mcpServers"]["custom"] = {"url": "https://example.com/mcp"}
data["mcpServers"]["context7"]["headers"]["CONTEXT7_API_KEY"] = "ctx7-kimi-key"
data["mcpServers"]["brave-search"]["env"]["BRAVE_API_KEY"] = "brave-kimi-key"
data["mcpServers"]["firecrawl"]["env"]["FIRECRAWL_API_KEY"] = "firecrawl-kimi-key"
path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY
  rm -rf "$sandbox_kimi_manifest_only/source"
  HOME="$sandbox_kimi_manifest_only/home" \
  B_AGENTIC_REPO="$sandbox_kimi_manifest_only/missing-source" \
  B_AGENTIC_DIR="$sandbox_kimi_manifest_only/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  bash "$ROOT_DIR/install.sh" --runtime=kimi-code-cli --uninstall >"$sandbox_kimi_manifest_only/manifest-only-uninstall.log" 2>&1
  assert_contains "$sandbox_kimi_manifest_only/manifest-only-uninstall.log" 'Manifest-only uninstall complete for kimi-code-cli'
  assert_json_value "$sandbox_kimi_manifest_only/home/.kimi-code/mcp.json" "set(data['mcpServers']) == {'custom'}"
  assert_json_value "$sandbox_kimi_manifest_only/home/.kimi-code/mcp.json" "data.get('userOnly') is True"
  assert_no_path "$sandbox_kimi_manifest_only/home/.kimi-code/config.toml"
  assert_no_path "$sandbox_kimi_manifest_only/home/.kimi-code/b-agentic"

  mkdir -p "$sandbox_kimi_preserve/home/.kimi-code"
  printf '# User Kimi kernel\n' > "$sandbox_kimi_preserve/home/.kimi-code/b-agentic-kernel.md"
  expect_install_status 2 "$sandbox_kimi_preserve" "$snapshot_repo" --runtime=kimi-code-cli
  assert_contains "$sandbox_kimi_preserve/home/.kimi-code/b-agentic-kernel.md" '# User Kimi kernel'
  assert_contains "$sandbox_kimi_preserve/home/.kimi-code/b-agentic/install.json" '"activationState": "pending"'

  mkdir -p "$sandbox_kimi_replace/home/.kimi-code"
  printf '# User Kimi kernel\n' > "$sandbox_kimi_replace/home/.kimi-code/b-agentic-kernel.md"
  expect_install_status 0 "$sandbox_kimi_replace" "$snapshot_repo" --runtime=kimi-code-cli --replace-memory
  assert_contains "$sandbox_kimi_replace/home/.kimi-code/b-agentic-kernel.md" '<!-- b-agentic-managed -->'
  assert_contains "$sandbox_kimi_replace/home/.kimi-code/b-agentic/install.json" '"memoryAction": "replace"'
  assert_glob "$sandbox_kimi_replace/home/.kimi-code/b-agentic/backups/b-agentic-kernel.md.bak-*"
}
