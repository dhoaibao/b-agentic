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

run_invalid_runtime_layout_validation_case() {
  local snapshot_repo="$1"
  local sandbox_invalid="$WORK_DIR/invalid-runtime-layout"
  local sandbox_schema="$WORK_DIR/invalid-runtime-schema"

  git clone --quiet "$snapshot_repo" "$sandbox_invalid"
  python3 - "$sandbox_invalid/runtimes/registry.yaml" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["runtimes"][0]["metadata_root"] = "~/.broken/meta"
path.write_text(json.dumps(data, indent=2) + "\n")
PY

  local rc=0
  set +e
  ( cd "$sandbox_invalid" && python3 tooling/generate/registry_sync.py --check ) >"$sandbox_invalid/layout-check.log" 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "invalid runtime layout should fail registry sync validation"
  assert_contains "$sandbox_invalid/layout-check.log" 'metadata_root: must end with b-agentic'

  git clone --quiet "$snapshot_repo" "$sandbox_schema"
  python3 - "$sandbox_schema/runtimes/registry.yaml" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["runtimes"][0]["config_schema_family"] = "unknown-schema"
path.write_text(json.dumps(data, indent=2) + "\n")
PY

  rc=0
  set +e
  ( cd "$sandbox_schema" && python3 tooling/generate/registry_sync.py --check ) >"$sandbox_schema/schema-check.log" 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "invalid runtime config schema should fail registry sync validation"
  assert_contains "$sandbox_schema/schema-check.log" 'config_schema_family: expected one of'
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
  assert_contains "$sandbox_all/manifest-only-uninstall.log" 'Manifest-only uninstall complete for kimi-code-cli'
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
  assert_no_path "$sandbox_all/home/.kimi-code/skills/b-plan"
  assert_no_path "$sandbox_all/home/.kimi-code/AGENTS.md"
  assert_no_path "$sandbox_all/home/.kimi-code/config.toml"
  assert_no_path "$sandbox_all/home/.kimi-code/agents/b-explore.md"

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
  assert_contains "$sandbox_claude/install.log" 'codegraph:'
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
  assert_contains "$sandbox_codex/install.log" 'codegraph:'
  assert_contains "$sandbox_codex/install.log" 'context7:'
  assert_contains "$sandbox_codex/install.log" 'brave-search:'
  assert_contains "$sandbox_codex/install.log" 'firecrawl:'
  assert_contains "$sandbox_codex/install.log" 'playwright:'
  assert_contains "$sandbox_codex/install.log" 'mcp-startup:'
  assert_contains "$sandbox_codex/install.log" 'rtk:'
}

run_shell_tool_prompt_case() {
  local snapshot_repo="$1"
  local sandbox="$WORK_DIR/shell-tool-prompt"
  local bin_dir="$sandbox/bin"
  local apt_sandbox="$WORK_DIR/shell-tool-apt-get"
  local apt_bin_dir="$apt_sandbox/bin"
  local apt_log="$apt_sandbox/apt-get.log"
  local apt_install_log="$apt_sandbox/install.log"
  local install_log="$sandbox/install.log"
  local rc=0
  local tool src

  mkdir -p "$bin_dir" "$sandbox/home"

  for tool in basename chmod cmp cp date dirname env git grep id mkdir mktemp python3 rm uname; do
    src="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$src" ] || fail "required smoke helper not found: $tool"
    ln -s "$src" "$bin_dir/$tool"
  done

  set +e
  python3 - "$sandbox" "$snapshot_repo" "$install_log" "$bin_dir" "$ROOT_DIR/install.sh" <<'PY'
import os, pty, select, sys

sandbox, repo_snapshot, log_path, smoke_path, install_script = sys.argv[1:6]
env = dict(os.environ)
env["HOME"] = os.path.join(sandbox, "home")
env["PATH"] = smoke_path
env["B_AGENTIC_REPO"] = repo_snapshot
env["B_AGENTIC_DIR"] = os.path.join(sandbox, "source")
env["B_AGENTIC_PROMPT_API_KEYS"] = "N"
env["B_AGENTIC_INSTALL_RTK"] = "N"
env["B_AGENTIC_INSTALL_SERENA"] = "N"
env["B_AGENTIC_INSTALL_CODEGRAPH"] = "N"
env["B_AGENTIC_SHELL_RECOMMEND_MANAGER"] = "manual"

pid, fd = pty.fork()
if pid == 0:
    os.environ.update(env)
    os.execv("/bin/bash", ["bash", install_script, "--runtime=claude-code"])

os.write(fd, b"n\n")
status = None
with open(log_path, "wb") as log:
    while True:
        try:
            result, status = os.waitpid(pid, os.WNOHANG)
            if result:
                break
            ready, _, _ = select.select([fd], [], [], 0.1)
            if ready:
                chunk = os.read(fd, 4096)
                if not chunk:
                    _, status = os.waitpid(pid, 0)
                    break
                log.write(chunk)
                log.flush()
        except (OSError, select.error):
            break

os.close(fd)
if status is None:
    _, status = os.waitpid(pid, 0)

