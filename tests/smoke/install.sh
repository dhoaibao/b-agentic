#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="$(mktemp -d /tmp/b-agentic-smoke.XXXXXX)"

cleanup() {
	rm -rf "$WORK_DIR"
}

trap cleanup EXIT

source "$ROOT_DIR/tests/smoke/lib.sh"

run_manifest_only_corrupted_manifest_case() {
	local sandbox_corrupt="$WORK_DIR/manifest-only-corrupt"

	mkdir -p "$sandbox_corrupt/home/Documents/b-owned" "$sandbox_corrupt/home/.pi/agent/b-agentic"
	printf 'sentinel\n' >"$sandbox_corrupt/home/Documents/b-owned/file.txt"
	cat >"$sandbox_corrupt/home/.pi/agent/b-agentic/install.json" <<EOF
{"runtime":"pi","paths":{"skills":"$sandbox_corrupt/home/Documents","kernel":"$sandbox_corrupt/home/.pi/agent/AGENTS.md"},"skills":["b-owned"],"agents":[]}
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
	assert_contains "$sandbox_corrupt/uninstall.log" "requires $sandbox_corrupt/home/.pi/agent/b-agentic/tooling/install/manifest_uninstall.py"
	assert_file "$sandbox_corrupt/home/Documents/b-owned/file.txt"
	assert_no_path "$sandbox_corrupt/source"
}

run_manifest_only_custom_paths_case() {
	local sandbox_custom="$WORK_DIR/manifest-only-custom-paths"
	local manifest_path skill_dir kernel_path snapshot_path

	mkdir -p "$sandbox_custom/home/custom-meta" "$sandbox_custom/home/custom-skills/b-plan" "$sandbox_custom/home/custom-kernel"
	manifest_path="$sandbox_custom/home/custom-meta/install.json"
	skill_dir="$sandbox_custom/home/custom-skills/b-plan"
	kernel_path="$sandbox_custom/home/custom-kernel/AGENTS.md"
	snapshot_path="$sandbox_custom/home/custom-meta/AGENTS.md"

	printf 'Generated from skills/registry.yaml\n' >"$skill_dir/SKILL.md"
	printf '<!-- b-agentic-managed -->\ncustom kernel\n' >"$kernel_path"
	printf '<!-- b-agentic-managed -->\ncustom kernel\n' >"$snapshot_path"
	cat >"$manifest_path" <<EOF
{"runtime":"pi","paths":{"skills":"$sandbox_custom/home/custom-skills","kernel":"$kernel_path"},"skills":["b-plan"],"agents":[]}
EOF

	HOME="$sandbox_custom/home" python3 "$ROOT_DIR/tooling/install/manifest_uninstall.py" "$manifest_path" >"$sandbox_custom/uninstall.log" 2>&1

	assert_contains "$sandbox_custom/uninstall.log" 'Manifest-only uninstall complete for pi'
	assert_no_path "$skill_dir"
	assert_no_path "$kernel_path"
	assert_no_path "$sandbox_custom/home/custom-meta"
}

run_manifest_only_merged_config_case() {
	local snapshot_repo="$1"
	local sandbox="$WORK_DIR/manifest-only-merged-config"
	local mcp_path manifest_path

	mkdir -p "$sandbox/home/.pi/agent"
	mcp_path="$sandbox/home/.pi/agent/mcp.json"

	cat >"$mcp_path" <<EOF
{"mcpServers":{"user-server":{"command":"user-server-cmd"}}}
EOF

	expect_install_status 0 "$sandbox" "$snapshot_repo"

	assert_contains "$mcp_path" '"user-server"'
	assert_contains "$mcp_path" '"codegraph"'

	manifest_path="$sandbox/home/.pi/agent/b-agentic/install.json"
	assert_file "$manifest_path"

	rm -rf "$sandbox/source"
	HOME="$sandbox/home" \
		B_AGENTIC_REPO="$sandbox/missing-source" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" --uninstall >"$sandbox/uninstall.log" 2>&1

	assert_contains "$sandbox/uninstall.log" 'Manifest-only uninstall complete for pi'
	assert_contains "$mcp_path" '"user-server"'
	assert_not_contains "$mcp_path" '"codegraph"'
	assert_not_contains "$mcp_path" '"serena"'
}

