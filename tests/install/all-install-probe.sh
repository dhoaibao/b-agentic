#!/usr/bin/env bash
# Exercise tooling/install/all_install.py (through install.sh --runtime=all) in sandbox HOME directories.
# Needs bun, python3, git, node, and jq: no network, credentials, Claude Code, Pi, or package manager.
# Every scenario owns a private HOME and logging shims stand in for npm, npx, pnpm, yarn, curl, wget, and pi.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT

fail() { echo "all install probe failed: $*" >&2; exit 1; }
for tool in bun jq node git python3; do command -v "$tool" >/dev/null 2>&1 || fail "this probe needs $tool on PATH"; done

# Logging shims: every package-manager or download call is appended to $calls.
shims="$work/shims"
calls="$work/calls.log"
mkdir -p "$shims"
: >"$calls"
for tool in npm npx pnpm yarn curl wget; do
  printf '#!/bin/sh\necho "%s $*" >>"%s"\nexit 0\n' "$tool" "$calls" >"$shims/$tool"
done
cat >"$shims/pi" <<EOF
#!/bin/sh
echo "pi \$*" >>"$calls"
[ "\$1" = "--version" ] || exit 2
echo "\${FAKE_PI_VERSION:-1.6.0}"
EOF
chmod +x "$shims"/*

# A PATH without bun (for AC-2 missing-bun refusal test).
nobun="$work/nobun"
mkdir -p "$nobun"
for tool in bash sh env python3 git node jq cat mkdir rm mv cp ln chmod; do
  resolved=$(command -v "$tool" 2>/dev/null || true)
  if [ -n "$resolved" ] && [ -x "$resolved" ]; then
    ln -sf "$resolved" "$nobun/$tool"
  fi
done

out="" err="" rc=0
run() {
  local home=$1
  shift
  rc=0
  out=$(env -u CLAUDE_CONFIG_DIR -u PI_CODING_AGENT_DIR HOME="$home" PATH="$shims:$PATH" \
    bash "$root/install.sh" --runtime=all "$@" 2>"$work/stderr") || rc=$?
  err=$(cat "$work/stderr")
}
expect_ok() { [ "$rc" -eq 0 ] || fail "$1: exit $rc: $err $out"; }
expect_refused() { [ "$rc" -ne 0 ] || fail "$1 must be refused: $out"; }

tree() {
  # shellcheck disable=SC2016 # The inner script runs in sh and expands its own variables.
  ( cd "$1" && find . \( -type f -o -type l \) -not -path '*/b-agentic/backups/*' -print0 \
      | sort -z | xargs -0 -r sh -c 'for f; do if [ -L "$f" ]; then printf "link %s -> %s\n" "$f" "$(readlink "$f")"; else printf "%s  %s\n" "$(sha256sum "$f" | cut -d" " -f1)" "$f"; fi; done' _ )
}
fresh_home() { mkdir -p "$work/$1"; printf '%s' "$work/$1"; }

# --- AC-1: fresh install, idempotent rerun, --dry-run, --with/--without ------------------------
home=$(fresh_home fresh)
: >"$calls"
run "$home" -y; expect_ok "fresh --runtime=all -y"
[ -f "$home/.claude/b-agentic/install.json" ] || fail "Claude manifest missing"
[ -f "$home/.claude/CLAUDE.md" ] || fail "CLAUDE.md missing"
[ -f "$home/.claude.json" ] || fail ".claude.json missing"
[ -f "$home/.pi/agent/b-agentic/install.json" ] || fail "Pi manifest missing"
[ -f "$home/.pi/agent/AGENTS.md" ] || fail "Pi AGENTS.md missing"
[ -f "$home/.pi/agent/settings.json" ] || fail "Pi settings.json missing"
[ -f "$home/.pi/agent/mcp.json" ] || fail "Pi mcp.json missing"
if grep -Eq '^(npm|npx|pnpm|yarn|curl|wget) ' "$calls"; then
  fail "fresh install called a package manager or downloader: $(cat "$calls")"
fi

before=$(tree "$home")
run "$home" -y; expect_ok "idempotent rerun"
[ "$before" = "$(tree "$home")" ] || fail "idempotent rerun modified files"

home=$(fresh_home dry-run)
run "$home" --dry-run; expect_ok "--runtime=all --dry-run"
[ -z "$(find "$home" -mindepth 1)" ] || fail "--dry-run must write nothing"
grep -Fq 'for Claude Code' <<<"$out" || fail "--dry-run must report Claude Code plan: $out"
grep -Fq 'for Pi' <<<"$out" || fail "--dry-run must report Pi plan: $out"

home=$(fresh_home optional)
run "$home" -y --with=drawio; expect_ok "--with=drawio"
[ -f "$home/.claude/skills/b-drawio/SKILL.md" ] || fail "--with=drawio missing in Claude"
[ "$(jq -r '.mcpServers | has("drawio")' "$home/.claude.json")" = true ] || fail "drawio MCP missing in Claude"
[ -f "$home/.pi/agent/skills/b-drawio/SKILL.md" ] || fail "--with=drawio missing in Pi"
[ "$(jq -r '.mcpServers | has("drawio")' "$home/.pi/agent/mcp.json")" = true ] || fail "drawio MCP missing in Pi"
run "$home" -y --without=drawio; expect_ok "--without=drawio"
[ ! -e "$home/.claude/skills/b-drawio" ] && [ "$(jq -r '.mcpServers | has("drawio")' "$home/.claude.json")" = false ] \
  || fail "--without=drawio must remove drawio from Claude"
[ ! -e "$home/.pi/agent/skills/b-drawio" ] && [ "$(jq -r '.mcpServers | has("drawio")' "$home/.pi/agent/mcp.json")" = false ] \
  || fail "--without=drawio must remove drawio from Pi"
echo "install probe passed: fresh-dryrun-optional"

# --- AC-2: preflight/planning refusal in either runtime writes nothing to either root ----------
home=$(fresh_home fail-pi-settings)
mkdir -p "$home/.pi/agent"
printf '{broken\n' >"$home/.pi/agent/settings.json"
before=$(tree "$home")
run "$home" -y; expect_refused "malformed Pi settings.json"
[ ! -e "$home/.claude" ] && [ ! -e "$home/.claude.json" ] || fail "Pi refusal must not write Claude files"
[ "$before" = "$(tree "$home")" ] || fail "Pi refusal modified existing files"

home=$(fresh_home fail-claude-settings)
mkdir -p "$home/.claude"
printf '{broken\n' >"$home/.claude/settings.json"
before=$(tree "$home")
run "$home" -y; expect_refused "malformed Claude settings.json"
[ ! -e "$home/.pi" ] || fail "Claude refusal must not write Pi files"
[ "$before" = "$(tree "$home")" ] || fail "Claude refusal modified existing files"

home=$(fresh_home fail-pi-claudemd)
mkdir -p "$home/.pi/agent"
printf '# clash\n' >"$home/.pi/agent/CLAUDE.md"
before=$(tree "$home")
run "$home" -y; expect_refused "CLAUDE.md under ~/.pi/agent"
[ ! -e "$home/.claude" ] && [ ! -e "$home/.claude.json" ] || fail "Pi context clash must not write Claude files"
[ "$before" = "$(tree "$home")" ] || fail "Pi context clash modified existing files"

if ! PATH="$nobun:/usr/bin:/bin" command -v bun >/dev/null 2>&1; then
  home=$(fresh_home fail-nobun)
  rc=0
  out=$(env -u CLAUDE_CONFIG_DIR -u PI_CODING_AGENT_DIR HOME="$home" PATH="$nobun:/usr/bin:/bin" \
    bash "$root/install.sh" --runtime=all -y 2>"$work/stderr") || rc=$?
  err=$(cat "$work/stderr")
  expect_refused "missing bun on PATH"
  [ -z "$(find "$home" -mindepth 1)" ] || fail "missing bun refusal must write nothing"
fi

home=$(fresh_home fail-env)
rc=0
out=$(env HOME="$home" CLAUDE_CONFIG_DIR="$work/elsewhere-claude" PATH="$shims:$PATH" \
  bash "$root/install.sh" --runtime=all -y 2>"$work/stderr") || rc=$?
expect_refused "custom CLAUDE_CONFIG_DIR"
[ -z "$(find "$home" -mindepth 1)" ] && [ ! -e "$work/elsewhere-claude" ] || fail "CLAUDE_CONFIG_DIR refusal wrote files"
rc=0
out=$(env HOME="$home" PI_CODING_AGENT_DIR="$work/elsewhere-pi" PATH="$shims:$PATH" \
  bash "$root/install.sh" --runtime=all -y 2>"$work/stderr") || rc=$?
expect_refused "custom PI_CODING_AGENT_DIR"
[ -z "$(find "$home" -mindepth 1)" ] && [ ! -e "$work/elsewhere-pi" ] || fail "PI_CODING_AGENT_DIR refusal wrote files"
echo "install probe passed: preflight-atomic"

# --- AC-3: Pi-restricted flags refused before any git call or write ----------------------------
gitshim="$work/git-shim"
mkdir -p "$gitshim"
gitcalls="$work/git-calls.log"
: >"$gitcalls"
cat >"$gitshim/git" <<EOF
#!/bin/sh
echo "git \$*" >>"$gitcalls"
exit 99
EOF
chmod +x "$gitshim/git"

home=$(fresh_home flag-restrictions)
run "$home" -y --statusline-only; expect_refused "--statusline-only with --runtime=all"
grep -Fq -- '--runtime=all' <<<"$err" || fail "statusline refusal must name --runtime=all: $err"
for flag in --update --ref=main; do
  rc=0
  out=$(env -u CLAUDE_CONFIG_DIR -u PI_CODING_AGENT_DIR HOME="$home" PATH="$gitshim:$PATH" \
    bash "$root/install.sh" --runtime=all -y "$flag" 2>"$work/stderr") || rc=$?
  err=$(cat "$work/stderr")
  expect_refused "--runtime=all $flag"
  grep -Fq -- '--runtime=all' <<<"$err" || fail "$flag refusal must name --runtime=all: $err"
done
rc=0
out=$(env -u CLAUDE_CONFIG_DIR -u PI_CODING_AGENT_DIR HOME="$home" B_AGENTIC_DIR="$work/clone" PATH="$gitshim:$PATH" \
  bash -s -- --runtime=all -y <"$root/install.sh" 2>"$work/stderr") || rc=$?
err=$(cat "$work/stderr")
expect_refused "piped --runtime=all"
grep -Fq 'never clones' <<<"$err" || fail "piped --runtime=all must refuse to clone: $err"
[ ! -s "$gitcalls" ] && [ ! -e "$work/clone" ] || fail "refused bootstrap reached git: $(cat "$gitcalls")"
[ -z "$(find "$home" -mindepth 1)" ] || fail "refused bootstrap wrote files"
echo "install probe passed: flag-restrictions"

# --- AC-4: --runtime=all --uninstall -----------------------------------------------------------
home=$(fresh_home uninstall-both)
run "$home" -y; expect_ok "install before uninstall"
run "$home" --uninstall; expect_ok "--runtime=all --uninstall"
[ ! -e "$home/.claude/b-agentic/install.json" ] && [ ! -e "$home/.claude/skills" ] \
  || fail "Claude manifest or skills left behind after uninstall"
[ ! -e "$home/.pi/agent/b-agentic/install.json" ] && [ ! -e "$home/.pi/agent/skills" ] \
  || fail "Pi manifest or skills left behind after uninstall"
[ -d "$home/.claude/b-agentic/backups" ] && [ -d "$home/.pi/agent/b-agentic/backups" ] \
  || fail "backups must be kept on uninstall"

home=$(fresh_home uninstall-claude-only)
env -u CLAUDE_CONFIG_DIR -u PI_CODING_AGENT_DIR HOME="$home" PATH="$shims:$PATH" \
  bash "$root/install.sh" -y >/dev/null || fail "claude-only install failed"
run "$home" --uninstall; expect_ok "uninstall when only Claude installed"
[ ! -e "$home/.claude/b-agentic/install.json" ] || fail "Claude must be uninstalled"
[ ! -e "$home/.pi" ] || fail "Pi dir must not be created when Pi had no manifest"
grep -Fq 'nothing to uninstall: no b-agentic Pi manifest found' <<<"$out" \
  || fail "missing Pi manifest message: $out"

home=$(fresh_home uninstall-empty)
run "$home" --uninstall; expect_ok "uninstall on empty HOME"
[ -z "$(find "$home" -mindepth 1)" ] || fail "empty uninstall must write nothing"

home=$(fresh_home uninstall-malformed-pi)
run "$home" -y; expect_ok "install before malformed uninstall"
printf '{broken\n' >"$home/.pi/agent/settings.json"
claude_before=$(tree "$home/.claude")
run "$home" --uninstall; expect_refused "uninstall with malformed Pi settings.json"
[ "$claude_before" = "$(tree "$home/.claude")" ] || fail "failed Pi uninstall plan must not remove Claude files"
echo "install probe passed: uninstall"

# --- AC-5: interactive PTY checklists, summaries, single confirm, deduplicated vendor prompts --
cat >"$work/pty-run.py" <<'PY'
import os, pty, select, signal, subprocess, sys, time

home, *answers = sys.argv[1:]
env = {
    k: v
    for k, v in os.environ.items()
    if k not in {"NO_COLOR", "CLAUDE_CONFIG_DIR", "PI_CODING_AGENT_DIR", "B_AGENTIC_CLAUDE_DIR"}
}
env.update(HOME=home, TERM="xterm-256color")
pid, fd = pty.fork()
if pid == 0:
    keep = {
        k: os.environ[k]
        for k in ("PROBE_ROOT", "PROBE_CMD", "PROBE_CURL_LOG", "PROBE_BIN_TARGET", "PROBE_RTK_LOG", "PROBE_TRACE_LOG")
        if k in os.environ
    }
    os.execvpe("bash", ["bash", "-c", os.environ["PROBE_CMD"]], {**env, **keep})
buf, last, since = b"", time.time(), b""
while time.time() - last < 20:
    ready, _, _ = select.select([fd], [], [], 0.3)
    if ready:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        buf, since, last = buf + chunk, since + chunk, time.time()
    elif answers and time.time() - last > 0.5 and (b"[Y/n]" in since or b"[y/N]" in since or b"Enter confirms" in since):
        answer = answers.pop(0)
        if answer.startswith("!"):
            subprocess.run(answer[1:], shell=True, env=env, check=True)
            last = time.time()
        else:
            os.write(fd, (answer + "\n").encode())
            last, since = time.time(), b""
    elif not answers and time.time() - last > 3:
        break
deadline = time.time() + 15
child_status = None
while child_status is None:
    waited_pid, status = os.waitpid(pid, os.WNOHANG)
    if waited_pid != 0:
        child_status = status
        break
    if time.time() > deadline:
        try:
            os.killpg(pid, signal.SIGKILL)
        except OSError:
            os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        sys.stderr.write("pty harness: command timed out; output so far:\n")
        sys.stderr.write(buf.decode(errors="replace") + "\n")
        sys.exit(1)
    time.sleep(0.1)
sys.stdout.write(buf.decode(errors="replace"))
sys.exit(os.waitstatus_to_exitcode(child_status))
PY

novendor="$work/novendor-bin"
mkdir -p "$novendor"
for util in bun bash sh env python3 git node jq cat echo mkdir rm mv cp ln chmod touch tr head cut grep find sort xargs sha256sum dirname basename readlink mktemp sed awk wc ls test '['; do
  resolved=$(command -v "$util" 2>/dev/null || true)
  if [ -n "$resolved" ] && [ -x "$resolved" ]; then
    ln -sf "$resolved" "$novendor/$util"
  fi
done
for forbidden in claude pi rtk codegraph curl; do
  if PATH="$novendor" command -v "$forbidden" >/dev/null 2>&1; then
    fail "novendor PATH must not contain $forbidden"
  fi
done

curl_bin="$work/curl-bin"
mkdir -p "$curl_bin"
cat >"$curl_bin/curl" <<'SH'
#!/bin/sh
echo "curl $*" >>"$PROBE_CURL_LOG"
if [ -n "${PROBE_TRACE_LOG:-}" ]; then
  echo "curl $*" >>"$PROBE_TRACE_LOG"
fi
url=""
for arg in "$@"; do
  case "$arg" in http://*|https://*) url="$arg" ;; esac
done
case "$url" in
  https://claude.ai/install.sh)
    printf '#!/bin/sh\nmkdir -p "%s"\nprintf "#!/bin/sh\\nexit 0\\n" >"%s/claude"\nchmod +x "%s/claude"\n' \
      "$PROBE_BIN_TARGET" "$PROBE_BIN_TARGET" "$PROBE_BIN_TARGET"
    ;;
  https://pi.dev/install.sh)
    printf '#!/bin/sh\nmkdir -p "%s"\nprintf "#!/bin/sh\\necho 1.6.0\\n" >"%s/pi"\nchmod +x "%s/pi"\n' \
      "$PROBE_BIN_TARGET" "$PROBE_BIN_TARGET" "$PROBE_BIN_TARGET"
    ;;
  https://raw.githubusercontent.com/rtk-ai/rtk/*)
    printf '#!/bin/sh\nmkdir -p "$HOME/.local/bin"\nprintf "#!/bin/sh\\necho rtk \\$* >>\\"%s\\"\\nexit 0\\n" >"$HOME/.local/bin/rtk"\nchmod +x "$HOME/.local/bin/rtk"\n' "$PROBE_RTK_LOG"
    ;;
  https://raw.githubusercontent.com/colbymchenry/codegraph/*)
    printf '#!/bin/sh\nmkdir -p "%s"\nprintf "#!/bin/sh\\nexit 0\\n" >"%s/codegraph"\nchmod +x "%s/codegraph"\n' \
      "$PROBE_BIN_TARGET" "$PROBE_BIN_TARGET" "$PROBE_BIN_TARGET"
    ;;
  *)
    printf 'exit 99\n'
    ;;
esac
SH
chmod +x "$curl_bin/curl"

tui_run_path() {
  local home=$1 path=$2 command=$3
  shift 3
  PATH="$path" PROBE_ROOT="$root" PROBE_CMD="$command" python3 "$work/pty-run.py" "$home" "$@" || fail "pty harness failed"
}
tui_run_refused() {
  local home=$1 path=$2 command=$3
  shift 3
  local pty_rc=0
  PATH="$path" PROBE_ROOT="$root" PROBE_CMD="$command" python3 "$work/pty-run.py" "$home" "$@" || pty_rc=$?
  [ "$pty_rc" -ne 0 ] || fail "expected pty command to fail: $command"
}

# shellcheck disable=SC2016
all_cmd='bash "$PROBE_ROOT/install.sh" --runtime=all'

# Declining the single Proceed confirm writes nothing under HOME.
home=$(fresh_home tui-decline)
tui_out=$(tui_run_refused "$home" "$shims:$PATH" "$all_cmd" "" "" n)
grep -Fq 'Optional components for Claude Code' <<<"$tui_out" || fail "Claude checklist label missing: $tui_out"
grep -Fq 'Optional components for Pi' <<<"$tui_out" || fail "Pi checklist label missing: $tui_out"
grep -Fq 'Installation Summary (Claude Code)' <<<"$tui_out" || fail "Claude summary box missing: $tui_out"
grep -Fq 'Installation Summary (Pi)' <<<"$tui_out" || fail "Pi summary box missing: $tui_out"
[ "$(grep -c 'Proceed with installation?' <<<"$tui_out")" -eq 1 ] || fail "expected exactly 1 confirm: $tui_out"
[ -z "$(find "$home" -mindepth 1)" ] || fail "declining confirm must write nothing under HOME"

# Accepting with all four vendor tools missing offers each once in order, plus 1 RTK hook prompt.
home=$(fresh_home tui-vendor)
vbin="$work/vbin-all"
curl_log="$work/curl-all.log"
rtk_log="$work/rtk-all.log"
trace_log="$work/trace-all.log"
: >"$curl_log"; : >"$rtk_log"; : >"$trace_log"
# shellcheck disable=SC2016
both_manifests='!test -f "$HOME/.claude/b-agentic/install.json" && test -f "$HOME/.pi/agent/b-agentic/install.json"'
tui_out=$(PROBE_CURL_LOG="$curl_log" PROBE_BIN_TARGET="$vbin" PROBE_RTK_LOG="$rtk_log" PROBE_TRACE_LOG="$trace_log" \
  tui_run_path "$home" "$curl_bin:$vbin:$novendor" "$all_cmd" "" "" y "$both_manifests" y y y y y)
expected_trace=$(cat <<'TRACE'
curl -fsSL https://claude.ai/install.sh
curl -fsSL https://pi.dev/install.sh
curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh
curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh
TRACE
)
[ "$(cat "$trace_log")" = "$expected_trace" ] || fail "vendor ordered trace mismatch: $(cat "$trace_log")"
[ "$(grep -c '^rtk init -g --hook-only --auto-patch$' "$rtk_log")" -eq 1 ] || fail "RTK hook must run exactly once: $(cat "$rtk_log")"
if grep -Fq 'pi is not on PATH' <<<"$tui_out"; then fail "stale missing-pi warning must be cleared: $tui_out"; fi
[ -x "$vbin/claude" ] && [ -x "$vbin/pi" ] && [ -x "$home/.local/bin/rtk" ] && [ -x "$vbin/codegraph" ] \
  || fail "vendor stubs not installed"

# Excluded modes and non-TTY never invoke curl.
home=$(fresh_home tui-excluded)
curl_log="$work/curl-excluded.log"
: >"$curl_log"
for mode in -y --dry-run --uninstall; do
  tui_out=$(PROBE_CURL_LOG="$curl_log" tui_run_path "$home" "$curl_bin:$novendor" "$all_cmd $mode")
  if grep -Fq '[y/N]' <<<"$tui_out"; then fail "$mode must not show vendor prompts: $tui_out"; fi
done
env -u CLAUDE_CONFIG_DIR -u PI_CODING_AGENT_DIR HOME="$home" PATH="$curl_bin:$novendor" \
  bash "$root/install.sh" --runtime=all >"$work/all-nontty.out" 2>"$work/all-nontty.err" \
  || fail "non-tty --runtime=all failed: $(cat "$work/all-nontty.err")"
[ ! -s "$curl_log" ] || fail "excluded modes or non-tty called curl: $(cat "$curl_log")"
echo "install probe passed: tui-vendor"

echo "all install probe passed"