if os.WIFEXITED(status):
    sys.exit(os.WEXITSTATUS(status))
if os.WIFSIGNALED(status):
    sys.exit(128 + os.WTERMSIG(status))
sys.exit(1)
PY
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "expected shell tool prompt install exit 0, got $rc"
  assert_contains "$install_log" "Shell tooling missing (rg, fd/fdfind, jq). Install now with 'install manually: ripgrep, fd or fd-find, jq'? [y/N]:"
  assert_contains "$install_log" 'core: blocked: missing rg, fd/fdfind, jq'
  assert_not_contains "$install_log" 'suggestions only; no packages were installed automatically'

  mkdir -p "$apt_bin_dir" "$apt_sandbox/home"
  for tool in basename bash chmod cmp cp date dirname env git grep ln mkdir mktemp python3 rm uname; do
    src="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$src" ] || fail "required smoke helper not found: $tool"
    ln -s "$src" "$apt_bin_dir/$tool"
  done
  cat > "$apt_bin_dir/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-u" ]; then
  printf '1000\n'
  exit 0
fi
exit 1
EOF
  cat > "$apt_bin_dir/sudo" <<EOF
#!/usr/bin/env bash
printf 'sudo:%s\n' "\$*" >> "$apt_log"
"\$@"
EOF
  cat > "$apt_bin_dir/apt-get" <<EOF
#!/usr/bin/env bash
printf 'apt-get:%s\n' "\$*" >> "$apt_log"
exit 0
EOF
  chmod +x "$apt_bin_dir/id" "$apt_bin_dir/sudo" "$apt_bin_dir/apt-get"

  set +e
  HOME="$apt_sandbox/home" \
  PATH="$apt_bin_dir" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$apt_sandbox/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  B_AGENTIC_INSTALL_RTK=N \
  B_AGENTIC_INSTALL_SERENA=N \
  B_AGENTIC_INSTALL_CODEGRAPH=N \
  B_AGENTIC_SHELL_RECOMMEND_MANAGER=apt-get \
  bash "$ROOT_DIR/install.sh" --runtime=claude-code --install-shell-tools >"$apt_install_log" 2>&1
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "expected apt-get shell tool install exit 0, got $rc"
  assert_contains "$apt_log" 'sudo:apt-get install -y ripgrep fd-find jq'
  assert_contains "$apt_log" 'apt-get:install -y ripgrep fd-find jq'
  assert_contains "$apt_install_log" 'Shell tooling install command completed'
}

run_mcp_doctor_case() {
  local snapshot_repo="$1"
  local sandbox_claude="$WORK_DIR/mcp-doctor-claude"
  local sandbox_codex="$WORK_DIR/mcp-doctor-codex"
  local sandbox_opencode="$WORK_DIR/mcp-doctor-opencode"
  local sandbox_kimi="$WORK_DIR/mcp-doctor-kimi"
  local bin_dir="$WORK_DIR/mcp-doctor-bin"
  local doctor_log="$WORK_DIR/mcp-doctor.log"
  mkdir -p "$sandbox_claude/home" "$sandbox_codex/home" "$sandbox_opencode/home" "$sandbox_kimi/home" "$bin_dir"

  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin_dir/serena"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin_dir/codegraph"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin_dir/pnpm"
  chmod +x "$bin_dir/serena" "$bin_dir/codegraph" "$bin_dir/pnpm"

  expect_install_status 0 "$sandbox_claude" "$snapshot_repo" --runtime=claude-code
  PATH="$bin_dir:$PATH" \
  CONTEXT7_API_KEY=test-context7 \
  BRAVE_API_KEY=test-brave \
  FIRECRAWL_API_KEY=test-firecrawl \
  python3 "$ROOT_DIR/tooling/validate/mcp_doctor.py" --runtime=claude-code --home "$sandbox_claude/home" >"$doctor_log"
  assert_contains "$doctor_log" 'serena: ready:'
  assert_contains "$doctor_log" 'codegraph: ready:'
  assert_contains "$doctor_log" 'context7: ready:'
  assert_contains "$doctor_log" 'brave-search: ready:'
  assert_contains "$doctor_log" 'firecrawl: ready:'
  assert_contains "$doctor_log" 'playwright: ready:'

  expect_install_status 0 "$sandbox_codex" "$snapshot_repo" --runtime=codex-cli
  PATH="$bin_dir:$PATH" \
  BRAVE_API_KEY=test-brave \
  FIRECRAWL_API_KEY=test-firecrawl \
  python3 "$ROOT_DIR/tooling/validate/mcp_doctor.py" --runtime=codex-cli --home "$sandbox_codex/home" >"$doctor_log"
  assert_contains "$doctor_log" 'context7: blocked: missing CONTEXT7_API_KEY; env binding configured in Codex config'
  PATH="$bin_dir:$PATH" \
  CONTEXT7_API_KEY=test-context7 \
  BRAVE_API_KEY=test-brave \
  FIRECRAWL_API_KEY=test-firecrawl \
  python3 "$ROOT_DIR/tooling/validate/mcp_doctor.py" --runtime=codex-cli --home "$sandbox_codex/home" >"$doctor_log"
  assert_contains "$doctor_log" 'serena: ready:'
  assert_contains "$doctor_log" 'codegraph: ready:'
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
  assert_contains "$doctor_log" 'codegraph: ready:'
  assert_contains "$doctor_log" 'context7: ready:'
  assert_contains "$doctor_log" 'brave-search: ready:'
  assert_contains "$doctor_log" 'firecrawl: ready:'
  assert_contains "$doctor_log" 'playwright: ready:'

  expect_install_status 0 "$sandbox_kimi" "$snapshot_repo" --runtime=kimi-code-cli
  PATH="$bin_dir:$PATH" \
  python3 "$ROOT_DIR/tooling/validate/mcp_doctor.py" --runtime=kimi-code-cli --home "$sandbox_kimi/home" >"$doctor_log"
  assert_contains "$doctor_log" 'serena: ready:'
  assert_contains "$doctor_log" 'codegraph: ready:'
  assert_contains "$doctor_log" 'context7: blocked: missing CONTEXT7_API_KEY'
  assert_contains "$doctor_log" 'brave-search: blocked: set BRAVE_API_KEY in Kimi MCP config'
  assert_contains "$doctor_log" 'firecrawl: blocked: set FIRECRAWL_API_KEY in Kimi MCP config'
  assert_contains "$doctor_log" 'playwright: ready:'

}

