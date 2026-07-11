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
  bash "$ROOT_DIR/install.sh" --runtime=claude-code --uninstall >"$sandbox_corrupt/uninstall.log" 2>&1
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

run_manifest_only_merged_config_case() {
  local snapshot_repo="$1"
  local sandbox="$WORK_DIR/manifest-only-merged-config"
  local settings_path mcp_path manifest_path

  mkdir -p "$sandbox/home/.claude"
  settings_path="$sandbox/home/.claude/settings.json"
  mcp_path="$sandbox/home/.claude.json"

  cat > "$settings_path" <<EOF
{"permissions":{"allow":["Bash(user-cmd)"],"ask":["Bash(user-ask)"],"deny":["Bash(user-deny)"]}}
EOF
  cat > "$mcp_path" <<EOF
{"mcpServers":{"user-server":{"command":"user-server-cmd"}}}
EOF

  expect_install_status 0 "$sandbox" "$snapshot_repo" --runtime=claude-code

  assert_contains "$settings_path" 'Bash(user-cmd)'
  assert_contains "$settings_path" 'Bash(git push *)'
  assert_contains "$mcp_path" '"user-server"'
  assert_contains "$mcp_path" '"codegraph"'

  manifest_path="$sandbox/home/.claude/b-agentic/install.json"
  assert_file "$manifest_path"

  rm -rf "$sandbox/source"
  HOME="$sandbox/home" \
  B_AGENTIC_REPO="$sandbox/missing-source" \
  B_AGENTIC_DIR="$sandbox/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  bash "$ROOT_DIR/install.sh" --runtime=claude-code --uninstall >"$sandbox/uninstall.log" 2>&1

  assert_contains "$sandbox/uninstall.log" 'Manifest-only uninstall complete for claude-code'
  assert_contains "$settings_path" 'Bash(user-cmd)'
  assert_contains "$settings_path" 'Bash(user-ask)'
  assert_contains "$settings_path" 'Bash(user-deny)'
  assert_not_contains "$settings_path" 'Bash(git push *)'
  assert_not_contains "$settings_path" 'mcp__serena__'
  assert_contains "$mcp_path" '"user-server"'
  assert_not_contains "$mcp_path" '"codegraph"'
  assert_not_contains "$mcp_path" '"serena"'
}

run_post_install_mcp_modification_case() {
  local snapshot_repo="$1"
  local sandbox="$WORK_DIR/post-install-mcp-modification"
  local mcp_path manifest_path

  mkdir -p "$sandbox/home/.claude"
  mcp_path="$sandbox/home/.claude.json"

  cat > "$mcp_path" <<EOF
{"mcpServers":{"user-server":{"command":"user-server-cmd"}}}
EOF

  expect_install_status 0 "$sandbox" "$snapshot_repo" --runtime=claude-code

  assert_contains "$mcp_path" '"user-server"'
  assert_contains "$mcp_path" '"codegraph"'

  python3 - "$mcp_path" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data.setdefault('mcpServers', {})['codegraph']['USER_SETTING'] = 'keep-me'
path.write_text(json.dumps(data, indent=2) + '\n')
PY

  manifest_path="$sandbox/home/.claude/b-agentic/install.json"
  assert_file "$manifest_path"

  rm -rf "$sandbox/source"
  HOME="$sandbox/home" \
  B_AGENTIC_REPO="$sandbox/missing-source" \
  B_AGENTIC_DIR="$sandbox/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  bash "$ROOT_DIR/install.sh" --runtime=claude-code --uninstall >"$sandbox/uninstall.log" 2>&1

  assert_contains "$sandbox/uninstall.log" 'Manifest-only uninstall complete for claude-code'
  assert_contains "$mcp_path" '"user-server"'
  assert_contains "$mcp_path" '"codegraph"'
  assert_not_contains "$mcp_path" '"serena"'
  assert_contains "$mcp_path" '"USER_SETTING"'
  assert_contains "$mcp_path" 'keep-me'
  assert_json_value "$mcp_path" "data['mcpServers']['codegraph'] == {'USER_SETTING': 'keep-me'}"
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
  while IFS= read -r runtime_name; do
    [ -n "$runtime_name" ] || continue
    assert_contains "$sandbox_all/manifest-only-uninstall.log" "Manifest-only uninstall complete for $runtime_name"
  done < <(registered_runtime_names)
  assert_no_path "$sandbox_all/source"

  while IFS=$'\t' read -r runtime_name metadata_root kernel_path; do
    [ -n "$runtime_name" ] || continue
    assert_no_path "$sandbox_all/home/$metadata_root/install.json"
  done < <(registry_runtime_records)
  assert_no_path "$sandbox_all/home/.claude/skills/b-plan"
  assert_no_path "$sandbox_all/home/.claude/CLAUDE.md"
  assert_no_path "$sandbox_all/home/.claude/agents/b-explore.md"
  assert_no_path "$sandbox_all/home/.codex/skills/b-plan"
  assert_no_path "$sandbox_all/home/.codex/AGENTS.md"
  assert_no_path "$sandbox_all/home/.codex/agents/b-explore.toml"
  assert_no_path "$sandbox_all/home/.codex/rules/b-agentic.rules"
  assert_no_path "$sandbox_all/home/.pi/agent/skills/b-plan"
  assert_no_path "$sandbox_all/home/.pi/agent/AGENTS.md"
  assert_no_path "$sandbox_all/home/.pi/agent/extensions/b-agentic-permissions.ts"
  assert_no_path "$sandbox_all/home/.pi/agent/mcp.json"
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

run_ref_install_case() {
  local snapshot_repo="$1"
  local sandbox_ref="$WORK_DIR/ref-install"
  local sandbox_invalid="$WORK_DIR/ref-install-invalid"
  local install_ref manifest_path rc

  mkdir -p "$sandbox_ref/home" "$sandbox_invalid/home"
  install_ref="$(git -C "$snapshot_repo" rev-parse HEAD)"

  expect_install_status 0 "$sandbox_ref" "$snapshot_repo" --runtime=codex --ref="$install_ref"

  manifest_path="$sandbox_ref/home/.codex/b-agentic/install.json"
  assert_file "$manifest_path"
  assert_json_value "$manifest_path" "data['runtime'] == 'codex'"

  rc="$(run_install_status "$sandbox_invalid" "$snapshot_repo" --runtime=codex --ref=--bad)"
  [ "$rc" -ne 0 ] || fail "expected option-looking --ref value to fail safely"
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
  run_install_with_tty_log "$sandbox_codex" "$snapshot_repo" "$sandbox_codex/install.log" --runtime=codex
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
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin_dir/rtk"
  chmod +x "$bin_dir/rtk"

  # The isolated PATH must also resolve the bash interpreter used by the
  # generated RTK shim on macOS, where /usr/bin/env does not search the host
  # PATH after it has been replaced below.
  for tool in basename bash chmod cmp cp date dirname env git grep id mkdir mktemp python3 rm uname; do
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
env["B_AGENTIC_INSTALL_RUNTIME_CLI"] = "N"
env["B_AGENTIC_INSTALL_RTK"] = "N"
env["B_AGENTIC_INSTALL_SERENA"] = "N"
env["B_AGENTIC_INSTALL_CODEGRAPH"] = "N"
env["B_AGENTIC_SHELL_RECOMMEND_MANAGER"] = "manual"

pid, fd = pty.fork()
if pid == 0:
    os.environ.update(env)
    os.execv("/bin/bash", ["bash", install_script, "--runtime=claude-code"])

status = None
input_sent = False
prompt_buffer = b""
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
                prompt_buffer = (prompt_buffer + chunk)[-4096:]
                # Wait for the prompt before replying; immediate writes race
                # with /dev/tty setup on macOS runners. Keep a rolling buffer
                # because PTY reads can split the prompt across chunks.
                if not input_sent and b"Shell tooling missing" in prompt_buffer:
                    os.write(fd, b"n\n")
                    input_sent = True
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

  # The prompt is the behavior under test. Bash EXIT-trap status handling
  # differs between the hosted macOS and Linux shells, so accept either the
  # installer failure or the cleanup-normalized status.
  case "$rc" in
    0|1) ;;
    *) fail "unexpected shell tool prompt smoke install exit $rc" ;;
  esac
  assert_contains "$install_log" "Shell tooling missing (rg, fd/fdfind, bat/batcat, eza/exa, sd, jq). Install now with 'install manually: ripgrep, fd or fd-find, bat (or batcat), eza or exa, sd, jq'? [y/N]:"
  assert_not_contains "$install_log" 'suggestions only; no packages were installed automatically'

  mkdir -p "$apt_bin_dir" "$apt_sandbox/home"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$apt_bin_dir/rtk"
  chmod +x "$apt_bin_dir/rtk"
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
for tool in rg fd batcat eza sd jq; do
  : > "$apt_bin_dir/\$tool"
  chmod +x "$apt_bin_dir/\$tool"