run_manifest_only_extension_restore_case() {
	local snapshot_repo="$1"
	local sandbox="$WORK_DIR/manifest-only-extension-restore"
	local extension_path="$sandbox/home/.pi/agent/extensions/b-agentic-permissions.ts"

	mkdir -p "$(dirname "$extension_path")"
	printf 'user-owned permission extension\n' >"$extension_path"
	expect_install_status 0 "$sandbox" "$snapshot_repo"
	assert_not_contains "$extension_path" 'user-owned permission extension'
	rm "$extension_path"
	expect_install_status 0 "$sandbox" "$snapshot_repo"

	rm -rf "$sandbox/source"
	HOME="$sandbox/home" \
		B_AGENTIC_REPO="$sandbox/missing-source" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" --uninstall >"$sandbox/uninstall.log" 2>&1

	assert_contains "$sandbox/uninstall.log" 'Manifest-only uninstall complete for pi'
	assert_contains "$extension_path" 'user-owned permission extension'
}

run_manifest_only_extension_symlink_case() {
	local snapshot_repo="$1"
	local sandbox="$WORK_DIR/manifest-only-extension-symlink"
	local extension_path="$sandbox/home/.pi/agent/extensions/b-agentic-permissions.ts"
	local target_path="$sandbox/target.ts"

	mkdir -p "$(dirname "$extension_path")"
	printf 'user-owned permission extension\n' >"$extension_path"
	expect_install_status 0 "$sandbox" "$snapshot_repo"
	cp "$extension_path" "$target_path"
	rm "$extension_path"
	ln -s "$target_path" "$extension_path"

	rm -rf "$sandbox/source"
	HOME="$sandbox/home" \
		B_AGENTIC_REPO="$sandbox/missing-source" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" --uninstall >"$sandbox/uninstall.log" 2>&1

	assert_contains "$sandbox/uninstall.log" 'preserving symlinked Pi permission extension'
	[ -L "$extension_path" ] || fail "expected manifest-only uninstall to preserve symlinked extension"
	assert_contains "$target_path" 'tool_call'
	assert_not_contains "$target_path" 'user-owned permission extension'
}

run_post_install_mcp_modification_case() {
	local snapshot_repo="$1"
	local sandbox="$WORK_DIR/post-install-mcp-modification"
	local mcp_path manifest_path

	mkdir -p "$sandbox/home/.pi/agent"
	mcp_path="$sandbox/home/.pi/agent/mcp.json"

	cat >"$mcp_path" <<EOF
{"mcpServers":{"user-server":{"command":"user-server-cmd"}}}
EOF

	expect_install_status 0 "$sandbox" "$snapshot_repo"

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

	manifest_path="$sandbox/home/.pi/agent/b-agentic/install.json"
	assert_file "$manifest_path"

	rm -rf "$sandbox/source"
	HOME="$sandbox/home" \
		B_AGENTIC_REPO="$sandbox/missing-source" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" --uninstall >"$sandbox/uninstall.log" 2>&1

	assert_contains "$sandbox/uninstall.log" 'Manifest-only uninstall complete for pi'
	assert_contains "$mcp_path" '"user-server"'
	assert_contains "$mcp_path" '"codegraph"'
	assert_not_contains "$mcp_path" '"serena"'
	assert_contains "$mcp_path" '"USER_SETTING"'
	assert_contains "$mcp_path" 'keep-me'
	assert_json_value "$mcp_path" "data['mcpServers']['codegraph'] == {'USER_SETTING': 'keep-me'}"
}

