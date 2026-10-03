#!/usr/bin/env bash
# Sandbox test: install runs the vendor installers for missing Pi, bun, rtk and
# codegraph (through a fake curl), reports PATH additions, and never runs them
# for sync or dry-run. No network or real vendor script is used.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
unset B_AGENTIC_PI_DIR PI_CODING_AGENT_DIR XDG_CONFIG_HOME B_AGENTIC_DRY_RUN B_AGENTIC_UNINSTALL \
  B_AGENTIC_FORCE B_AGENTIC_REPLACE_MEMORY B_AGENTIC_REF
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/b-agentic-runtime-tools.XXXXXX")"
WORK_DIR="$(cd "$WORK_DIR" && pwd -P)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { printf 'runtime-tools.sh: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "expected $2 in $1"; }
assert_not_contains() { ! grep -Fq -- "$2" "$1" || fail "unexpected $2 in $1"; }

new_case() {
  local sandbox="$WORK_DIR/$1" directory
  mkdir -p "$sandbox/home" "$sandbox/source" "$sandbox/bin"
  cp "$ROOT_DIR/install.sh" "$sandbox/source/"
  for directory in pi skills references tooling; do
    cp -R "$ROOT_DIR/$directory" "$sandbox/source/"
  done
  # Fake curl: record the URL and emit a script that creates the named tool
  # in ~/.local/bin (the real vendors' default location).
  cat >"$sandbox/bin/curl" <<'STUB'
#!/usr/bin/env bash
url="${*: -1}"
echo "$url" >>"$CURL_LOG"
case "$url" in
  https://pi.dev/install.sh) tool=pi ;;
  https://bun.com/install) tool=bun ;;
  *rtk-ai/rtk*) tool=rtk ;;
  *colbymchenry/codegraph*) tool=codegraph ;;
  *) exit 22 ;;
esac
[ "${CURL_FAIL_TOOL:-}" != "$tool" ] || exit 22
printf 'mkdir -p "$HOME/.local/bin"\nprintf "#!/usr/bin/env bash\\nexit 0\\n" >"$HOME/.local/bin/%s"\nchmod +x "$HOME/.local/bin/%s"\n' "$tool" "$tool"
STUB
  chmod +x "$sandbox/bin/curl"
  # Allowlisted utilities only: a host-managed pi, bun, rtk or codegraph must never be reachable.
  mkdir -p "$sandbox/util"
  for tool in bash env git python3 sh cat cp mv rm mkdir rmdir mktemp cmp grep sed awk sort head tail tr dirname basename \
    date tty chmod ln find uname id wc cut readlink touch ls sleep tee diff xargs printf true false; do
    path="$(command -v "$tool" 2>/dev/null || true)"
    case "$path" in /*) ln -sf "$path" "$sandbox/util/$tool" ;; esac
  done
  printf '%s' "$sandbox"
}

# run_install <sandbox> [installer args...]; PATH deliberately lacks every managed tool.
run_install() {
  local sandbox="$1"
  shift
  HOME="$sandbox/home" PATH="$sandbox/bin:$sandbox/util" CURL_LOG="$sandbox/curl.log" \
    B_AGENTIC_DIR="$sandbox/source" B_AGENTIC_REPO="$sandbox/source" \
    B_AGENTIC_CLICKUP_MCP=no CI=1 \
    bash "$ROOT_DIR/install.sh" "$@"
}

# R1. A fresh install runs every installer once and reports the PATH addition.
case1="$(new_case fresh)"
run_install "$case1" >"$case1/log" 2>&1 || { cat "$case1/log" >&2; fail 'fresh install failed'; }
for url in https://bun.com/install https://pi.dev/install.sh; do
  assert_contains "$case1/curl.log" "$url"
done
assert_contains "$case1/curl.log" rtk-ai/rtk
assert_contains "$case1/curl.log" colbymchenry/codegraph
assert_contains "$case1/log" 'Ensure your shell profile puts'
assert_not_contains "$case1/log" 'could not install'

# R2. A failing vendor installer warns, is listed in Next steps, and does not abort.
case2="$(new_case failing-tool)"
CURL_FAIL_TOOL=rtk run_install "$case2" >"$case2/log" 2>&1 || { cat "$case2/log" >&2; fail 'install aborted on a tool failure'; }
assert_contains "$case2/log" 'could not install: rtk'
assert_contains "$case2/log" 'Install missing tools to enable the affected workflows: rtk'

# R3. Sync warns about missing tools and never runs a vendor installer.
case3="$(new_case sync)"
mkdir -p "$case3/home/.pi/agent"
printf '#!/usr/bin/env bash\necho 1.0.0\n' >"$case3/bin/pi"
chmod +x "$case3/bin/pi"
run_install "$case3" --sync >"$case3/log" 2>&1 || { cat "$case3/log" >&2; fail 'sync failed'; }
[ ! -s "$case3/curl.log" ] || fail 'sync ran a vendor installer'
assert_contains "$case3/log" 'optional tools not found'

# R4. Sync neither discovers nor selects a Pi hidden in a vendor bin directory.
case4="$(new_case hidden-pi)"
mkdir -p "$case4/home/.pi/agent" "$case4/home/.local/bin"
printf '#!/usr/bin/env bash\necho 0.5.0 >&2\necho 0.5.0\n' >"$case4/home/.local/bin/pi"
chmod +x "$case4/home/.local/bin/pi"
run_install "$case4" --sync >"$case4/log" 2>&1 || true
assert_not_contains "$case4/log" 'older than the required'
[ ! -s "$case4/curl.log" ] || fail 'sync with a hidden Pi ran a vendor installer'

# R5. With every tool present, install and --update upgrade them: bun and codegraph
#     through their own command, rtk through its official installer; sync does not.
case5="$(new_case upgrade)"
mkdir -p "$case5/home/.pi/agent"
for tool in bun codegraph rtk pi; do
  # shellcheck disable=SC2016 # The stub expands these when it runs, not now.
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$TOOL_LOG"\n[ "$1" = --version ] && echo 1.0.0\nexit 0\n' "$tool" >"$case5/bin/$tool"
  chmod +x "$case5/bin/$tool"
done
upgrade_run() {
  TOOL_LOG="$case5/tools.log" run_install "$case5" "$@" >"$case5/log" 2>&1 || { cat "$case5/log" >&2; fail "install $* failed"; }
}
: >"$case5/tools.log"
upgrade_run --update
assert_contains "$case5/tools.log" 'bun upgrade'
assert_contains "$case5/tools.log" 'codegraph upgrade'
assert_contains "$case5/curl.log" rtk-ai/rtk
assert_not_contains "$case5/curl.log" bun.com
: >"$case5/tools.log"; : >"$case5/curl.log"
upgrade_run --sync
[ ! -s "$case5/curl.log" ] || fail 'sync ran a vendor installer'
assert_not_contains "$case5/tools.log" 'upgrade'
: >"$case5/tools.log"; : >"$case5/curl.log"
upgrade_run
assert_contains "$case5/tools.log" 'bun upgrade'
assert_contains "$case5/tools.log" 'codegraph upgrade'
assert_contains "$case5/curl.log" rtk-ai/rtk

printf 'Runtime tool installer checks passed.\n'