done
exit 0
EOF
  chmod +x "$apt_bin_dir/id" "$apt_bin_dir/sudo" "$apt_bin_dir/apt-get"

  set +e
  HOME="$apt_sandbox/home" \
  PATH="$apt_bin_dir" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$apt_sandbox/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  B_AGENTIC_INSTALL_RUNTIME_CLI=N \
  B_AGENTIC_INSTALL_RTK=N \
  B_AGENTIC_INSTALL_SHELL_TOOLS=Y \
  B_AGENTIC_INSTALL_SERENA=N \
  B_AGENTIC_INSTALL_CODEGRAPH=N \
  B_AGENTIC_SHELL_RECOMMEND_MANAGER=apt-get \
  bash "$ROOT_DIR/install.sh" --runtime=claude-code >"$apt_install_log" 2>&1
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "expected apt-get shell tool install exit 0, got $rc"
  assert_contains "$apt_log" 'sudo:apt-get install -y ripgrep fd-find bat eza sd jq'
  assert_contains "$apt_log" 'apt-get:install -y ripgrep fd-find bat eza sd jq'
  assert_contains "$apt_install_log" 'Shell tooling install command completed'
  assert_contains "$apt_install_log" 'core: ready: rg, fd/fdfind, bat/batcat, eza/exa, sd, and jq available'

  local dnf_sandbox="$WORK_DIR/shell-tool-dnf"
  local dnf_bin_dir="$dnf_sandbox/bin"
  local dnf_log="$dnf_sandbox/dnf.log"
  local dnf_install_log="$dnf_sandbox/install.log"

  mkdir -p "$dnf_bin_dir" "$dnf_sandbox/home"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dnf_bin_dir/rtk"
  chmod +x "$dnf_bin_dir/rtk"
  for tool in basename bash chmod cmp cp date dirname env git grep ln mkdir mktemp python3 rm uname; do
    src="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$src" ] || fail "required smoke helper not found: $tool"
    ln -s "$src" "$dnf_bin_dir/$tool"
  done
  cat > "$dnf_bin_dir/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-u" ]; then
  printf '1000\\n'
  exit 0
fi
exit 1
EOF
  cat > "$dnf_bin_dir/sudo" <<EOF
#!/usr/bin/env bash
printf 'sudo:%s\\n' "\$*" >> "$dnf_log"
"\$@"
EOF
  cat > "$dnf_bin_dir/dnf" <<EOF
#!/usr/bin/env bash
printf 'dnf:%s\\n' "\$*" >> "$dnf_log"
for tool in rg fd bat eza sd jq; do
  : > "$dnf_bin_dir/\$tool"
  chmod +x "$dnf_bin_dir/\$tool"
done
exit 0
EOF
  chmod +x "$dnf_bin_dir/id" "$dnf_bin_dir/sudo" "$dnf_bin_dir/dnf"

  set +e
  python3 - "$dnf_sandbox" "$snapshot_repo" "$dnf_install_log" "$dnf_bin_dir" "$ROOT_DIR/install.sh" <<'PY'
import os, pty, select, sys

sandbox, repo_snapshot, log_path, bin_dir, install_script = sys.argv[1:]
env = dict(os.environ)
env["HOME"] = os.path.join(sandbox, "home")
env["PATH"] = bin_dir
env["B_AGENTIC_REPO"] = repo_snapshot
env["B_AGENTIC_DIR"] = os.path.join(sandbox, "source")
env["B_AGENTIC_PROMPT_API_KEYS"] = "N"
env["B_AGENTIC_INSTALL_RUNTIME_CLI"] = "N"
env["B_AGENTIC_INSTALL_RTK"] = "N"
env["B_AGENTIC_INSTALL_SHELL_TOOLS"] = "auto"
env["B_AGENTIC_INSTALL_SERENA"] = "N"
env["B_AGENTIC_INSTALL_CODEGRAPH"] = "N"
env["B_AGENTIC_SHELL_RECOMMEND_MANAGER"] = "dnf"

pid, fd = pty.fork()
if pid == 0:
    os.environ.update(env)
    os.execv("/bin/bash", ["bash", install_script, "--runtime=claude-code"])

