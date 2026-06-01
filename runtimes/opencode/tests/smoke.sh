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
  local sandbox_opencode_bunx_migration="$WORK_DIR/opencode-bunx-migration"
  local sandbox_opencode_install_report="$WORK_DIR/opencode-install-report"
  local sandbox_opencode_cwd_repo="$WORK_DIR/opencode-cwd-repo"
  local sandbox_opencode_stale_command="$WORK_DIR/opencode-stale-command"

  mkdir -p "$sandbox_opencode/home"
  expect_install_status 0 "$sandbox_opencode" "$snapshot_repo" --runtime=opencode
  assert_file "$sandbox_opencode/home/.config/opencode/AGENTS.md"
  assert_contains "$sandbox_opencode/home/.config/opencode/AGENTS.md" '<!-- b-agentic-managed -->'
  assert_file "$sandbox_opencode/home/.config/opencode/skills/b-plan/SKILL.md"
  assert_file "$sandbox_opencode/home/.config/opencode/skills/b-plan/reference.md"
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
  assert_json_value "$sandbox_opencode/home/.config/opencode/opencode.json" "set(data['mcp']) == {'serena', 'context7', 'brave-search', 'firecrawl', 'playwright'}"
  assert_json_value "$sandbox_opencode/home/.config/opencode/opencode.json" "data['mcp']['serena']['command'] == ['serena', 'start-mcp-server', '--context', 'ide', '--project-from-cwd']"
  assert_json_value "$sandbox_opencode/home/.config/opencode/opencode.json" "data['mcp']['context7']['headers']['CONTEXT7_API_KEY'] == '{env:CONTEXT7_API_KEY}'"
  assert_json_value "$sandbox_opencode/home/.config/opencode/opencode.json" "data['mcp']['brave-search']['command'][0] == 'pnpm'"
  assert_json_value "$sandbox_opencode/home/.config/opencode/opencode.json" "data['mcp']['firecrawl']['command'][0] == 'pnpm'"
  assert_json_value "$sandbox_opencode/home/.config/opencode/opencode.json" "data['mcp']['playwright']['command'][0] == 'pnpm'"
  assert_json_value "$sandbox_opencode/home/.config/opencode/opencode.json" "data['mcp']['playwright']['command'][-1] == '--isolated'"
  assert_file "$sandbox_opencode/home/.config/opencode/b-agentic/references/contract/index.md"
  assert_not_contains "$sandbox_opencode/home/.config/opencode/b-agentic/references/contract/index.md" 'The active runtime kernel lives in `CLAUDE.md` (Claude Code) or `AGENTS.md` (OpenCode)'
  assert_no_path "$sandbox_opencode/home/.config/opencode/b-agentic/references/contract/00-kernel.md"
  assert_not_contains "$sandbox_opencode/home/.config/opencode/b-agentic/references/contract/05-evidence.md" 'active `CLAUDE.md`'
  assert_not_contains "$sandbox_opencode/home/.config/opencode/b-agentic/references/contract/06-safety.md" 'Use `~/.claude/b-agentic/...` or `/tmp/claude-code/b-agentic/...` instead by default.'
  assert_not_contains "$sandbox_opencode/home/.config/opencode/b-agentic/references/contract/07-execution.md" 'save the full output under `/tmp/claude-code/b-agentic/<skill>/<slug>.log`'
  assert_not_contains "$sandbox_opencode/home/.config/opencode/b-agentic/references/contract/08-artifacts.md" 'auth/session state and similar secrets default to `~/.claude/b-agentic/<skill>/<run-id>/` or `/tmp/claude-code/b-agentic/<skill>/<run-id>/`'
  assert_not_contains "$sandbox_opencode/home/.config/opencode/b-agentic/references/contract/10-decisions.md" 'capture the failing output under `/tmp/claude-code/b-agentic/b-test/`'
  assert_not_contains "$sandbox_opencode/home/.config/opencode/skills/b-plan/SKILL.md" 'CLAUDE.md section 3'
  assert_not_contains "$sandbox_opencode/home/.config/opencode/skills/b-plan/SKILL.md" 'per `CLAUDE.md` §3'
  assert_not_contains "$sandbox_opencode/home/.config/opencode/skills/b-implement/SKILL.md" 'CLAUDE.md section 3'
  assert_not_contains "$sandbox_opencode/home/.config/opencode/skills/b-research/SKILL.md" 'approval-gated by `CLAUDE.md`'
  assert_contains "$sandbox_opencode/home/.config/opencode/skills/b-plan/SKILL.md" 'include durable frontmatter'
  assert_contains "$sandbox_opencode/home/.config/opencode/skills/b-plan/reference.md" 'slug: <task-slug>'
  assert_contains "$sandbox_opencode/home/.config/opencode/skills/b-review/SKILL.md" './reference.md'
  assert_contains "$sandbox_opencode/home/.config/opencode/skills/b-review/SKILL.md" 'self-audits when explicitly requested or invoked with `--audit-suite`'
  assert_contains "$sandbox_opencode/home/.config/opencode/skills/b-review/SKILL.md" 'with or without `--audit-suite`'
  assert_not_contains "$sandbox_opencode/home/.config/opencode/skills/b-review/SKILL.md" 'suite self-audit without `--audit-suite` -> ask'
  assert_not_contains "$sandbox_opencode/home/.config/opencode/skills/b-review/SKILL.md" 'Do NOT invoke for repo/suite audits'
  assert_contains "$sandbox_opencode/home/.config/opencode/commands/b-review.md" 'description: Review changed code or b-agentic suite audit'
  assert_contains "$sandbox_opencode/home/.config/opencode/AGENTS.md" 'Runtime gate checklist:'
  assert_not_contains "$sandbox_opencode/home/.config/opencode/skills/b-plan/SKILL.md" 'B_AGENTIC_RUNTIME_REFERENCES'
  assert_not_contains "$sandbox_opencode/home/.config/opencode/skills/b-plan/SKILL.md" 'B_AGENTIC_SKILL_DIR'
  assert_not_contains "$sandbox_opencode/home/.config/opencode/skills/b-plan/reference.md" 'B_AGENTIC_RUNTIME_REFERENCES'
  assert_not_contains "$sandbox_opencode/home/.config/opencode/skills/b-plan/reference.md" 'B_AGENTIC_SKILL_DIR'
  assert_no_path "$sandbox_opencode/home/.config/opencode/skills/b-plan/references"

  mkdir -p "$sandbox_opencode_install_report/home"
  HOME="$sandbox_opencode_install_report/home" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox_opencode_install_report/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  bash "$ROOT_DIR/install.sh" --runtime=opencode >"$sandbox_opencode_install_report/install.log" 2>&1
  assert_contains "$sandbox_opencode_install_report/install.log" '==> [1/7] Syncing skills'
  assert_contains "$sandbox_opencode_install_report/install.log" 'Summary:'
  assert_contains "$sandbox_opencode_install_report/install.log" 'activation: active'
  assert_contains "$sandbox_opencode_install_report/install.log" 'commands: '
  assert_contains "$sandbox_opencode_install_report/install.log" 'Readiness:'
  assert_contains "$sandbox_opencode_install_report/install.log" 'serena: install/init separately; installer never runs onboarding'
  assert_contains "$sandbox_opencode_install_report/install.log" 'api-keys: Context7, Brave Search, and Firecrawl need user-scope keys'
  assert_contains "$sandbox_opencode_install_report/install.log" 'Shell tooling:'
  assert_contains "$sandbox_opencode_install_report/install.log" 'core: rg, fd/fdfind, jq'
  assert_contains "$sandbox_opencode_install_report/install.log" 'optional: bat/batcat, yq, git-delta, gh, tmux, fzf'
  assert_contains "$sandbox_opencode_install_report/install.log" 'optional-use: readable file previews, YAML-heavy work, better git diffs, GitHub-heavy workflows, long-running jobs, and non-interactive scoring'
  assert_contains "$sandbox_opencode_install_report/install.log" 'installer: suggestions only; no packages were installed automatically'
  assert_contains "$sandbox_opencode_install_report/install.log" 'Next steps:'
  assert_contains "$sandbox_opencode_install_report/install.log" 'launch: start a new OpenCode session so it picks up'

  HOME="$sandbox_opencode_install_report/home" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox_opencode_install_report/source-brew" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  B_AGENTIC_SHELL_RECOMMEND_MANAGER=brew \
  bash "$ROOT_DIR/install.sh" --runtime=opencode >"$sandbox_opencode_install_report/install-brew.log" 2>&1
  assert_contains "$sandbox_opencode_install_report/install-brew.log" 'core-install: brew install ripgrep fd jq'
  assert_contains "$sandbox_opencode_install_report/install-brew.log" 'optional-install: brew install bat yq git-delta gh tmux fzf'

  HOME="$sandbox_opencode_install_report/home" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox_opencode_install_report/source-apt" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  B_AGENTIC_SHELL_RECOMMEND_MANAGER=apt \
  bash "$ROOT_DIR/install.sh" --runtime=opencode >"$sandbox_opencode_install_report/install-apt.log" 2>&1
  assert_contains "$sandbox_opencode_install_report/install-apt.log" 'core-install: sudo apt install -y ripgrep fd-find jq'
  assert_contains "$sandbox_opencode_install_report/install-apt.log" 'optional-install: sudo apt install -y bat yq git-delta gh tmux fzf'

  HOME="$sandbox_opencode_install_report/home" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox_opencode_install_report/source-dnf" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  B_AGENTIC_SHELL_RECOMMEND_MANAGER=dnf \
  bash "$ROOT_DIR/install.sh" --runtime=opencode >"$sandbox_opencode_install_report/install-dnf.log" 2>&1
  assert_contains "$sandbox_opencode_install_report/install-dnf.log" 'core-install: sudo dnf install -y ripgrep fd-find jq'
  assert_contains "$sandbox_opencode_install_report/install-dnf.log" 'optional-install: sudo dnf install -y bat yq git-delta gh tmux fzf'

  HOME="$sandbox_opencode_install_report/home" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox_opencode_install_report/source-manual" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  B_AGENTIC_SHELL_RECOMMEND_MANAGER=manual \
  bash "$ROOT_DIR/install.sh" --runtime=opencode >"$sandbox_opencode_install_report/install-manual.log" 2>&1
  assert_contains "$sandbox_opencode_install_report/install-manual.log" 'core-install: install manually: ripgrep, fd or fd-find, jq'
  assert_contains "$sandbox_opencode_install_report/install-manual.log" 'optional-install: install manually: bat or batcat, yq, git-delta, gh, tmux, fzf'

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

  mkdir -p "$sandbox_opencode_stale_command/home"
  expect_install_status 0 "$sandbox_opencode_stale_command" "$snapshot_repo" --runtime=opencode
  printf 'managed old\n' > "$sandbox_opencode_stale_command/home/.config/opencode/commands/b-old-managed.md"
  printf 'managed old\n' > "$sandbox_opencode_stale_command/home/.config/opencode/b-agentic/commands/b-old-managed.md"
  printf 'user edit\n' > "$sandbox_opencode_stale_command/home/.config/opencode/commands/b-old-user.md"
  printf 'snapshot old\n' > "$sandbox_opencode_stale_command/home/.config/opencode/b-agentic/commands/b-old-user.md"
  printf 'unsafe command\n' > "$sandbox_opencode_stale_command/home/.config/opencode/sentinel.md"
  printf 'unsafe command\n' > "$sandbox_opencode_stale_command/home/.config/opencode/b-agentic/sentinel.md"
  python3 - "$sandbox_opencode_stale_command/home/.config/opencode/b-agentic/install.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data['commands'].extend(['b-old-managed', 'b-old-user', '../sentinel'])
