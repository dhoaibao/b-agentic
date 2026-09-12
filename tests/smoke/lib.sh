#!/usr/bin/env bash

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

assert_no_path() {
	local path="$1"
	[ ! -e "$path" ] || fail "unexpected path: $path"
}

assert_glob() {
	local pattern="$1"
	compgen -G "$pattern" >/dev/null || fail "expected match: $pattern"
}

assert_contains() {
	local path="$1" needle="$2"
	grep -Fq "$needle" "$path" || fail "expected '$needle' in $path"
}

assert_json_value() {
	local path="$1" expression="$2"
	python3 - "$path" "$expression" <<'PY' || fail "JSON assertion failed for $path: $expression"
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
if not eval(sys.argv[2], {'data': data}):
    sys.exit(1)
PY
}

assert_toml_value() {
	local path="$1" expression="$2"
	python3 - "$path" "$expression" <<'PY' || fail "TOML assertion failed for $path: $expression"
import sys
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:
    print('TOML assertions require Python 3.11+ (stdlib tomllib).', file=sys.stderr)
    sys.exit(1)

data = tomllib.loads(Path(sys.argv[1]).read_text())
if not eval(sys.argv[2], {'data': data}):
    sys.exit(1)
PY
}

assert_not_contains() {
	local path="$1" needle="$2"
	! grep -Fq "$needle" "$path" || fail "did not expect '$needle' in $path"
}

assert_equal_files() {
	local left="$1" right="$2"
	cmp -s "$left" "$right" || fail "expected files to match: $left vs $right"
}

make_release_fixture() {
	local fixture_dir="$1"
	mkdir -p "$fixture_dir"
	bash "$ROOT_DIR/scripts/build-release.sh" "$fixture_dir" >/dev/null
}

# Tars an arbitrary staged payload directory into a release fixture layout
# (tarball + matching checksum) for corrupted-payload cases.
make_fixture_from_payload() {
	local payload_dir="$1" fixture_dir="$2"
	mkdir -p "$fixture_dir"
	tar -czf "$fixture_dir/b-agentic.tar.gz" -C "$payload_dir" install.sh VERSION skills references adapters tooling
	{
		if command -v sha256sum >/dev/null 2>&1; then
			sha256sum "$fixture_dir/b-agentic.tar.gz"
		else
			shasum -a 256 "$fixture_dir/b-agentic.tar.gz"
		fi
	} | awk '{print $1 "  b-agentic.tar.gz"}' >"$fixture_dir/b-agentic.tar.gz.sha256"
}

make_dracula_fixture() {
	local fixture_dir="$1"
	mkdir -p "$fixture_dir"
	git -C "$fixture_dir" init -q
	git -C "$fixture_dir" config user.name 'b-agentic smoke'
	git -C "$fixture_dir" config user.email 'smoke@example.com'
	cat >"$fixture_dir/dracula.json" <<'EOF'
{
  "name": "Dracula",
  "colors": {
    "background": "#282a36",
    "foreground": "#f8f8f2"
  }
}
EOF
	git -C "$fixture_dir" add dracula.json
	git -C "$fixture_dir" commit -qm 'dracula theme fixture'
}