run_mcp_package_override_case() {
  local snapshot_repo="$1"
  local sandbox_claude="$WORK_DIR/mcp-package-claude"
  local sandbox_claude_upgrade="$WORK_DIR/mcp-package-claude-upgrade"
  local sandbox_codex="$WORK_DIR/mcp-package-codex"
  local sandbox_kimi="$WORK_DIR/mcp-package-kimi"
  local sandbox_opencode="$WORK_DIR/mcp-package-opencode"
  local sandbox_opencode_upgrade="$WORK_DIR/mcp-package-opencode-upgrade"
  local rc=0
  mkdir -p "$sandbox_claude/home" "$sandbox_claude_upgrade/home" "$sandbox_codex/home" "$sandbox_kimi/home" "$sandbox_opencode/home" "$sandbox_opencode_upgrade/home"

  set +e
  HOME="$sandbox_claude/home" \
  PATH="$(smoke_path_with_runtime_clis "$sandbox_claude")" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox_claude/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  B_AGENTIC_INSTALL_RTK=N \
  B_AGENTIC_INSTALL_SERENA=N \
  B_AGENTIC_INSTALL_CODEGRAPH=N \
  B_AGENTIC_BRAVE_MCP_PACKAGE='@example/brave-mcp@1.0.0' \
  B_AGENTIC_FIRECRAWL_MCP_PACKAGE='example-firecrawl-mcp@2.0.0' \
  B_AGENTIC_PLAYWRIGHT_MCP_PACKAGE='@example/playwright-mcp@3.0.0' \
  bash "$ROOT_DIR/install.sh" --runtime=claude-code >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "expected Claude package override install exit 0, got $rc"
  assert_json_value "$sandbox_claude/home/.claude.json" "data['mcpServers']['brave-search']['args'][1] == '@example/brave-mcp@1.0.0'"
  assert_json_value "$sandbox_claude/home/.claude.json" "data['mcpServers']['firecrawl']['args'][1] == 'example-firecrawl-mcp@2.0.0'"
  assert_json_value "$sandbox_claude/home/.claude.json" "data['mcpServers']['playwright']['args'][1] == '@example/playwright-mcp@3.0.0'"

  expect_install_status 0 "$sandbox_claude_upgrade" "$snapshot_repo" --runtime=claude-code
  set +e
  HOME="$sandbox_claude_upgrade/home" \
  PATH="$(smoke_path_with_runtime_clis "$sandbox_claude_upgrade")" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox_claude_upgrade/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  B_AGENTIC_INSTALL_RTK=N \
  B_AGENTIC_INSTALL_SERENA=N \
  B_AGENTIC_INSTALL_CODEGRAPH=N \
  B_AGENTIC_BRAVE_MCP_PACKAGE='@example/brave-mcp@1.0.0' \
  B_AGENTIC_FIRECRAWL_MCP_PACKAGE='example-firecrawl-mcp@2.0.0' \
  B_AGENTIC_PLAYWRIGHT_MCP_PACKAGE='@example/playwright-mcp@3.0.0' \
  bash "$ROOT_DIR/install.sh" --runtime=claude-code >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "expected Claude package override upgrade exit 0, got $rc"
  assert_json_value "$sandbox_claude_upgrade/home/.claude.json" "data['mcpServers']['brave-search']['args'] == ['dlx', '@example/brave-mcp@1.0.0', '--transport', 'stdio']"
  assert_json_value "$sandbox_claude_upgrade/home/.claude.json" "data['mcpServers']['firecrawl']['args'] == ['dlx', 'example-firecrawl-mcp@2.0.0']"
  assert_json_value "$sandbox_claude_upgrade/home/.claude.json" "data['mcpServers']['playwright']['args'] == ['dlx', '@example/playwright-mcp@3.0.0', '--isolated']"

  set +e
  HOME="$sandbox_claude_upgrade/home" \
  PATH="$(smoke_path_with_runtime_clis "$sandbox_claude_upgrade")" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox_claude_upgrade/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  B_AGENTIC_INSTALL_RTK=N \
  B_AGENTIC_INSTALL_SERENA=N \
  B_AGENTIC_INSTALL_CODEGRAPH=N \
  B_AGENTIC_BRAVE_MCP_PACKAGE='@example/brave-mcp@1.1.0' \
  B_AGENTIC_FIRECRAWL_MCP_PACKAGE='example-firecrawl-mcp@2.1.0' \
  B_AGENTIC_PLAYWRIGHT_MCP_PACKAGE='@example/playwright-mcp@3.1.0' \
  bash "$ROOT_DIR/install.sh" --runtime=claude-code >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "expected Claude package repin exit 0, got $rc"
  assert_json_value "$sandbox_claude_upgrade/home/.claude.json" "data['mcpServers']['brave-search']['args'] == ['dlx', '@example/brave-mcp@1.1.0', '--transport', 'stdio']"
  assert_json_value "$sandbox_claude_upgrade/home/.claude.json" "data['mcpServers']['firecrawl']['args'] == ['dlx', 'example-firecrawl-mcp@2.1.0']"
  assert_json_value "$sandbox_claude_upgrade/home/.claude.json" "data['mcpServers']['playwright']['args'] == ['dlx', '@example/playwright-mcp@3.1.0', '--isolated']"

  set +e
  HOME="$sandbox_opencode/home" \
  PATH="$(smoke_path_with_runtime_clis "$sandbox_opencode")" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox_opencode/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  B_AGENTIC_INSTALL_RTK=N \
  B_AGENTIC_INSTALL_SERENA=N \
  B_AGENTIC_INSTALL_CODEGRAPH=N \
  B_AGENTIC_BRAVE_MCP_PACKAGE='@example/brave-mcp@1.0.0' \
  B_AGENTIC_FIRECRAWL_MCP_PACKAGE='example-firecrawl-mcp@2.0.0' \
  B_AGENTIC_PLAYWRIGHT_MCP_PACKAGE='@example/playwright-mcp@3.0.0' \
  bash "$ROOT_DIR/install.sh" --runtime=opencode >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "expected OpenCode package override install exit 0, got $rc"
  assert_json_value "$sandbox_opencode/home/.config/opencode/opencode.json" "data['mcp']['brave-search']['command'][2] == '@example/brave-mcp@1.0.0'"
  assert_json_value "$sandbox_opencode/home/.config/opencode/opencode.json" "data['mcp']['firecrawl']['command'][2] == 'example-firecrawl-mcp@2.0.0'"
  assert_json_value "$sandbox_opencode/home/.config/opencode/opencode.json" "data['mcp']['playwright']['command'][2] == '@example/playwright-mcp@3.0.0'"

  expect_install_status 0 "$sandbox_opencode_upgrade" "$snapshot_repo" --runtime=opencode
  set +e
  HOME="$sandbox_opencode_upgrade/home" \
  PATH="$(smoke_path_with_runtime_clis "$sandbox_opencode_upgrade")" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox_opencode_upgrade/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  B_AGENTIC_INSTALL_RTK=N \
  B_AGENTIC_INSTALL_SERENA=N \
  B_AGENTIC_INSTALL_CODEGRAPH=N \
  B_AGENTIC_BRAVE_MCP_PACKAGE='@example/brave-mcp@1.0.0' \
  B_AGENTIC_FIRECRAWL_MCP_PACKAGE='example-firecrawl-mcp@2.0.0' \
  B_AGENTIC_PLAYWRIGHT_MCP_PACKAGE='@example/playwright-mcp@3.0.0' \
  bash "$ROOT_DIR/install.sh" --runtime=opencode >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "expected OpenCode package override upgrade exit 0, got $rc"
  assert_json_value "$sandbox_opencode_upgrade/home/.config/opencode/opencode.json" "data['mcp']['brave-search']['command'] == ['pnpm', 'dlx', '@example/brave-mcp@1.0.0', '--transport', 'stdio']"
  assert_json_value "$sandbox_opencode_upgrade/home/.config/opencode/opencode.json" "data['mcp']['firecrawl']['command'] == ['pnpm', 'dlx', 'example-firecrawl-mcp@2.0.0']"
  assert_json_value "$sandbox_opencode_upgrade/home/.config/opencode/opencode.json" "data['mcp']['playwright']['command'] == ['pnpm', 'dlx', '@example/playwright-mcp@3.0.0', '--isolated']"

  set +e
  HOME="$sandbox_codex/home" \
  PATH="$(smoke_path_with_runtime_clis "$sandbox_codex")" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox_codex/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  B_AGENTIC_INSTALL_RTK=N \
  B_AGENTIC_INSTALL_SERENA=N \
  B_AGENTIC_INSTALL_CODEGRAPH=N \
  B_AGENTIC_BRAVE_MCP_PACKAGE='@example/brave-mcp@1.0.0' \
  B_AGENTIC_FIRECRAWL_MCP_PACKAGE='example-firecrawl-mcp@2.0.0' \
  B_AGENTIC_PLAYWRIGHT_MCP_PACKAGE='@example/playwright-mcp@3.0.0' \
  bash "$ROOT_DIR/install.sh" --runtime=codex-cli >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "expected Codex package override install exit 0, got $rc"
  assert_toml_value "$sandbox_codex/home/.codex/config.toml" "data['mcp_servers']['brave-search']['args'][1] == '@example/brave-mcp@1.0.0'"
  assert_toml_value "$sandbox_codex/home/.codex/config.toml" "data['mcp_servers']['firecrawl']['args'][1] == 'example-firecrawl-mcp@2.0.0'"
  assert_toml_value "$sandbox_codex/home/.codex/config.toml" "data['mcp_servers']['playwright']['args'][1] == '@example/playwright-mcp@3.0.0'"

  set +e
  HOME="$sandbox_kimi/home" \
  PATH="$(smoke_path_with_runtime_clis "$sandbox_kimi")" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox_kimi/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  B_AGENTIC_INSTALL_RTK=N \
  B_AGENTIC_INSTALL_SERENA=N \
  B_AGENTIC_INSTALL_CODEGRAPH=N \
  B_AGENTIC_BRAVE_MCP_PACKAGE='@example/brave-mcp@1.0.0' \
  B_AGENTIC_FIRECRAWL_MCP_PACKAGE='example-firecrawl-mcp@2.0.0' \
  B_AGENTIC_PLAYWRIGHT_MCP_PACKAGE='@example/playwright-mcp@3.0.0' \
  bash "$ROOT_DIR/install.sh" --runtime=kimi-code-cli >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "expected Kimi package override install exit 0, got $rc"
  assert_json_value "$sandbox_kimi/home/.kimi-code/mcp.json" "data['mcpServers']['brave-search']['args'][1] == '@example/brave-mcp@1.0.0'"
  assert_json_value "$sandbox_kimi/home/.kimi-code/mcp.json" "data['mcpServers']['firecrawl']['args'][1] == 'example-firecrawl-mcp@2.0.0'"
  assert_json_value "$sandbox_kimi/home/.kimi-code/mcp.json" "data['mcpServers']['playwright']['args'][1] == '@example/playwright-mcp@3.0.0'"
  assert_json_value "$sandbox_kimi/home/.kimi-code/mcp.json" "'bearerTokenEnvVar' not in data['mcpServers']['context7']"
}