run_ref_install_case() {
	local snapshot_repo="$1"
	local sandbox_ref="$WORK_DIR/ref-install"
	local sandbox_invalid="$WORK_DIR/ref-install-invalid"
	local install_ref manifest_path rc

	mkdir -p "$sandbox_ref/home" "$sandbox_invalid/home"
	install_ref="$(git -C "$snapshot_repo" rev-parse HEAD)"

	expect_install_status 0 "$sandbox_ref" "$snapshot_repo" --ref="$install_ref"

	manifest_path="$sandbox_ref/home/.pi/agent/b-agentic/install.json"
	assert_file "$manifest_path"
	assert_json_value "$manifest_path" "data['runtime'] == 'pi'"

	rc="$(run_install_status "$sandbox_invalid" "$snapshot_repo" --ref=--bad)"
	[ "$rc" -ne 0 ] || fail "expected option-looking --ref value to fail safely"
}

run_invalid_skill_payload_case() {
	local snapshot_repo="$1"
	local sandbox_source="$WORK_DIR/missing-skill-payload-source"
	local sandbox_install="$WORK_DIR/missing-skill-payload-install"

	git clone --quiet "$snapshot_repo" "$sandbox_source"
	rm "$sandbox_source/skills/b-plan/SKILL.md"
	git -C "$sandbox_source" add -A
	git -C "$sandbox_source" -c user.name='b-agentic smoke' -c user.email='smoke@example.test' commit -qm 'remove generated Pi skill payload'

	expect_install_status 1 "$sandbox_install" "$sandbox_source"
}

run_skill_collision_smoke_case() {
	local snapshot_repo="$1"
	local sandbox_collision="$WORK_DIR/skill-collision"
	local skill_path="$sandbox_collision/home/.pi/agent/skills/b-plan/SKILL.md"
	local manifest_path="$sandbox_collision/home/.pi/agent/b-agentic/install.json"

	mkdir -p "$(dirname "$skill_path")"
	printf 'user-owned b-plan
' >"$skill_path"
	expect_install_status 0 "$sandbox_collision" "$snapshot_repo"
	assert_file "$manifest_path"
	assert_contains "$skill_path" 'user-owned b-plan'
	assert_json_value "$manifest_path" "'b-plan' not in data['skills']"
}

run_readiness_report_case() {
	local snapshot_repo="$1"
	local sandbox="$WORK_DIR/readiness-pi"
	local rc=0

	mkdir -p "$sandbox/home"

	set +e
	run_install_with_tty_log "$sandbox" "$snapshot_repo" "$sandbox/install.log"
	rc=$?
	set -e
	[ "$rc" -eq 0 ] || fail "expected Pi readiness install exit 0, got $rc"
	assert_contains "$sandbox/install.log" 'Readiness:'
	assert_contains "$sandbox/install.log" 'serena:'
	assert_contains "$sandbox/install.log" 'codegraph:'
	assert_contains "$sandbox/install.log" 'context7:'
	assert_contains "$sandbox/install.log" 'brave-search:'
	assert_contains "$sandbox/install.log" 'firecrawl:'
	assert_contains "$sandbox/install.log" 'playwright:'
	assert_contains "$sandbox/install.log" 'mcp-startup:'
	assert_contains "$sandbox/install.log" 'rtk:'
}

run_optional_shell_tool_case() {
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
	printf '#!/usr/bin/env bash\nexit 0\n' >"$bin_dir/rtk"
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
env["B_AGENTIC_INSTALL_PI_CLI"] = "N"
env["B_AGENTIC_INSTALL_RTK"] = "N"
env["B_AGENTIC_INSTALL_SERENA"] = "N"
env["B_AGENTIC_INSTALL_CODEGRAPH"] = "N"
env["B_AGENTIC_SHELL_RECOMMEND_MANAGER"] = "manual"

pid, fd = pty.fork()
if pid == 0:
    os.environ.update(env)
    os.execv("/bin/bash", ["bash", install_script])

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

	[ "$rc" -eq 0 ] || fail "expected default optional shell tool skip exit 0, got $rc"
	assert_contains "$install_log" 'Optional shell tooling is not installed automatically; set B_AGENTIC_INSTALL_SHELL_TOOLS=Y to install rg, fd/fdfind, bat, eza/exa, sd, jq'
	assert_not_contains "$install_log" 'Shell tooling missing'

	mkdir -p "$apt_bin_dir" "$apt_sandbox/home"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$apt_bin_dir/rtk"
	chmod +x "$apt_bin_dir/rtk"
	for tool in basename bash chmod cmp cp date dirname env git grep ln mkdir mktemp python3 rm uname; do
		src="$(command -v "$tool" 2>/dev/null || true)"
		[ -n "$src" ] || fail "required smoke helper not found: $tool"
		ln -s "$src" "$apt_bin_dir/$tool"
	done
	cat >"$apt_bin_dir/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-u" ]; then
  printf '1000\n'
  exit 0
