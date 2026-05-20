#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d /tmp/b-agentic-smoke.XXXXXX)"

cleanup() {
  rm -rf "$WORK_DIR"
}

trap cleanup EXIT

fail() {
  printf 'smoke-install.sh: %s\n' "$*" >&2
  exit 1
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || fail "required binary not found: $1"
}

assert_file() {
  local path="$1"
  [ -f "$path" ] || fail "expected file: $path"
}

assert_no_file() {
  local path="$1"
  [ ! -e "$path" ] || fail "unexpected file: $path"
}

assert_contains() {
  local path="$1" needle="$2"
  grep -Fq "$needle" "$path" || fail "expected '$needle' in $path"
}

assert_not_contains() {
  local path="$1" needle="$2"
  ! grep -Fq "$needle" "$path" || fail "did not expect '$needle' in $path"
}

assert_equal_files() {
  local left="$1" right="$2"
  cmp -s "$left" "$right" || fail "expected files to match: $left vs $right"
}

assert_text_equals() {
  local path="$1" expected="$2"
  local expected_file
  expected_file="$(mktemp)"
  printf '%s' "$expected" > "$expected_file"
  cmp -s "$path" "$expected_file" || fail "unexpected content in $path"
  rm -f "$expected_file"
}

make_repo_snapshot() {
  local snapshot_dir="$1"
  mkdir -p "$snapshot_dir"
  cp -R "$ROOT_DIR"/. "$snapshot_dir"/
  rm -rf "$snapshot_dir/.git" "$snapshot_dir/.opencode"
  git -C "$snapshot_dir" init -q
  git -C "$snapshot_dir" add .
  git -C "$snapshot_dir" -c user.name='b-agentic smoke' -c user.email='smoke@example.com' commit -qm 'snapshot'
}

run_install_status() {
  local sandbox="$1" repo_snapshot="$2" install_mcp="$3"
  shift 3

  local rc=0
  set +e
  HOME="$sandbox/home" \
  B_AGENTIC_REPO="$repo_snapshot" \
  B_AGENTIC_DIR="$sandbox/source" \
  B_AGENTIC_INSTALL_MCP="$install_mcp" \
  B_AGENTIC_INSTALL_GITNEXUS=N \
  B_AGENTIC_INSTALL_PLAYWRIGHT_MCP=N \
  bash "$ROOT_DIR/install.sh" "$@" >/dev/null 2>&1
  rc=$?
  set -e

  printf '%s' "$rc"
}

run_install_output() {
  local sandbox="$1" repo_snapshot="$2" install_mcp="$3"
  shift 3

  HOME="$sandbox/home" \
  B_AGENTIC_REPO="$repo_snapshot" \
  B_AGENTIC_DIR="$sandbox/source" \
  B_AGENTIC_INSTALL_MCP="$install_mcp" \
  B_AGENTIC_INSTALL_GITNEXUS=N \
  B_AGENTIC_INSTALL_PLAYWRIGHT_MCP=N \
  bash "$ROOT_DIR/install.sh" "$@"
}

expect_install_status() {
  local expected="$1" sandbox="$2" repo_snapshot="$3" install_mcp="$4"
  shift 4

  local rc
  rc="$(run_install_status "$sandbox" "$repo_snapshot" "$install_mcp" "$@")"
  [ "$rc" -eq "$expected" ] || fail "expected install exit $expected, got $rc"
}

run_piped_install_with_tty_status() {
  local sandbox="$1" repo_snapshot="$2" responses="$3"
  local runner="$sandbox/run-piped-install.sh"
  local rc=0

  cat > "$runner" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export HOME="$sandbox/home"
export B_AGENTIC_REPO="$repo_snapshot"
export B_AGENTIC_DIR="$sandbox/source"
export B_AGENTIC_INSTALL_MCP=N
export B_AGENTIC_INSTALL_GITNEXUS=N
export B_AGENTIC_INSTALL_PLAYWRIGHT_MCP=N
cat "$ROOT_DIR/install.sh" | bash
EOF
  chmod +x "$runner"

  set +e
  printf '%s' "$responses" | script -qefc "$runner" /dev/null >/dev/null 2>&1
  rc=$?
  set -e

  printf '%s' "$rc"
}