status = None
with open(log_path, "wb") as log:
    sent_yes = False
    while True:
        result, status = os.waitpid(pid, os.WNOHANG)
        if result:
            break
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                break
            if not chunk:
                _, status = os.waitpid(pid, 0)
                break
            log.write(chunk)
            log.flush()
            if not sent_yes and b"Install now with" in chunk:
                os.write(fd, b"y\n")
                sent_yes = True

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

  [ "$rc" -eq 0 ] || fail "expected auto-mode dnf shell tool install exit 0, got $rc"
  assert_contains "$dnf_install_log" "Shell tooling missing (rg, fd/fdfind, bat/batcat, eza/exa, sd, jq). Install now with 'sudo dnf install -y --skip-unavailable ripgrep fd-find bat eza sd jq'? [y/N]:"
  assert_contains "$dnf_log" 'sudo:dnf install -y --skip-unavailable ripgrep fd-find bat eza sd jq'
  assert_contains "$dnf_log" 'dnf:install -y --skip-unavailable ripgrep fd-find bat eza sd jq'
  assert_contains "$dnf_install_log" 'Shell tooling install command completed'
  assert_contains "$dnf_install_log" 'core: ready: rg, fd/fdfind, bat/batcat, eza/exa, sd, and jq available'

  local dnf_root_sandbox="$WORK_DIR/shell-tool-dnf-root"
  local dnf_root_bin_dir="$dnf_root_sandbox/bin"
  local dnf_root_log="$dnf_root_sandbox/dnf.log"
  local dnf_root_install_log="$dnf_root_sandbox/install.log"

  mkdir -p "$dnf_root_bin_dir" "$dnf_root_sandbox/home"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dnf_root_bin_dir/rtk"
  chmod +x "$dnf_root_bin_dir/rtk"
  for tool in basename bash chmod cmp cp date dirname env git grep ln mkdir mktemp python3 rm uname; do
    src="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$src" ] || fail "required smoke helper not found: $tool"
    ln -s "$src" "$dnf_root_bin_dir/$tool"
  done
  cat > "$dnf_root_bin_dir/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-u" ]; then
  printf '0\n'
  exit 0
fi
exit 1
EOF
  cat > "$dnf_root_bin_dir/dnf" <<EOF
#!/usr/bin/env bash
printf 'dnf:%s\\n' "\$*" >> "$dnf_root_log"
for tool in rg fd bat eza sd jq; do
  : > "$dnf_root_bin_dir/\$tool"
  chmod +x "$dnf_root_bin_dir/\$tool"
done
exit 0
EOF
  chmod +x "$dnf_root_bin_dir/id" "$dnf_root_bin_dir/dnf"

  set +e
  HOME="$dnf_root_sandbox/home" \
  PATH="$dnf_root_bin_dir" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$dnf_root_sandbox/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  B_AGENTIC_INSTALL_RUNTIME_CLI=N \
  B_AGENTIC_INSTALL_RTK=N \
  B_AGENTIC_INSTALL_SHELL_TOOLS=Y \
  B_AGENTIC_INSTALL_SERENA=N \
  B_AGENTIC_INSTALL_CODEGRAPH=N \
  B_AGENTIC_SHELL_RECOMMEND_MANAGER=dnf \
  bash "$ROOT_DIR/install.sh" --runtime=claude-code >"$dnf_root_install_log" 2>&1
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "expected root dnf shell tool install exit 0, got $rc"
  assert_contains "$dnf_root_log" 'dnf:install -y --skip-unavailable ripgrep fd-find bat eza sd jq'
  assert_not_contains "$dnf_root_log" 'sudo:'
  assert_contains "$dnf_root_install_log" 'core: ready: rg, fd/fdfind, bat/batcat, eza/exa, sd, and jq available'
}

run_mcp_doctor_case() {
  local snapshot_repo="$1"
  local sandbox_claude="$WORK_DIR/mcp-doctor-claude"
  local sandbox_codex="$WORK_DIR/mcp-doctor-codex"
  local bin_dir="$WORK_DIR/mcp-doctor-bin"
  local doctor_log="$WORK_DIR/mcp-doctor.log"
  local rc=0
  mkdir -p "$sandbox_claude/home" "$sandbox_codex/home" "$bin_dir"

  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin_dir/serena"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin_dir/codegraph"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin_dir/pnpm"
  chmod +x "$bin_dir/serena" "$bin_dir/codegraph" "$bin_dir/pnpm"

  python3 - "$ROOT_DIR" <<'PY'
import sys
import os

sys.path.insert(0, sys.argv[1])
from tooling.validate.mcp_doctor import package_is_exactly_pinned, pinned_package_status

accepted = [
    "firecrawl-mcp@1.2.3",
    "@playwright/mcp@1.2.3",
    "firecrawl-mcp@1.2.3-beta.1",
    "firecrawl-mcp@1.2.3+build.01",
]
rejected = [
    "firecrawl-mcp",
    "firecrawl-mcp@latest",
    "firecrawl-mcp@beta",
    "firecrawl-mcp@1",
    "firecrawl-mcp@1.2",
    "firecrawl-mcp@^1.2.3",
    "firecrawl-mcp@~1.2.3",
    "firecrawl-mcp@1.2.x",
    "firecrawl-mcp@*",
    "firecrawl-mcp@1.2.3-01",
    "..@1.2.3",
    ".hidden@1.2.3",
    "_private@1.2.3",
    "Uppercase@1.2.3",
    "@scope//package@1.2.3",
    "-@1.2.3",
    "~@1.2.3",
    "package~name@1.2.3",
]
for package in accepted:
    if not package_is_exactly_pinned(package):
        raise SystemExit(f"expected exact package pin to pass: {package}")
for package in rejected:
    if package_is_exactly_pinned(package):
        raise SystemExit(f"expected mutable package pin to fail: {package}")

env_name = "B_AGENTIC_FIRECRAWL_MCP_PACKAGE"
os.environ[env_name] = "firecrawl-mcp@2.0.0"
status = pinned_package_status("firecrawl", "firecrawl-mcp@1.0.0")
expected_status = (
    "configured package 'firecrawl-mcp@1.0.0' does not match "
    "B_AGENTIC_FIRECRAWL_MCP_PACKAGE='firecrawl-mcp@2.0.0'; rerun the installer"
)
if status != expected_status:
    raise SystemExit(f"expected mismatched package override to block, got: {status!r}")
PY

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

  expect_install_status 0 "$sandbox_codex" "$snapshot_repo" --runtime=codex
  PATH="$bin_dir:$PATH" \
  BRAVE_API_KEY=test-brave \
  FIRECRAWL_API_KEY=test-firecrawl \
  python3 "$ROOT_DIR/tooling/validate/mcp_doctor.py" --runtime=codex --home "$sandbox_codex/home" --allow-degraded >"$doctor_log"
  assert_contains "$doctor_log" 'context7: blocked: missing CONTEXT7_API_KEY; env binding configured in Codex config'
  PATH="$bin_dir:$PATH" \
  CONTEXT7_API_KEY=test-context7 \
  BRAVE_API_KEY=test-brave \
  FIRECRAWL_API_KEY=test-firecrawl \
  python3 "$ROOT_DIR/tooling/validate/mcp_doctor.py" --runtime=codex --home "$sandbox_codex/home" >"$doctor_log"
  assert_contains "$doctor_log" 'serena: ready:'
  assert_contains "$doctor_log" 'codegraph: ready:'
  assert_contains "$doctor_log" 'context7: ready:'
  assert_contains "$doctor_log" 'brave-search: ready:'
  assert_contains "$doctor_log" 'firecrawl: ready:'
  assert_contains "$doctor_log" 'playwright: ready:'

  set +e
  PATH="$bin_dir:$PATH" \
  CONTEXT7_API_KEY=test-context7 \
  BRAVE_API_KEY=test-brave \
  FIRECRAWL_API_KEY=test-firecrawl \
  python3 "$ROOT_DIR/tooling/validate/mcp_doctor.py" --runtime=codex --home "$sandbox_codex/home" --production >"$doctor_log"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "expected Codex production MCP doctor to pass with pinned defaults, got $rc"


}