run_kimi_context7_env_binding_upgrade_case() {
  local snapshot_repo="$1"
  local sandbox="$WORK_DIR/kimi-context7-env-binding-upgrade"
  local claude_sandbox="$WORK_DIR/claude-context7-env-binding-preserve"
  local rc=0
  mkdir -p "$sandbox/home/.kimi-code" "$claude_sandbox/home"

  cat > "$sandbox/home/.kimi-code/mcp.json" <<'JSON'
{
  "mcpServers": {
    "context7": {
      "url": "https://mcp.context7.com/mcp",
      "bearerTokenEnvVar": "CONTEXT7_API_KEY"
    }
  }
}
JSON

  rc="$(run_install_status "$sandbox" "$snapshot_repo" --runtime=kimi-code-cli)"
  [ "$rc" -eq 0 ] || fail "expected Kimi Context7 env binding upgrade exit 0, got $rc"
  assert_json_value "$sandbox/home/.kimi-code/mcp.json" "'bearerTokenEnvVar' not in data['mcpServers']['context7']"

  cat > "$sandbox/home/.kimi-code/mcp.json" <<'JSON'
{
  "mcpServers": {
    "context7": {
      "url": "https://mcp.context7.com/mcp",
      "headers": {
        "CONTEXT7_API_KEY": "custom"
      },
      "bearerTokenEnvVar": "CONTEXT7_API_KEY"
    }
  }
}
JSON

  rc="$(run_install_status "$sandbox" "$snapshot_repo" --runtime=kimi-code-cli)"
  [ "$rc" -eq 0 ] || fail "expected Kimi Context7 env binding plus headers upgrade exit 0, got $rc"
  assert_json_value "$sandbox/home/.kimi-code/mcp.json" "'bearerTokenEnvVar' not in data['mcpServers']['context7']"
  assert_json_value "$sandbox/home/.kimi-code/mcp.json" "data['mcpServers']['context7']['headers']['CONTEXT7_API_KEY'] == 'custom'"

  cat > "$claude_sandbox/home/.claude.json" <<'JSON'
{
  "mcpServers": {
    "context7": {
      "type": "http",
      "url": "https://mcp.context7.com/mcp",
      "headers": {
        "CONTEXT7_API_KEY": "custom"
      },
      "bearerTokenEnvVar": "CONTEXT7_API_KEY"
    }
  }
}
JSON

  rc="$(run_install_status "$claude_sandbox" "$snapshot_repo" --runtime=claude-code)"
  [ "$rc" -eq 0 ] || fail "expected Claude Context7 env binding preserve exit 0, got $rc"
  assert_json_value "$claude_sandbox/home/.claude.json" "data['mcpServers']['context7']['bearerTokenEnvVar'] == 'CONTEXT7_API_KEY'"
}