fi
exit 1
EOF
	cat >"$apt_bin_dir/sudo" <<EOF
#!/usr/bin/env bash
printf 'sudo:%s\n' "\$*" >> "$apt_log"
"\$@"
EOF
	cat >"$apt_bin_dir/apt-get" <<EOF
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
		B_AGENTIC_INSTALL_PI_CLI=N \
		B_AGENTIC_INSTALL_RTK=N \
		B_AGENTIC_INSTALL_SHELL_TOOLS=Y \
		B_AGENTIC_INSTALL_SERENA=N \
		B_AGENTIC_INSTALL_CODEGRAPH=N \
		B_AGENTIC_SHELL_RECOMMEND_MANAGER=apt-get \
		bash "$ROOT_DIR/install.sh" >"$apt_install_log" 2>&1
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
	printf '#!/usr/bin/env bash\nexit 0\n' >"$dnf_bin_dir/rtk"
	chmod +x "$dnf_bin_dir/rtk"
	for tool in basename bash chmod cmp cp date dirname env git grep ln mkdir mktemp python3 rm uname; do
		src="$(command -v "$tool" 2>/dev/null || true)"
		[ -n "$src" ] || fail "required smoke helper not found: $tool"
		ln -s "$src" "$dnf_bin_dir/$tool"
	done
	cat >"$dnf_bin_dir/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-u" ]; then
  printf '1000\\n'
  exit 0
fi
exit 1
EOF
	cat >"$dnf_bin_dir/sudo" <<EOF
#!/usr/bin/env bash
printf 'sudo:%s\\n' "\$*" >> "$dnf_log"
"\$@"
EOF
	cat >"$dnf_bin_dir/dnf" <<EOF
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
env["B_AGENTIC_INSTALL_PI_CLI"] = "N"
env["B_AGENTIC_INSTALL_RTK"] = "N"
env["B_AGENTIC_INSTALL_SHELL_TOOLS"] = "auto"
env["B_AGENTIC_INSTALL_SERENA"] = "N"
env["B_AGENTIC_INSTALL_CODEGRAPH"] = "N"
env["B_AGENTIC_SHELL_RECOMMEND_MANAGER"] = "dnf"

pid, fd = pty.fork()
if pid == 0:
    os.environ.update(env)
    os.execv("/bin/bash", ["bash", install_script])

status = None
with open(log_path, "wb") as log:
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

	[ "$rc" -eq 0 ] || fail "expected auto-mode optional shell tool skip exit 0, got $rc"
	assert_contains "$dnf_install_log" 'Optional shell tooling is not installed automatically; set B_AGENTIC_INSTALL_SHELL_TOOLS=Y to install rg, fd/fdfind, bat, eza/exa, sd, jq'
	[ ! -e "$dnf_log" ] || fail "auto-mode optional shell tooling must not invoke dnf"
	assert_contains "$dnf_install_log" 'core: optional tools unavailable: rg, fd/fdfind, bat/batcat, eza/exa, sd, jq'

	local dnf_root_sandbox="$WORK_DIR/shell-tool-dnf-root"
	local dnf_root_bin_dir="$dnf_root_sandbox/bin"
	local dnf_root_log="$dnf_root_sandbox/dnf.log"
	local dnf_root_install_log="$dnf_root_sandbox/install.log"

	mkdir -p "$dnf_root_bin_dir" "$dnf_root_sandbox/home"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$dnf_root_bin_dir/rtk"
	chmod +x "$dnf_root_bin_dir/rtk"
	for tool in basename bash chmod cmp cp date dirname env git grep ln mkdir mktemp python3 rm uname; do
		src="$(command -v "$tool" 2>/dev/null || true)"
		[ -n "$src" ] || fail "required smoke helper not found: $tool"
		ln -s "$src" "$dnf_root_bin_dir/$tool"
	done
	cat >"$dnf_root_bin_dir/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-u" ]; then
  printf '0\n'
  exit 0