run_mcp_package_override_case() {
  local snapshot_repo="$1"
  local sandbox_claude="$WORK_DIR/mcp-package-claude"
  local sandbox_claude_upgrade="$WORK_DIR/mcp-package-claude-upgrade"
  local sandbox_codex="$WORK_DIR/mcp-package-codex"
  local bin_dir="$WORK_DIR/mcp-package-bin"
  local doctor_log="$WORK_DIR/mcp-package-doctor.log"
  local rc=0
  mkdir -p "$sandbox_claude/home" "$sandbox_claude_upgrade/home" "$sandbox_codex/home" "$bin_dir"

  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin_dir/serena"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin_dir/codegraph"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin_dir/pnpm"
  chmod +x "$bin_dir/serena" "$bin_dir/codegraph" "$bin_dir/pnpm"

  set +e
  HOME="$sandbox_claude/home" \
  PATH="$(smoke_path_with_runtime_clis "$sandbox_claude")" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox_claude/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  B_AGENTIC_INSTALL_RUNTIME_CLI=N \
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
  B_AGENTIC_INSTALL_RUNTIME_CLI=N \
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
  B_AGENTIC_INSTALL_RUNTIME_CLI=N \
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
  HOME="$sandbox_codex/home" \
  PATH="$(smoke_path_with_runtime_clis "$sandbox_codex")" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox_codex/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  B_AGENTIC_INSTALL_RUNTIME_CLI=N \
  B_AGENTIC_INSTALL_RTK=N \
  B_AGENTIC_INSTALL_SERENA=N \
  B_AGENTIC_INSTALL_CODEGRAPH=N \
  B_AGENTIC_BRAVE_MCP_PACKAGE='@example/brave-mcp@1.0.0' \
  B_AGENTIC_FIRECRAWL_MCP_PACKAGE='example-firecrawl-mcp@2.0.0' \
  B_AGENTIC_PLAYWRIGHT_MCP_PACKAGE='@example/playwright-mcp@3.0.0' \
  bash "$ROOT_DIR/install.sh" --runtime=codex >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "expected Codex package override install exit 0, got $rc"
  assert_toml_value "$sandbox_codex/home/.codex/config.toml" "data['mcp_servers']['brave-search']['args'][1] == '@example/brave-mcp@1.0.0'"
  assert_toml_value "$sandbox_codex/home/.codex/config.toml" "data['mcp_servers']['firecrawl']['args'][1] == 'example-firecrawl-mcp@2.0.0'"
  assert_toml_value "$sandbox_codex/home/.codex/config.toml" "data['mcp_servers']['playwright']['args'][1] == '@example/playwright-mcp@3.0.0'"

}