run_existing_tool_upgrade_case() {
  local snapshot_repo="$1"
  local sandbox="$WORK_DIR/existing-tool-upgrade"
  local bin_dir="$sandbox/bin"
  local upgrade_log="$sandbox/upgrade.log"
  local install_log="$sandbox/install.log"
  local smoke_path
  local rc=0

  mkdir -p "$sandbox/home" "$bin_dir"

  cat > "$bin_dir/rtk" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$bin_dir/serena" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$bin_dir/codegraph" <<EOF
#!/usr/bin/env bash
printf 'codegraph:%s\n' "\$*" >> "$upgrade_log"
exit 0
EOF
  cat > "$bin_dir/uv" <<EOF
#!/usr/bin/env bash
printf 'uv:%s\n' "\$*" >> "$upgrade_log"
EOF
  cat > "$bin_dir/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' 'printf "rtk-upgrade\n" >> "$upgrade_log"'
EOF
  chmod +x "$bin_dir/rtk" "$bin_dir/serena" "$bin_dir/codegraph" "$bin_dir/uv" "$bin_dir/curl"
  smoke_path="$(smoke_path_with_runtime_clis "$sandbox" "$bin_dir")"

  set +e
  python3 - "$sandbox" "$snapshot_repo" "$smoke_path" "$install_log" "$ROOT_DIR/install.sh" <<'PY'
import os, pty, select, sys

sandbox, repo_snapshot, smoke_path, log_path, install_script = sys.argv[1:6]
env = dict(os.environ)
env["HOME"] = os.path.join(sandbox, "home")
env["PATH"] = smoke_path
env["B_AGENTIC_REPO"] = repo_snapshot
env["B_AGENTIC_DIR"] = os.path.join(sandbox, "source")
env["B_AGENTIC_PROMPT_API_KEYS"] = "N"
env["B_AGENTIC_INSTALL_CODEGRAPH"] = "auto"

pid, fd = pty.fork()
if pid == 0:
    os.environ.update(env)
    os.execv("/bin/bash", ["bash", install_script, "--runtime=claude-code"])

os.write(fd, b"n\nn\n")
status = None
with open(log_path, "wb") as log:
    while True:
        try:
            result, status = os.waitpid(pid, os.WNOHANG)
            if result:
                break
            ready, _, _ = select.select([fd], [], [], 0.1)
            if ready:
                chunk = os.read(fd, 4096)
                if not chunk:
                    _, status = os.waitpid(pid, 0)
                    break
                log.write(chunk)
                log.flush()
        except (OSError, select.error):
            break

os.close(fd)
if status is None:
    _, status = os.waitpid(pid, 0)

if os.WIFEXITED(status):
    sys.exit(os.WEXITSTATUS(status))
if os.WIFSIGNALED(status):
    sys.exit(128 + os.WTERMSIG(status))
sys.exit(1)
PY
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "expected existing tool upgrade install exit 0, got $rc"
  assert_contains "$upgrade_log" 'rtk-upgrade'
  assert_contains "$upgrade_log" 'uv:tool upgrade serena-agent'
  assert_contains "$upgrade_log" 'codegraph:upgrade'
  assert_contains "$install_log" 'RTK already installed; upgrading'
  assert_contains "$install_log" 'Serena already installed; upgrading'
  assert_contains "$install_log" 'CodeGraph already installed; upgrading'
  assert_not_contains "$install_log" 'Install RTK (Rust Token Killer)'
  assert_not_contains "$install_log" 'Install Serena MCP agent'
  assert_not_contains "$install_log" 'Install CodeGraph MCP agent'
}

