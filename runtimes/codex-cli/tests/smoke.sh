# Sourced by tests/smoke/install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by tests/smoke/install.sh" >&2
  exit 1
fi

run_runtime_smoke_cases() {
  local snapshot_repo="$1"
  local sandbox_codex="$WORK_DIR/codex"
  local sandbox_codex_preserve="$WORK_DIR/codex-preserve"
  local sandbox_codex_replace="$WORK_DIR/codex-replace"
  local sandbox_codex_dry_run="$WORK_DIR/codex-dry-run"
  local sandbox_codex_dry_run_tty="$WORK_DIR/codex-dry-run-tty"
  local sandbox_codex_prompt_keys="$WORK_DIR/codex-prompt-keys"
  local sandbox_codex_merge="$WORK_DIR/codex-merge"
  local sandbox_codex_legacy_managed="$WORK_DIR/codex-legacy-managed"
  local sandbox_codex_conflict="$WORK_DIR/codex-conflict"
  local sandbox_codex_install_report="$WORK_DIR/codex-install-report"
  local sandbox_codex_cwd_repo="$WORK_DIR/codex-cwd-repo"
  local managed_skill_entries_expr="[item for item in data['skills']['config'] if '/.codex/skills/' in item.get('path', '')]"
  local managed_skill_enabled_expr="$managed_skill_entries_expr and all(item.get('enabled') is True for item in data['skills']['config'] if '/.codex/skills/' in item.get('path', ''))"
  local managed_skill_missing_enabled_expr="$managed_skill_entries_expr and all('enabled' not in item for item in data['skills']['config'] if '/.codex/skills/' in item.get('path', ''))"
  local codex_activate_hook_expr="any(hook.get('matcher') == 'startup|resume|clear|compact' and any(command.get('command') == 'serena-hooks activate --client=codex' for command in hook.get('hooks', [])) for hook in data['hooks']['SessionStart'])"
  local codex_remind_hook_expr="any(hook.get('matcher') == '.*' and any(command.get('command') == 'serena-hooks remind --client=codex' for command in hook.get('hooks', [])) for hook in data['hooks']['PreToolUse'])"
  local codex_cleanup_hook_expr="any(hook.get('matcher') == '.*' and any(command.get('command') == 'serena-hooks cleanup --client=codex' for command in hook.get('hooks', [])) for hook in data['hooks']['Stop'])"

  mkdir -p "$sandbox_codex/home"
  expect_install_status 0 "$sandbox_codex" "$snapshot_repo" --runtime=codex-cli
  assert_file "$sandbox_codex/home/.codex/AGENTS.md"
  assert_contains "$sandbox_codex/home/.codex/AGENTS.md" '<!-- b-agentic-managed -->'
  assert_file "$sandbox_codex/home/.codex/skills/b-plan/SKILL.md"
  assert_file "$sandbox_codex/home/.codex/skills/b-plan/reference.md"
  assert_file "$sandbox_codex/home/.codex/skills/b-review/SKILL.md"
  assert_contains "$sandbox_codex/home/.codex/skills/b-review/SKILL.md" 'self-audits when explicitly requested or invoked with `--audit-suite`'
  assert_contains "$sandbox_codex/home/.codex/skills/b-review/SKILL.md" 'with or without `--audit-suite`'
  assert_not_contains "$sandbox_codex/home/.codex/skills/b-review/SKILL.md" 'suite self-audit without `--audit-suite` -> ask'
  assert_not_contains "$sandbox_codex/home/.codex/skills/b-review/SKILL.md" 'Do NOT invoke for repo/suite audits'
  assert_contains "$sandbox_codex/home/.codex/AGENTS.md" 'Runtime Kernel'
  assert_file "$sandbox_codex/home/.codex/b-agentic/install.json"
  assert_contains "$sandbox_codex/home/.codex/b-agentic/install.json" '"runtime": "codex-cli"'
  assert_contains "$sandbox_codex/home/.codex/b-agentic/install.json" '"activationState": "active"'
  assert_contains "$sandbox_codex/home/.codex/b-agentic/install.json" '"configAction": "write"'
  assert_file "$sandbox_codex/home/.codex/config.toml"
  assert_contains "$sandbox_codex/home/.codex/config.toml" '# BEGIN b-agentic managed config'
  assert_contains "$sandbox_codex/home/.codex/config.toml" '[mcp_servers.context7]'
  assert_contains "$sandbox_codex/home/.codex/config.toml" 'env_http_headers = { CONTEXT7_API_KEY = "CONTEXT7_API_KEY" }'
  assert_contains "$sandbox_codex/home/.codex/config.toml" 'env_vars = ["BRAVE_API_KEY"]'
  assert_contains "$sandbox_codex/home/.codex/config.toml" 'env_vars = ["FIRECRAWL_API_KEY"]'
  assert_contains "$sandbox_codex/home/.codex/config.toml" '[[skills.config]]'
  assert_contains "$sandbox_codex/home/.codex/config.toml" 'enabled = true'
  assert_contains "$sandbox_codex/home/.codex/config.toml" 'path = "/'
  assert_contains "$sandbox_codex/home/.codex/config.toml" '[features]'
  assert_contains "$sandbox_codex/home/.codex/config.toml" 'hooks = true'
  assert_contains "$sandbox_codex/home/.codex/config.toml" '[[hooks.SessionStart]]'
  assert_contains "$sandbox_codex/home/.codex/config.toml" 'serena-hooks activate --client=codex'
  assert_contains "$sandbox_codex/home/.codex/config.toml" '[[hooks.PreToolUse]]'
  assert_contains "$sandbox_codex/home/.codex/config.toml" 'serena-hooks remind --client=codex'
  assert_contains "$sandbox_codex/home/.codex/config.toml" '[[hooks.Stop]]'
  assert_contains "$sandbox_codex/home/.codex/config.toml" 'serena-hooks cleanup --client=codex'
  assert_contains "$sandbox_codex/home/.codex/skills/b-plan/reference.md" 'slug: <task-slug>'
  assert_not_contains "$sandbox_codex/home/.codex/skills/b-plan/reference.md" 'B_AGENTIC_RUNTIME_REFERENCES'
  assert_not_contains "$sandbox_codex/home/.codex/skills/b-plan/reference.md" 'B_AGENTIC_SKILL_DIR'
  assert_toml_value "$sandbox_codex/home/.codex/config.toml" "'serena' in data['mcp_servers']"
  assert_toml_value "$sandbox_codex/home/.codex/config.toml" "data['mcp_servers']['serena']['args'] == ['start-mcp-server', '--context', 'codex', '--project-from-cwd']"
  assert_toml_value "$sandbox_codex/home/.codex/config.toml" "data['features']['hooks'] is True"
  assert_toml_value "$sandbox_codex/home/.codex/config.toml" "$codex_activate_hook_expr"
  assert_toml_value "$sandbox_codex/home/.codex/config.toml" "$codex_remind_hook_expr"
  assert_toml_value "$sandbox_codex/home/.codex/config.toml" "$codex_cleanup_hook_expr"
  assert_toml_value "$sandbox_codex/home/.codex/config.toml" "any(item['path'].endswith('/.codex/skills/b-plan') for item in data['skills']['config'])"
  assert_toml_value "$sandbox_codex/home/.codex/config.toml" "$managed_skill_enabled_expr"
  assert_file "$sandbox_codex/home/.codex/b-agentic/references/contract/index.md"
  assert_file "$sandbox_codex/home/.codex/b-agentic/templates/mcp.user.template.toml"
  assert_no_path "$sandbox_codex/home/.claude"
  assert_no_path "$sandbox_codex/home/.config/opencode"

  mkdir -p "$sandbox_codex_install_report/home"
  HOME="$sandbox_codex_install_report/home" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox_codex_install_report/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  bash "$ROOT_DIR/install.sh" --runtime=codex-cli >"$sandbox_codex_install_report/install.log" 2>&1
  assert_contains "$sandbox_codex_install_report/install.log" '==> [1/5] Syncing skills'
  assert_contains "$sandbox_codex_install_report/install.log" 'Summary:'
  assert_contains "$sandbox_codex_install_report/install.log" 'activation: active'
  assert_contains "$sandbox_codex_install_report/install.log" 'Readiness:'
  assert_contains "$sandbox_codex_install_report/install.log" 'serena: install/init separately; installer never runs onboarding'
  assert_contains "$sandbox_codex_install_report/install.log" 'api-keys: Context7, Brave Search, and Firecrawl need user-scope keys'
  assert_contains "$sandbox_codex_install_report/install.log" 'Shell tooling:'
  assert_contains "$sandbox_codex_install_report/install.log" 'core: rg, fd/fdfind, jq'
  assert_contains "$sandbox_codex_install_report/install.log" 'optional: bat/batcat, yq, git-delta, gh, tmux, fzf'
  assert_contains "$sandbox_codex_install_report/install.log" 'optional-use: readable file previews, YAML-heavy work, better git diffs, GitHub-heavy workflows, long-running jobs, and non-interactive scoring'
  assert_contains "$sandbox_codex_install_report/install.log" 'installer: suggestions only; no packages were installed automatically'
  assert_contains "$sandbox_codex_install_report/install.log" 'Next steps:'
  assert_contains "$sandbox_codex_install_report/install.log" 'launch: start a new Codex CLI session so it picks up'

  HOME="$sandbox_codex_install_report/home" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox_codex_install_report/source-brew" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  B_AGENTIC_SHELL_RECOMMEND_MANAGER=brew \
  bash "$ROOT_DIR/install.sh" --runtime=codex-cli >"$sandbox_codex_install_report/install-brew.log" 2>&1
  assert_contains "$sandbox_codex_install_report/install-brew.log" 'core-install: brew install ripgrep fd jq'
  assert_contains "$sandbox_codex_install_report/install-brew.log" 'optional-install: brew install bat yq git-delta gh tmux fzf'

  HOME="$sandbox_codex_install_report/home" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox_codex_install_report/source-apt" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  B_AGENTIC_SHELL_RECOMMEND_MANAGER=apt \
  bash "$ROOT_DIR/install.sh" --runtime=codex-cli >"$sandbox_codex_install_report/install-apt.log" 2>&1
  assert_contains "$sandbox_codex_install_report/install-apt.log" 'core-install: sudo apt install -y ripgrep fd-find jq'
  assert_contains "$sandbox_codex_install_report/install-apt.log" 'optional-install: sudo apt install -y bat yq git-delta gh tmux fzf'

  HOME="$sandbox_codex_install_report/home" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox_codex_install_report/source-dnf" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  B_AGENTIC_SHELL_RECOMMEND_MANAGER=dnf \
  bash "$ROOT_DIR/install.sh" --runtime=codex-cli >"$sandbox_codex_install_report/install-dnf.log" 2>&1
  assert_contains "$sandbox_codex_install_report/install-dnf.log" 'core-install: sudo dnf install -y ripgrep fd-find jq'
  assert_contains "$sandbox_codex_install_report/install-dnf.log" 'optional-install: sudo dnf install -y bat yq git-delta gh tmux fzf'

  HOME="$sandbox_codex_install_report/home" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox_codex_install_report/source-manual" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  B_AGENTIC_SHELL_RECOMMEND_MANAGER=manual \
  bash "$ROOT_DIR/install.sh" --runtime=codex-cli >"$sandbox_codex_install_report/install-manual.log" 2>&1
  assert_contains "$sandbox_codex_install_report/install-manual.log" 'core-install: install manually: ripgrep, fd or fd-find, jq'
  assert_contains "$sandbox_codex_install_report/install-manual.log" 'optional-install: install manually: bat or batcat, yq, git-delta, gh, tmux, fzf'

  mkdir -p "$sandbox_codex_cwd_repo/home" "$sandbox_codex_cwd_repo/current-repo"
  git -C "$sandbox_codex_cwd_repo/current-repo" init -q
  expect_install_status_in_cwd 0 "$sandbox_codex_cwd_repo/current-repo" "$sandbox_codex_cwd_repo" "$snapshot_repo" --runtime=codex-cli
  assert_no_path "$sandbox_codex_cwd_repo/current-repo/.b-agentic"
  expect_install_status_in_cwd 0 "$sandbox_codex_cwd_repo/current-repo" "$sandbox_codex_cwd_repo" "$snapshot_repo" --runtime=codex-cli --uninstall
  assert_no_path "$sandbox_codex_cwd_repo/current-repo/.b-agentic"

  mkdir -p "$sandbox_codex_preserve/home/.codex"
  printf '# User Codex Memory\n' > "$sandbox_codex_preserve/home/.codex/AGENTS.md"
  expect_install_status 2 "$sandbox_codex_preserve" "$snapshot_repo" --runtime=codex-cli
  assert_contains "$sandbox_codex_preserve/home/.codex/AGENTS.md" '# User Codex Memory'
  assert_contains "$sandbox_codex_preserve/home/.codex/b-agentic/install.json" '"activationState": "pending"'

  mkdir -p "$sandbox_codex_replace/home/.codex"
  printf '# User Codex Memory\n' > "$sandbox_codex_replace/home/.codex/AGENTS.md"
  expect_install_status 0 "$sandbox_codex_replace" "$snapshot_repo" --runtime=codex-cli --replace-memory
  assert_contains "$sandbox_codex_replace/home/.codex/AGENTS.md" '<!-- b-agentic-managed -->'
  assert_contains "$sandbox_codex_replace/home/.codex/b-agentic/install.json" '"memoryAction": "replace"'
  assert_glob "$sandbox_codex_replace/home/.codex/b-agentic/backups/AGENTS.md.bak-*"

  mkdir -p "$sandbox_codex_dry_run/home"
  expect_install_status 0 "$sandbox_codex_dry_run" "$snapshot_repo" --runtime=codex-cli --dry-run
  assert_no_path "$sandbox_codex_dry_run/home/.codex"
  assert_no_path "$sandbox_codex_dry_run/source"

  mkdir -p "$sandbox_codex_dry_run_tty/home"
  env \
    HOME="$sandbox_codex_dry_run_tty/home" \
    B_AGENTIC_REPO="$snapshot_repo" \
    B_AGENTIC_DIR="$sandbox_codex_dry_run_tty/source" \
    B_AGENTIC_PROMPT_API_KEYS=N \
    script -q -e -c "bash '$ROOT_DIR/install.sh' --runtime=codex-cli --dry-run" \
      "$sandbox_codex_dry_run_tty/install.log" >/dev/null 2>&1
  python3 - "$sandbox_codex_dry_run_tty/install.log" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
text = re.sub(r'\x1b\[[0-9;?]*[ -/]*[@-~]', '', text).replace('\r', '\n')

if '[dry-run]' not in text:
    raise SystemExit('expected dry-run command output in tty log')
for marker in ('[ok]', '[-]', '[\\]', '[|]', '[/]'):
    if marker in text:
        raise SystemExit(f'unexpected spinner marker in dry-run tty log: {marker}')
PY

  mkdir -p "$sandbox_codex_prompt_keys/home"
  expect_install_with_tty_status 0 "$sandbox_codex_prompt_keys" "$snapshot_repo" $'ctx7-codex-key\nbrave-codex-key\nfirecrawl-codex-key\n' --runtime=codex-cli --prompt-api-keys
  assert_contains "$sandbox_codex_prompt_keys/home/.codex/config.toml" 'http_headers = { CONTEXT7_API_KEY = "ctx7-codex-key" }'
  assert_contains "$sandbox_codex_prompt_keys/home/.codex/config.toml" 'BRAVE_API_KEY = "brave-codex-key"'
  assert_contains "$sandbox_codex_prompt_keys/home/.codex/config.toml" 'FIRECRAWL_API_KEY = "firecrawl-codex-key"'
  assert_contains "$sandbox_codex_prompt_keys/home/.codex/b-agentic/templates/mcp.user.template.toml" 'env_vars = ["BRAVE_API_KEY"]'
  assert_not_contains "$sandbox_codex_prompt_keys/home/.codex/b-agentic/templates/mcp.user.template.toml" 'brave-codex-key'
  expect_install_status 0 "$sandbox_codex_prompt_keys" "$snapshot_repo" --runtime=codex-cli --uninstall
  assert_no_path "$sandbox_codex_prompt_keys/home/.codex/config.toml"

  mkdir -p "$sandbox_codex_merge/home/.codex"
  cat <<'EOF' > "$sandbox_codex_merge/home/.codex/config.toml"
model = "gpt-5.4"

[mcp_servers.custom]
command = "custom-mcp"

[[hooks.PreToolUse]]
matcher = "^Bash$"

[[hooks.PreToolUse.hooks]]
type = "command"
command = "custom-hook"

[[skills.config]]
path = "/tmp/custom-skill"
enabled = true
EOF
  expect_install_status 0 "$sandbox_codex_merge" "$snapshot_repo" --runtime=codex-cli
  assert_toml_value "$sandbox_codex_merge/home/.codex/config.toml" "data['model'] == 'gpt-5.4'"
  assert_toml_value "$sandbox_codex_merge/home/.codex/config.toml" "data['mcp_servers']['custom']['command'] == 'custom-mcp'"
  assert_toml_value "$sandbox_codex_merge/home/.codex/config.toml" "any(hook.get('matcher') == '^Bash$' and hook.get('hooks', [{}])[0].get('command') == 'custom-hook' for hook in data['hooks']['PreToolUse'])"
  assert_toml_value "$sandbox_codex_merge/home/.codex/config.toml" "$codex_remind_hook_expr"
  assert_toml_value "$sandbox_codex_merge/home/.codex/config.toml" "'/tmp/custom-skill' in [item['path'] for item in data['skills']['config']]"
  assert_toml_value "$sandbox_codex_merge/home/.codex/config.toml" "any(item['path'].endswith('/.codex/skills/b-plan') for item in data['skills']['config'])"
  expect_install_status 0 "$sandbox_codex_merge" "$snapshot_repo" --runtime=codex-cli --uninstall
  assert_toml_value "$sandbox_codex_merge/home/.codex/config.toml" "data == {'model': 'gpt-5.4', 'mcp_servers': {'custom': {'command': 'custom-mcp'}}, 'hooks': {'PreToolUse': [{'matcher': '^Bash$', 'hooks': [{'type': 'command', 'command': 'custom-hook'}]}]}, 'skills': {'config': [{'path': '/tmp/custom-skill', 'enabled': True}]}}"

  mkdir -p "$sandbox_codex_legacy_managed/home"
  expect_install_status 0 "$sandbox_codex_legacy_managed" "$snapshot_repo" --runtime=codex-cli
  python3 - "$sandbox_codex_legacy_managed/home/.codex/config.toml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text().replace("\nenabled = true", "")
text = text.replace("serena-hooks remind --client=codex", "serena-hooks stale-remind --client=codex")
path.write_text(text)
PY
  assert_toml_value "$sandbox_codex_legacy_managed/home/.codex/config.toml" "$managed_skill_missing_enabled_expr"
  assert_contains "$sandbox_codex_legacy_managed/home/.codex/config.toml" 'serena-hooks stale-remind --client=codex'
  expect_install_status 0 "$sandbox_codex_legacy_managed" "$snapshot_repo" --runtime=codex-cli
  assert_toml_value "$sandbox_codex_legacy_managed/home/.codex/config.toml" "$managed_skill_enabled_expr"
  assert_toml_value "$sandbox_codex_legacy_managed/home/.codex/config.toml" "$codex_remind_hook_expr"
  assert_not_contains "$sandbox_codex_legacy_managed/home/.codex/config.toml" 'serena-hooks stale-remind --client=codex'
  expect_install_status 0 "$sandbox_codex_legacy_managed" "$snapshot_repo" --runtime=codex-cli --uninstall
  assert_no_path "$sandbox_codex_legacy_managed/home/.codex/config.toml"

  mkdir -p "$sandbox_codex_conflict/home/.codex"
  cat <<'EOF' > "$sandbox_codex_conflict/home/.codex/config.toml"
[features]
hooks = false

[mcp_servers.context7]
url = "https://example.com/custom-context7"
EOF
  expect_install_status 0 "$sandbox_codex_conflict" "$snapshot_repo" --runtime=codex-cli
  assert_toml_value "$sandbox_codex_conflict/home/.codex/config.toml" "data['features']['hooks'] is False"
  assert_toml_value "$sandbox_codex_conflict/home/.codex/config.toml" "data['mcp_servers']['context7']['url'] == 'https://example.com/custom-context7'"
  assert_toml_value "$sandbox_codex_conflict/home/.codex/config.toml" "$codex_activate_hook_expr"
  assert_contains "$sandbox_codex_conflict/home/.codex/config.toml" '[mcp_servers.brave-search]'
  expect_install_status 0 "$sandbox_codex_conflict" "$snapshot_repo" --runtime=codex-cli --uninstall
  assert_toml_value "$sandbox_codex_conflict/home/.codex/config.toml" "data == {'features': {'hooks': False}, 'mcp_servers': {'context7': {'url': 'https://example.com/custom-context7'}}}"

  expect_install_status 0 "$sandbox_codex" "$snapshot_repo" --runtime=codex-cli --uninstall
  assert_no_path "$sandbox_codex/home/.codex/b-agentic"
  assert_no_path "$sandbox_codex/home/.codex/AGENTS.md"
  assert_no_path "$sandbox_codex/home/.codex/config.toml"
}