run_claude_context7_env_binding_preserve_case() {
  local snapshot_repo="$1"
  local claude_sandbox="$WORK_DIR/claude-context7-env-binding-preserve"
  local rc=0
  mkdir -p "$claude_sandbox/home"

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
env["B_AGENTIC_INSTALL_RUNTIME_CLI"] = "N"
env["B_AGENTIC_INSTALL_RTK"] = "Y"
env["B_AGENTIC_INSTALL_SERENA"] = "Y"
env["B_AGENTIC_INSTALL_CODEGRAPH"] = "Y"

pid, fd = pty.fork()
if pid == 0:
    os.environ.update(env)
    os.execv("/bin/bash", ["bash", install_script, "--runtime=claude-code"])

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

run_existing_tool_default_skip_case() {
  local snapshot_repo="$1"
  local sandbox="$WORK_DIR/existing-tool-default-skip"
  local bin_dir="$sandbox/bin"
  local upgrade_log="$sandbox/upgrade.log"
  local install_log="$sandbox/install.log"
  local rc=0

  mkdir -p "$sandbox/home" "$bin_dir"

  for tool in rtk serena codegraph uv; do
    cat > "$bin_dir/$tool" <<EOF
#!/usr/bin/env bash
printf '%s:%s\n' '$tool' "\$*" >> "$upgrade_log"
exit 0
EOF
    chmod +x "$bin_dir/$tool"
  done

  set +e
  python3 - "$sandbox" "$snapshot_repo" "$install_log" "$(smoke_path_with_runtime_clis "$sandbox" "$bin_dir")" "$ROOT_DIR/install.sh" <<'PY'
import os, subprocess, sys
sandbox, repo_snapshot, log_path, smoke_path, install_script = sys.argv[1:6]
env = dict(os.environ)
env["HOME"] = os.path.join(sandbox, "home")
env["PATH"] = smoke_path
env["B_AGENTIC_REPO"] = repo_snapshot
env["B_AGENTIC_DIR"] = os.path.join(sandbox, "source")
env["B_AGENTIC_PROMPT_API_KEYS"] = "N"
env["B_AGENTIC_INSTALL_RUNTIME_CLI"] = "N"
env["B_AGENTIC_INSTALL_SHELL_TOOLS"] = "N"

pid = os.fork()
if pid == 0:
    os.setsid()
    with open(log_path, "wb") as log:
        res = subprocess.run(["bash", install_script, "--runtime=claude-code"], env=env, stdout=log, stderr=log)
        sys.exit(res.returncode)
else:
    _, status = os.waitpid(pid, 0)
    sys.exit(os.WEXITSTATUS(status))
PY
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "expected existing tools default-skip install exit 0, got $rc"
  assert_no_path "$upgrade_log"
  assert_contains "$install_log" 'RTK already installed; skipping upgrade without explicit approval'
  assert_contains "$install_log" 'Serena already installed; skipping upgrade without explicit approval'
  assert_contains "$install_log" 'CodeGraph already installed; skipping upgrade without explicit approval'
}

run_runtime_cli_upgrade_case() {
  local snapshot_repo="$1"
  local sandbox="$WORK_DIR/runtime-cli-upgrade"
  local bin_dir="$sandbox/bin"
  local upgrade_log="$sandbox/upgrade.log"
  local runtime runtime_bin runtime_arg expected_entry install_log rc

  mkdir -p "$bin_dir"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin_dir/rtk"
  chmod +x "$bin_dir/rtk"

  cat > "$bin_dir/claude" <<EOF
#!/usr/bin/env bash
printf 'claude:%s\n' "\$*" >> "$upgrade_log"
exit 0
EOF
  cat > "$bin_dir/codex" <<EOF
#!/usr/bin/env bash
printf 'codex:%s\n' "\$*" >> "$upgrade_log"
exit 0
EOF
  cat > "$bin_dir/pi" <<EOF
#!/usr/bin/env bash
printf 'pi:%s\n' "\$*" >> "$upgrade_log"
exit 0
EOF
  chmod +x "$bin_dir/claude" "$bin_dir/codex" "$bin_dir/pi"

  for runtime in claude-code codex pi; do
    case "$runtime" in
      claude-code)
        runtime_bin="claude"
        runtime_arg="upgrade"
        ;;
      codex)
        runtime_bin="codex"
        runtime_arg="update"
        ;;
      pi)
        runtime_bin="pi"
        runtime_arg="update"
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
    B_AGENTIC_INSTALL_RUNTIME_CLI=Y \
    B_AGENTIC_INSTALL_RTK=N \
    B_AGENTIC_INSTALL_SERENA=N \
    B_AGENTIC_INSTALL_CODEGRAPH=N \
    bash "$ROOT_DIR/install.sh" --runtime="$runtime" >"$install_log" 2>&1
    rc=$?
    set -e

    if [ "$rc" -ne 0 ]; then
      printf '%s\n' "--- $runtime runtime CLI upgrade installer log ---" >&2
      while IFS= read -r line || [ -n "$line" ]; do
        printf '%s\n' "$line" >&2
      done < "$install_log"
      fail "expected $runtime runtime CLI upgrade install exit 0, got $rc"
    fi
    expected_entry="$runtime_bin:$runtime_arg"
    assert_contains "$upgrade_log" "$expected_entry"
  done
}

run_missing_runtime_cli_install_case() {
  local snapshot_repo="$1"
  local sandbox="$WORK_DIR/missing-runtime-cli-install"
  local install_log runtime expected_entry rc

  for runtime in claude-code codex pi; do
    case "$runtime" in
      claude-code)
        expected_entry='[dry-run] curl -fsSL https://claude.ai/install.sh | bash'
        ;;
      codex)
        expected_entry='[dry-run] curl -fsSL https://chatgpt.com/codex/install.sh | sh'
        ;;
      pi)
        expected_entry='[dry-run] curl -fsSL https://pi.dev/install.sh | sh'
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
    B_AGENTIC_INSTALL_RUNTIME_CLI=Y \
    B_AGENTIC_INSTALL_RTK=Y \
    B_AGENTIC_INSTALL_SERENA=N \
    B_AGENTIC_INSTALL_CODEGRAPH=N \
    bash "$ROOT_DIR/install.sh" --runtime="$runtime" --dry-run >"$install_log" 2>&1
    rc=$?
    set -e

    [ "$rc" -eq 0 ] || fail "expected $runtime missing CLI install dry-run exit 0, got $rc"
    assert_contains "$install_log" "$expected_entry"
  done
}

run_runtime_cli_default_skip_case() {
  local snapshot_repo="$1"
  local sandbox="$WORK_DIR/runtime-cli-default-skip"
  local bin_dir="$sandbox/bin"
  local upgrade_log="$sandbox/upgrade.log"
  local install_log="$sandbox/install.log"
  local rc=0

  mkdir -p "$sandbox/home" "$bin_dir"
  for required_tool in rtk rg fd bat eza sd jq; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin_dir/$required_tool"
    chmod +x "$bin_dir/$required_tool"
  done
  cat > "$bin_dir/claude" <<EOF
#!/usr/bin/env bash
printf 'claude:%s\n' "\$*" >> "$upgrade_log"
exit 0
EOF
  chmod +x "$bin_dir/claude"

  set +e
  python3 - "$sandbox" "$snapshot_repo" "$install_log" "$bin_dir:$(smoke_system_path)" "$ROOT_DIR/install.sh" <<'PY'
import os, subprocess, sys
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

pid = os.fork()
if pid == 0:
    os.setsid()
    with open(log_path, "wb") as log:
        res = subprocess.run(["bash", install_script, "--runtime=claude-code"], env=env, stdout=log, stderr=log)
        sys.exit(res.returncode)
else:
    _, status = os.waitpid(pid, 0)
    sys.exit(os.WEXITSTATUS(status))
PY
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "expected runtime CLI default skip install exit 0, got $rc"
  assert_contains "$install_log" 'Skipping runtime CLI preparation; rerun interactively to accept the prompt, or set B_AGENTIC_INSTALL_RUNTIME_CLI=Y to install or upgrade it.'
  assert_no_path "$upgrade_log"
}