fi
exit 1
EOF
	cat >"$dnf_root_bin_dir/dnf" <<EOF
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
		B_AGENTIC_INSTALL_PI_CLI=N \
		B_AGENTIC_INSTALL_RTK=N \
		B_AGENTIC_INSTALL_SHELL_TOOLS=Y \
		B_AGENTIC_INSTALL_SERENA=N \
		B_AGENTIC_INSTALL_CODEGRAPH=N \
		B_AGENTIC_SHELL_RECOMMEND_MANAGER=dnf \
		bash "$ROOT_DIR/install.sh" >"$dnf_root_install_log" 2>&1
	rc=$?
	set -e

	[ "$rc" -eq 0 ] || fail "expected root dnf shell tool install exit 0, got $rc"
	assert_contains "$dnf_root_log" 'dnf:install -y --skip-unavailable ripgrep fd-find bat eza sd jq'
	assert_not_contains "$dnf_root_log" 'sudo:'
	assert_contains "$dnf_root_install_log" 'core: ready: rg, fd/fdfind, bat/batcat, eza/exa, sd, and jq available'
}

run_mcp_doctor_case() {
	local snapshot_repo="$1"
	local sandbox="$WORK_DIR/mcp-doctor-pi"
	local bin_dir="$WORK_DIR/mcp-doctor-bin"
	local doctor_log="$WORK_DIR/mcp-doctor.log"
	local invalid_doctor_log="$WORK_DIR/mcp-doctor-invalid.log"
	local rc=0
	mkdir -p "$sandbox/home" "$bin_dir"

	printf '#!/usr/bin/env bash\nexit 0\n' >"$bin_dir/serena"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$bin_dir/codegraph"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$bin_dir/pnpm"
	cat >"$bin_dir/pi" <<'EOF'
#!/usr/bin/env bash
log_dir="$(cd "$(dirname "$0")" && pwd)"
if [ "${1:-}" = "list" ]; then
  [ -f "$log_dir/pi-adapter-installed" ] && printf 'npm:pi-mcp-adapter\n' || printf '(no packages)\n'
  exit 0
fi
if [ "${1:-}" = "install" ]; then
  [ "${2:-}" = "npm:pi-mcp-adapter" ] && : > "$log_dir/pi-adapter-installed"
  exit 0
fi
exit 0
EOF
	chmod +x "$bin_dir/serena" "$bin_dir/codegraph" "$bin_dir/pnpm" "$bin_dir/pi"

	set +e
	HOME="$sandbox/home" \
		PATH="$bin_dir:$(smoke_runtime_cli_path "$sandbox")" \
		B_AGENTIC_REPO="$snapshot_repo" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		B_AGENTIC_INSTALL_PI_CLI=N \
		B_AGENTIC_INSTALL_RTK=N \
		B_AGENTIC_INSTALL_SERENA=N \
		B_AGENTIC_INSTALL_CODEGRAPH=N \
		B_AGENTIC_INSTALL_PI_MCP_ADAPTER=Y \
		bash "$ROOT_DIR/install.sh" >/dev/null 2>&1
	rc=$?
	set -e
	[ "$rc" -eq 0 ] || fail "expected Pi MCP adapter install exit 0, got $rc"

	set +e
	PATH="$bin_dir:$(smoke_system_path)" \
	CONTEXT7_API_KEY=test-context7 \
	BRAVE_API_KEY=test-brave \
	FIRECRAWL_API_KEY=test-firecrawl \
		python3 "$ROOT_DIR/tooling/validate/mcp_doctor.py" --home "$sandbox/home" >"$doctor_log"
	rc=$?
	set -e
	[ "$rc" -eq 0 ] || fail "expected Pi MCP doctor to pass with latest launchers, got $rc"
	assert_contains "$doctor_log" 'mcp-adapter: ready:'
	assert_contains "$doctor_log" 'serena: ready:'
	assert_contains "$doctor_log" 'codegraph: ready:'
	assert_contains "$doctor_log" 'context7: ready:'
	assert_contains "$doctor_log" 'brave-search: ready:'
	assert_contains "$doctor_log" 'firecrawl: ready:'
	assert_contains "$doctor_log" 'playwright: ready:'

	printf '[]\n' >"$sandbox/home/.pi/agent/mcp.json"
	set +e
	python3 "$ROOT_DIR/tooling/validate/mcp_doctor.py" --home "$sandbox/home" >"$invalid_doctor_log" 2>&1
	rc=$?
	set -e
	[ "$rc" -eq 1 ] || fail "expected malformed Pi MCP config to fail cleanly, got $rc"
	assert_contains "$invalid_doctor_log" 'status: invalid config: config root must be an object'
	assert_not_contains "$invalid_doctor_log" 'Traceback'
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

	cat >"$bin_dir/rtk" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	cat >"$bin_dir/serena" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	cat >"$bin_dir/codegraph" <<EOF
#!/usr/bin/env bash
printf 'codegraph:%s\n' "\$*" >> "$upgrade_log"
exit 0
EOF
	cat >"$bin_dir/uv" <<EOF
#!/usr/bin/env bash
printf 'uv:%s\n' "\$*" >> "$upgrade_log"
EOF
	cat >"$bin_dir/curl" <<EOF
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
env["B_AGENTIC_INSTALL_PI_CLI"] = "N"
env["B_AGENTIC_INSTALL_RTK"] = "Y"
env["B_AGENTIC_INSTALL_SERENA"] = "Y"
env["B_AGENTIC_INSTALL_CODEGRAPH"] = "Y"
env["B_AGENTIC_INSTALL_PI_MCP_ADAPTER"] = "N"
env["B_AGENTIC_INSTALL_PI_OBSERVATIONAL_MEMORY"] = "N"

pid, fd = pty.fork()
if pid == 0:
    os.environ.update(env)
    os.execv("/bin/bash", ["bash", install_script])

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
		cat >"$bin_dir/$tool" <<EOF
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
env["B_AGENTIC_INSTALL_PI_CLI"] = "N"
env["B_AGENTIC_INSTALL_SHELL_TOOLS"] = "N"

pid = os.fork()
if pid == 0:
    os.setsid()
    with open(log_path, "wb") as log:
        res = subprocess.run(["bash", install_script], env=env, stdout=log, stderr=log)
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
	local install_log rc

	mkdir -p "$sandbox/home" "$bin_dir"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$bin_dir/rtk"
	chmod +x "$bin_dir/rtk"

	cat >"$bin_dir/pi" <<EOF
#!/usr/bin/env bash
printf 'pi:%s\n' "\$*" >> "$upgrade_log"
exit 0
EOF
	chmod +x "$bin_dir/pi"

	install_log="$sandbox/install.log"
	rc=0
	set +e
	HOME="$sandbox/home" \
		PATH="$(smoke_path_with_runtime_clis "$sandbox" "$bin_dir")" \
		B_AGENTIC_REPO="$snapshot_repo" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		B_AGENTIC_INSTALL_PI_CLI=Y \
		B_AGENTIC_INSTALL_RTK=N \
		B_AGENTIC_INSTALL_SHELL_TOOLS=N \
		B_AGENTIC_INSTALL_SERENA=N \
		B_AGENTIC_INSTALL_CODEGRAPH=N \
		bash "$ROOT_DIR/install.sh" >"$install_log" 2>&1
	rc=$?
	set -e

	[ "$rc" -eq 0 ] || fail "expected pi runtime CLI upgrade install exit 0, got $rc"
	assert_contains "$upgrade_log" 'pi:update'
}

