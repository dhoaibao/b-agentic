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
  env \
    HOME="$sandbox/home" \
    B_AGENTIC_REPO="$repo_snapshot" \
    B_AGENTIC_DIR="$sandbox/source" \
    script -q -e -c "bash '$ROOT_DIR/install.sh' $*" /dev/null <<< "$input" >/dev/null 2>&1
  rc=$?
  set -e

  printf '%s' "$rc"
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