main() {
  local snapshot_repo="$WORK_DIR/repo-snapshot"
  local sandbox_fresh="$WORK_DIR/fresh"
  local sandbox_legacy_env="$WORK_DIR/legacy-env"
  local sandbox_legacy_b_nexus_env="$WORK_DIR/legacy-b-nexus-env"
  local sandbox_legacy_migration="$WORK_DIR/legacy-migration"
  local sandbox_legacy_b_nexus_migration="$WORK_DIR/legacy-b-nexus-migration"
  local sandbox_preserve="$WORK_DIR/preserve"
  local sandbox_replace="$WORK_DIR/replace"
  local sandbox_playwright="$WORK_DIR/playwright"
  local sandbox_dry_run="$WORK_DIR/dry-run"
  local sandbox_piped="$WORK_DIR/piped"
  local sandbox_provider_delete="$WORK_DIR/provider-delete"
  local sandbox_uninstall="$WORK_DIR/uninstall"
  local sandbox_uninstall_modified="$WORK_DIR/uninstall-modified"
  local sandbox_uninstall_merged="$WORK_DIR/uninstall-merged"
  local sandbox_uninstall_custom="$WORK_DIR/uninstall-custom"
  local rc

  require_bin git
  require_bin script

  make_repo_snapshot "$snapshot_repo"

  mkdir -p "$sandbox_fresh/home"
  expect_install_status 0 "$sandbox_fresh" "$snapshot_repo" N
  assert_file "$sandbox_fresh/home/.config/opencode/skills/b-plan/SKILL.md"
  assert_file "$sandbox_fresh/home/.config/opencode/skills/b-browser/SKILL.md"
  assert_file "$sandbox_fresh/home/.config/opencode/skills/b-review/reference.md"
  assert_no_file "$sandbox_fresh/home/.config/opencode/skills/b-test/reference.md"
  assert_no_file "$sandbox_fresh/home/.config/opencode/skills/b-e2e/SKILL.md"
  assert_file "$sandbox_fresh/home/.config/opencode/commands/b-plan.md"
  assert_file "$sandbox_fresh/home/.config/opencode/commands/b-browser.md"
  assert_no_file "$sandbox_fresh/home/.config/opencode/commands/b-e2e.md"
  assert_no_file "$sandbox_fresh/home/.config/opencode/references/b-agentic/domain-glossary.md"
  assert_no_file "$sandbox_fresh/home/.config/opencode/references/b-agentic/security-checklist.md"
  assert_no_file "$sandbox_fresh/home/.config/opencode/references/b-agentic/testing-patterns.md"
  assert_no_file "$sandbox_fresh/home/.config/opencode/references/b-agentic/accessibility-checklist.md"
  assert_file "$sandbox_fresh/home/.config/opencode/AGENTS.md"
  assert_file "$sandbox_fresh/home/.config/opencode/b-agentic/AGENTS.md"
  assert_file "$sandbox_fresh/home/.config/opencode/b-agentic/install.json"
  assert_no_file "$sandbox_fresh/home/.config/opencode/b-agentic/backups"
  assert_no_file "$sandbox_fresh/home/.config/opencode/AGENTS.b-skills.md"
  assert_no_file "$sandbox_fresh/home/.config/opencode/b-skills-install.json"
  assert_no_file "$sandbox_fresh/home/.config/opencode/b-skills/AGENTS.md"
  assert_equal_files "$sandbox_fresh/home/.config/opencode/AGENTS.md" "$sandbox_fresh/home/.config/opencode/b-agentic/AGENTS.md"
  assert_contains "$sandbox_fresh/home/.config/opencode/b-agentic/install.json" '"agentsAction": "replace"'
  assert_contains "$sandbox_fresh/home/.config/opencode/b-agentic/install.json" '"activationState": "active"'

  expect_install_status 0 "$sandbox_fresh" "$snapshot_repo" N
  assert_file "$sandbox_fresh/home/.config/opencode/b-agentic/install.json"

  mkdir -p "$sandbox_legacy_env/home"
  HOME="$sandbox_legacy_env/home" \
  B_SKILLS_REPO="$snapshot_repo" \
  B_SKILLS_DIR="$sandbox_legacy_env/source" \
  B_SKILLS_INSTALL_MCP=N \
  B_SKILLS_INSTALL_GITNEXUS=N \
  bash "$ROOT_DIR/install.sh" >/dev/null
  assert_file "$sandbox_legacy_env/home/.config/opencode/b-agentic/install.json"
  assert_contains "$sandbox_legacy_env/home/.config/opencode/b-agentic/install.json" '"suite": "b-agentic"'

  mkdir -p "$sandbox_legacy_b_nexus_env/home"
  HOME="$sandbox_legacy_b_nexus_env/home" \
  B_NEXUS_REPO="$snapshot_repo" \
  B_NEXUS_DIR="$sandbox_legacy_b_nexus_env/source" \
  B_NEXUS_INSTALL_MCP=N \
  B_NEXUS_INSTALL_GITNEXUS=N \
  bash "$ROOT_DIR/install.sh" >/dev/null
  assert_file "$sandbox_legacy_b_nexus_env/home/.config/opencode/b-agentic/install.json"
  assert_contains "$sandbox_legacy_b_nexus_env/home/.config/opencode/b-agentic/install.json" '"suite": "b-agentic"'

  mkdir -p "$sandbox_legacy_migration/home/.config/opencode/b-skills/backups" "$sandbox_legacy_migration/home/.config/opencode/references/b-skills"
  printf '# b-skills — OpenCode Runtime Kernel\n' > "$sandbox_legacy_migration/home/.config/opencode/b-skills/AGENTS.md"
  cp "$sandbox_legacy_migration/home/.config/opencode/b-skills/AGENTS.md" "$sandbox_legacy_migration/home/.config/opencode/AGENTS.md"
  printf 'legacy-user-rules\n' > "$sandbox_legacy_migration/home/.config/opencode/b-skills/backups/AGENTS.md.bak-old"
  printf 'legacy contract\n' > "$sandbox_legacy_migration/home/.config/opencode/references/b-skills/runtime-contract.md"
  cat > "$sandbox_legacy_migration/home/.config/opencode/b-skills/install.json" <<EOF
{
  "suite": "b-skills",
  "backups": {
    "globalAgents": "$sandbox_legacy_migration/home/.config/opencode/b-skills/backups/AGENTS.md.bak-old",
    "config": "none"
  }
}
EOF
  expect_install_status 2 "$sandbox_legacy_migration" "$snapshot_repo" N
  assert_no_file "$sandbox_legacy_migration/home/.config/opencode/references/b-skills/runtime-contract.md"
  assert_no_file "$sandbox_legacy_migration/home/.config/opencode/b-skills/AGENTS.md"
  assert_no_file "$sandbox_legacy_migration/home/.config/opencode/b-skills/install.json"
  assert_file "$sandbox_legacy_migration/home/.config/opencode/b-agentic/backups/AGENTS.md.bak-old"
  assert_contains "$sandbox_legacy_migration/home/.config/opencode/b-agentic/install.json" '"activationState": "pending"'

  mkdir -p "$sandbox_legacy_b_nexus_migration/home/.config/opencode/b-nexus/backups" "$sandbox_legacy_b_nexus_migration/home/.config/opencode/references/b-nexus"
  printf '# b-nexus — OpenCode Runtime Kernel\n' > "$sandbox_legacy_b_nexus_migration/home/.config/opencode/b-nexus/AGENTS.md"
  cp "$sandbox_legacy_b_nexus_migration/home/.config/opencode/b-nexus/AGENTS.md" "$sandbox_legacy_b_nexus_migration/home/.config/opencode/AGENTS.md"
  printf 'legacy-user-rules\n' > "$sandbox_legacy_b_nexus_migration/home/.config/opencode/b-nexus/backups/AGENTS.md.bak-old"
  printf 'legacy contract\n' > "$sandbox_legacy_b_nexus_migration/home/.config/opencode/references/b-nexus/runtime-contract.md"
  cat > "$sandbox_legacy_b_nexus_migration/home/.config/opencode/b-nexus/install.json" <<EOF
{
  "suite": "b-nexus",
  "backups": {
    "globalAgents": "$sandbox_legacy_b_nexus_migration/home/.config/opencode/b-nexus/backups/AGENTS.md.bak-old",
    "config": "none"
  }
}
EOF
  expect_install_status 2 "$sandbox_legacy_b_nexus_migration" "$snapshot_repo" N
  assert_no_file "$sandbox_legacy_b_nexus_migration/home/.config/opencode/references/b-nexus/runtime-contract.md"
  assert_no_file "$sandbox_legacy_b_nexus_migration/home/.config/opencode/b-nexus/AGENTS.md"
  assert_no_file "$sandbox_legacy_b_nexus_migration/home/.config/opencode/b-nexus/install.json"
  assert_file "$sandbox_legacy_b_nexus_migration/home/.config/opencode/b-agentic/backups/AGENTS.md.bak-old"
  assert_contains "$sandbox_legacy_b_nexus_migration/home/.config/opencode/b-agentic/install.json" '"activationState": "pending"'

  mkdir -p "$sandbox_preserve/home/.config/opencode"
  printf 'user-global-rules\n' > "$sandbox_preserve/home/.config/opencode/AGENTS.md"
  local preserve_output_file="$sandbox_preserve/install-output.txt"
  set +e
  run_install_output "$sandbox_preserve" "$snapshot_repo" N > "$preserve_output_file" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "expected install exit 2, got $rc"
  assert_contains "$preserve_output_file" 'RUNTIME KERNEL NOT ACTIVE'
  assert_contains "$preserve_output_file" 'runtime gates, required read gates, and status/handoff rules may not be enforced'
  assert_text_equals "$sandbox_preserve/home/.config/opencode/AGENTS.md" $'user-global-rules\n'
  assert_file "$sandbox_preserve/home/.config/opencode/b-agentic/AGENTS.md"
  assert_no_file "$sandbox_preserve/home/.config/opencode/AGENTS.b-skills.md"
  assert_contains "$sandbox_preserve/home/.config/opencode/b-agentic/install.json" '"agentsAction": "preserve"'
  assert_contains "$sandbox_preserve/home/.config/opencode/b-agentic/install.json" '"activationState": "pending"'

  mkdir -p "$sandbox_replace/home/.config/opencode"
  printf '{"existing": true}\n' > "$sandbox_replace/home/.config/opencode/opencode.json"
  printf 'legacy-rules\n' > "$sandbox_replace/home/.config/opencode/AGENTS.md"
  expect_install_status 0 "$sandbox_replace" "$snapshot_repo" Y --replace-agents
  assert_file "$sandbox_replace/home/.config/opencode/b-agentic/AGENTS.md"
  assert_contains "$sandbox_replace/home/.config/opencode/opencode.json" '"mcp"'
  assert_not_contains "$sandbox_replace/home/.config/opencode/opencode.json" '"playwright"'
  compgen -G "$sandbox_replace/home/.config/opencode/b-agentic/backups/opencode.json.bak-*" >/dev/null || fail 'expected config backup after config mutation'
  compgen -G "$sandbox_replace/home/.config/opencode/b-agentic/backups/AGENTS.md.bak-*" >/dev/null || fail 'expected AGENTS backup after replacement'

  mkdir -p "$sandbox_playwright/home/.config/opencode"
  printf '{"existing": true}\n' > "$sandbox_playwright/home/.config/opencode/opencode.json"
  HOME="$sandbox_playwright/home" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox_playwright/source" \
  B_AGENTIC_INSTALL_MCP=Y \
  B_AGENTIC_INSTALL_GITNEXUS=N \
  B_AGENTIC_INSTALL_PLAYWRIGHT_MCP=Y \
  bash "$ROOT_DIR/install.sh" --replace-agents >/dev/null 2>&1
  assert_contains "$sandbox_playwright/home/.config/opencode/opencode.json" '"playwright"'
  assert_contains "$sandbox_playwright/home/.config/opencode/opencode.json" '"@playwright/mcp@latest"'
  assert_contains "$sandbox_playwright/home/.config/opencode/opencode.json" '"--isolated"'
  assert_contains "$sandbox_playwright/home/.config/opencode/b-agentic/install.json" '"playwright": true'

  mkdir -p "$sandbox_dry_run/home/.config/opencode"
  printf 'keep-me\n' > "$sandbox_dry_run/home/.config/opencode/AGENTS.md"
  printf '{"dryRun": false}\n' > "$sandbox_dry_run/home/.config/opencode/opencode.json"
  expect_install_status 0 "$sandbox_dry_run" "$snapshot_repo" Y --dry-run --replace-agents
  assert_text_equals "$sandbox_dry_run/home/.config/opencode/AGENTS.md" $'keep-me\n'
  assert_text_equals "$sandbox_dry_run/home/.config/opencode/opencode.json" $'{"dryRun": false}\n'
  [ ! -e "$sandbox_dry_run/home/.config/opencode/b-agentic/install.json" ] || fail 'dry-run should not write install manifest'

  mkdir -p "$sandbox_piped/home/.config/opencode"
  printf 'legacy-rules\n' > "$sandbox_piped/home/.config/opencode/AGENTS.md"
  rc="$(run_piped_install_with_tty_status "$sandbox_piped" "$snapshot_repo" $'y\nn\n')"
  [ "$rc" -eq 0 ] || fail "expected piped install exit 0, got $rc"
  assert_equal_files "$sandbox_piped/home/.config/opencode/AGENTS.md" "$sandbox_piped/home/.config/opencode/b-agentic/AGENTS.md"
  assert_contains "$sandbox_piped/home/.config/opencode/b-agentic/install.json" '"agentsAction": "replace"'
  assert_contains "$sandbox_piped/home/.config/opencode/b-agentic/install.json" '"activationState": "active"'
  compgen -G "$sandbox_piped/home/.config/opencode/b-agentic/backups/AGENTS.md.bak-*" >/dev/null || fail 'expected AGENTS backup after prompted replacement'

  mkdir -p "$sandbox_provider_delete/home/.config/opencode"
  cat > "$sandbox_provider_delete/home/.config/opencode/opencode.json" <<'EOF'
{
  "provider": {
    "openrouter": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "OpenRouter",
      "options": {
        "baseURL": "https://openrouter.ai/api/v1",
        "apiKey": "saved-key"
      },
      "models": {
        "remove-me": {
          "name": "Remove Me"
        },
        "keep-me": {
          "name": "Keep Me"
        }
      }
    }
  }
}
EOF
  rc="$(run_piped_install_with_tty_status "$sandbox_provider_delete" "$snapshot_repo" $'y\nopenrouter\n\n\n\ny\ny\nn\n\n')"
  [ "$rc" -eq 0 ] || fail "expected provider-delete install exit 0, got $rc"
  assert_contains "$sandbox_provider_delete/home/.config/opencode/opencode.json" '"keep-me"'
  assert_not_contains "$sandbox_provider_delete/home/.config/opencode/opencode.json" '"remove-me"'
  assert_contains "$sandbox_provider_delete/home/.config/opencode/b-agentic/install.json" '"customProvider": "openrouter"'

  mkdir -p "$sandbox_uninstall/home/.config/opencode"
  printf 'legacy-rules\n' > "$sandbox_uninstall/home/.config/opencode/AGENTS.md"
  expect_install_status 0 "$sandbox_uninstall" "$snapshot_repo" N --replace-agents
  compgen -G "$sandbox_uninstall/home/.config/opencode/b-agentic/backups/AGENTS.md.bak-*" >/dev/null || fail 'expected AGENTS backup before uninstall'
  run_install_output "$sandbox_uninstall" "$snapshot_repo" N --uninstall >/dev/null
  assert_no_file "$sandbox_uninstall/home/.config/opencode/skills/b-plan/SKILL.md"
  assert_no_file "$sandbox_uninstall/home/.config/opencode/skills/b-browser/SKILL.md"
  assert_no_file "$sandbox_uninstall/home/.config/opencode/commands/b-plan.md"
  assert_no_file "$sandbox_uninstall/home/.config/opencode/commands/b-browser.md"
  assert_no_file "$sandbox_uninstall/home/.config/opencode/references/b-agentic/runtime-contract.md"
  assert_no_file "$sandbox_uninstall/home/.config/opencode/b-agentic/AGENTS.md"
  assert_no_file "$sandbox_uninstall/home/.config/opencode/b-agentic/install.json"
  compgen -G "$sandbox_uninstall/home/.config/opencode/b-agentic/backups/AGENTS.md.bak-*" >/dev/null || fail 'expected AGENTS backup to remain after uninstall'
  assert_text_equals "$sandbox_uninstall/home/.config/opencode/AGENTS.md" $'legacy-rules\n'

  mkdir -p "$sandbox_uninstall/home/.config/opencode"
  printf 'manual backup\n' > "$sandbox_uninstall/home/.config/opencode/AGENTS.md.bak-manual"
  expect_install_status 2 "$sandbox_uninstall" "$snapshot_repo" N
  assert_file "$sandbox_uninstall/home/.config/opencode/AGENTS.md.bak-manual"
  assert_no_file "$sandbox_uninstall/home/.config/opencode/b-agentic/backups/AGENTS.md.bak-manual"

  mkdir -p "$sandbox_uninstall_modified/home/.config/opencode"
  printf 'legacy-rules\n' > "$sandbox_uninstall_modified/home/.config/opencode/AGENTS.md"
  expect_install_status 0 "$sandbox_uninstall_modified" "$snapshot_repo" N --replace-agents
  printf 'user-edited-rules\n' > "$sandbox_uninstall_modified/home/.config/opencode/AGENTS.md"
  run_install_output "$sandbox_uninstall_modified" "$snapshot_repo" N --uninstall >/dev/null
  assert_text_equals "$sandbox_uninstall_modified/home/.config/opencode/AGENTS.md" $'user-edited-rules\n'

  mkdir -p "$sandbox_uninstall_merged/home/.config/opencode"
  printf '# b-agentic — OpenCode Runtime Kernel\ncustom-user-rules\n' > "$sandbox_uninstall_merged/home/.config/opencode/AGENTS.md"
  run_install_output "$sandbox_uninstall_merged" "$snapshot_repo" N --uninstall >/dev/null
  assert_text_equals "$sandbox_uninstall_merged/home/.config/opencode/AGENTS.md" $'# b-agentic — OpenCode Runtime Kernel\ncustom-user-rules\n'

  mkdir -p "$sandbox_uninstall_custom/home/.config/opencode/skills/b-plan" "$sandbox_uninstall_custom/home/.config/opencode/commands"
  printf '%s\n' 'custom skill' > "$sandbox_uninstall_custom/home/.config/opencode/skills/b-plan/SKILL.md"
  printf '%s\n' 'custom command' > "$sandbox_uninstall_custom/home/.config/opencode/commands/b-plan.md"
  run_install_output "$sandbox_uninstall_custom" "$snapshot_repo" N --uninstall >/dev/null
  assert_text_equals "$sandbox_uninstall_custom/home/.config/opencode/skills/b-plan/SKILL.md" $'custom skill\n'
  assert_text_equals "$sandbox_uninstall_custom/home/.config/opencode/commands/b-plan.md" $'custom command\n'

  printf 'smoke-install.sh: PASS\n'
}

main "$@"
