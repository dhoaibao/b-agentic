#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="$(mktemp -d /tmp/b-agentic-smoke.XXXXXX)"

cleanup() {
  rm -rf "$WORK_DIR"
}

trap cleanup EXIT

source "$ROOT_DIR/tests/smoke/lib.sh"

registry_runtime_records() {
  python3 - "$ROOT_DIR/runtimes/registry.yaml" <<'PY'
from pathlib import Path
import json
import sys

registry = json.loads(Path(sys.argv[1]).read_text())
for runtime in registry.get('runtimes', []):
    name = runtime.get('name')
    metadata_root = runtime.get('metadata_root')
    memory_install_path = runtime.get('memory_install_path')
    if (
        isinstance(name, str) and name
        and isinstance(metadata_root, str) and metadata_root.startswith('~/')
        and isinstance(memory_install_path, str) and memory_install_path.startswith('~/')
    ):
        print(f"{name}\t{metadata_root[2:]}\t{memory_install_path[2:]}")
PY
}

first_runtime_skill_collision_record() {
  python3 - "$ROOT_DIR/runtimes/registry.yaml" <<'PY'
from pathlib import Path
import json
import sys

registry = json.loads(Path(sys.argv[1]).read_text())
for runtime in registry.get('runtimes', []):
    name = runtime.get('name')
    metadata_root = runtime.get('metadata_root')
    memory_install_path = runtime.get('memory_install_path')
    skills_install_root = runtime.get('skills_install_root')
    if (
        isinstance(name, str) and name
        and isinstance(metadata_root, str) and metadata_root.startswith('~/')
        and isinstance(memory_install_path, str) and memory_install_path.startswith('~/')
        and isinstance(skills_install_root, str) and skills_install_root.startswith('~/')
    ):
        print(f"{name}\t{metadata_root[2:]}\t{memory_install_path[2:]}\t{skills_install_root[2:]}")
        break
PY
}

opencode_skill_collision_record() {
  python3 - "$ROOT_DIR/runtimes/registry.yaml" <<'PY'
from pathlib import Path
import json
import sys

registry = json.loads(Path(sys.argv[1]).read_text())
for runtime in registry.get('runtimes', []):
    if runtime.get('name') != 'opencode':
        continue
    metadata_root = runtime.get('metadata_root')
    skills_install_root = runtime.get('skills_install_root')
    wrappers = runtime.get('command_wrappers', {})
    commands_root = wrappers.get('install_root') if isinstance(wrappers, dict) else None
    if (
        isinstance(metadata_root, str) and metadata_root.startswith('~/')
        and isinstance(skills_install_root, str) and skills_install_root.startswith('~/')
        and isinstance(commands_root, str) and commands_root.startswith('~/')
    ):
        print(f"{metadata_root[2:]}\t{skills_install_root[2:]}\t{commands_root[2:]}")
    break
PY
}

run_manifest_only_corrupted_manifest_case() {
  local sandbox_corrupt="$WORK_DIR/manifest-only-corrupt"

  mkdir -p "$sandbox_corrupt/home/Documents/b-owned" "$sandbox_corrupt/home/.claude/b-agentic"
  printf 'sentinel\n' > "$sandbox_corrupt/home/Documents/b-owned/file.txt"
  cat > "$sandbox_corrupt/home/.claude/b-agentic/install.json" <<EOF
{"runtime":"claude-code","paths":{"skills":"$sandbox_corrupt/home/Documents","kernel":"$sandbox_corrupt/home/.claude/CLAUDE.md"},"skills":["b-owned"],"agents":[]}
EOF

  local rc=0
  set +e
  HOME="$sandbox_corrupt/home" \
  B_AGENTIC_REPO="$sandbox_corrupt/missing-source" \
  B_AGENTIC_DIR="$sandbox_corrupt/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  bash "$ROOT_DIR/install.sh" --uninstall >"$sandbox_corrupt/uninstall.log" 2>&1
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "corrupt manifest-only uninstall without helper should fail safely"
  assert_contains "$sandbox_corrupt/uninstall.log" "requires $sandbox_corrupt/home/.claude/b-agentic/tooling/install/manifest_uninstall.py"
  assert_file "$sandbox_corrupt/home/Documents/b-owned/file.txt"
  assert_no_path "$sandbox_corrupt/source"
}

