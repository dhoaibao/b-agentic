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

# stock macOS has no GNU timeout; spawn the child in its own process group so a timeout kills descendants too
bounded() { # bounded <seconds> <command...>
  if command -v timeout >/dev/null 2>&1; then timeout -k 2 "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout -k 2 "$@"
  else perl -e '
    my $secs = shift;
    my $pid = fork();
    die "fork: $!\n" unless defined $pid;
    if ($pid == 0) {
      setpgrp(0, 0);
      exec @ARGV or die "exec: $!\n";
    }
    local $SIG{ALRM} = sub {
      kill "TERM", -$pid;
      select(undef, undef, undef, 0.2);
      kill "KILL", -$pid;
      waitpid($pid, 0);
      exit 124;
    };
    alarm $secs;
    waitpid($pid, 0);
    alarm 0;
    exit(($? & 127) ? 128 + ($? & 127) : ($? >> 8));
  ' "$@"
  fi
}

out="" err="" rc=0
run() {
  local home=$1
  shift
  rc=0
  out=$(bounded 30 env -u CLAUDE_CONFIG_DIR -u PI_CODING_AGENT_DIR PYTHONFAULTHANDLER=1 HOME="$home" PATH="$shims:$PATH" \
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
for assets in "$home/.claude/b-agentic" "$home/.pi/agent/b-agentic"; do
  grep -q '^# code object from .*__pycache__/b_run_lib.*\.pyc' <<<"$(HOME="$home" python3 -I -B -v "$assets/bin/b_run.py" schema spec 2>&1 >/dev/null)" \
    || fail "the CLI installed in $assets must load its installed bytecode"
done
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
[ ! -e "$home/.claude/b-agentic/bin" ] && [ ! -e "$home/.pi/agent/b-agentic/bin" ] \
  || fail "uninstall must leave no helper folder or __pycache__"

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

os.set_blocking(fd, False)
fd_open = True


def close_fd() -> None:
    global fd_open
    if fd_open:
        try:
            os.close(fd)
        except OSError:
            pass
        fd_open = False


def drain_fd() -> bytes:
    out = bytearray()
    while fd_open and len(out) < 65536:
        try:
            chunk = os.read(fd, 4096)
        except BlockingIOError:
            break
        except OSError:
            close_fd()
            break
        if not chunk:
            close_fd()
            break
        out.extend(chunk)
    return bytes(out)


buf, start, last, since = b"", time.time(), time.time(), b""
while fd_open and time.time() - last < 20 and time.time() - start < 45:
    ready, _, _ = select.select([fd], [], [], 0.3)
    if ready:
        chunk = drain_fd()
        if chunk:
            buf, since, last = buf + chunk, since + chunk, time.time()
    elif answers and time.time() - last > 0.5 and (b"[Y/n]" in since or b"[y/N]" in since or b"Enter confirms" in since):
        answer = answers.pop(0)
        if answer.startswith("!"):
            subprocess.run(answer[1:], shell=True, env=env, check=True, timeout=15)
            last = time.time()
        else:
            os.write(fd, (answer + "\n").encode())
            last, since = time.time(), b""
    elif not answers and time.time() - last > 3:
        break

deadline = time.time() + 15
child_status = None
while child_status is None:
    if fd_open:
        extra = drain_fd()
        if extra:
            buf += extra
    waited_pid, status = os.waitpid(pid, os.WNOHANG)
    if waited_pid != 0:
        child_status = status
        break
    if time.time() > deadline:
        close_fd()
        try:
            os.killpg(pid, signal.SIGKILL)
        except OSError:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        os.waitpid(pid, 0)
        sys.stderr.write("pty harness: command timed out; output so far:\n")
        sys.stderr.write(buf.decode(errors="replace") + "\n")
        sys.exit(1)
    time.sleep(0.1)
if fd_open:
    buf += drain_fd()
    close_fd()
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

# --- Cross-runtime alias refusal: shared symlink target across Claude Code and Pi -----------
shared="$work/shared-dotfiles.md"
printf '# shared user notes\n' >"$shared"
shared_before=$(sha256sum "$shared" | cut -d" " -f1)

# (a) install -y with CLAUDE.md and AGENTS.md both linked to the same dotfiles file.
home=$(fresh_home alias-install)
mkdir -p "$home/.claude" "$home/.pi/agent"
ln -s "$shared" "$home/.claude/CLAUDE.md"
ln -s "$shared" "$home/.pi/agent/AGENTS.md"
before=$(tree "$home")
run "$home" -y; expect_refused "cross-runtime alias on install -y"
grep -Fq 'Claude Code CLAUDE.md' <<<"$err" || fail "cross-runtime install error must name Claude Code CLAUDE.md: $err"
grep -Fq 'Pi AGENTS.md' <<<"$err" || fail "cross-runtime install error must name Pi AGENTS.md: $err"
[ "$before" = "$(tree "$home")" ] || fail "cross-runtime install refusal modified HOME tree"
[ "$shared_before" = "$(sha256sum "$shared" | cut -d" " -f1)" ] || fail "cross-runtime install refusal modified shared target"
[ ! -e "$home/.claude/b-agentic/install.json" ] && [ ! -e "$home/.pi/agent/b-agentic/install.json" ] \
  || fail "cross-runtime install refusal must write no manifest"

# (b) --uninstall after a clean install, then linking both kernel files to the same dotfiles file.
home=$(fresh_home alias-uninstall)
run "$home" -y; expect_ok "clean install before cross-runtime alias uninstall"
rm -f "$home/.claude/CLAUDE.md" "$home/.pi/agent/AGENTS.md"
ln -s "$shared" "$home/.claude/CLAUDE.md"
ln -s "$shared" "$home/.pi/agent/AGENTS.md"
before=$(tree "$home")
run "$home" --uninstall; expect_refused "cross-runtime alias on --uninstall"
grep -Fq 'Claude Code CLAUDE.md' <<<"$err" || fail "cross-runtime uninstall error must name Claude Code CLAUDE.md: $err"
grep -Fq 'Pi AGENTS.md' <<<"$err" || fail "cross-runtime uninstall error must name Pi AGENTS.md: $err"
[ "$before" = "$(tree "$home")" ] || fail "cross-runtime uninstall refusal modified HOME tree"
[ "$shared_before" = "$(sha256sum "$shared" | cut -d" " -f1)" ] || fail "cross-runtime uninstall refusal modified shared target"

# (c) interactive Proceed prompt: links created via ! before answering y must be caught by re-plan.
home=$(fresh_home alias-replan)
# shellcheck disable=SC2016
link_both="!mkdir -p \"\$HOME/.claude\" \"\$HOME/.pi/agent\" && ln -sf \"$shared\" \"\$HOME/.claude/CLAUDE.md\" && ln -sf \"$shared\" \"\$HOME/.pi/agent/AGENTS.md\""
tui_out=$(tui_run_refused "$home" "$shims:$PATH" "$all_cmd" "" "" "$link_both" y)
grep -Fq 'Claude Code CLAUDE.md' <<<"$tui_out" || fail "cross-runtime replan error must name Claude Code CLAUDE.md: $tui_out"
grep -Fq 'Pi AGENTS.md' <<<"$tui_out" || fail "cross-runtime replan error must name Pi AGENTS.md: $tui_out"
[ "$shared_before" = "$(sha256sum "$shared" | cut -d" " -f1)" ] || fail "cross-runtime replan refusal modified shared target"
[ "$(find "$home" \( -type f -o -type l \) | sort)" = "$(printf '%s\n%s\n' "$home/.claude/CLAUDE.md" "$home/.pi/agent/AGENTS.md")" ] \
  || fail "cross-runtime replan refusal wrote extra files under HOME"

# (d) single-manifest --uninstall: refuse when aliased in either direction, keep unaliased working.
home=$(fresh_home alias-uninstall-claude-only)
env -u CLAUDE_CONFIG_DIR -u PI_CODING_AGENT_DIR HOME="$home" PATH="$shims:$PATH" \
  bash "$root/install.sh" -y >/dev/null || fail "claude-only install failed"
mv "$home/.claude/CLAUDE.md" "$shared"
ln -s "$shared" "$home/.claude/CLAUDE.md"
mkdir -p "$home/.pi/agent"
ln -s "$shared" "$home/.pi/agent/AGENTS.md"
before=$(tree "$home")
shared_claude_before=$(sha256sum "$shared" | cut -d" " -f1)
run "$home" --uninstall; expect_refused "cross-runtime alias on claude-only --uninstall"
grep -Fq 'Claude Code CLAUDE.md' <<<"$err" || fail "claude-only alias uninstall must name Claude Code CLAUDE.md: $err"
grep -Fq 'Pi AGENTS.md' <<<"$err" || fail "claude-only alias uninstall must name Pi AGENTS.md: $err"
[ "$before" = "$(tree "$home")" ] || fail "claude-only alias uninstall refusal modified HOME tree"
[ "$shared_claude_before" = "$(sha256sum "$shared" | cut -d" " -f1)" ] || fail "claude-only alias uninstall modified shared target"

printf '# shared user notes\n' >"$shared"
home=$(fresh_home alias-uninstall-pi-only)
env -u CLAUDE_CONFIG_DIR -u PI_CODING_AGENT_DIR HOME="$home" PATH="$shims:$PATH" \
  bash "$root/install.sh" --runtime=pi -y >/dev/null || fail "pi-only install failed"
mv "$home/.pi/agent/AGENTS.md" "$shared"
ln -s "$shared" "$home/.pi/agent/AGENTS.md"
mkdir -p "$home/.claude"
ln -s "$shared" "$home/.claude/CLAUDE.md"
before=$(tree "$home")
shared_pi_before=$(sha256sum "$shared" | cut -d" " -f1)
run "$home" --uninstall; expect_refused "cross-runtime alias on pi-only --uninstall"
grep -Fq 'Claude Code CLAUDE.md' <<<"$err" || fail "pi-only alias uninstall must name Claude Code CLAUDE.md: $err"
grep -Fq 'Pi AGENTS.md' <<<"$err" || fail "pi-only alias uninstall must name Pi AGENTS.md: $err"
[ "$before" = "$(tree "$home")" ] || fail "pi-only alias uninstall refusal modified HOME tree"
[ "$shared_pi_before" = "$(sha256sum "$shared" | cut -d" " -f1)" ] || fail "pi-only alias uninstall modified shared target"

home=$(fresh_home uninstall-pi-only-clean)
env -u CLAUDE_CONFIG_DIR -u PI_CODING_AGENT_DIR HOME="$home" PATH="$shims:$PATH" \
  bash "$root/install.sh" --runtime=pi -y >/dev/null || fail "pi-only clean install failed"
run "$home" --uninstall; expect_ok "unaliased uninstall when only Pi installed"
[ ! -e "$home/.pi/agent/b-agentic/install.json" ] || fail "Pi must be uninstalled"
[ ! -e "$home/.claude" ] || fail "Claude dir must not be created when Claude had no manifest"

# (e) mixed-format alias (CLAUDE.md and Pi settings.json linked to Markdown file) before JSON parsing.
printf '# shared user notes\n' >"$shared"
home=$(fresh_home alias-mixed-install)
mkdir -p "$home/.claude" "$home/.pi/agent"
ln -s "$shared" "$home/.claude/CLAUDE.md"
ln -s "$shared" "$home/.pi/agent/settings.json"
before=$(tree "$home")
run "$home" -y; expect_refused "mixed-format cross-runtime alias on install -y"
grep -Fq 'Claude Code CLAUDE.md' <<<"$err" || fail "mixed-format install error must name Claude Code CLAUDE.md: $err"
grep -Fq 'Pi settings.json' <<<"$err" || fail "mixed-format install error must name Pi settings.json: $err"
[ "$before" = "$(tree "$home")" ] || fail "mixed-format install refusal modified HOME tree"
[ "$shared_before" = "$(sha256sum "$shared" | cut -d" " -f1)" ] || fail "mixed-format install refusal modified shared target"

home=$(fresh_home alias-mixed-uninstall)
run "$home" -y; expect_ok "clean install before mixed-format uninstall"
rm -f "$home/.claude/CLAUDE.md" "$home/.pi/agent/settings.json"
ln -s "$shared" "$home/.claude/CLAUDE.md"
ln -s "$shared" "$home/.pi/agent/settings.json"
before=$(tree "$home")
run "$home" --uninstall; expect_refused "mixed-format cross-runtime alias on --uninstall"
grep -Fq 'Claude Code CLAUDE.md' <<<"$err" || fail "mixed-format uninstall error must name Claude Code CLAUDE.md: $err"
grep -Fq 'Pi settings.json' <<<"$err" || fail "mixed-format uninstall error must name Pi settings.json: $err"
[ "$before" = "$(tree "$home")" ] || fail "mixed-format uninstall refusal modified HOME tree"
[ "$shared_before" = "$(sha256sum "$shared" | cut -d" " -f1)" ] || fail "mixed-format uninstall refusal modified shared target"

home=$(fresh_home alias-mixed-replan)
# shellcheck disable=SC2016
link_mixed="!mkdir -p \"\$HOME/.claude\" \"\$HOME/.pi/agent\" && ln -sf \"$shared\" \"\$HOME/.claude/CLAUDE.md\" && ln -sf \"$shared\" \"\$HOME/.pi/agent/settings.json\""
tui_out=$(tui_run_refused "$home" "$shims:$PATH" "$all_cmd" "" "" "$link_mixed" y)
grep -Fq 'Claude Code CLAUDE.md' <<<"$tui_out" || fail "mixed-format replan error must name Claude Code CLAUDE.md: $tui_out"
grep -Fq 'Pi settings.json' <<<"$tui_out" || fail "mixed-format replan error must name Pi settings.json: $tui_out"
[ "$shared_before" = "$(sha256sum "$shared" | cut -d" " -f1)" ] || fail "mixed-format replan refusal modified shared target"
[ "$(find "$home" \( -type f -o -type l \) | sort)" = "$(printf '%s\n%s\n' "$home/.claude/CLAUDE.md" "$home/.pi/agent/settings.json")" ] \
  || fail "mixed-format replan refusal wrote extra files under HOME"

# (f) config hard-linked to opposite-runtime managed payload (Claude settings.json <-> Pi skills/b-review/SKILL.md).
for mode in install uninstall; do
  home=$(fresh_home "alias-payload-config-$mode")
  run "$home" -y; expect_ok "clean install before payload config $mode"
  ln -f "$home/.pi/agent/skills/b-review/SKILL.md" "$home/.claude/settings.json"
  before=$(tree "$home")
  inode_before=$(sha256sum "$home/.pi/agent/skills/b-review/SKILL.md" | cut -d" " -f1)
  if [ "$mode" = "install" ]; then
    run "$home" -y; expect_refused "config-to-payload hard link on install -y"
  else
    run "$home" --uninstall; expect_refused "config-to-payload hard link on --uninstall"
  fi
  grep -Fq 'Claude Code settings.json' <<<"$err" || fail "payload-config $mode error must name Claude Code settings.json: $err"
  grep -Fq 'Pi skills/b-review/SKILL.md' <<<"$err" || fail "payload-config $mode error must name Pi skills/b-review/SKILL.md: $err"
  [ "$before" = "$(tree "$home")" ] || fail "payload-config $mode refusal modified HOME tree"
  [ "$inode_before" = "$(sha256sum "$home/.pi/agent/skills/b-review/SKILL.md" | cut -d" " -f1)" ] \
    || fail "payload-config $mode refusal modified shared inode"
done

home=$(fresh_home alias-payload-config-replan)
run "$home" -y; expect_ok "clean install before payload config replan"
# shellcheck disable=SC2016
link_payload_cfg="!ln -f \"\$HOME/.pi/agent/skills/b-review/SKILL.md\" \"\$HOME/.claude/settings.json\" && (cd \"\$HOME\" && find . \\( -type f -o -type l \\) -not -path '*/b-agentic/backups/*' -print0 | sort -z | xargs -0 sha256sum >\"$work/replan-cfg.tree\")"
inode_before=$(sha256sum "$home/.pi/agent/skills/b-review/SKILL.md" | cut -d" " -f1)
tui_out=$(tui_run_refused "$home" "$shims:$PATH" "$all_cmd" "" "" "$link_payload_cfg" y)
grep -Fq 'Claude Code settings.json' <<<"$tui_out" || fail "payload-config replan error must name Claude Code settings.json: $tui_out"
grep -Fq 'Pi skills/b-review/SKILL.md' <<<"$tui_out" || fail "payload-config replan error must name Pi skills/b-review/SKILL.md: $tui_out"
after=$(cd "$home" && find . \( -type f -o -type l \) -not -path '*/b-agentic/backups/*' -print0 | sort -z | xargs -0 sha256sum)
[ "$(cat "$work/replan-cfg.tree")" = "$after" ] || fail "payload-config replan refusal modified HOME tree"
[ "$inode_before" = "$(sha256sum "$home/.pi/agent/skills/b-review/SKILL.md" | cut -d" " -f1)" ] \
  || fail "payload-config replan refusal modified shared inode"

# (g) manifest hard-linked to opposite-runtime managed payload (Claude install.json <-> Pi skills/b-review/SKILL.md).
for mode in install uninstall; do
  home=$(fresh_home "alias-payload-manifest-$mode")
  run "$home" -y; expect_ok "clean install before payload manifest $mode"
  ln -f "$home/.pi/agent/skills/b-review/SKILL.md" "$home/.claude/b-agentic/install.json"
  before=$(tree "$home")
  inode_before=$(sha256sum "$home/.pi/agent/skills/b-review/SKILL.md" | cut -d" " -f1)
  if [ "$mode" = "install" ]; then
    run "$home" -y; expect_refused "manifest-to-payload hard link on install -y"
  else
    run "$home" --uninstall; expect_refused "manifest-to-payload hard link on --uninstall"
  fi
  grep -Fq 'Claude Code the install manifest' <<<"$err" || fail "payload-manifest $mode error must name Claude Code the install manifest: $err"
  grep -Fq 'Pi skills/b-review/SKILL.md' <<<"$err" || fail "payload-manifest $mode error must name Pi skills/b-review/SKILL.md: $err"
  [ "$before" = "$(tree "$home")" ] || fail "payload-manifest $mode refusal modified HOME tree"
  [ "$inode_before" = "$(sha256sum "$home/.pi/agent/skills/b-review/SKILL.md" | cut -d" " -f1)" ] \
    || fail "payload-manifest $mode refusal modified shared inode"
done

home=$(fresh_home alias-payload-manifest-replan)
run "$home" -y; expect_ok "clean install before payload manifest replan"
# shellcheck disable=SC2016
link_payload_manifest="!ln -f \"\$HOME/.pi/agent/skills/b-review/SKILL.md\" \"\$HOME/.claude/b-agentic/install.json\" && (cd \"\$HOME\" && find . \\( -type f -o -type l \\) -not -path '*/b-agentic/backups/*' -print0 | sort -z | xargs -0 sha256sum >\"$work/replan-manifest.tree\")"
inode_before=$(sha256sum "$home/.pi/agent/skills/b-review/SKILL.md" | cut -d" " -f1)
tui_out=$(tui_run_refused "$home" "$shims:$PATH" "$all_cmd" "" "" "$link_payload_manifest" y)
grep -Fq 'Claude Code the install manifest' <<<"$tui_out" || fail "payload-manifest replan error must name Claude Code the install manifest: $tui_out"
grep -Fq 'Pi skills/b-review/SKILL.md' <<<"$tui_out" || fail "payload-manifest replan error must name Pi skills/b-review/SKILL.md: $tui_out"
after=$(cd "$home" && find . \( -type f -o -type l \) -not -path '*/b-agentic/backups/*' -print0 | sort -z | xargs -0 sha256sum)
[ "$(cat "$work/replan-manifest.tree")" = "$after" ] || fail "payload-manifest replan refusal modified HOME tree"
[ "$inode_before" = "$(sha256sum "$home/.pi/agent/skills/b-review/SKILL.md" | cut -d" " -f1)" ] \
  || fail "payload-manifest replan refusal modified shared inode"

# (h) direct cross-root symlinks in both directions across install, uninstall, and replan (R3-1).
for dir_case in claude-to-pi pi-to-claude; do
  home=$(fresh_home "alias-direct-install-$dir_case")
  mkdir -p "$home/.claude" "$home/.pi/agent"
  if [ "$dir_case" = "claude-to-pi" ]; then
    ln -s "$home/.pi/agent/AGENTS.md" "$home/.claude/CLAUDE.md"
  else
    ln -s "$home/.claude/CLAUDE.md" "$home/.pi/agent/AGENTS.md"
  fi
  before=$(tree "$home")
  run "$home" -y; expect_refused "direct cross-root symlink $dir_case on install -y"
  grep -Fq 'Claude Code CLAUDE.md' <<<"$err" || fail "direct $dir_case install error must name Claude Code CLAUDE.md: $err"
  grep -Fq 'Pi AGENTS.md' <<<"$err" || fail "direct $dir_case install error must name Pi AGENTS.md: $err"
  [ "$before" = "$(tree "$home")" ] || fail "direct $dir_case install refusal modified HOME tree"

  home=$(fresh_home "alias-direct-uninstall-$dir_case")
  run "$home" -y; expect_ok "clean install before direct $dir_case uninstall"
  if [ "$dir_case" = "claude-to-pi" ]; then
    rm -f "$home/.claude/CLAUDE.md"
    ln -s "$home/.pi/agent/AGENTS.md" "$home/.claude/CLAUDE.md"
  else
    rm -f "$home/.pi/agent/AGENTS.md"
    ln -s "$home/.claude/CLAUDE.md" "$home/.pi/agent/AGENTS.md"
  fi
  before=$(tree "$home")
  target_before=$(sha256sum "$home/.claude/CLAUDE.md" 2>/dev/null || sha256sum "$home/.pi/agent/AGENTS.md")
  run "$home" --uninstall; expect_refused "direct cross-root symlink $dir_case on --uninstall"
  grep -Fq 'Claude Code CLAUDE.md' <<<"$err" || fail "direct $dir_case uninstall error must name Claude Code CLAUDE.md: $err"
  grep -Fq 'Pi AGENTS.md' <<<"$err" || fail "direct $dir_case uninstall error must name Pi AGENTS.md: $err"
  [ "$before" = "$(tree "$home")" ] || fail "direct $dir_case uninstall refusal modified HOME tree"
  target_after=$(sha256sum "$home/.claude/CLAUDE.md" 2>/dev/null || sha256sum "$home/.pi/agent/AGENTS.md")
  [ "$target_before" = "$target_after" ] || fail "direct $dir_case uninstall modified target"

  home=$(fresh_home "alias-direct-replan-$dir_case")
  if [ "$dir_case" = "claude-to-pi" ]; then
    # shellcheck disable=SC2016
    link_direct="!mkdir -p \"\$HOME/.claude\" \"\$HOME/.pi/agent\" && ln -sf \"\$HOME/.pi/agent/AGENTS.md\" \"\$HOME/.claude/CLAUDE.md\" && (cd \"\$HOME\" && find . \\( -type f -o -type l \\) -print0 | sort -z | xargs -0 -r sh -c 'for f; do if [ -L \"\$f\" ]; then printf \"link %s -> %s\\n\" \"\$f\" \"\$(readlink \"\$f\")\"; else sha256sum \"\$f\"; fi; done' _ >\"$work/direct-$dir_case.tree\")"
  else
    # shellcheck disable=SC2016
    link_direct="!mkdir -p \"\$HOME/.claude\" \"\$HOME/.pi/agent\" && ln -sf \"\$HOME/.claude/CLAUDE.md\" \"\$HOME/.pi/agent/AGENTS.md\" && (cd \"\$HOME\" && find . \\( -type f -o -type l \\) -print0 | sort -z | xargs -0 -r sh -c 'for f; do if [ -L \"\$f\" ]; then printf \"link %s -> %s\\n\" \"\$f\" \"\$(readlink \"\$f\")\"; else sha256sum \"\$f\"; fi; done' _ >\"$work/direct-$dir_case.tree\")"
  fi
  tui_out=$(tui_run_refused "$home" "$shims:$PATH" "$all_cmd" "" "" "$link_direct" y)
  grep -Fq 'Claude Code CLAUDE.md' <<<"$tui_out" || fail "direct $dir_case replan error must name Claude Code CLAUDE.md: $tui_out"
  grep -Fq 'Pi AGENTS.md' <<<"$tui_out" || fail "direct $dir_case replan error must name Pi AGENTS.md: $tui_out"
  [ "$(cat "$work/direct-$dir_case.tree")" = "$(tree "$home")" ] || fail "direct $dir_case replan refusal modified HOME tree"
done

# (i) intra-runtime duplicate sharing a target with the other runtime reports cross-runtime pair first (R3-1).
printf '# shared user notes\n' >"$shared"
shared_before=$(sha256sum "$shared" | cut -d" " -f1)

home=$(fresh_home alias-dup-install)
mkdir -p "$home/.claude" "$home/.pi/agent"
ln -s "$shared" "$home/.claude/CLAUDE.md"
ln -s "$shared" "$home/.claude/settings.json"
ln -s "$shared" "$home/.pi/agent/AGENTS.md"
before=$(tree "$home")
run "$home" -y; expect_refused "local duplicate + cross-runtime alias on install -y"
grep -Fq 'Claude Code CLAUDE.md' <<<"$err" || fail "dup+cross install must name Claude Code CLAUDE.md: $err"
grep -Fq 'Pi AGENTS.md' <<<"$err" || fail "dup+cross install must name Pi AGENTS.md: $err"
[ "$before" = "$(tree "$home")" ] || fail "dup+cross install refusal modified HOME tree"
[ "$shared_before" = "$(sha256sum "$shared" | cut -d" " -f1)" ] || fail "dup+cross install modified shared target"

home=$(fresh_home alias-dup-uninstall)
run "$home" -y; expect_ok "clean install before dup+cross uninstall"
rm -f "$home/.claude/CLAUDE.md" "$home/.claude/settings.json" "$home/.pi/agent/AGENTS.md"
ln -s "$shared" "$home/.claude/CLAUDE.md"
ln -s "$shared" "$home/.claude/settings.json"
ln -s "$shared" "$home/.pi/agent/AGENTS.md"
before=$(tree "$home")
run "$home" --uninstall; expect_refused "local duplicate + cross-runtime alias on --uninstall"
grep -Fq 'Claude Code CLAUDE.md' <<<"$err" || fail "dup+cross uninstall must name Claude Code CLAUDE.md: $err"
grep -Fq 'Pi AGENTS.md' <<<"$err" || fail "dup+cross uninstall must name Pi AGENTS.md: $err"
[ "$before" = "$(tree "$home")" ] || fail "dup+cross uninstall refusal modified HOME tree"
[ "$shared_before" = "$(sha256sum "$shared" | cut -d" " -f1)" ] || fail "dup+cross uninstall modified shared target"

home=$(fresh_home alias-dup-replan)
# shellcheck disable=SC2016
link_dup="!mkdir -p \"\$HOME/.claude\" \"\$HOME/.pi/agent\" && ln -sf \"$shared\" \"\$HOME/.claude/CLAUDE.md\" && ln -sf \"$shared\" \"\$HOME/.claude/settings.json\" && ln -sf \"$shared\" \"\$HOME/.pi/agent/AGENTS.md\" && (cd \"\$HOME\" && find . \\( -type f -o -type l \\) -print0 | sort -z | xargs -0 -r sh -c 'for f; do if [ -L \"\$f\" ]; then printf \"link %s -> %s\\n\" \"\$f\" \"\$(readlink \"\$f\")\"; else sha256sum \"\$f\"; fi; done' _ >\"$work/dup-replan.tree\")"
tui_out=$(tui_run_refused "$home" "$shims:$PATH" "$all_cmd" "" "" "$link_dup" y)
grep -Fq 'Claude Code CLAUDE.md' <<<"$tui_out" || fail "dup+cross replan must name Claude Code CLAUDE.md: $tui_out"
grep -Fq 'Pi AGENTS.md' <<<"$tui_out" || fail "dup+cross replan must name Pi AGENTS.md: $tui_out"
[ "$(cat "$work/dup-replan.tree")" = "$(tree "$home")" ] || fail "dup+cross replan refusal modified HOME tree"
[ "$shared_before" = "$(sha256sum "$shared" | cut -d" " -f1)" ] || fail "dup+cross replan modified shared target"

# (j) manifest-free uninstall and --without exclusions ignore unowned hard-linked user files (R3-2).
home=$(fresh_home unowned-uninstall)
mkdir -p "$home/.claude/skills/b-plan" "$home/.claude/skills/b-review" \
         "$home/.pi/agent/skills/b-plan" "$home/.pi/agent/skills/b-review"
printf '# user claude plan\n' >"$home/.claude/skills/b-plan/SKILL.md"
ln -f "$home/.claude/skills/b-plan/SKILL.md" "$home/.claude/skills/b-review/SKILL.md"
printf '# user pi plan\n' >"$home/.pi/agent/skills/b-plan/SKILL.md"
ln -f "$home/.pi/agent/skills/b-plan/SKILL.md" "$home/.pi/agent/skills/b-review/SKILL.md"
before=$(tree "$home")
run "$home" --uninstall; expect_ok "manifest-free uninstall with hard-linked user skills"
[ "$before" = "$(tree "$home")" ] || fail "manifest-free uninstall modified user files"

home=$(fresh_home excluded-install)
mkdir -p "$home/.claude/skills/b-drawio" "$home/.claude/skills/b-plan" \
         "$home/.pi/agent/skills/b-drawio"
printf '# user claude drawio\n' >"$home/.claude/skills/b-drawio/SKILL.md"
ln -f "$home/.claude/skills/b-drawio/SKILL.md" "$home/.claude/skills/b-plan/SKILL.md"
ln -f "$home/.claude/skills/b-drawio/SKILL.md" "$home/.pi/agent/skills/b-drawio/SKILL.md"
run "$home" -y --without=drawio; expect_ok "install with --without=drawio and unowned hard-linked drawio files"
[ -f "$home/.claude/b-agentic/install.json" ] && [ -f "$home/.pi/agent/b-agentic/install.json" ] \
  || fail "--without=drawio install missing manifests"

home=$(fresh_home excluded-replan)
stub_bin="$work/stub-excluded"
mkdir -p "$stub_bin"
cp "$shims/pi" "$stub_bin/pi"
for tool in claude rtk codegraph; do
  printf '#!/bin/sh\nexit 0\n' >"$stub_bin/$tool"
done
chmod +x "$stub_bin"/*
# shellcheck disable=SC2016
link_excluded='!mkdir -p "$HOME/.claude/skills/b-drawio" "$HOME/.claude/skills/b-plan" "$HOME/.pi/agent/skills/b-drawio" && printf "# user drawio\n" >"$HOME/.claude/skills/b-drawio/SKILL.md" && ln -f "$HOME/.claude/skills/b-drawio/SKILL.md" "$HOME/.claude/skills/b-plan/SKILL.md" && ln -f "$HOME/.claude/skills/b-drawio/SKILL.md" "$HOME/.pi/agent/skills/b-drawio/SKILL.md"'
tui_out=$(tui_run_path "$home" "$stub_bin:$novendor" "$all_cmd --without=drawio" "$link_excluded" y n)
[ -f "$home/.claude/b-agentic/install.json" ] && [ -f "$home/.pi/agent/b-agentic/install.json" ] \
  || fail "--without=drawio replan must succeed: $tui_out"

# (k) constructor MCP-file link (~/.claude.json -> ~/.pi/agent/settings.json) on install and uninstall (R4-1).
home=$(fresh_home alias-mcp-install)
mkdir -p "$home/.pi/agent"
printf '{}\n' >"$home/.pi/agent/settings.json"
ln -s "$home/.pi/agent/settings.json" "$home/.claude.json"
before=$(tree "$home")
run "$home" -y; expect_refused ".claude.json -> Pi settings.json on install -y"
grep -Fq 'Claude Code .claude.json' <<<"$err" || fail "mcp-link install must name Claude Code .claude.json: $err"
grep -Fq 'Pi settings.json' <<<"$err" || fail "mcp-link install must name Pi settings.json: $err"
[ "$before" = "$(tree "$home")" ] || fail "mcp-link install refusal modified HOME tree"

home=$(fresh_home alias-mcp-uninstall)
run "$home" -y; expect_ok "clean install before mcp-link uninstall"
rm -f "$home/.claude.json"
ln -s "$home/.pi/agent/settings.json" "$home/.claude.json"
before=$(tree "$home")
run "$home" --uninstall; expect_refused ".claude.json -> Pi settings.json on --uninstall"
grep -Fq 'Claude Code .claude.json' <<<"$err" || fail "mcp-link uninstall must name Claude Code .claude.json: $err"
grep -Fq 'Pi settings.json' <<<"$err" || fail "mcp-link uninstall must name Pi settings.json: $err"
[ "$before" = "$(tree "$home")" ] || fail "mcp-link uninstall refusal modified HOME tree"

# (l) symlinked runtime roots in both directions on install and uninstall (R4-1).
for dir_case in claude-root-to-pi pi-root-to-claude; do
  for mode in install uninstall; do
    home=$(fresh_home "alias-root-$dir_case-$mode")
    if [ "$dir_case" = "claude-root-to-pi" ]; then
      mkdir -p "$home/.pi/agent"
      ln -s "$home/.pi/agent" "$home/.claude"
    else
      mkdir -p "$home/.claude" "$home/.pi"
      ln -s "$home/.claude" "$home/.pi/agent"
    fi
    before=$(tree "$home")
    if [ "$mode" = "install" ]; then
      run "$home" -y; expect_refused "symlinked root $dir_case on install -y"
    else
      run "$home" --uninstall; expect_refused "symlinked root $dir_case on --uninstall"
    fi
    grep -Fq 'Claude Code ' <<<"$err" || fail "root-link $dir_case $mode must name Claude Code destination: $err"
    grep -Fq 'Pi ' <<<"$err" || fail "root-link $dir_case $mode must name Pi destination: $err"
    [ "$before" = "$(tree "$home")" ] || fail "root-link $dir_case $mode refusal modified HOME tree"
  done
done

echo "install probe: cross-runtime-alias (m)-(p)"
# (m) FIFO at install.json never blocks; known config alias still names both runtimes (R4-2).
for runtime_dir in ".claude" ".pi/agent"; do
  for mode in install uninstall; do
    home=$(fresh_home "fifo-${runtime_dir//\//-}-$mode")
    mkdir -p "$home/$runtime_dir/b-agentic"
    mkfifo "$home/$runtime_dir/b-agentic/install.json"
    rc=0
    if [ "$mode" = "install" ]; then
      out=$(bounded 5 env -u CLAUDE_CONFIG_DIR -u PI_CODING_AGENT_DIR HOME="$home" PATH="$shims:$PATH" \
        bash "$root/install.sh" --runtime=all -y 2>"$work/stderr") || rc=$?
    else
      out=$(bounded 5 env -u CLAUDE_CONFIG_DIR -u PI_CODING_AGENT_DIR HOME="$home" PATH="$shims:$PATH" \
        bash "$root/install.sh" --runtime=all --uninstall 2>"$work/stderr") || rc=$?
    fi
    err=$(cat "$work/stderr")
    [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ "$rc" -ne 142 ] || fail "FIFO manifest $runtime_dir $mode exited $rc (124/142=hang): $err"
    grep -Fq 'must be a regular file' <<<"$err" || fail "FIFO manifest $runtime_dir $mode error: $err"

    # With a known config alias, the cross-runtime diagnostic wins without hanging on the FIFO.
    mkdir -p "$home/.claude" "$home/.pi/agent"
    ln -sf "$shared" "$home/.claude/CLAUDE.md"
    ln -sf "$shared" "$home/.pi/agent/AGENTS.md"
    rc=0
    if [ "$mode" = "install" ]; then
      out=$(bounded 5 env -u CLAUDE_CONFIG_DIR -u PI_CODING_AGENT_DIR HOME="$home" PATH="$shims:$PATH" \
        bash "$root/install.sh" --runtime=all -y 2>"$work/stderr") || rc=$?
    else
      out=$(bounded 5 env -u CLAUDE_CONFIG_DIR -u PI_CODING_AGENT_DIR HOME="$home" PATH="$shims:$PATH" \
        bash "$root/install.sh" --runtime=all --uninstall 2>"$work/stderr") || rc=$?
    fi
    err=$(cat "$work/stderr")
    [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ "$rc" -ne 142 ] || fail "FIFO+alias $runtime_dir $mode exited $rc (124/142=hang): $err"
    grep -Fq 'Claude Code CLAUDE.md' <<<"$err" || fail "FIFO+alias $runtime_dir $mode must name Claude Code CLAUDE.md: $err"
    grep -Fq 'Pi AGENTS.md' <<<"$err" || fail "FIFO+alias $runtime_dir $mode must name Pi AGENTS.md: $err"
  done
done

# (n) symlinked b-agentic directory is never read through; known config alias still names both runtimes (R4-2).
outside_bag="$work/outside-bagentic"
mkdir -p "$outside_bag"
printf '{outside-not-json\n' >"$outside_bag/install.json"
for runtime_dir in ".claude" ".pi/agent"; do
  for mode in install uninstall; do
    home=$(fresh_home "symdir-${runtime_dir//\//-}-$mode")
    mkdir -p "$home/$runtime_dir"
    ln -s "$outside_bag" "$home/$runtime_dir/b-agentic"
    if [ "$mode" = "install" ]; then
      run "$home" -y; expect_refused "symlinked b-agentic dir $runtime_dir $mode"
    else
      run "$home" --uninstall; expect_refused "symlinked b-agentic dir $runtime_dir $mode"
    fi
    grep -Fq 'is a symlink' <<<"$err" || fail "symlinked b-agentic $runtime_dir $mode must refuse symlink, not parse outside JSON: $err"

    mkdir -p "$home/.claude" "$home/.pi/agent"
    ln -sf "$shared" "$home/.claude/CLAUDE.md"
    ln -sf "$shared" "$home/.pi/agent/AGENTS.md"
    if [ "$mode" = "install" ]; then
      run "$home" -y; expect_refused "symlinked b-agentic+alias $runtime_dir $mode"
    else
      run "$home" --uninstall; expect_refused "symlinked b-agentic+alias $runtime_dir $mode"
    fi
    grep -Fq 'Claude Code CLAUDE.md' <<<"$err" || fail "symdir+alias $runtime_dir $mode must name Claude Code CLAUDE.md: $err"
    grep -Fq 'Pi AGENTS.md' <<<"$err" || fail "symdir+alias $runtime_dir $mode must name Pi AGENTS.md: $err"
  done
done

# (o) interactive install allows deselecting unowned hard-linked drawio skills recorded as selected (R4-3).
home=$(fresh_home interactive-deselect-unowned)
mkdir -p "$home/.claude/skills/b-drawio" "$home/.pi/agent/skills/b-drawio"
printf '# pre-existing unowned claude drawio\n' >"$home/.claude/skills/b-drawio/SKILL.md"
printf '# pre-existing unowned pi drawio\n' >"$home/.pi/agent/skills/b-drawio/SKILL.md"
env -u CLAUDE_CONFIG_DIR -u PI_CODING_AGENT_DIR HOME="$home" PATH="$stub_bin:$novendor" \
  bash "$root/install.sh" --runtime=all -y --with=drawio >/dev/null || fail "seed unowned drawio install failed"
ln -f "$home/.claude/skills/b-drawio/SKILL.md" "$home/.pi/agent/skills/b-drawio/SKILL.md"
[ "$(jq -r '.optional_components.drawio' "$home/.claude/b-agentic/install.json")" = true ] || fail "Claude manifest should record drawio=true"
[ "$(jq -r '.files | has("skills/b-drawio/SKILL.md")' "$home/.claude/b-agentic/install.json")" = false ] || fail "Claude unowned drawio should not be in files"
[ "$(jq -r '.optional_components.drawio' "$home/.pi/agent/b-agentic/install.json")" = true ] || fail "Pi manifest should record drawio=true"
[ "$(jq -r '.files | has("skills/b-drawio/SKILL.md")' "$home/.pi/agent/b-agentic/install.json")" = false ] || fail "Pi unowned drawio should not be in files"
tui_out=$(tui_run_path "$home" "$stub_bin:$novendor" "$all_cmd" "jj " "jj " y n)
[ "$(jq -r '.optional_components.drawio' "$home/.claude/b-agentic/install.json")" = false ] || fail "Claude drawio must be deselected: $tui_out"
[ "$(jq -r '.optional_components.drawio' "$home/.pi/agent/b-agentic/install.json")" = false ] || fail "Pi drawio must be deselected: $tui_out"

# (p) interactive install selecting two unselected Claude optional skills hard-linked to Pi AGENTS.md names cross-runtime alias (R4-3).
home=$(fresh_home interactive-select-alias)
mkdir -p "$home/.claude/skills/b-excalidraw" "$home/.claude/skills/b-drawio" "$home/.pi/agent"
printf '# shared pi agents\n' >"$home/.pi/agent/AGENTS.md"
ln -f "$home/.pi/agent/AGENTS.md" "$home/.claude/skills/b-excalidraw/SKILL.md"
ln -f "$home/.pi/agent/AGENTS.md" "$home/.claude/skills/b-drawio/SKILL.md"
before=$(tree "$home")
inode_before=$(sha256sum "$home/.pi/agent/AGENTS.md" | cut -d" " -f1)
tui_out=$(tui_run_refused "$home" "$stub_bin:$novendor" "$all_cmd" "j j " "")
grep -Fq 'Claude Code skills/' <<<"$tui_out" || fail "selected-alias error must name Claude Code skill path: $tui_out"
grep -Fq 'Pi AGENTS.md' <<<"$tui_out" || fail "selected-alias error must name Pi AGENTS.md: $tui_out"
[ "$before" = "$(tree "$home")" ] || fail "selected-alias refusal modified HOME tree"
[ "$inode_before" = "$(sha256sum "$home/.pi/agent/AGENTS.md" | cut -d" " -f1)" ] || fail "selected-alias refusal modified shared inode"

echo "install probe: cross-runtime-alias (q)-(t)"
# (q) constructor/preflight/manifest checks do not mask payload aliases (R5-1).
home=$(fresh_home alias-mcp-fresh-payload)
mkdir -p "$home/.pi/agent/skills/b-review"
ln -s "$home/.pi/agent/skills/b-review/SKILL.md" "$home/.claude.json"
before=$(tree "$home")
run "$home" -y; expect_refused ".claude.json -> Pi b-review SKILL.md on fresh install -y"
grep -Fq 'Claude Code .claude.json' <<<"$err" || fail "fresh mcp->payload must name Claude Code .claude.json: $err"
grep -Fq 'Pi skills/b-review/SKILL.md' <<<"$err" || fail "fresh mcp->payload must name Pi skills/b-review/SKILL.md: $err"
[ "$before" = "$(tree "$home")" ] || fail "fresh mcp->payload refusal modified HOME tree"

home=$(fresh_home alias-mcp-uninstall-payload)
run "$home" -y; expect_ok "clean install before mcp->payload uninstall"
rm -f "$home/.claude.json"
ln -s "$home/.pi/agent/skills/b-review/SKILL.md" "$home/.claude.json"
before=$(tree "$home")
run "$home" --uninstall; expect_refused ".claude.json -> Pi b-review SKILL.md on --uninstall"
grep -Fq 'Claude Code .claude.json' <<<"$err" || fail "uninstall mcp->payload must name Claude Code .claude.json: $err"
grep -Fq 'Pi skills/b-review/SKILL.md' <<<"$err" || fail "uninstall mcp->payload must name Pi skills/b-review/SKILL.md: $err"
[ "$before" = "$(tree "$home")" ] || fail "uninstall mcp->payload refusal modified HOME tree"

home=$(fresh_home alias-cfg-fresh-payload-claude)
mkdir -p "$home/.claude" "$home/.pi/agent/skills/b-review"
ln -s "$home/.pi/agent/skills/b-review/SKILL.md" "$home/.claude/CLAUDE.md"
before=$(tree "$home")
run "$home" -y; expect_refused "CLAUDE.md -> Pi b-review SKILL.md on fresh install -y"
grep -Fq 'Claude Code CLAUDE.md' <<<"$err" || fail "fresh CLAUDE.md->payload must name Claude Code CLAUDE.md: $err"
grep -Fq 'Pi skills/b-review/SKILL.md' <<<"$err" || fail "fresh CLAUDE.md->payload must name Pi skills/b-review/SKILL.md: $err"
[ "$before" = "$(tree "$home")" ] || fail "fresh CLAUDE.md->payload refusal modified HOME tree"

home=$(fresh_home alias-cfg-fresh-payload-pi)
mkdir -p "$home/.claude/skills/b-review" "$home/.pi/agent"
ln -s "$home/.claude/skills/b-review/SKILL.md" "$home/.pi/agent/AGENTS.md"
before=$(tree "$home")
run "$home" -y; expect_refused "AGENTS.md -> Claude b-review SKILL.md on fresh install -y"
grep -Fq 'Claude Code skills/b-review/SKILL.md' <<<"$err" || fail "fresh AGENTS.md->payload must name Claude Code skills/b-review/SKILL.md: $err"
grep -Fq 'Pi AGENTS.md' <<<"$err" || fail "fresh AGENTS.md->payload must name Pi AGENTS.md: $err"
[ "$before" = "$(tree "$home")" ] || fail "fresh AGENTS.md->payload refusal modified HOME tree"

home=$(fresh_home alias-manifest-fresh-payload)
mkdir -p "$home/.claude/b-agentic" "$home/.pi/agent/skills/b-review"
printf '# not json\n' >"$home/.pi/agent/skills/b-review/SKILL.md"
ln -f "$home/.pi/agent/skills/b-review/SKILL.md" "$home/.claude/b-agentic/install.json"
before=$(tree "$home")
run "$home" -y; expect_refused "manifest hard-linked to fresh Pi payload on install -y"
grep -Fq 'Claude Code the install manifest' <<<"$err" || fail "fresh manifest->payload must name Claude Code the install manifest: $err"
grep -Fq 'Pi skills/b-review/SKILL.md' <<<"$err" || fail "fresh manifest->payload must name Pi skills/b-review/SKILL.md: $err"
[ "$before" = "$(tree "$home")" ] || fail "fresh manifest->payload refusal modified HOME tree"

home=$(fresh_home alias-manifest-badutf8-replan)
# shellcheck disable=SC2016
link_badutf8='!mkdir -p "$HOME/.claude/b-agentic" "$HOME/.pi/agent/skills/b-review" && python3 -c "import os; open(os.path.expanduser(\"~/.pi/agent/skills/b-review/SKILL.md\"), \"wb\").write(b\"\\xff\\xfeinvalid\")" && ln -f "$HOME/.pi/agent/skills/b-review/SKILL.md" "$HOME/.claude/b-agentic/install.json"'
tui_out=$(tui_run_refused "$home" "$stub_bin:$novendor" "$all_cmd" "" "" "$link_badutf8" y)
grep -Fq 'Claude Code the install manifest' <<<"$tui_out" || fail "bad-utf8 replan must name Claude Code the install manifest: $tui_out"
grep -Fq 'Pi skills/b-review/SKILL.md' <<<"$tui_out" || fail "bad-utf8 replan must name Pi skills/b-review/SKILL.md: $tui_out"

# (r) Proceed-prompt ancestor redirects (~/.pi -> ~/.claude and ~/.pi/agent -> ~/.claude/pi-agent) refuse protected paths without reading sentinel JSON (R5-2).
home=$(fresh_home replan-protected-ancestor)
# shellcheck disable=SC2016
swap_pi='!mkdir -p "$HOME/.claude/agent/b-agentic" && printf "{sentinel-not-json\n" >"$HOME/.claude/agent/b-agentic/install.json" && ln -s "$HOME/.claude" "$HOME/.pi"'
tui_out=$(tui_run_refused "$home" "$stub_bin:$novendor" "$all_cmd" "" "" "$swap_pi" y)
grep -Fq 'refusing to write under ' <<<"$tui_out" \
  || fail "redirected ~/.pi must report protected-path refusal: $tui_out"
if grep -Fq 'not valid JSON' <<<"$tui_out"; then
  fail "redirected ~/.pi must not read or parse sentinel install.json: $tui_out"
fi

home=$(fresh_home replan-protected-agent-dir)
# shellcheck disable=SC2016
swap_agent='!mkdir -p "$HOME/.claude/pi-agent/b-agentic" "$HOME/.pi" && printf "{sentinel-not-json\n" >"$HOME/.claude/pi-agent/b-agentic/install.json" && ln -s "$HOME/.claude/pi-agent" "$HOME/.pi/agent"'
tui_out=$(tui_run_refused "$home" "$stub_bin:$novendor" "$all_cmd" "" "" "$swap_agent" y)
grep -Fq 'refusing to write under the Claude Code directory' <<<"$tui_out" \
  || fail "redirected ~/.pi/agent must report Claude Code protected-path refusal: $tui_out"
if grep -Fq 'not valid JSON' <<<"$tui_out"; then
  fail "redirected ~/.pi/agent must not read or parse sentinel install.json: $tui_out"
fi

# (s) supported disjoint symlinked runtime roots succeed on install and uninstall (R6-1).
home=$(fresh_home disjoint-symlink-roots)
ext_claude="$work/ext-claude-root"
ext_pi="$work/ext-pi-root"
mkdir -p "$ext_claude" "$ext_pi" "$home/.pi"
ln -s "$ext_claude" "$home/.claude"
ln -s "$ext_pi" "$home/.pi/agent"
run "$home" -y; expect_ok "disjoint symlinked roots on install -y"
[ -f "$ext_claude/b-agentic/install.json" ] && [ -f "$ext_pi/b-agentic/install.json" ] \
  || fail "disjoint symlinked roots must install into targets"
run "$home" --uninstall; expect_ok "disjoint symlinked roots on --uninstall"
[ ! -e "$ext_claude/b-agentic/install.json" ] && [ ! -e "$ext_pi/b-agentic/install.json" ] \
  || fail "disjoint symlinked roots must uninstall cleanly"

# (t) malformed manifest containers (e.g. pending: null) do not mask a known alias or raise AttributeError (R6-2).
for runtime_dir in ".claude" ".pi/agent"; do
  for mode in install uninstall; do
    home=$(fresh_home "badmanifest-${runtime_dir//\//-}-$mode")
    mkdir -p "$home/$runtime_dir/b-agentic"
    printf '{"schema":1,"target":"%s","pending":null}\n' "$( [ "$runtime_dir" = ".claude" ] && echo claude || echo pi )" \
      >"$home/$runtime_dir/b-agentic/install.json"
    if [ "$mode" = "install" ]; then
      run "$home" -y; expect_refused "pending:null $runtime_dir $mode without alias"
    else
      run "$home" --uninstall; expect_refused "pending:null $runtime_dir $mode without alias"
    fi
    grep -Fq 'pending must be an object' <<<"$err" || fail "pending:null must raise InstallError, not AttributeError: $err"

    mkdir -p "$home/.claude" "$home/.pi/agent"
    ln -sf "$shared" "$home/.claude/CLAUDE.md"
    ln -sf "$shared" "$home/.pi/agent/AGENTS.md"
    before=$(tree "$home")
    if [ "$mode" = "install" ]; then
      run "$home" -y; expect_refused "pending:null + alias $runtime_dir $mode"
    else
      run "$home" --uninstall; expect_refused "pending:null + alias $runtime_dir $mode"
    fi
    grep -Fq 'Claude Code CLAUDE.md' <<<"$err" || fail "pending:null+alias must name Claude Code CLAUDE.md: $err"
    grep -Fq 'Pi AGENTS.md' <<<"$err" || fail "pending:null+alias must name Pi AGENTS.md: $err"
    [ "$before" = "$(tree "$home")" ] || fail "pending:null+alias $mode modified HOME tree"
  done
done

home=$(fresh_home badmanifest-replan)
# shellcheck disable=SC2016
link_badmanifest='!mkdir -p "$HOME/.claude/b-agentic" "$HOME/.pi/agent" && printf "{\"schema\":1,\"pending\":null}\n" >"$HOME/.claude/b-agentic/install.json" && ln -sf "'"$shared"'" "$HOME/.claude/CLAUDE.md" && ln -sf "'"$shared"'" "$HOME/.pi/agent/AGENTS.md"'
tui_out=$(tui_run_refused "$home" "$stub_bin:$novendor" "$all_cmd" "" "" "$link_badmanifest" y)
grep -Fq 'Claude Code CLAUDE.md' <<<"$tui_out" || fail "pending:null replan must name Claude Code CLAUDE.md: $tui_out"
grep -Fq 'Pi AGENTS.md' <<<"$tui_out" || fail "pending:null replan must name Pi AGENTS.md: $tui_out"

echo "install probe: cross-runtime-alias (u)-(x)"
# (u) unrelated ELOOP symlink loop refuses when alone and does not mask a known cross-runtime alias (R6-3).
home=$(fresh_home eloop-only)
mkdir -p "$home/.pi/agent"
ln -s "$home/.pi/agent/loop-b" "$home/.pi/agent/settings.json"
ln -s "$home/.pi/agent/settings.json" "$home/.pi/agent/loop-b"
before=$(tree "$home")
run "$home" -y; expect_refused "eloop-only on install -y"
[ "$before" = "$(tree "$home")" ] || fail "eloop-only refusal modified HOME tree"

for mode in install uninstall; do
  home=$(fresh_home "eloop-alias-$mode")
  mkdir -p "$home/.claude" "$home/.pi/agent"
  ln -s "$home/.pi/agent/loop-b" "$home/.pi/agent/settings.json"
  ln -s "$home/.pi/agent/settings.json" "$home/.pi/agent/loop-b"
  ln -s "$shared" "$home/.claude/CLAUDE.md"
  ln -s "$shared" "$home/.pi/agent/AGENTS.md"
  before=$(tree "$home")
  if [ "$mode" = "install" ]; then
    run "$home" -y; expect_refused "eloop+alias on install -y"
  else
    run "$home" --uninstall; expect_refused "eloop+alias on --uninstall"
  fi
  grep -Fq 'Claude Code CLAUDE.md' <<<"$err" || fail "eloop+alias $mode must name Claude Code CLAUDE.md: $err"
  grep -Fq 'Pi AGENTS.md' <<<"$err" || fail "eloop+alias $mode must name Pi AGENTS.md: $err"
  [ "$before" = "$(tree "$home")" ] || fail "eloop+alias $mode modified HOME tree"
done

home=$(fresh_home eloop-replan)
# shellcheck disable=SC2016
link_eloop='!mkdir -p "$HOME/.claude" "$HOME/.pi/agent" && ln -sf "$HOME/.pi/agent/loop-b" "$HOME/.pi/agent/settings.json" && ln -sf "$HOME/.pi/agent/settings.json" "$HOME/.pi/agent/loop-b" && ln -sf "'"$shared"'" "$HOME/.claude/CLAUDE.md" && ln -sf "'"$shared"'" "$HOME/.pi/agent/AGENTS.md"'
tui_out=$(tui_run_refused "$home" "$stub_bin:$novendor" "$all_cmd" "" "" "$link_eloop" y)
grep -Fq 'Claude Code CLAUDE.md' <<<"$tui_out" || fail "eloop+alias replan must name Claude Code CLAUDE.md: $tui_out"
grep -Fq 'Pi AGENTS.md' <<<"$tui_out" || fail "eloop+alias replan must name Pi AGENTS.md: $tui_out"

# (v) permission errors on unrelated destinations/manifest parents do not mask a known alias (R7-1).
perm_probe="$work/perm-check-dir"
mkdir -p "$perm_probe"
: >"$perm_probe/sentinel"
chmod 000 "$perm_probe"
if python3 -c 'import os, sys; os.stat(sys.argv[1])' "$perm_probe/sentinel" 2>/dev/null; then
  chmod 700 "$perm_probe"
  echo "install probe skipped: chmod 000 mode-bit cases (process bypasses directory modes)"
else
  chmod 700 "$perm_probe"
  for target_dir in "extensions" "b-agentic"; do
    for mode in install uninstall; do
      home=$(fresh_home "perm-${target_dir}-$mode")
      mkdir -p "$home/.pi/agent/$target_dir" "$home/.claude"
      chmod 000 "$home/.pi/agent/$target_dir"
      if [ "$mode" = "install" ]; then
        run "$home" -y; expect_refused "EACCES $target_dir $mode without alias"
      else
        run "$home" --uninstall; expect_refused "EACCES $target_dir $mode without alias"
      fi

      ln -sf "$shared" "$home/.claude/CLAUDE.md"
      ln -sf "$shared" "$home/.pi/agent/AGENTS.md"
      if [ "$mode" = "install" ]; then
        run "$home" -y; expect_refused "EACCES+alias $target_dir $mode"
      else
        run "$home" --uninstall; expect_refused "EACCES+alias $target_dir $mode"
      fi
      chmod 700 "$home/.pi/agent/$target_dir"
      grep -Fq 'Claude Code CLAUDE.md' <<<"$err" || fail "EACCES+alias $target_dir $mode must name Claude Code CLAUDE.md: $err"
      grep -Fq 'Pi AGENTS.md' <<<"$err" || fail "EACCES+alias $target_dir $mode must name Pi AGENTS.md: $err"
    done
  done
fi

# Simulate Python 3.12 Path.is_symlink/exists/is_dir raising PermissionError on unrelated files in either runtime.
PYTHONPATH="$root/tooling/install" ROOT_DIR="$root" WORK_DIR="$work" python3 - <<'PY' || fail "Python 3.12 PermissionError simulation failed"
import os, shutil
from pathlib import Path
import all_install, claude_install

root = Path(os.environ["ROOT_DIR"])
work = Path(os.environ["WORK_DIR"]) / "py312-perm-sim"
orig_is_symlink, orig_exists, orig_is_dir = Path.is_symlink, Path.exists, Path.is_dir

for runtime in ("claude", "pi"):
    for with_alias in (True, False):
        home = work / f"{runtime}-alias-{with_alias}"
        shutil.rmtree(home, ignore_errors=True)
        (home / ".claude" / "b-agentic").mkdir(parents=True)
        (home / ".pi" / "agent" / "b-agentic").mkdir(parents=True)
        (home / ".claude" / "settings.json").write_text("{}\n")
        (home / ".pi" / "agent" / "settings.json").write_text("{}\n")
        if with_alias:
            shared = work / "shared.md"
            shared.write_text("# shared\n")
            (home / ".claude" / "CLAUDE.md").symlink_to(shared)
            (home / ".pi" / "agent" / "AGENTS.md").symlink_to(shared)
        blocked_name = "settings.json"
        blocked_root = home / (".claude" if runtime == "claude" else ".pi")

        def boom_symlink(self):
            if self.name == blocked_name and blocked_root in self.parents:
                raise PermissionError(13, "Permission denied", str(self))
            return orig_is_symlink(self)

        def boom_exists(self):
            if self.name == "b-agentic" and blocked_root in self.parents:
                raise PermissionError(13, "Permission denied", str(self))
            return orig_exists(self)

        def boom_is_dir(self):
            if self.name == "b-agentic" and blocked_root in self.parents:
                raise PermissionError(13, "Permission denied", str(self))
            return orig_is_dir(self)

        os.environ["HOME"] = str(home)
        os.environ.pop("CLAUDE_CONFIG_DIR", None)
        os.environ.pop("PI_CODING_AGENT_DIR", None)
        Path.is_symlink, Path.exists, Path.is_dir = boom_symlink, boom_exists, boom_is_dir
        try:
            for args in (["-y", "--source", str(root)], ["--uninstall", "--source", str(root)]):
                err_text = None
                try:
                    c = claude_install.Installer(root, False, False, defer_guards=True)
                    p = all_install.pi_install.Installer(root, False, False, defer_guards=True)
                    all_install.precheck_cross_runtime_destinations(c, p, for_uninstall=("--uninstall" in args))
                except claude_install.InstallError as exc:
                    err_text = str(exc)
                if with_alias:
                    assert err_text and "Claude Code CLAUDE.md" in err_text and "Pi AGENTS.md" in err_text, (
                        f"{runtime} {args} expected alias error, got {err_text!r}"
                    )
                else:
                    assert err_text and "Permission denied" in err_text, (
                        f"{runtime} {args} expected deferred permission error, got {err_text!r}"
                    )
        finally:
            Path.is_symlink, Path.exists, Path.is_dir = orig_is_symlink, orig_exists, orig_is_dir
PY

# (w) malformed manifest values (embedded NUL in files/pending.files and 5000-digit int) defer cleanly (R7-2).
for runtime_dir in ".claude" ".pi/agent"; do
  target_val=$( [ "$runtime_dir" = ".claude" ] && echo claude || echo pi )
  for case_kind in nul-files nul-pending bigint; do
    for mode in install uninstall; do
      home=$(fresh_home "badval-${target_val}-${case_kind}-$mode")
      mkdir -p "$home/$runtime_dir/b-agentic"
      case "$case_kind" in
        nul-files)
          printf '{"schema":1,"target":"%s","files":{"skills/\\u0000bad/SKILL.md":"abc"}}\n' "$target_val" \
            >"$home/$runtime_dir/b-agentic/install.json"
          expect_msg="unsafe managed path"
          ;;
        nul-pending)
          printf '{"schema":1,"target":"%s","pending":{"files":{"skills/\\u0000bad/SKILL.md":["abc"]}}}\n' "$target_val" \
            >"$home/$runtime_dir/b-agentic/install.json"
          expect_msg="unsafe managed path"
          ;;
        bigint)
          python3 -c "import sys; open(sys.argv[1], 'w').write('{\"schema\":1,\"target\":\"' + sys.argv[2] + '\",\"big\":' + ('9' * 5000) + '}\n')" \
            "$home/$runtime_dir/b-agentic/install.json" "$target_val"
          expect_msg="not valid JSON"
          ;;
      esac
      if [ "$mode" = "install" ]; then
        run "$home" -y; expect_refused "$target_val $case_kind $mode without alias"
      else
        run "$home" --uninstall; expect_refused "$target_val $case_kind $mode without alias"
      fi
      grep -Fq "$expect_msg" <<<"$err" || fail "$target_val $case_kind $mode expected InstallError ($expect_msg), got: $err"

      mkdir -p "$home/.claude" "$home/.pi/agent"
      ln -sf "$shared" "$home/.claude/CLAUDE.md"
      ln -sf "$shared" "$home/.pi/agent/AGENTS.md"
      before=$(tree "$home")
      if [ "$mode" = "install" ]; then
        run "$home" -y; expect_refused "$target_val $case_kind + alias $mode"
      else
        run "$home" --uninstall; expect_refused "$target_val $case_kind + alias $mode"
      fi
      grep -Fq 'Claude Code CLAUDE.md' <<<"$err" || fail "$target_val $case_kind+alias $mode must name Claude Code CLAUDE.md: $err"
      grep -Fq 'Pi AGENTS.md' <<<"$err" || fail "$target_val $case_kind+alias $mode must name Pi AGENTS.md: $err"
      [ "$before" = "$(tree "$home")" ] || fail "$target_val $case_kind+alias $mode modified HOME tree"
    done
  done
done

home=$(fresh_home badval-replan)
# shellcheck disable=SC2016
link_badval='!mkdir -p "$HOME/.pi/agent/b-agentic" "$HOME/.claude" && printf "{\"schema\":1,\"target\":\"pi\",\"files\":{\"skills/\\u0000bad/SKILL.md\":\"abc\"}}\n" >"$HOME/.pi/agent/b-agentic/install.json" && ln -sf "'"$shared"'" "$HOME/.claude/CLAUDE.md" && ln -sf "'"$shared"'" "$HOME/.pi/agent/AGENTS.md"'
tui_out=$(tui_run_refused "$home" "$stub_bin:$novendor" "$all_cmd" "" "" "$link_badval" y)
grep -Fq 'Claude Code CLAUDE.md' <<<"$tui_out" || fail "badval replan must name Claude Code CLAUDE.md: $tui_out"
grep -Fq 'Pi AGENTS.md' <<<"$tui_out" || fail "badval replan must name Pi AGENTS.md: $tui_out"

# (x) Pi theme (themes/dracula.json) hard-linked to CLAUDE.md is caught on install -y (--force) and replan (R8-1).
home=$(fresh_home alias-theme-install)
mkdir -p "$home/.claude" "$home/.pi/agent/themes"
printf '# shared theme and claude md\n' >"$home/.pi/agent/themes/dracula.json"
ln -f "$home/.pi/agent/themes/dracula.json" "$home/.claude/CLAUDE.md"
before=$(tree "$home")
inode_before=$(sha256sum "$home/.pi/agent/themes/dracula.json" | cut -d" " -f1)
run "$home" -y --force; expect_refused "CLAUDE.md <-> Pi themes/dracula.json on install -y --force"
grep -Fq 'Claude Code CLAUDE.md' <<<"$err" || fail "theme alias install must name Claude Code CLAUDE.md: $err"
grep -Fq 'Pi themes/dracula.json' <<<"$err" || fail "theme alias install must name Pi themes/dracula.json: $err"
[ "$before" = "$(tree "$home")" ] || fail "theme alias install refusal modified HOME tree"
[ "$inode_before" = "$(sha256sum "$home/.pi/agent/themes/dracula.json" | cut -d" " -f1)" ] \
  || fail "theme alias install refusal modified shared inode"

home=$(fresh_home alias-theme-replan)
# shellcheck disable=SC2016
link_theme='!mkdir -p "$HOME/.claude" "$HOME/.pi/agent/themes" && printf "# shared theme\n" >"$HOME/.pi/agent/themes/dracula.json" && ln -f "$HOME/.pi/agent/themes/dracula.json" "$HOME/.claude/CLAUDE.md"'
tui_out=$(tui_run_refused "$home" "$stub_bin:$novendor" "$all_cmd" "" "" "$link_theme" y)
grep -Fq 'Claude Code CLAUDE.md' <<<"$tui_out" || fail "theme alias replan must name Claude Code CLAUDE.md: $tui_out"
grep -Fq 'Pi themes/dracula.json' <<<"$tui_out" || fail "theme alias replan must name Pi themes/dracula.json: $tui_out"
[ ! -e "$home/.claude/b-agentic/install.json" ] && [ ! -e "$home/.pi/agent/b-agentic/install.json" ] \
  || fail "theme alias replan refusal wrote manifests"

echo "install probe: cross-runtime-alias (y)-(cc)"
# (y) RecursionError from deeply nested JSON or long symlink chains defers cleanly (R8-2).
for runtime_dir in ".claude" ".pi/agent"; do
  target_val=$( [ "$runtime_dir" = ".claude" ] && echo claude || echo pi )
  for mode in install uninstall; do
    home=$(fresh_home "deepjson-${target_val}-$mode")
    mkdir -p "$home/$runtime_dir/b-agentic"
    python3 -c "import sys; open(sys.argv[1], 'w').write(('{\"a\":' * 2000) + '{}' + ('}' * 2000))" \
      "$home/$runtime_dir/b-agentic/install.json"
    if [ "$mode" = "install" ]; then
      run "$home" -y; expect_refused "deep JSON $target_val $mode without alias"
    else
      run "$home" --uninstall; expect_refused "deep JSON $target_val $mode without alias"
    fi
    grep -Eq 'not valid JSON|unsupported schema|not a Pi manifest' <<<"$err" || fail "deep JSON $target_val $mode must raise InstallError, got: $err"

    mkdir -p "$home/.claude" "$home/.pi/agent"
    ln -sf "$shared" "$home/.claude/CLAUDE.md"
    ln -sf "$shared" "$home/.pi/agent/AGENTS.md"
    before=$(tree "$home")
    if [ "$mode" = "install" ]; then
      run "$home" -y; expect_refused "deep JSON + alias $target_val $mode"
    else
      run "$home" --uninstall; expect_refused "deep JSON + alias $target_val $mode"
    fi
    grep -Fq 'Claude Code CLAUDE.md' <<<"$err" || fail "deep JSON+alias $mode must name Claude Code CLAUDE.md: $err"
    grep -Fq 'Pi AGENTS.md' <<<"$err" || fail "deep JSON+alias $mode must name Pi AGENTS.md: $err"
    [ "$before" = "$(tree "$home")" ] || fail "deep JSON+alias $mode modified HOME tree"
  done
done

PYTHONPATH="$root/tooling/install" ROOT_DIR="$root" WORK_DIR="$work" python3 - <<'PY' || fail "realpath RecursionError simulation failed"
import os, shutil
from pathlib import Path
import all_install, claude_install

root = Path(os.environ["ROOT_DIR"])
work = Path(os.environ["WORK_DIR"]) / "realpath-recursion-sim"
orig_realpath = os.path.realpath

for runtime in ("claude", "pi"):
    for with_alias in (True, False):
        home = work / f"{runtime}-alias-{with_alias}"
        shutil.rmtree(home, ignore_errors=True)
        (home / ".claude" / "b-agentic").mkdir(parents=True)
        (home / ".pi" / "agent" / "b-agentic").mkdir(parents=True)
        (home / ".claude" / "settings.json").symlink_to(home / "dangling-claude")
        (home / ".pi" / "agent" / "settings.json").symlink_to(home / "dangling-pi")
        if with_alias:
            shared = work / "shared.md"
            shared.write_text("# shared\n")
            (home / ".claude" / "CLAUDE.md").symlink_to(shared)
            (home / ".pi" / "agent" / "AGENTS.md").symlink_to(shared)
        blocked_root = str(home / (".claude" if runtime == "claude" else ".pi"))

        def boom_realpath(path, *args, **kwargs):
            text = os.fspath(path)
            if "settings.json" in text and text.startswith(blocked_root):
                raise RecursionError("maximum recursion depth exceeded while resolving symlink")
            return orig_realpath(path, *args, **kwargs)

        os.environ["HOME"] = str(home)
        os.environ.pop("CLAUDE_CONFIG_DIR", None)
        os.environ.pop("PI_CODING_AGENT_DIR", None)
        os.path.realpath = boom_realpath
        try:
            for for_uninstall in (False, True):
                err_text = None
                try:
                    c = claude_install.Installer(root, False, False, defer_guards=True)
                    p = all_install.pi_install.Installer(root, False, False, defer_guards=True)
                    all_install.precheck_cross_runtime_destinations(c, p, for_uninstall=for_uninstall)
                except claude_install.InstallError as exc:
                    err_text = str(exc)
                if with_alias:
                    assert err_text and "Claude Code CLAUDE.md" in err_text and "Pi AGENTS.md" in err_text, (
                        f"{runtime} uninstall={for_uninstall} expected alias error, got {err_text!r}"
                    )
                else:
                    assert err_text and "recursion" in err_text.lower(), (
                        f"{runtime} uninstall={for_uninstall} expected clean InstallError, got {err_text!r}"
                    )
        finally:
            os.path.realpath = orig_realpath
PY

PYTHONPATH="$root/tooling/install" ROOT_DIR="$root" WORK_DIR="$work" python3 - <<'PY' || fail "json.loads RecursionError simulation failed"
import json, os, shutil
from pathlib import Path
import all_install, claude_install

root = Path(os.environ["ROOT_DIR"])
work = Path(os.environ["WORK_DIR"]) / "json-recursion-sim"
orig_loads = json.loads

for runtime in ("claude", "pi"):
    for with_alias in (True, False):
        home = work / f"{runtime}-alias-{with_alias}"
        shutil.rmtree(home, ignore_errors=True)
        (home / ".claude" / "b-agentic").mkdir(parents=True)
        (home / ".pi" / "agent" / "b-agentic").mkdir(parents=True)
        (home / ".claude" / "b-agentic" / "install.json").write_text("{}\n")
        (home / ".pi" / "agent" / "b-agentic" / "install.json").write_text("{}\n")
        if with_alias:
            shared = work / "shared.md"
            shared.write_text("# shared\n")
            (home / ".claude" / "CLAUDE.md").symlink_to(shared)
            (home / ".pi" / "agent" / "AGENTS.md").symlink_to(shared)
        os.environ["HOME"] = str(home)
        os.environ.pop("CLAUDE_CONFIG_DIR", None)
        os.environ.pop("PI_CODING_AGENT_DIR", None)
        orig_json_loads = claude_install.json.loads

        def runtime_loads(s, *args, **kwargs):
            if s.strip() == "{}":
                raise RecursionError("maximum recursion depth exceeded in json")
            return orig_json_loads(s, *args, **kwargs)

        claude_install.json.loads = runtime_loads
        try:
            for for_uninstall in (False, True):
                err_text = None
                try:
                    c = claude_install.Installer(root, False, False, defer_guards=True)
                    p = all_install.pi_install.Installer(root, False, False, defer_guards=True)
                    all_install.precheck_cross_runtime_destinations(c, p, for_uninstall=for_uninstall)
                except claude_install.InstallError as exc:
                    err_text = str(exc)
                if with_alias:
                    assert err_text and "Claude Code CLAUDE.md" in err_text and "Pi AGENTS.md" in err_text, (
                        f"{runtime} uninstall={for_uninstall} expected alias error, got {err_text!r}"
                    )
                else:
                    assert err_text and "not valid JSON" in err_text, (
                        f"{runtime} uninstall={for_uninstall} expected InstallError, got {err_text!r}"
                    )
        finally:
            claude_install.json.loads = orig_json_loads
PY

# (z) manifest edit + config alias introduced during Claude checklist does not mask alias before Pi checklist (R8-3).
home=$(fresh_home checklist-race-alias)
# shellcheck disable=SC2016
race_cmd='!mkdir -p "$HOME/.claude" "$HOME/.pi/agent/b-agentic" && printf "{broken\n" >"$HOME/.pi/agent/b-agentic/install.json" && ln -sf "'"$shared"'" "$HOME/.claude/CLAUDE.md" && ln -sf "'"$shared"'" "$HOME/.pi/agent/AGENTS.md"'
tui_out=$(tui_run_refused "$home" "$stub_bin:$novendor" "$all_cmd" "$race_cmd" "" "")
grep -Fq 'Claude Code CLAUDE.md' <<<"$tui_out" || fail "checklist-race must name Claude Code CLAUDE.md: $tui_out"
grep -Fq 'Pi AGENTS.md' <<<"$tui_out" || fail "checklist-race must name Pi AGENTS.md: $tui_out"
[ ! -e "$home/.claude/b-agentic/install.json" ] && [ ! -e "$home/.pi/agent/settings.json" ] \
  || fail "checklist-race refusal must write no files"

# (aa) manifest is never opened when root resolves to $HOME or manifest aliases same-runtime MCP config (R9-1).
for runtime in claude pi; do
  for mode in install uninstall; do
    home=$(fresh_home "nomonkey-root-${runtime}-$mode")
    mkdir -p "$home/b-agentic"
    printf '{sentinel-not-json\n' >"$home/b-agentic/install.json"
    if [ "$runtime" = "claude" ]; then
      ln -s "$home" "$home/.claude"
    else
      mkdir -p "$home/.pi"
      ln -s "$home" "$home/.pi/agent"
    fi
    if [ "$mode" = "install" ]; then
      run "$home" -y; expect_refused "root->$HOME $runtime $mode"
    else
      run "$home" --uninstall; expect_refused "root->$HOME $runtime $mode"
    fi
    grep -Fq 'refusing to manage' <<<"$err" || fail "root->$HOME $runtime $mode must refuse root: $err"
    if grep -Fq 'not valid JSON' <<<"$err"; then
      fail "root->$HOME $runtime $mode must not open sentinel install.json: $err"
    fi

    home=$(fresh_home "nomonkey-mcp-${runtime}-$mode")
    if [ "$runtime" = "claude" ]; then
      mkdir -p "$home/.claude/b-agentic"
      printf '{sentinel-not-json\n' >"$home/.claude.json"
      ln -f "$home/.claude.json" "$home/.claude/b-agentic/install.json"
    else
      mkdir -p "$home/.pi/agent/b-agentic"
      printf '{sentinel-not-json\n' >"$home/.pi/agent/mcp.json"
      ln -f "$home/.pi/agent/mcp.json" "$home/.pi/agent/b-agentic/install.json"
    fi
    if [ "$mode" = "install" ]; then
      run "$home" -y; expect_refused "manifest<->mcp $runtime $mode"
    else
      run "$home" --uninstall; expect_refused "manifest<->mcp $runtime $mode"
    fi
    grep -Fq 'resolve to the same file' <<<"$err" || fail "manifest<->mcp $runtime $mode must report alias: $err"
    if grep -Fq 'not valid JSON' <<<"$err"; then
      fail "manifest<->mcp $runtime $mode must not open sentinel install.json: $err"
    fi
  done
done

home=$(fresh_home nomonkey-replan)
# shellcheck disable=SC2016
swap_root_home='!mkdir -p "$HOME/b-agentic" && printf "{sentinel-not-json\n" >"$HOME/b-agentic/install.json" && ln -s "$HOME" "$HOME/.claude"'
tui_out=$(tui_run_refused "$home" "$stub_bin:$novendor" "$all_cmd" "" "" "$swap_root_home" y)
grep -Fq 'refusing to manage' <<<"$tui_out" || fail "replan root->$HOME must report refusing to manage: $tui_out"
if grep -Fq 'not valid JSON' <<<"$tui_out"; then
  fail "replan root->$HOME must not open sentinel install.json: $tui_out"
fi

# (bb) malformed sibling manifest fields/keys do not hide valid aliased files or pending.files entries (R9-2).
for runtime in claude pi; do
  if [ "$runtime" = "claude" ]; then
    mdir=".claude"; mtarget="claude"; opp_dir=".pi/agent"; opp_file="AGENTS.md"; opp_label="Pi AGENTS.md"; self_prefix="Claude Code"
  else
    mdir=".pi/agent"; mtarget="pi"; opp_dir=".claude"; opp_file="CLAUDE.md"; opp_label="Claude Code CLAUDE.md"; self_prefix="Pi"
  fi
  for case_kind in files-pending-null pending-mcp-null; do
    for mode in install uninstall; do
      home=$(fresh_home "partial-manifest-${runtime}-${case_kind}-$mode")
      mkdir -p "$home/$mdir/b-agentic" "$home/$mdir/skills/b-retired" "$home/$opp_dir"
      printf '# retired shared\n' >"$home/$mdir/skills/b-retired/SKILL.md"
      if [ "$case_kind" = "files-pending-null" ]; then
        printf '{"schema":1,"target":"%s","files":{"skills/b-retired/SKILL.md":"abc","/bad/key":"x"},"pending":null}\n' "$mtarget" \
          >"$home/$mdir/b-agentic/install.json"
      else
        printf '{"schema":1,"target":"%s","files":{"/bad/key":"x"},"pending":{"files":{"skills/b-retired/SKILL.md":["abc"]}},"mcp":null}\n' "$mtarget" \
          >"$home/$mdir/b-agentic/install.json"
      fi
      # Without alias: strict validation error still fires.
      if [ "$mode" = "install" ]; then
        run "$home" -y; expect_refused "partial manifest $runtime $case_kind $mode without alias"
      else
        run "$home" --uninstall; expect_refused "partial manifest $runtime $case_kind $mode without alias"
      fi
      grep -Eq 'must be an object|unsafe managed path' <<<"$err" || fail "partial manifest without alias: $err"

      # With alias to valid entry: cross-runtime diagnostic wins.
      ln -f "$home/$mdir/skills/b-retired/SKILL.md" "$home/$opp_dir/$opp_file"
      before=$(tree "$home")
      if [ "$mode" = "install" ]; then
        run "$home" -y; expect_refused "partial manifest+alias $runtime $case_kind $mode"
      else
        run "$home" --uninstall; expect_refused "partial manifest+alias $runtime $case_kind $mode"
      fi
      grep -Fq "$self_prefix skills/b-retired/SKILL.md" <<<"$err" || fail "partial manifest+alias must name $self_prefix skills/b-retired/SKILL.md: $err"
      grep -Fq "$opp_label" <<<"$err" || fail "partial manifest+alias must name $opp_label: $err"
      [ "$before" = "$(tree "$home")" ] || fail "partial manifest+alias $mode modified HOME tree"
    done
  done
done

home=$(fresh_home partial-manifest-replan)
# shellcheck disable=SC2016
link_partial='!mkdir -p "$HOME/.pi/agent/b-agentic" "$HOME/.pi/agent/skills/b-retired" "$HOME/.claude" && printf "# retired\n" >"$HOME/.pi/agent/skills/b-retired/SKILL.md" && ln -f "$HOME/.pi/agent/skills/b-retired/SKILL.md" "$HOME/.claude/CLAUDE.md" && printf "{\"schema\":1,\"target\":\"pi\",\"files\":{\"/bad\":\"x\"},\"pending\":{\"files\":{\"skills/b-retired/SKILL.md\":[\"abc\"]}},\"mcp\":null}\n" >"$HOME/.pi/agent/b-agentic/install.json"'
tui_out=$(tui_run_refused "$home" "$stub_bin:$novendor" "$all_cmd" "" "" "$link_partial" y)
grep -Fq 'Claude Code CLAUDE.md' <<<"$tui_out" || fail "partial manifest replan must name Claude Code CLAUDE.md: $tui_out"
grep -Fq 'Pi skills/b-retired/SKILL.md' <<<"$tui_out" || fail "partial manifest replan must name Pi skills/b-retired/SKILL.md: $tui_out"

# (cc) root overrides short-circuit exact defaults and defer RecursionError/unsupported overrides until after pair check (R9-3).
PYTHONPATH="$root/tooling/install" ROOT_DIR="$root" WORK_DIR="$work" python3 - <<'PY' || fail "override RecursionError check failed"
import os, shutil
from pathlib import Path
import all_install, claude_install

root = Path(os.environ["ROOT_DIR"])
work = Path(os.environ["WORK_DIR"]) / "override-recursion"
orig_realpath = os.path.realpath

# 1) Exact default overrides succeed even if realpath raises RecursionError.
for var, suffix in (("CLAUDE_CONFIG_DIR", ".claude"), ("B_AGENTIC_CLAUDE_DIR", ".claude"), ("PI_CODING_AGENT_DIR", ".pi/agent")):
    home = work / f"exact-{var}"
    shutil.rmtree(home, ignore_errors=True)
    home.mkdir(parents=True)
    os.environ["HOME"] = str(home)
    for k in ("CLAUDE_CONFIG_DIR", "B_AGENTIC_CLAUDE_DIR", "PI_CODING_AGENT_DIR"):
        os.environ.pop(k, None)
    os.environ[var] = str(home / suffix)

    def boom_exact(path, *a, **kw):
        raise RecursionError("realpath recursion")

    os.path.realpath = boom_exact
    try:
        c = claude_install.Installer(root, False, False, defer_guards=True)
        p = all_install.pi_install.Installer(root, False, False, defer_guards=True)
        assert c.override_error is None and p.override_error is None, f"{var} exact default must not error"
    finally:
        os.path.realpath = orig_realpath

# 2) Non-exact override hitting RecursionError defers until after independent .claude.json <-> Pi settings.json pair check.
for var in ("CLAUDE_CONFIG_DIR", "B_AGENTIC_CLAUDE_DIR", "PI_CODING_AGENT_DIR"):
    for with_alias in (True, False):
        home = work / f"bad-{var}-{with_alias}"
        shutil.rmtree(home, ignore_errors=True)
        (home / ".pi" / "agent").mkdir(parents=True)
        (home / ".pi" / "agent" / "settings.json").write_text("{}\n")
        if with_alias:
            (home / ".claude.json").symlink_to(home / ".pi" / "agent" / "settings.json")
        os.environ["HOME"] = str(home)
        for k in ("CLAUDE_CONFIG_DIR", "B_AGENTIC_CLAUDE_DIR", "PI_CODING_AGENT_DIR"):
            os.environ.pop(k, None)
        override_path = str(home / "custom-override")
        os.environ[var] = override_path

        def boom_override(path, *a, **kw):
            if os.fspath(path) == override_path:
                raise RecursionError("realpath recursion")
            return orig_realpath(path, *a, **kw)

        os.path.realpath = boom_override
        try:
            for for_uninstall in (False, True):
                err_text = None
                try:
                    c = claude_install.Installer(root, False, False, defer_guards=True)
                    p = all_install.pi_install.Installer(root, False, False, defer_guards=True)
                    all_install.precheck_cross_runtime_destinations(c, p, for_uninstall=for_uninstall)
                except claude_install.InstallError as exc:
                    err_text = str(exc)
                if with_alias:
                    assert err_text and "Claude Code .claude.json" in err_text and "Pi settings.json" in err_text, (
                        f"{var} uninstall={for_uninstall} expected alias error, got {err_text!r}"
                    )
                else:
                    assert err_text and var in err_text and "cannot resolve directory" in err_text, (
                        f"{var} uninstall={for_uninstall} expected deferred override error, got {err_text!r}"
                    )
        finally:
            os.path.realpath = orig_realpath
for k in ("CLAUDE_CONFIG_DIR", "B_AGENTIC_CLAUDE_DIR", "PI_CODING_AGENT_DIR"):
    os.environ.pop(k, None)
PY
echo "install probe passed: cross-runtime-alias"

echo "all install probe passed"