smoke_runtime_cli_path() {
	local sandbox="$1"
	local bin_dir="$sandbox/smoke-bin"
	local name=agent

	mkdir -p "$bin_dir"
	cat >"$bin_dir/$name" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	chmod +x "$bin_dir/$name"

	# Pi mock supports list/install so package lifecycle smoke can observe installs.
	cat >"$bin_dir/pi" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log_dir="$(cd "$(dirname "$0")" && pwd)"
if [ "${B_AGENTIC_VERBOSE_MOCK:-0}" -eq 1 ]; then
  printf 'pi routine output %s\n' "$*"
  printf 'warning: mocked actionable warning\n' >&2
fi
if [ "${1:-}" = "list" ]; then
  found=0
  if [ -f "$log_dir/pi-adapter-installed" ]; then
    printf 'npm:pi-mcp-adapter\n'
    found=1
  fi
  if [ -f "$log_dir/pi-observational-memory-installed" ]; then
    printf 'npm:pi-observational-memory\n'
    found=1
  fi
  if [ -f "$log_dir/pi-usage-installed" ]; then
    printf 'npm:@sreetej510/pi-usage\n'
    found=1
  fi
  if [ -f "$log_dir/pi-anthropic-auth-installed" ]; then
    printf 'npm:@gotgenes/pi-anthropic-auth\n'
    found=1
  fi
  if [ -f "$log_dir/pi-intercom-installed" ]; then
    printf 'npm:pi-intercom\n'
    found=1
  fi
  if [ -f "$log_dir/pi-ask-user-question-versioned-installed" ]; then
    printf 'npm:@juicesharp/rpiv-ask-user-question@1.0.0\n'
    found=1
  elif [ -f "$log_dir/pi-ask-user-question-installed" ]; then
    printf 'npm:@juicesharp/rpiv-ask-user-question\n'
    found=1
  fi
  if [ -f "$log_dir/pi-lsp-ranged-installed" ]; then
    printf 'npm:@narumitw/pi-lsp@^1.0.0\n'
    found=1
  fi
  if [ -f "$log_dir/pi-todo-versioned-installed" ]; then
    printf 'npm:@juicesharp/rpiv-todo@1.0.0\n'
    found=1
  elif [ -f "$log_dir/pi-todo-installed" ]; then
    printf 'npm:@juicesharp/rpiv-todo\n'
    found=1
  fi
  [ "$found" -eq 1 ] || printf 'No packages installed.\n'
  exit 0
fi
if [ "${1:-}" = "update" ]; then
  printf 'update%s\n' "${2:+ $2}" >> "$log_dir/pi-install.log"
  exit 0
fi
if [ "${1:-}" = "install" ]; then
  printf '%s\n' "${2:-}" >> "$log_dir/pi-install.log"
  if [ "${2:-}" = "npm:pi-mcp-adapter" ]; then
    : > "$log_dir/pi-adapter-installed"
  fi
  if [ "${2:-}" = "npm:pi-observational-memory" ]; then
    : > "$log_dir/pi-observational-memory-installed"
  fi
  if [ "${2:-}" = "npm:@sreetej510/pi-usage" ]; then
    : > "$log_dir/pi-usage-installed"
  fi
  if [ "${2:-}" = "npm:@gotgenes/pi-anthropic-auth" ]; then
    : > "$log_dir/pi-anthropic-auth-installed"
  fi
  if [ "${2:-}" = "npm:pi-intercom" ]; then
    : > "$log_dir/pi-intercom-installed"
  fi
  if [ "${2:-}" = "npm:@juicesharp/rpiv-ask-user-question" ]; then
    rm -f "$log_dir/pi-ask-user-question-versioned-installed"
    : > "$log_dir/pi-ask-user-question-installed"
  fi
  if [ "${2:-}" = "npm:@juicesharp/rpiv-todo" ]; then
    rm -f "$log_dir/pi-todo-versioned-installed"
    : > "$log_dir/pi-todo-installed"
  fi
  exit 0
fi
exit 0
EOF
	chmod +x "$bin_dir/pi"

	# Required installer prerequisites are present in the isolated smoke PATH.
	# file:// URLs pass through to the real curl so release-fixture downloads
	# behave exactly as on a user machine; every other URL gets a no-op payload
	# so piped remote installers never touch the network.
	real_curl="$(command -v curl)"
	cat >"$bin_dir/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
for arg in "\$@"; do
	case "\$arg" in
	file://*) exec "$real_curl" "\$@" ;;
	esac
done
printf 'exit 0\n'
EOF
	chmod +x "$bin_dir/curl"
	local name=codegraph
	cat >"$bin_dir/$name" <<'EOF'
#!/usr/bin/env bash
log_dir="$(cd "$(dirname "$0")" && pwd)"
if [ "${B_AGENTIC_VERBOSE_MOCK:-0}" -eq 1 ]; then
  printf 'dependency routine output %s\n' "$*"
fi
if [ "$(basename "$0")" = "codegraph" ] && [ -f "$log_dir/fail-codegraph" ]; then
	printf 'forced codegraph diagnostic\n' >&2
	exit 23
fi
exit 0
EOF
	chmod +x "$bin_dir/$name"
	cat >"$bin_dir/bun" <<'EOF'
#!/usr/bin/env bash
log_dir="$(cd "$(dirname "$0")" && pwd)"
if [ "${B_AGENTIC_VERBOSE_MOCK:-0}" -eq 1 ]; then
  printf 'bun routine output %s\n' "$*"
fi
printf 'bun %s\n' "$*" >> "$log_dir/bun.log"
exit 0
EOF
	ln -sfn bun "$bin_dir/bunx"
	chmod +x "$bin_dir/bun"
	cat >"$bin_dir/sudo" <<'EOF'
#!/usr/bin/env bash
"$@"
EOF
	cat >"$bin_dir/apt-get" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	cp "$bin_dir/apt-get" "$bin_dir/apt"
	chmod +x "$bin_dir/sudo" "$bin_dir/apt-get" "$bin_dir/apt"

	for name in rtk rg fd bat eza sd jq; do
		cat >"$bin_dir/$name" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
		chmod +x "$bin_dir/$name"
	done

	printf '%s:%s' "$bin_dir" "$(smoke_system_path)"
}