run_missing_runtime_cli_install_case() {
	local snapshot_repo="$1"
	local sandbox="$WORK_DIR/missing-runtime-cli-install"
	local bin_dir="$sandbox/bin"
	local install_log rc required_tool

	mkdir -p "$sandbox/home" "$bin_dir"
	for required_tool in rtk rg fd bat eza sd jq; do
		printf '#!/usr/bin/env bash\nexit 0\n' >"$bin_dir/$required_tool"
		chmod +x "$bin_dir/$required_tool"
	done

	install_log="$sandbox/install.log"
	rc=0
	set +e
	HOME="$sandbox/home" \
		PATH="$bin_dir:$(smoke_system_path)" \
		B_AGENTIC_REPO="$snapshot_repo" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		B_AGENTIC_INSTALL_PI_CLI=Y \
		B_AGENTIC_INSTALL_RTK=Y \
		B_AGENTIC_INSTALL_SHELL_TOOLS=N \
		B_AGENTIC_INSTALL_SERENA=N \
		B_AGENTIC_INSTALL_CODEGRAPH=N \
		bash "$ROOT_DIR/install.sh" --dry-run >"$install_log" 2>&1
	rc=$?
	set -e

	[ "$rc" -eq 0 ] || fail "expected pi missing CLI install dry-run exit 0, got $rc"
	assert_contains "$install_log" '[dry-run] curl -fsSL https://pi.dev/install.sh | sh'
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
		printf '#!/usr/bin/env bash\nexit 0\n' >"$bin_dir/$required_tool"
		chmod +x "$bin_dir/$required_tool"
	done

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
        res = subprocess.run(["bash", install_script], env=env, stdout=log, stderr=log)
        sys.exit(res.returncode)
else:
    _, status = os.waitpid(pid, 0)
    sys.exit(os.WEXITSTATUS(status))
PY
	rc=$?
	set -e

	[ "$rc" -eq 0 ] || fail "expected runtime CLI default skip install exit 0, got $rc"
	assert_contains "$install_log" 'Skipping Pi CLI preparation; rerun interactively to accept the prompt, or set B_AGENTIC_INSTALL_PI_CLI=Y to install or upgrade it.'
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
		printf '#!/usr/bin/env bash\nexit 0\n' >"$bin_dir/$required_tool"
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
    os.execv("/bin/bash", ["bash", install_script, "--dry-run"])

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
	assert_contains "$install_log" 'Install the Pi CLI now? [y/N]:'
	assert_contains "$install_log" '[dry-run] curl -fsSL https://pi.dev/install.sh | sh'
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

	cat >"$bin_dir/pi" <<EOF
#!/usr/bin/env bash
printf 'pi:%s\n' "\$*" >> "$upgrade_log"
exit 0
EOF
	chmod +x "$bin_dir/pi"
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
env["B_AGENTIC_INSTALL_PI_MCP_ADAPTER"] = "N"
env["B_AGENTIC_INSTALL_PI_OBSERVATIONAL_MEMORY"] = "N"

pid, fd = pty.fork()
if pid == 0:
    os.environ.update(env)
    os.execv("/bin/bash", ["bash", install_script])

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
	assert_contains "$install_log" 'Upgrade the installed Pi CLI now? [y/N]:'
	assert_not_contains "$install_log" 'pi_cli_installed: command not found'
	assert_not_contains "$install_log" 'Install the Pi CLI now? [y/N]:'
	assert_contains "$install_log" 'Pi CLI already installed; upgrading with pi update'
	assert_contains "$upgrade_log" 'pi:update'
}