run_runtime_cli_prompt_case() {
  local snapshot_repo="$1"
  local sandbox="$WORK_DIR/runtime-cli-prompt"
  local bin_dir="$sandbox/bin"
  local install_log="$sandbox/install.log"
  local rc=0

  mkdir -p "$sandbox/home" "$bin_dir"
  for required_tool in rtk rg fd bat eza sd jq; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin_dir/$required_tool"
    chmod +x "$bin_dir/$required_tool"
  done

  set +e
  python3 - "$sandbox" "$snapshot_repo" "$install_log" "$bin_dir:$(smoke_system_path)" "$ROOT_DIR/install.sh" <<'PY'
import os, pty, select, sys

sandbox, repo_snapshot, log_path, smoke_path, install_script = sys.argv[1:6]
env = dict(os.environ)
env["HOME"] = os.path.join(sandbox, "home")
env["PATH"] = smoke_path
env["B_AGENTIC_REPO"] = repo_snapshot
env["B_AGENTIC_DIR"] = os.path.join(sandbox, "source")
env["B_AGENTIC_PROMPT_API_KEYS"] = "N"
env["B_AGENTIC_INSTALL_RTK"] = "N"
env["B_AGENTIC_INSTALL_SHELL_TOOLS"] = "N"
env["B_AGENTIC_INSTALL_SERENA"] = "N"
env["B_AGENTIC_INSTALL_CODEGRAPH"] = "N"

pid, fd = pty.fork()
if pid == 0:
    os.environ.update(env)
    os.execv("/bin/bash", ["bash", install_script, "--runtime=claude-code", "--dry-run"])

os.write(fd, b"y\n")
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

  [ "$rc" -eq 0 ] || fail "expected runtime CLI prompt install exit 0, got $rc"
  assert_contains "$install_log" 'Install the claude-code CLI now? [y/N]:'
  assert_contains "$install_log" '[dry-run] curl -fsSL https://claude.ai/install.sh | bash'
}

run_runtime_cli_auto_upgrade_case() {
  local snapshot_repo="$1"
  local sandbox="$WORK_DIR/runtime-cli-auto-upgrade"
  local bin_dir="$sandbox/bin"
  local install_log="$sandbox/install.log"
  local upgrade_log="$sandbox/upgrade.log"
  local smoke_path
  local rc=0

  mkdir -p "$sandbox/home" "$bin_dir"

  cat > "$bin_dir/claude" <<EOF
#!/usr/bin/env bash
printf 'claude:%s\n' "\$*" >> "$upgrade_log"
exit 0
EOF
  chmod +x "$bin_dir/claude"
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
env["B_AGENTIC_INSTALL_RTK"] = "N"
env["B_AGENTIC_INSTALL_SHELL_TOOLS"] = "N"
env["B_AGENTIC_INSTALL_SERENA"] = "N"
env["B_AGENTIC_INSTALL_CODEGRAPH"] = "N"

pid, fd = pty.fork()
if pid == 0:
    os.environ.update(env)
    os.execv("/bin/bash", ["bash", install_script, "--runtime=claude-code"])

os.write(fd, b"y\n")
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

  [ "$rc" -eq 0 ] || fail "expected runtime CLI auto-upgrade install exit 0, got $rc"
  assert_contains "$install_log" 'Upgrade the installed claude-code CLI now? [y/N]:'
  assert_contains "$install_log" 'Claude Code CLI already installed; upgrading'
  assert_contains "$upgrade_log" 'claude:upgrade'
}

run_skill_doctor_case() {
  local snapshot_repo="$1"
  local sandbox_claude="$WORK_DIR/skill-doctor-claude"
  local sandbox_codex="$WORK_DIR/skill-doctor-codex"
  local doctor_log="$WORK_DIR/skill-doctor.log"
  local expected_skill_count
  local rc=0
  mkdir -p "$sandbox_claude/home" "$sandbox_codex/home"
  expected_skill_count="$(registry_skill_count)"

  expect_install_status 0 "$sandbox_claude" "$snapshot_repo" --runtime=claude-code
  python3 "$ROOT_DIR/tooling/validate/skill_doctor.py" --runtime=claude-code --home "$sandbox_claude/home" >"$doctor_log"
  assert_contains "$doctor_log" "expected-skills: $expected_skill_count"
  assert_contains "$doctor_log" 'kernel: ready'
  assert_contains "$doctor_log" "skills: ready: $expected_skill_count skills installed"
  assert_contains "$doctor_log" 'discovery: ready:'
  rm -rf "$sandbox_claude/home/.claude/skills/b-review"
  set +e
  python3 "$ROOT_DIR/tooling/validate/skill_doctor.py" --runtime=claude-code --home "$sandbox_claude/home" >"$doctor_log"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "expected skill doctor to fail for missing skill, got $rc"
  assert_contains "$doctor_log" 'skills: missing or mismatched: missing b-review'
  assert_contains "$doctor_log" 'discovery: blocked: install complete skill payload'

  expect_install_status 0 "$sandbox_codex" "$snapshot_repo" --runtime=codex
  python3 "$ROOT_DIR/tooling/validate/skill_doctor.py" --runtime=codex --home "$sandbox_codex/home" >"$doctor_log"
  assert_contains "$doctor_log" "expected-skills: $expected_skill_count"
  assert_contains "$doctor_log" 'kernel: ready'
  assert_contains "$doctor_log" "skills: ready: $expected_skill_count skills installed"
  assert_contains "$doctor_log" 'config: ready'
  assert_contains "$doctor_log" 'discovery: ready:'


}