smoke_system_path() {
	local python_bin python_dir

	python_bin="$(command -v python3 2>/dev/null || true)"
	if [ -n "$python_bin" ]; then
		python_dir="$(dirname "$python_bin")"
		printf '%s:/usr/bin:/bin' "$python_dir"
	else
		printf '/usr/bin:/bin'
	fi
}

smoke_path_with_runtime_clis() {
	local sandbox="$1" extra_path="${2:-}"
	local smoke_path
	smoke_path="$(smoke_runtime_cli_path "$sandbox")"
	if [ -n "$extra_path" ]; then
		printf '%s:%s' "$extra_path" "$smoke_path"
	else
		printf '%s' "$smoke_path"
	fi
}

run_install_status() {
	local sandbox="$1" release_fixture="$2"
	shift 2

	local smoke_path
	smoke_path="$(smoke_runtime_cli_path "$sandbox")"

	local rc=0
	set +e
	HOME="$sandbox/home" \
		PATH="$smoke_path" \
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_DRACULA_REPO="${B_AGENTIC_DRACULA_REPO:-}" \
		B_AGENTIC_PROMPT_API_KEYS=N \
	bash "$ROOT_DIR/install.sh" "$@" >/dev/null 2>&1
	rc=$?
	set -e

	printf '%s' "$rc"
}

run_install_status_in_cwd() {
	local install_cwd="$1" sandbox="$2" release_fixture="$3"
	shift 3

	local smoke_path
	smoke_path="$(smoke_runtime_cli_path "$sandbox")"

	local rc=0
	set +e
	(
		cd "$install_cwd"
		HOME="$sandbox/home" \
			PATH="$smoke_path" \
			B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" \
			B_AGENTIC_DIR="$sandbox/source" \
			B_AGENTIC_DRACULA_REPO="${B_AGENTIC_DRACULA_REPO:-}" \
			B_AGENTIC_PROMPT_API_KEYS=N \
			bash "$ROOT_DIR/install.sh" "$@" >/dev/null 2>&1
	)
	rc=$?
	set -e

	printf '%s' "$rc"
}

run_install_with_tty_status() {
	local sandbox="$1" release_fixture="$2" input="$3"
	shift 3

	local smoke_path
	smoke_path="$(smoke_runtime_cli_path "$sandbox")"

	local rc=0
	set +e
	python3 - "$sandbox" "$release_fixture" "$input" "$smoke_path" "$ROOT_DIR/install.sh" "$@" <<'PY' >/dev/null 2>&1
import os, pty, select, sys

sandbox, release_fixture, input_data, smoke_path, install_script = sys.argv[1:6]
args = sys.argv[6:]

env = dict(os.environ)
env["HOME"] = os.path.join(sandbox, "home")
env["PATH"] = smoke_path
env["B_AGENTIC_RELEASE_URL"] = "file://" + release_fixture + "/b-agentic.tar.gz"
env["B_AGENTIC_CHECKSUM_URL"] = "file://" + release_fixture + "/b-agentic.tar.gz.sha256"
env["B_AGENTIC_DIR"] = os.path.join(sandbox, "source")

pid, fd = pty.fork()
if pid == 0:
    os.environ.update(env)
    os.execv("/bin/bash", ["bash", install_script] + args)

if input_data:
    os.write(fd, input_data.encode())

status = None
while True:
    try:
        result, child_status = os.waitpid(pid, os.WNOHANG)
        if result:
            status = child_status
            break
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready and not os.read(fd, 4096):
            _, status = os.waitpid(pid, 0)
            break
    except (OSError, select.error):
        break

os.close(fd)
if status is None:
    _, status = os.waitpid(pid, 0)

sys.exit(os.WEXITSTATUS(status))
PY
	rc=$?
	set -e

	printf '%s' "$rc"
}