run_manifest_only_custom_paths_case() {
  local sandbox_custom="$WORK_DIR/manifest-only-custom-paths"
  local manifest_path skill_dir kernel_path snapshot_path

  mkdir -p "$sandbox_custom/home/custom-meta" "$sandbox_custom/home/custom-skills/b-plan" "$sandbox_custom/home/custom-kernel"
  manifest_path="$sandbox_custom/home/custom-meta/install.json"
  skill_dir="$sandbox_custom/home/custom-skills/b-plan"
  kernel_path="$sandbox_custom/home/custom-kernel/CLAUDE.md"
  snapshot_path="$sandbox_custom/home/custom-meta/CLAUDE.md"

  printf 'Generated from skills/registry.yaml\n' > "$skill_dir/SKILL.md"
  printf '<!-- b-agentic-managed -->\ncustom kernel\n' > "$kernel_path"
  printf '<!-- b-agentic-managed -->\ncustom kernel\n' > "$snapshot_path"
  cat > "$manifest_path" <<EOF
{"runtime":"claude-code","paths":{"skills":"$sandbox_custom/home/custom-skills","kernel":"$kernel_path"},"skills":["b-plan"],"agents":[]}
EOF

  HOME="$sandbox_custom/home" python3 "$ROOT_DIR/tooling/install/manifest_uninstall.py" "$manifest_path" >"$sandbox_custom/uninstall.log" 2>&1

  assert_contains "$sandbox_custom/uninstall.log" 'Manifest-only uninstall complete for claude-code'
  assert_no_path "$skill_dir"
  assert_no_path "$kernel_path"
  assert_no_path "$sandbox_custom/home/custom-meta"
}

run_all_runtime_smoke_case() {
  local snapshot_repo="$1"
  local sandbox_all="$WORK_DIR/all-runtimes"
  local runtime_name metadata_root kernel_path manifest_path
  local sandbox_pending="$WORK_DIR/all-runtimes-pending"
  local pending_runtime_name="" pending_kernel_path=""

  mkdir -p "$sandbox_all/home"
  expect_install_status 0 "$sandbox_all" "$snapshot_repo" --runtime=all

  while IFS=$'\t' read -r runtime_name metadata_root kernel_path; do
    [ -n "$runtime_name" ] || continue
    manifest_path="$sandbox_all/home/$metadata_root/install.json"
    assert_file "$manifest_path"
    assert_json_value "$manifest_path" "data['runtime'] == '$runtime_name'"
    assert_file "$sandbox_all/home/$metadata_root/references/contract/runtime.md"
    assert_file "$sandbox_all/home/$metadata_root/references/contract/safety-tools.md"
    assert_no_path "$sandbox_all/home/$metadata_root/references/contract/output.md"
    assert_no_path "$sandbox_all/home/$metadata_root/references/contract/decisions.md"
    assert_no_path "$sandbox_all/home/$metadata_root/references/contract/state-machine.md"
    assert_no_path "$sandbox_all/home/$metadata_root/references/contract/index.md"
  done < <(registry_runtime_records install)

  rm -rf "$sandbox_all/source"
  HOME="$sandbox_all/home" \
  B_AGENTIC_REPO="$sandbox_all/missing-source" \
  B_AGENTIC_DIR="$sandbox_all/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  bash "$ROOT_DIR/install.sh" --runtime=all --uninstall >"$sandbox_all/manifest-only-uninstall.log" 2>&1
  assert_contains "$sandbox_all/manifest-only-uninstall.log" 'Manifest-only uninstall complete for claude-code'
  assert_contains "$sandbox_all/manifest-only-uninstall.log" 'Manifest-only uninstall complete for opencode'
  assert_contains "$sandbox_all/manifest-only-uninstall.log" 'Manifest-only uninstall complete for codex-cli'
  assert_no_path "$sandbox_all/source"

  while IFS=$'\t' read -r runtime_name metadata_root kernel_path; do
    [ -n "$runtime_name" ] || continue
    assert_no_path "$sandbox_all/home/$metadata_root/install.json"
  done < <(registry_runtime_records)
  assert_no_path "$sandbox_all/home/.claude/skills/b-plan"
  assert_no_path "$sandbox_all/home/.claude/CLAUDE.md"
  assert_no_path "$sandbox_all/home/.claude/agents/b-explore.md"
  assert_no_path "$sandbox_all/home/.config/opencode/skills/b-plan"
  assert_no_path "$sandbox_all/home/.config/opencode/AGENTS.md"
  assert_no_path "$sandbox_all/home/.config/opencode/commands/b-plan.md"
  assert_no_path "$sandbox_all/home/.config/opencode/agents/b-explore.md"
  assert_no_path "$sandbox_all/home/.codex/skills/b-plan"
  assert_no_path "$sandbox_all/home/.codex/AGENTS.md"
  assert_no_path "$sandbox_all/home/.codex/agents/b-explore.toml"
  assert_no_path "$sandbox_all/home/.codex/rules/b-agentic.rules"

  mkdir -p "$sandbox_pending/home"
  IFS=$'\t' read -r pending_runtime_name _ pending_kernel_path < <(registry_runtime_records)
  [ -n "$pending_runtime_name" ] || fail "expected at least one registered runtime"
  mkdir -p "$(dirname "$sandbox_pending/home/$pending_kernel_path")"
  printf 'user-owned kernel\n' > "$sandbox_pending/home/$pending_kernel_path"

  expect_install_status 2 "$sandbox_pending" "$snapshot_repo" --runtime=all

  while IFS=$'\t' read -r runtime_name metadata_root kernel_path; do
    [ -n "$runtime_name" ] || continue
    manifest_path="$sandbox_pending/home/$metadata_root/install.json"
    assert_file "$manifest_path"
    assert_json_value "$manifest_path" "data['runtime'] == '$runtime_name'"
    if [ "$runtime_name" = "$pending_runtime_name" ]; then
      assert_json_value "$manifest_path" "data['activationState'] == 'pending'"
    else
      assert_json_value "$manifest_path" "data['activationState'] == 'active'"
    fi
  done < <(registry_runtime_records install)
}