path.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')
PY
  expect_install_status 0 "$sandbox_opencode_stale_command" "$snapshot_repo" --runtime=opencode
  assert_no_path "$sandbox_opencode_stale_command/home/.config/opencode/commands/b-old-managed.md"
  assert_file "$sandbox_opencode_stale_command/home/.config/opencode/commands/b-old-user.md"
  assert_contains "$sandbox_opencode_stale_command/home/.config/opencode/commands/b-old-user.md" 'user edit'
  assert_file "$sandbox_opencode_stale_command/home/.config/opencode/sentinel.md"
  mkdir -p "$sandbox_opencode_stale_command/home/.config/opencode/poisoned-commands"
  cp "$sandbox_opencode_stale_command/home/.config/opencode/b-agentic/commands/b-plan.md" \
    "$sandbox_opencode_stale_command/home/.config/opencode/poisoned-commands/b-plan.md"
  python3 - "$sandbox_opencode_stale_command/home/.config/opencode/b-agentic/install.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data['commands'].append('../sentinel')
data['paths']['commands'] = str(path.parent.parent / 'poisoned-commands')
path.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')
PY
  expect_install_status 0 "$sandbox_opencode_stale_command" "$snapshot_repo" --runtime=opencode --uninstall
  assert_file "$sandbox_opencode_stale_command/home/.config/opencode/sentinel.md"
  assert_file "$sandbox_opencode_stale_command/home/.config/opencode/poisoned-commands/b-plan.md"

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
  assert_json_value "$sandbox_opencode_merge/home/.config/opencode/opencode.json" "data.get('userOnly') is True"
  assert_contains "$sandbox_opencode_merge/home/.config/opencode/b-agentic/install.json" '"mcpAction": "merge"'
  expect_install_status 0 "$sandbox_opencode_merge" "$snapshot_repo" --runtime=opencode --uninstall
  assert_json_value "$sandbox_opencode_merge/home/.config/opencode/opencode.json" "set(data['mcp']) == {'my-custom'}"
  assert_json_value "$sandbox_opencode_merge/home/.config/opencode/opencode.json" "data.get('userOnly') is True"

  mkdir -p "$sandbox_opencode_mcp_migration/home/.config/opencode"
  printf '{"mcp":{"brave-search":{"type":"local","command":["npx","-y","@brave/brave-search-mcp-server","--transport","stdio"],"environment":{"BRAVE_API_KEY":"{env:BRAVE_API_KEY}"}},"firecrawl":{"type":"local","command":["npx","-y","firecrawl-mcp"],"environment":{"FIRECRAWL_API_KEY":"{env:FIRECRAWL_API_KEY}"}},"playwright":{"type":"local","command":["npx","-y","@playwright/mcp@latest","--isolated"]}}}\n' > "$sandbox_opencode_mcp_migration/home/.config/opencode/opencode.json"
  expect_install_status 0 "$sandbox_opencode_mcp_migration" "$snapshot_repo" --runtime=opencode
  assert_json_value "$sandbox_opencode_mcp_migration/home/.config/opencode/opencode.json" "data['mcp']['brave-search']['command'] == ['pnpm', 'dlx', '@brave/brave-search-mcp-server', '--transport', 'stdio']"
  assert_json_value "$sandbox_opencode_mcp_migration/home/.config/opencode/opencode.json" "data['mcp']['firecrawl']['command'] == ['pnpm', 'dlx', 'firecrawl-mcp']"
  assert_json_value "$sandbox_opencode_mcp_migration/home/.config/opencode/opencode.json" "data['mcp']['playwright']['command'] == ['pnpm', 'dlx', '@playwright/mcp@latest', '--isolated']"

  mkdir -p "$sandbox_opencode_bunx_migration/home/.config/opencode"
  printf '{"mcp":{"brave-search":{"type":"local","command":["bunx","@brave/brave-search-mcp-server","--transport","stdio"],"environment":{"BRAVE_API_KEY":"{env:BRAVE_API_KEY}"}},"firecrawl":{"type":"local","command":["bunx","firecrawl-mcp"],"environment":{"FIRECRAWL_API_KEY":"{env:FIRECRAWL_API_KEY}"}},"playwright":{"type":"local","command":["bunx","@playwright/mcp@latest","--isolated"]}}}\n' > "$sandbox_opencode_bunx_migration/home/.config/opencode/opencode.json"
  expect_install_status 0 "$sandbox_opencode_bunx_migration" "$snapshot_repo" --runtime=opencode
  assert_json_value "$sandbox_opencode_bunx_migration/home/.config/opencode/opencode.json" "data['mcp']['brave-search']['command'] == ['pnpm', 'dlx', '@brave/brave-search-mcp-server', '--transport', 'stdio']"
  assert_json_value "$sandbox_opencode_bunx_migration/home/.config/opencode/opencode.json" "data['mcp']['firecrawl']['command'] == ['pnpm', 'dlx', 'firecrawl-mcp']"
  assert_json_value "$sandbox_opencode_bunx_migration/home/.config/opencode/opencode.json" "data['mcp']['playwright']['command'] == ['pnpm', 'dlx', '@playwright/mcp@latest', '--isolated']"
}