run_runtime_cli_upgrade_case() {
  local snapshot_repo="$1"
  local sandbox="$WORK_DIR/runtime-cli-upgrade"
  local bin_dir="$sandbox/bin"
  local upgrade_log="$sandbox/upgrade.log"
  local runtime runtime_bin runtime_arg expected_entry install_log rc

  mkdir -p "$bin_dir"

  cat > "$bin_dir/claude" <<EOF
#!/usr/bin/env bash
printf 'claude:%s\n' "\$*" >> "$upgrade_log"
exit 0
EOF
  cat > "$bin_dir/opencode" <<EOF
#!/usr/bin/env bash
printf 'opencode:%s\n' "\$*" >> "$upgrade_log"
exit 0
EOF
  cat > "$bin_dir/codex" <<EOF
#!/usr/bin/env bash
printf 'codex:%s\n' "\$*" >> "$upgrade_log"
exit 0
EOF
  cat > "$bin_dir/kimi" <<EOF
#!/usr/bin/env bash
printf 'kimi:%s\n' "\$*" >> "$upgrade_log"
exit 0
EOF
  chmod +x "$bin_dir/claude" "$bin_dir/opencode" "$bin_dir/codex" "$bin_dir/kimi"

  for runtime in claude-code opencode codex-cli kimi-code-cli; do
    case "$runtime" in
      claude-code)
        runtime_bin="claude"
        runtime_arg="upgrade"
        ;;
      opencode)
        runtime_bin="opencode"
        runtime_arg="upgrade"
        ;;
      codex-cli)
        runtime_bin="codex"
        runtime_arg="update"
        ;;
      kimi-code-cli)
        runtime_bin="kimi"
        runtime_arg="upgrade"
        ;;
      *)
        fail "unexpected runtime in upgrade smoke: $runtime"
        ;;
    esac

    mkdir -p "$sandbox/$runtime/home"
    install_log="$sandbox/$runtime/install.log"
    rc=0

    set +e
    HOME="$sandbox/$runtime/home" \
    PATH="$bin_dir:$PATH" \
    B_AGENTIC_REPO="$snapshot_repo" \
    B_AGENTIC_DIR="$sandbox/$runtime/source" \
    B_AGENTIC_PROMPT_API_KEYS=N \
    B_AGENTIC_INSTALL_RTK=N \
    B_AGENTIC_INSTALL_SERENA=N \
    B_AGENTIC_INSTALL_CODEGRAPH=N \
    bash "$ROOT_DIR/install.sh" --runtime="$runtime" >"$install_log" 2>&1
    rc=$?
    set -e

    [ "$rc" -eq 0 ] || fail "expected $runtime runtime CLI upgrade install exit 0, got $rc"
    expected_entry="$runtime_bin:$runtime_arg"
    assert_contains "$upgrade_log" "$expected_entry"
  done
}