run_skill_collision_smoke_case() {
  local snapshot_repo="$1"
  local sandbox_collision="$WORK_DIR/skill-collision"
  local runtime_name metadata_root kernel_path skills_root manifest_path skill_path

  IFS=$'\t' read -r runtime_name metadata_root kernel_path skills_root < <(first_runtime_skill_collision_record)
  [ -n "$runtime_name" ] || fail "expected at least one registered runtime"

  mkdir -p "$sandbox_collision/home/$skills_root/b-plan"
  skill_path="$sandbox_collision/home/$skills_root/b-plan/SKILL.md"
  printf 'user-owned b-plan\n' > "$skill_path"

  expect_install_status 0 "$sandbox_collision" "$snapshot_repo" --runtime="$runtime_name"

  manifest_path="$sandbox_collision/home/$metadata_root/install.json"
  assert_file "$manifest_path"
  assert_contains "$skill_path" 'user-owned b-plan'
  assert_json_value "$manifest_path" "'b-plan' not in data['skills']"
}

run_opencode_skill_command_collision_smoke_case() {
  local snapshot_repo="$1"
  local sandbox_collision="$WORK_DIR/opencode-skill-command-collision"
  local metadata_root skills_root commands_root manifest_path skill_path command_path

  IFS=$'\t' read -r metadata_root skills_root commands_root < <(opencode_skill_collision_record)
  [ -n "$metadata_root" ] || fail "expected opencode runtime collision record"

  mkdir -p "$sandbox_collision/home/$skills_root/b-plan"
  skill_path="$sandbox_collision/home/$skills_root/b-plan/SKILL.md"
  command_path="$sandbox_collision/home/$commands_root/b-plan.md"
  printf 'user-owned b-plan\n' > "$skill_path"

  expect_install_status 0 "$sandbox_collision" "$snapshot_repo" --runtime=opencode

  manifest_path="$sandbox_collision/home/$metadata_root/install.json"
  assert_file "$manifest_path"
  assert_contains "$skill_path" 'user-owned b-plan'
  assert_no_path "$command_path"
  assert_json_value "$manifest_path" "'b-plan' not in data['skills']"
  assert_json_value "$manifest_path" "'b-plan' not in data['commands']"
}