run_skill_doctor_case() {
	local snapshot_repo="$1"
	local sandbox="$WORK_DIR/skill-doctor-pi"
	local doctor_log="$WORK_DIR/skill-doctor.log"
	local expected_skill_count
	local rc=0
	mkdir -p "$sandbox/home"
	expected_skill_count="$(registry_skill_count)"

	expect_install_status 0 "$sandbox" "$snapshot_repo"
	python3 "$ROOT_DIR/tooling/validate/skill_doctor.py" --home "$sandbox/home" >"$doctor_log"
	assert_contains "$doctor_log" "expected-skills: $expected_skill_count"
	assert_contains "$doctor_log" 'kernel: ready'
	assert_contains "$doctor_log" "skills: ready: $expected_skill_count skills installed"
	assert_contains "$doctor_log" 'discovery: ready:'
	rm -rf "$sandbox/home/.pi/agent/skills/b-review"
	set +e
	python3 "$ROOT_DIR/tooling/validate/skill_doctor.py" --home "$sandbox/home" >"$doctor_log"
	rc=$?
	set -e
	[ "$rc" -eq 1 ] || fail "expected skill doctor to fail for missing skill, got $rc"
	assert_contains "$doctor_log" 'skills: missing or mismatched: missing b-review'
	assert_contains "$doctor_log" 'discovery: blocked: install complete skill payload'

}