run_install_with_tty_log() {
	local sandbox="$1" release_fixture="$2" log_path="$3"
	shift 3

	local smoke_path
	smoke_path="$(smoke_runtime_cli_path "$sandbox")"

	local rc=0
	set +e
	python3 - "$sandbox" "$release_fixture" "$log_path" "$smoke_path" "$ROOT_DIR/install.sh" "$@" <<'PY'
import errno, os, pty, select, sys

sandbox, release_fixture, log_path, smoke_path, install_script = sys.argv[1:6]
args = sys.argv[6:]
input_data = os.environ.get("B_AGENTIC_TTY_INPUT", "\n")

env = dict(os.environ)
env["HOME"] = os.path.join(sandbox, "home")
env["PATH"] = smoke_path
env["B_AGENTIC_RELEASE_URL"] = "file://" + release_fixture + "/b-agentic.tar.gz"
env["B_AGENTIC_CHECKSUM_URL"] = "file://" + release_fixture + "/b-agentic.tar.gz.sha256"
env["B_AGENTIC_DIR"] = os.path.join(sandbox, "source")
env["B_AGENTIC_PROMPT_API_KEYS"] = "N"

pid, fd = pty.fork()
if pid == 0:
    os.environ.update(env)
    os.execv("/bin/bash", ["bash", install_script] + args)

if input_data:
    os.write(fd, input_data.encode())

status = None
with open(log_path, "wb") as log:
    while True:
        if status is None:
            result, child_status = os.waitpid(pid, os.WNOHANG)
            if result:
                status = child_status

        try:
            ready, _, _ = select.select([fd], [], [], 0.1)
            if ready:
                chunk = os.read(fd, 4096)
                if not chunk:
                    break
                log.write(chunk)
                log.flush()
            elif status is not None:
                # The child has exited and the PTY has no more buffered data.
                break
        except OSError as error:
            # macOS reports PTY end-of-file as EIO instead of returning b"".
            if error.errno == errno.EIO:
                break
            raise

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

	return "$rc"
}

expect_install_with_tty_status() {
	local expected="$1" sandbox="$2" release_fixture="$3" input="$4"
	shift 4

	local rc
	rc="$(run_install_with_tty_status "$sandbox" "$release_fixture" "$input" "$@")"
	[ "$rc" -eq "$expected" ] || fail "expected TTY install exit $expected, got $rc"
}

expect_install_status() {
	local expected="$1" sandbox="$2" release_fixture="$3"
	shift 3

	local rc
	rc="$(run_install_status "$sandbox" "$release_fixture" "$@")"
	[ "$rc" -eq "$expected" ] || fail "expected install exit $expected, got $rc"
}

# Like run_install_status but captures full installer output into a log file
# so cases can assert the exact failure or success messages.
run_install_capture() {
	local sandbox="$1" release_fixture="$2" log_path="$3"
	shift 3

	local smoke_path rc
	smoke_path="$(smoke_runtime_cli_path "$sandbox")"
	set +e
	HOME="$sandbox/home" \
		PATH="$smoke_path" \
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" \
		B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" "$@" >"$log_path" 2>&1
	rc=$?
	set -e
	return "$rc"
}

expect_install_status_in_cwd() {
	local expected="$1" install_cwd="$2" sandbox="$3" release_fixture="$4"
	shift 4

	local rc
	rc="$(run_install_status_in_cwd "$install_cwd" "$sandbox" "$release_fixture" "$@")"
	[ "$rc" -eq "$expected" ] || fail "expected install exit $expected, got $rc"
}

# Counts bootstrap download scratch dirs; the installer's EXIT cleanup must
# keep this at zero across every install, success or failure. Pass a scoped
# TMPDIR to avoid racing sibling workers that share the real one.
temp_download_count() {
	local dir="${1:-${TMPDIR:-/tmp}}"
	find "$dir" -maxdepth 1 -name 'b-agentic-download.*' | wc -l
}

registry_skill_count() {
	python3 - "$ROOT_DIR/skills/registry.yaml" <<'PY'
from pathlib import Path
import json
import sys

registry = json.loads(Path(sys.argv[1]).read_text())
print(len([skill for skill in registry.get('skills', []) if isinstance(skill, dict) and isinstance(skill.get('name'), str)]))
PY
}