run_readiness_report_case() {
  local snapshot_repo="$1"
  local sandbox_claude="$WORK_DIR/readiness-claude"
  local sandbox_codex="$WORK_DIR/readiness-codex"
  local rc=0

  mkdir -p "$sandbox_claude/home" "$sandbox_codex/home"

  set +e
  run_install_with_tty_log "$sandbox_claude" "$snapshot_repo" "$sandbox_claude/install.log" --runtime=claude-code
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "expected Claude readiness install exit 0, got $rc"
  assert_contains "$sandbox_claude/install.log" 'Readiness:'
  assert_contains "$sandbox_claude/install.log" 'serena:'
  assert_contains "$sandbox_claude/install.log" 'context7:'
  assert_contains "$sandbox_claude/install.log" 'brave-search:'
  assert_contains "$sandbox_claude/install.log" 'firecrawl:'
  assert_contains "$sandbox_claude/install.log" 'playwright:'
  assert_contains "$sandbox_claude/install.log" 'mcp-startup:'
  assert_contains "$sandbox_claude/install.log" 'rtk:'

  set +e
  run_install_with_tty_log "$sandbox_codex" "$snapshot_repo" "$sandbox_codex/install.log" --runtime=codex-cli
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "expected Codex readiness install exit 0, got $rc"
  assert_contains "$sandbox_codex/install.log" 'Readiness:'
  assert_contains "$sandbox_codex/install.log" 'serena:'
  assert_contains "$sandbox_codex/install.log" 'context7:'
  assert_contains "$sandbox_codex/install.log" 'brave-search:'
  assert_contains "$sandbox_codex/install.log" 'firecrawl:'
  assert_contains "$sandbox_codex/install.log" 'playwright:'
  assert_contains "$sandbox_codex/install.log" 'mcp-startup:'
  assert_contains "$sandbox_codex/install.log" 'rtk:'
}

run_mcp_doctor_case() {
  local snapshot_repo="$1"
  local sandbox_claude="$WORK_DIR/mcp-doctor-claude"
  local sandbox_codex="$WORK_DIR/mcp-doctor-codex"
  local sandbox_opencode="$WORK_DIR/mcp-doctor-opencode"
  local bin_dir="$WORK_DIR/mcp-doctor-bin"
  local doctor_log="$WORK_DIR/mcp-doctor.log"
  mkdir -p "$sandbox_claude/home" "$sandbox_codex/home" "$sandbox_opencode/home" "$bin_dir"

  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin_dir/serena"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin_dir/pnpm"
  chmod +x "$bin_dir/serena" "$bin_dir/pnpm"

  expect_install_status 0 "$sandbox_claude" "$snapshot_repo" --runtime=claude-code
  PATH="$bin_dir:$PATH" \
  CONTEXT7_API_KEY=test-context7 \
  BRAVE_API_KEY=test-brave \
  FIRECRAWL_API_KEY=test-firecrawl \
  python3 "$ROOT_DIR/tooling/validate/mcp_doctor.py" --runtime=claude-code --home "$sandbox_claude/home" >"$doctor_log"
  assert_contains "$doctor_log" 'serena: ready:'
  assert_contains "$doctor_log" 'context7: ready:'
  assert_contains "$doctor_log" 'brave-search: ready:'
  assert_contains "$doctor_log" 'firecrawl: ready:'
  assert_contains "$doctor_log" 'playwright: ready:'

  expect_install_status 0 "$sandbox_codex" "$snapshot_repo" --runtime=codex-cli
  PATH="$bin_dir:$PATH" \
  CONTEXT7_API_KEY=test-context7 \
  BRAVE_API_KEY=test-brave \
  FIRECRAWL_API_KEY=test-firecrawl \
  python3 "$ROOT_DIR/tooling/validate/mcp_doctor.py" --runtime=codex-cli --home "$sandbox_codex/home" >"$doctor_log"
  assert_contains "$doctor_log" 'serena: ready:'
  assert_contains "$doctor_log" 'context7: ready:'
  assert_contains "$doctor_log" 'brave-search: ready:'
  assert_contains "$doctor_log" 'firecrawl: ready:'
  assert_contains "$doctor_log" 'playwright: ready:'

  expect_install_status 0 "$sandbox_opencode" "$snapshot_repo" --runtime=opencode
  PATH="$bin_dir:$PATH" \
  CONTEXT7_API_KEY=test-context7 \
  BRAVE_API_KEY=test-brave \
  FIRECRAWL_API_KEY=test-firecrawl \
  python3 "$ROOT_DIR/tooling/validate/mcp_doctor.py" --runtime=opencode --home "$sandbox_opencode/home" >"$doctor_log"
  assert_contains "$doctor_log" 'serena: ready:'
  assert_contains "$doctor_log" 'context7: ready:'
  assert_contains "$doctor_log" 'brave-search: ready:'
  assert_contains "$doctor_log" 'firecrawl: ready:'
  assert_contains "$doctor_log" 'playwright: ready:'

}