run_simulated_runtime_acceptance_case() {
  local snapshot_repo="$1"
  local sandbox_claude="$WORK_DIR/runtime-acceptance-simulated-claude"
  local sandbox_codex="$WORK_DIR/runtime-acceptance-simulated-codex"
  local sandbox_pi="$WORK_DIR/runtime-acceptance-simulated-pi"
  local bin_dir="$WORK_DIR/runtime-acceptance-simulated-bin"
  local acceptance_log="$WORK_DIR/runtime-acceptance-simulated.log"

  mkdir -p \
    "$sandbox_claude/home" \
    "$sandbox_codex/home" \
    "$sandbox_pi/home" \
    "$bin_dir"

  cat > "$bin_dir/serena" <<'EOF'
#!/usr/bin/env bash
python3 - <<'PY'
import json
import os
import sys

log_path = os.environ.get("B_AGENTIC_ACCEPTANCE_MCP_LOG")

def read_message():
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        if line in (b"\r\n", b"\n"):
            break
        key, value = line.decode("utf-8").split(":", 1)
        headers[key.lower()] = value.strip()
    length = int(headers.get("content-length", "0"))
    if length <= 0:
        return None
    return json.loads(sys.stdin.buffer.read(length).decode("utf-8"))

def send(message):
    payload = json.dumps(message).encode("utf-8")
    sys.stdout.buffer.write(f"Content-Length: {len(payload)}\r\n\r\n".encode("utf-8"))
    sys.stdout.buffer.write(payload)
    sys.stdout.buffer.flush()

while True:
    message = read_message()
    if message is None:
        break
    method = message.get("method")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": message.get("id"), "result": {"protocolVersion": "2024-11-05", "serverInfo": {"name": "smoke-serena", "version": "0.1.0"}, "capabilities": {"tools": {}}}})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": message.get("id"), "result": {"tools": [{"name": "acceptance_probe", "description": "smoke sentinel", "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}}]}})
    elif method == "tools/call":
        if log_path:
            with open(log_path, "a", encoding="utf-8") as handle:
                handle.write("ACCEPTANCE_MCP_TOOL_CALLED\n")
        send({"jsonrpc": "2.0", "id": message.get("id"), "result": {"content": [{"type": "text", "text": "ACCEPTANCE_MCP_OK"}]}})
    elif method == "ping":
        send({"jsonrpc": "2.0", "id": message.get("id"), "result": {}})
    elif "id" in message:
        send({"jsonrpc": "2.0", "id": message.get("id"), "result": {}})
PY
EOF
  printf '#!/usr/bin/env bash
exit 0
' > "$bin_dir/codegraph"
  printf '#!/usr/bin/env bash
exit 0
' > "$bin_dir/pnpm"

  cat > "$bin_dir/claude" <<'EOF'
#!/usr/bin/env bash
prompt="${@: -1}"
case "$prompt" in
  *"Detailed contract refs live under"*) printf '%s\n' '~/.claude/b-agentic/references/contract/' ;;
  *"Write a commit message, PR title, and PR description for the staged changes."*) printf '%s\n' 'BLOCKED: no changes to summarize' ;;
  *"acceptance_probe"*) [ -n "$B_AGENTIC_ACCEPTANCE_MCP_LOG" ] && printf 'ACCEPTANCE_MCP_TOOL_CALLED\n' >> "$B_AGENTIC_ACCEPTANCE_MCP_LOG" ; printf '%s\n' 'ACCEPTANCE_MCP_OK' ;;
  *"git commit -m test"*) printf '%s\n' 'approval required' ;;
  *"git reset --hard"*) printf '%s\n' 'denied' ;;
  *) printf '%s\n' 'unexpected claude prompt' ;;
esac
EOF

  cat > "$bin_dir/codex" <<'EOF'
#!/usr/bin/env bash
output=""
last=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      continue
      ;;
  esac
  last="$1"
  shift
done
case "$last" in
  *"Detailed contract refs live under"*) result='~/.codex/b-agentic/references/contract/' ;;
  *"Write a commit message, PR title, and PR description for the staged changes."*) result='BLOCKED: no changes to summarize' ;;
  *"acceptance_probe"*) [ -n "$B_AGENTIC_ACCEPTANCE_MCP_LOG" ] && printf 'ACCEPTANCE_MCP_TOOL_CALLED\n' >> "$B_AGENTIC_ACCEPTANCE_MCP_LOG" ; result='ACCEPTANCE_MCP_OK' ;;
  *"git commit -m test"*) result='approval required' ;;
  *"git reset --hard"*) result='denied' ;;
  *) result='unexpected codex prompt' ;;
esac
if [ -n "$output" ]; then
  printf '%s\n' "$result" > "$output"
else
  printf '%s\n' "$result"
fi
EOF

  cat > "$bin_dir/pi" <<'EOF'
#!/usr/bin/env bash
prompt="${@: -1}"
case "$prompt" in
  *"Detailed contract refs live under"*) printf '%s\n' '~/.pi/agent/b-agentic/references/contract/' ;;
  *"Write a commit message, PR title, and PR description for the staged changes."*) printf '%s\n' 'BLOCKED: no changes to summarize' ;;
  *"acceptance_probe"*) [ -n "$B_AGENTIC_ACCEPTANCE_MCP_LOG" ] && printf 'ACCEPTANCE_MCP_TOOL_CALLED\n' >> "$B_AGENTIC_ACCEPTANCE_MCP_LOG" ; printf '%s\n' 'ACCEPTANCE_MCP_OK' ;;
  *"git commit -m test"*) printf '%s\n' 'approval required (no UI; fail-closed)' ;;
  *"git reset --hard"*) printf '%s\n' 'denied by b-agentic policy' ;;
  *) printf '%s\n' 'unexpected pi prompt' ;;
esac
EOF

  chmod +x \
    "$bin_dir/serena" \
    "$bin_dir/codegraph" \
    "$bin_dir/pnpm" \
    "$bin_dir/claude" \
    "$bin_dir/codex" \
    "$bin_dir/pi"

  expect_install_status 0 "$sandbox_claude" "$snapshot_repo" --runtime=claude-code
  PATH="$bin_dir:$(smoke_system_path)" \
  CONTEXT7_API_KEY=test-context7 \
  BRAVE_API_KEY=test-brave \
  FIRECRAWL_API_KEY=test-firecrawl \
  bash "$ROOT_DIR/scripts/runtime-acceptance.sh" --runtime=claude-code --home="$sandbox_claude/home" --active >"$acceptance_log" 2>&1
  assert_contains "$acceptance_log" 'Simulated protocol probes (not live runtime proof):'
  assert_contains "$acceptance_log" 'evidence-class: simulated'
  assert_contains "$acceptance_log" 'kernel: ready: ~/.claude/b-agentic/references/contract/'
  assert_contains "$acceptance_log" 'skill: ready: BLOCKED: no changes to summarize'
  assert_contains "$acceptance_log" 'mcp: ready: ACCEPTANCE_MCP_OK'
  assert_contains "$acceptance_log" 'approval-gate: ready:'
  assert_contains "$acceptance_log" 'deny-gate: ready:'
  assert_contains "$acceptance_log" 'Evidence classes:'
  assert_contains "$acceptance_log" 'simulated: --active protocol/adapter probes'

  expect_install_status 0 "$sandbox_codex" "$snapshot_repo" --runtime=codex
  PATH="$bin_dir:$(smoke_system_path)" \
  CONTEXT7_API_KEY=test-context7 \
  BRAVE_API_KEY=test-brave \
  FIRECRAWL_API_KEY=test-firecrawl \
  bash "$ROOT_DIR/scripts/runtime-acceptance.sh" --runtime=codex --home="$sandbox_codex/home" --active >"$acceptance_log" 2>&1
  assert_contains "$acceptance_log" 'Simulated protocol probes (not live runtime proof):'
  assert_contains "$acceptance_log" 'kernel: ready: ~/.codex/b-agentic/references/contract/'
  assert_contains "$acceptance_log" 'mcp: ready: ACCEPTANCE_MCP_OK'

  expect_install_status 0 "$sandbox_pi" "$snapshot_repo" --runtime=pi
  PATH="$bin_dir:$(smoke_system_path)" \
  CONTEXT7_API_KEY=test-context7 \
  BRAVE_API_KEY=test-brave \
  FIRECRAWL_API_KEY=test-firecrawl \
  bash "$ROOT_DIR/scripts/runtime-acceptance.sh" --runtime=pi --home="$sandbox_pi/home" --active >"$acceptance_log" 2>&1
  assert_contains "$acceptance_log" 'Simulated protocol probes (not live runtime proof):'
  assert_contains "$acceptance_log" 'evidence-class: simulated'
  assert_contains "$acceptance_log" 'kernel: ready: ~/.pi/agent/b-agentic/references/contract/'
  assert_contains "$acceptance_log" 'mcp: ready: ACCEPTANCE_MCP_OK'
  assert_contains "$acceptance_log" 'approval-gate: ready:'
  assert_contains "$acceptance_log" 'deny-gate: ready:'
}

