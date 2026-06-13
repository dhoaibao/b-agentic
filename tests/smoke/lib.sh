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

make_repo_snapshot() {
  local snapshot_dir="$1"
  mkdir -p "$snapshot_dir"
  cp -R "$ROOT_DIR"/. "$snapshot_dir"/
  rm -rf "$snapshot_dir/.git" "$snapshot_dir/.b-agentic" "$snapshot_dir/.serena"
  git -C "$snapshot_dir" init -q
  git -C "$snapshot_dir" add .
  git -C "$snapshot_dir" -c user.name='b-agentic smoke' -c user.email='smoke@example.com' commit -qm 'snapshot'
}

run_install_status() {
  local sandbox="$1" repo_snapshot="$2"
  shift 2

  local rc=0
  set +e
  HOME="$sandbox/home" \
  B_AGENTIC_REPO="$repo_snapshot" \
  B_AGENTIC_DIR="$sandbox/source" \
  B_AGENTIC_PROMPT_API_KEYS=N \
  B_AGENTIC_INSTALL_RTK=N \
  B_AGENTIC_INSTALL_SERENA=N \
  B_AGENTIC_INSTALL_CODEGRAPH=N \
  bash "$ROOT_DIR/install.sh" "$@" >/dev/null 2>&1
  rc=$?
  set -e

  printf '%s' "$rc"
}

run_install_status_in_cwd() {
  local install_cwd="$1" sandbox="$2" repo_snapshot="$3"
  shift 3

  local rc=0
  set +e
  (
    cd "$install_cwd"
    HOME="$sandbox/home" \
    B_AGENTIC_REPO="$repo_snapshot" \
    B_AGENTIC_DIR="$sandbox/source" \
    B_AGENTIC_PROMPT_API_KEYS=N \
    B_AGENTIC_INSTALL_RTK=N \
    B_AGENTIC_INSTALL_SERENA=N \
    B_AGENTIC_INSTALL_CODEGRAPH=N \
    bash "$ROOT_DIR/install.sh" "$@" >/dev/null 2>&1
  )
  rc=$?
  set -e

  printf '%s' "$rc"
}

run_install_with_tty_status() {
  local sandbox="$1" repo_snapshot="$2" input="$3"
  shift 3

  local rc=0
  set +e
  python3 - "$sandbox" "$repo_snapshot" "$input" "$ROOT_DIR/install.sh" "$@" <<'PY' >/dev/null 2>&1
import os, pty, select, sys

sandbox, repo_snapshot, input_data, install_script = sys.argv[1:5]
args = sys.argv[5:]

env = dict(os.environ)
env["HOME"] = os.path.join(sandbox, "home")
env["B_AGENTIC_REPO"] = repo_snapshot
env["B_AGENTIC_DIR"] = os.path.join(sandbox, "source")
env["B_AGENTIC_INSTALL_RTK"] = "N"
env["B_AGENTIC_INSTALL_SERENA"] = "N"
env["B_AGENTIC_INSTALL_CODEGRAPH"] = "N"

pid, fd = pty.fork()
if pid == 0:
    os.environ.update(env)
    os.execv("/bin/bash", ["bash", install_script] + args)

if input_data:
    os.write(fd, input_data.encode())

status = None
while True:
    try:
        result, status = os.waitpid(pid, os.WNOHANG)
        if result:
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
  local sandbox="$1" repo_snapshot="$2" log_path="$3"
  shift 3

  local rc=0
  set +e
  python3 - "$sandbox" "$repo_snapshot" "$log_path" "$ROOT_DIR/install.sh" "$@" <<'PY'
import os, pty, select, sys

sandbox, repo_snapshot, log_path, install_script = sys.argv[1:5]
args = sys.argv[5:]

env = dict(os.environ)
env["HOME"] = os.path.join(sandbox, "home")
env["B_AGENTIC_REPO"] = repo_snapshot
env["B_AGENTIC_DIR"] = os.path.join(sandbox, "source")
env["B_AGENTIC_PROMPT_API_KEYS"] = "N"
env["B_AGENTIC_INSTALL_RTK"] = "N"
env["B_AGENTIC_INSTALL_SERENA"] = "N"
env["B_AGENTIC_INSTALL_CODEGRAPH"] = "N"

pid, fd = pty.fork()
if pid == 0:
    os.environ.update(env)
    os.execv("/bin/bash", ["bash", install_script] + args)

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

  return "$rc"
}

expect_install_with_tty_status() {
  local expected="$1" sandbox="$2" repo_snapshot="$3" input="$4"
  shift 4

  local rc
  rc="$(run_install_with_tty_status "$sandbox" "$repo_snapshot" "$input" "$@")"
  [ "$rc" -eq "$expected" ] || fail "expected TTY install exit $expected, got $rc"
}

expect_install_status() {
  local expected="$1" sandbox="$2" repo_snapshot="$3"
  shift 3

  local rc
  rc="$(run_install_status "$sandbox" "$repo_snapshot" "$@")"
  [ "$rc" -eq "$expected" ] || fail "expected install exit $expected, got $rc"
}

expect_install_status_in_cwd() {
  local expected="$1" install_cwd="$2" sandbox="$3" repo_snapshot="$4"
  shift 4

  local rc
  rc="$(run_install_status_in_cwd "$install_cwd" "$sandbox" "$repo_snapshot" "$@")"
  [ "$rc" -eq "$expected" ] || fail "expected install exit $expected, got $rc"
}

registered_runtime_names() {
  python3 - "$ROOT_DIR/runtimes/registry.yaml" <<'PY'
from pathlib import Path
import json
import sys

registry = json.loads(Path(sys.argv[1]).read_text())
for runtime in registry.get('runtimes', []):
    name = runtime.get('name')
    if isinstance(name, str) and name:
        print(name)
PY
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