run_rtk_latest_dry_run_case() {
	local snapshot_repo="$1"
	local sandbox="$WORK_DIR/rtk-latest-dry-run"
	local bin_dir="$sandbox/bin"
	local install_log="$sandbox/install.log"
	local rc required_tool

	mkdir -p "$sandbox/home" "$bin_dir"
	for required_tool in rg fd bat eza sd jq; do
		printf '#!/usr/bin/env bash\nexit 0\n' >"$bin_dir/$required_tool"
		chmod +x "$bin_dir/$required_tool"
	done

	set +e
	HOME="$sandbox/home" \
		PATH="$bin_dir:$(smoke_system_path)" \
		B_AGENTIC_REPO="$snapshot_repo" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		B_AGENTIC_INSTALL_PI_CLI=N \
		B_AGENTIC_INSTALL_RTK=Y \
		B_AGENTIC_INSTALL_SERENA=N \
		B_AGENTIC_INSTALL_CODEGRAPH=N \
		bash "$ROOT_DIR/install.sh" --dry-run >"$install_log" 2>&1
	rc=$?
	set -e
	[ "$rc" -eq 0 ] || fail "expected dry-run with latest RTK exit 0, got $rc"
	assert_contains "$install_log" '[dry-run] curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh'
}

main() {
	local snapshot_repo="$WORK_DIR/repo-snapshot"

	require_bin git
	require_bin node
	require_bin python3
	make_repo_snapshot "$snapshot_repo"
	echo "Running run_rtk_latest_dry_run_case..."
	run_rtk_latest_dry_run_case "$snapshot_repo"
	echo "Running run_ref_install_case..."
	run_ref_install_case "$snapshot_repo"
	echo "Running run_manifest_only_corrupted_manifest_case..."
	run_manifest_only_corrupted_manifest_case
	echo "Running run_manifest_only_custom_paths_case..."
	run_manifest_only_custom_paths_case
	echo "Running run_manifest_only_merged_config_case..."
	run_manifest_only_merged_config_case "$snapshot_repo"
	echo "Running run_manifest_only_extension_restore_case..."
	run_manifest_only_extension_restore_case "$snapshot_repo"
	echo "Running run_manifest_only_extension_symlink_case..."
	run_manifest_only_extension_symlink_case "$snapshot_repo"
	echo "Running run_post_install_mcp_modification_case..."
	run_post_install_mcp_modification_case "$snapshot_repo"
	echo "Running run_invalid_skill_payload_case..."
	run_invalid_skill_payload_case "$snapshot_repo"
	echo "Running run_skill_collision_smoke_case..."
	run_skill_collision_smoke_case "$snapshot_repo"
	echo "Running run_readiness_report_case..."
	run_readiness_report_case "$snapshot_repo"
	echo "Running run_optional_shell_tool_case..."
	run_optional_shell_tool_case "$snapshot_repo"
	echo "Running run_mcp_doctor_case..."
	run_mcp_doctor_case "$snapshot_repo"
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

	# shellcheck disable=SC1090
	source "$ROOT_DIR/pi/tests/smoke.sh"
	declare -F run_pi_smoke_cases >/dev/null || fail "Pi smoke suite did not define run_pi_smoke_cases"
	echo "Running Pi smoke cases..."
	run_pi_smoke_cases "$snapshot_repo"

	printf 'smoke-install.sh passed\n'
}

main "$@"