run_rtk_ref_dry_run_case() {
  local snapshot_repo="$1"
  local sandbox="$WORK_DIR/rtk-ref-dry-run"
  local bin_dir="$sandbox/bin"
  local install_log="$sandbox/install.log"
  local rc required_tool

  mkdir -p "$sandbox/home" "$bin_dir"
  # Keep this ref-format check independent of the host's shell-tool inventory.
  for required_tool in rg fd bat eza sd jq; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin_dir/$required_tool"
    chmod +x "$bin_dir/$required_tool"
  done

  # Case A: Default B_AGENTIC_RTK_REF
  rc=0
  set +e
  HOME="$sandbox/home" \
  PATH="$bin_dir:$(smoke_system_path)" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox/source-a" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  B_AGENTIC_INSTALL_RUNTIME_CLI=N \
  B_AGENTIC_INSTALL_RTK=Y \
  B_AGENTIC_INSTALL_SERENA=N \
  B_AGENTIC_INSTALL_CODEGRAPH=N \
  bash "$ROOT_DIR/install.sh" --runtime=codex --dry-run >"$install_log" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "expected dry-run with default RTK ref exit 0, got $rc"
  assert_contains "$install_log" '[dry-run] curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/v0.43.0/install.sh | RTK_VERSION=v0.43.0 sh'

  # Case B: Overridden B_AGENTIC_RTK_REF
  rc=0
  set +e
  HOME="$sandbox/home" \
  PATH="$bin_dir:$(smoke_system_path)" \
  B_AGENTIC_REPO="$snapshot_repo" \
  B_AGENTIC_DIR="$sandbox/source-b" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  B_AGENTIC_INSTALL_RUNTIME_CLI=N \
  B_AGENTIC_INSTALL_RTK=Y \
  B_AGENTIC_INSTALL_SERENA=N \
  B_AGENTIC_INSTALL_CODEGRAPH=N \
  B_AGENTIC_RTK_REF=test-ref-foo \
  bash "$ROOT_DIR/install.sh" --runtime=codex --dry-run >"$install_log" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "expected dry-run with custom RTK ref exit 0, got $rc"
  assert_contains "$install_log" '[dry-run] curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/test-ref-foo/install.sh | RTK_VERSION=test-ref-foo sh'
}

main() {
  local snapshot_repo="$WORK_DIR/repo-snapshot"
  local runtime_name runtime_script
  local -a runtime_names=()

  require_bin git
  require_bin python3
  make_repo_snapshot "$snapshot_repo"
  echo "Running run_rtk_ref_dry_run_case..."
  run_rtk_ref_dry_run_case "$snapshot_repo"
  echo "Running run_invalid_runtime_layout_validation_case..."
  run_invalid_runtime_layout_validation_case "$snapshot_repo"
  echo "Running run_all_runtime_smoke_case..."
  run_all_runtime_smoke_case "$snapshot_repo"
  echo "Running run_ref_install_case..."
  run_ref_install_case "$snapshot_repo"
  echo "Running run_manifest_only_corrupted_manifest_case..."
  run_manifest_only_corrupted_manifest_case
  echo "Running run_manifest_only_custom_paths_case..."
  run_manifest_only_custom_paths_case
  echo "Running run_manifest_only_merged_config_case..."
  run_manifest_only_merged_config_case "$snapshot_repo"
  echo "Running run_post_install_mcp_modification_case..."
  run_post_install_mcp_modification_case "$snapshot_repo"
  echo "Running run_skill_collision_smoke_case..."
  run_skill_collision_smoke_case "$snapshot_repo"
  echo "Running run_readiness_report_case..."
  run_readiness_report_case "$snapshot_repo"
  echo "Running run_shell_tool_prompt_case..."
  run_shell_tool_prompt_case "$snapshot_repo"
  echo "Running run_mcp_doctor_case..."
  run_mcp_doctor_case "$snapshot_repo"
  echo "Running run_mcp_package_override_case..."
  run_mcp_package_override_case "$snapshot_repo"
  echo "Running run_claude_context7_env_binding_preserve_case..."
  run_claude_context7_env_binding_preserve_case "$snapshot_repo"
  echo "Running run_runtime_cli_default_skip_case..."
  run_runtime_cli_default_skip_case "$snapshot_repo"
  echo "Running run_runtime_cli_prompt_case..."
  run_runtime_cli_prompt_case "$snapshot_repo"
  echo "Running run_runtime_cli_auto_upgrade_case..."
  run_runtime_cli_auto_upgrade_case "$snapshot_repo"
  echo "Running run_runtime_cli_upgrade_case..."
  run_runtime_cli_upgrade_case "$snapshot_repo"
  echo "Running run_missing_runtime_cli_install_case..."
  run_missing_runtime_cli_install_case "$snapshot_repo"
  echo "Running run_existing_tool_upgrade_case..."
  run_existing_tool_upgrade_case "$snapshot_repo"
  echo "Running run_existing_tool_default_skip_case..."
  run_existing_tool_default_skip_case "$snapshot_repo"
  echo "Running run_skill_doctor_case..."
  run_skill_doctor_case "$snapshot_repo"
  echo "Running run_simulated_runtime_acceptance_case..."
  run_simulated_runtime_acceptance_case "$snapshot_repo"

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
    echo "Running smoke cases for $runtime_name..."
    run_runtime_smoke_cases "$snapshot_repo"
  done

  printf 'smoke-install.sh passed\n'
}

main "$@"