run_missing_runtime_cli_install_case() {
  local snapshot_repo="$1"
  local sandbox="$WORK_DIR/missing-runtime-cli-install"
  local install_log runtime expected_entry rc

  for runtime in claude-code opencode codex-cli kimi-code-cli; do
    case "$runtime" in
      claude-code)
        expected_entry='[dry-run] curl -fsSL https://claude.ai/install.sh | bash'
        ;;
      opencode)
        expected_entry='[dry-run] curl -fsSL https://opencode.ai/install | bash'
        ;;
      codex-cli)
        expected_entry='[dry-run] curl -fsSL https://chatgpt.com/codex/install.sh | sh'
        ;;
      kimi-code-cli)
        expected_entry='[dry-run] curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash'
        ;;
      *)
        fail "unexpected runtime in missing CLI smoke: $runtime"
        ;;
    esac

    mkdir -p "$sandbox/$runtime/home"
    install_log="$sandbox/$runtime/install.log"
    rc=0

    set +e
    HOME="$sandbox/$runtime/home" \
    PATH="$(smoke_system_path)" \
    B_AGENTIC_REPO="$snapshot_repo" \
    B_AGENTIC_DIR="$sandbox/$runtime/source" \
    B_AGENTIC_PROMPT_API_KEYS=N \
    B_AGENTIC_INSTALL_RTK=N \
    B_AGENTIC_INSTALL_SERENA=N \
    B_AGENTIC_INSTALL_CODEGRAPH=N \
    bash "$ROOT_DIR/install.sh" --runtime="$runtime" --dry-run >"$install_log" 2>&1
    rc=$?
    set -e

    [ "$rc" -eq 0 ] || fail "expected $runtime missing CLI install dry-run exit 0, got $rc"
    assert_contains "$install_log" "$expected_entry"
  done
}

run_skill_doctor_case() {
  local snapshot_repo="$1"
  local sandbox_claude="$WORK_DIR/skill-doctor-claude"
  local sandbox_codex="$WORK_DIR/skill-doctor-codex"
  local sandbox_opencode="$WORK_DIR/skill-doctor-opencode"
  local sandbox_kimi="$WORK_DIR/skill-doctor-kimi"
  local doctor_log="$WORK_DIR/skill-doctor.log"
  local expected_skill_count
  mkdir -p "$sandbox_claude/home" "$sandbox_codex/home" "$sandbox_opencode/home" "$sandbox_kimi/home"
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

  expect_install_status 0 "$sandbox_kimi" "$snapshot_repo" --runtime=kimi-code-cli
  python3 "$ROOT_DIR/tooling/validate/skill_doctor.py" --runtime=kimi-code-cli --home "$sandbox_kimi/home" >"$doctor_log"
  assert_contains "$doctor_log" "expected-skills: $expected_skill_count"
  assert_contains "$doctor_log" 'kernel: ready'
  assert_contains "$doctor_log" "skills: ready: $expected_skill_count skills installed"
  assert_contains "$doctor_log" 'discovery: ready:'

}