run_skill_doctor_case() {
  local snapshot_repo="$1"
  local sandbox_claude="$WORK_DIR/skill-doctor-claude"
  local sandbox_codex="$WORK_DIR/skill-doctor-codex"
  local sandbox_opencode="$WORK_DIR/skill-doctor-opencode"
  local doctor_log="$WORK_DIR/skill-doctor.log"
  local expected_skill_count
  mkdir -p "$sandbox_claude/home" "$sandbox_codex/home" "$sandbox_opencode/home"
  expected_skill_count="$(registry_skill_count)"

  expect_install_status 0 "$sandbox_claude" "$snapshot_repo" --runtime=claude-code
  python3 "$ROOT_DIR/tooling/validate/skill_doctor.py" --runtime=claude-code --home "$sandbox_claude/home" >"$doctor_log"
  assert_contains "$doctor_log" "expected-skills: $expected_skill_count"
  assert_contains "$doctor_log" 'kernel: ready'
  assert_contains "$doctor_log" "skills: ready: $expected_skill_count skills installed"
  assert_contains "$doctor_log" 'discovery: ready:'
  rm -rf "$sandbox_claude/home/.claude/skills/b-review"
  python3 "$ROOT_DIR/tooling/validate/skill_doctor.py" --runtime=claude-code --home "$sandbox_claude/home" >"$doctor_log"
  assert_contains "$doctor_log" 'skills: missing or mismatched: missing b-review'
  assert_contains "$doctor_log" 'discovery: blocked: install complete skill payload'

  expect_install_status 0 "$sandbox_codex" "$snapshot_repo" --runtime=codex-cli
  python3 "$ROOT_DIR/tooling/validate/skill_doctor.py" --runtime=codex-cli --home "$sandbox_codex/home" >"$doctor_log"
  assert_contains "$doctor_log" "expected-skills: $expected_skill_count"
  assert_contains "$doctor_log" 'kernel: ready'
  assert_contains "$doctor_log" "skills: ready: $expected_skill_count skills installed"
  assert_contains "$doctor_log" 'config: ready'
  assert_contains "$doctor_log" 'discovery: ready:'

  expect_install_status 0 "$sandbox_opencode" "$snapshot_repo" --runtime=opencode
  python3 "$ROOT_DIR/tooling/validate/skill_doctor.py" --runtime=opencode --home "$sandbox_opencode/home" >"$doctor_log"
  assert_contains "$doctor_log" "expected-skills: $expected_skill_count"
  assert_contains "$doctor_log" 'kernel: ready'
  assert_contains "$doctor_log" "skills: ready: $expected_skill_count skills installed"
  assert_contains "$doctor_log" "wrappers: ready: $expected_skill_count wrappers installed"
  assert_contains "$doctor_log" 'discovery: ready:'

}

main() {
  local snapshot_repo="$WORK_DIR/repo-snapshot"
  local runtime_name runtime_script
  local -a runtime_names=()

  require_bin git
  require_bin python3
  make_repo_snapshot "$snapshot_repo"
  run_all_runtime_smoke_case "$snapshot_repo"
  run_manifest_only_corrupted_manifest_case
  run_manifest_only_custom_paths_case
  run_skill_collision_smoke_case "$snapshot_repo"
  run_opencode_skill_command_collision_smoke_case "$snapshot_repo"
  run_readiness_report_case "$snapshot_repo"
  run_mcp_doctor_case "$snapshot_repo"
  run_skill_doctor_case "$snapshot_repo"

  while IFS= read -r runtime_name; do
    [ -n "$runtime_name" ] || continue
    runtime_names+=("$runtime_name")
  done < <(registered_runtime_names)

  for runtime_name in "${runtime_names[@]}"; do
    runtime_script="$ROOT_DIR/runtimes/$runtime_name/tests/smoke.sh"
    [ -f "$runtime_script" ] || fail "missing smoke suite: $runtime_script"

    unset -f run_runtime_smoke_cases runtime_smoke_name 2>/dev/null || true
    # shellcheck disable=SC1090
    source "$runtime_script"
    declare -F run_runtime_smoke_cases >/dev/null || fail "runtime smoke suite did not define run_runtime_smoke_cases: $runtime_script"
    run_runtime_smoke_cases "$snapshot_repo"
  done

  printf 'smoke-install.sh passed\n'
}

main "$@"