run_kimi_code_home_case() {
  local snapshot_repo="$1"
  local sandbox="$WORK_DIR/kimi-code-home"
  local doctor_log="$WORK_DIR/kimi-code-home-doctor.log"
  local rc=0

  mkdir -p "$sandbox/home" "$sandbox/kimi-home"

  set +e
  HOME="$sandbox/home" \
  KIMI_CODE_HOME="$sandbox/kimi-home" \
  PATH="$(smoke_path_with_runtime_clis "$sandbox")" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  B_AGENTIC_INSTALL_RTK=N \
  B_AGENTIC_INSTALL_SERENA=N \
  B_AGENTIC_INSTALL_CODEGRAPH=N \
  bash "$ROOT_DIR/install.sh" --runtime=kimi-code-cli >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "expected Kimi KIMI_CODE_HOME install exit 0, got $rc"

  assert_file "$sandbox/kimi-home/AGENTS.md"
  assert_file "$sandbox/kimi-home/skills/b-plan/SKILL.md"
  assert_file "$sandbox/kimi-home/config.toml"
  assert_file "$sandbox/kimi-home/mcp.json"
  assert_no_path "$sandbox/home/.kimi-code/AGENTS.md"

  KIMI_CODE_HOME="$sandbox/kimi-home" \
  python3 "$ROOT_DIR/tooling/validate/mcp_doctor.py" --runtime=kimi-code-cli --home "$sandbox/home" >"$doctor_log"
  assert_contains "$doctor_log" "config: $sandbox/kimi-home/mcp.json"

  KIMI_CODE_HOME="$sandbox/kimi-home" \
  python3 "$ROOT_DIR/tooling/validate/skill_doctor.py" --runtime=kimi-code-cli --home "$sandbox/home" >"$doctor_log"
  assert_contains "$doctor_log" "kernel-path: $sandbox/kimi-home/AGENTS.md"
  assert_contains "$doctor_log" 'kernel: ready'
  assert_contains "$doctor_log" 'skills: ready:'

  rm -rf "$sandbox/source"
  HOME="$sandbox/home" \
  KIMI_CODE_HOME="$sandbox/kimi-home" \
  B_AGENTIC_REPO="$sandbox/missing-source" \
  B_AGENTIC_DIR="$sandbox/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  bash "$ROOT_DIR/install.sh" --runtime=kimi-code-cli --uninstall >"$sandbox/manifest-only-uninstall.log" 2>&1
  assert_contains "$sandbox/manifest-only-uninstall.log" 'Manifest-only uninstall complete for kimi-code-cli'
  assert_no_path "$sandbox/kimi-home/AGENTS.md"
  assert_no_path "$sandbox/kimi-home/config.toml"
  assert_no_path "$sandbox/kimi-home/mcp.json"
  assert_no_path "$sandbox/source"
}

run_kimi_prompted_mcp_key_uninstall_case() {
  local snapshot_repo="$1"
  local sandbox="$WORK_DIR/kimi-prompted-mcp-keys"
  local rc

  mkdir -p "$sandbox/home"

  rc="$(run_install_with_tty_status "$sandbox" "$snapshot_repo" $'context7-test\nbrave-test\nfirecrawl-test\nhttps://firecrawl.example\n' --runtime=kimi-code-cli --prompt-api-keys)"
  [ "$rc" -eq 0 ] || fail "expected Kimi prompted-key install exit 0, got $rc"

  assert_json_value "$sandbox/home/.kimi-code/mcp.json" "data['mcpServers']['context7']['headers']['CONTEXT7_API_KEY'] == 'context7-test'"
  assert_json_value "$sandbox/home/.kimi-code/mcp.json" "data['mcpServers']['brave-search']['env']['BRAVE_API_KEY'] == 'brave-test'"
  assert_json_value "$sandbox/home/.kimi-code/mcp.json" "data['mcpServers']['firecrawl']['env']['FIRECRAWL_API_KEY'] == 'firecrawl-test'"
  assert_json_value "$sandbox/home/.kimi-code/mcp.json" "data['mcpServers']['firecrawl']['env']['FIRECRAWL_API_URL'] == 'https://firecrawl.example'"

  rc="$(run_install_status "$sandbox" "$snapshot_repo" --runtime=kimi-code-cli --uninstall)"
  [ "$rc" -eq 0 ] || fail "expected Kimi prompted-key uninstall exit 0, got $rc"
  assert_no_path "$sandbox/home/.kimi-code/mcp.json"
}

main() {
  local snapshot_repo="$WORK_DIR/repo-snapshot"
  local runtime_name runtime_script
  local -a runtime_names=()

  require_bin git
  require_bin python3
  make_repo_snapshot "$snapshot_repo"
  run_invalid_runtime_layout_validation_case "$snapshot_repo"
  run_all_runtime_smoke_case "$snapshot_repo"
  run_manifest_only_corrupted_manifest_case
  run_manifest_only_custom_paths_case
  run_skill_collision_smoke_case "$snapshot_repo"
  run_opencode_skill_command_collision_smoke_case "$snapshot_repo"
  run_readiness_report_case "$snapshot_repo"
  run_shell_tool_prompt_case "$snapshot_repo"
  run_mcp_doctor_case "$snapshot_repo"
  run_mcp_package_override_case "$snapshot_repo"
  run_kimi_context7_env_binding_upgrade_case "$snapshot_repo"
  run_runtime_cli_upgrade_case "$snapshot_repo"
  run_missing_runtime_cli_install_case "$snapshot_repo"
  run_existing_tool_upgrade_case "$snapshot_repo"
  run_skill_doctor_case "$snapshot_repo"
  run_kimi_code_home_case "$snapshot_repo"
  run_kimi_prompted_mcp_key_uninstall_case "$snapshot_repo"

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
