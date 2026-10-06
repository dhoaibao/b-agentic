#!/usr/bin/env bash
# Exercise the Claude Code hooks and the Codex verdict mapper with scripted hook
# JSON and throwaway git repositories. Needs only node, git, and jq: no
# credentials, network, Claude Code, or Codex.
# shellcheck disable=SC2016 # Single-quoted shell commands with literal $ are the inputs under test.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
pathguard="$root/claude/hooks/b-path-guard.mjs"
verifygate="$root/claude/hooks/b-verify-gate.mjs"
codexguard="$root/claude/hooks/b-codex-guard.mjs"
verdict="$root/claude/bin/b-codex-verdict.mjs"
wrapper="$root/claude/bin/b-codex-review.mjs"
work=$(mktemp -d)
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_CEILING_DIRECTORIES="$work"
export B_AGENTIC_STATE_DIR="$work/state"

fail() { echo "hooks probe failed: $*" >&2; exit 1; }

# run <script> <json> [args...]: capture exit code in $rc and stderr in $err.
rc=0
err=""
run() {
  local script=$1 input=$2
  shift 2
  rc=0
  err=$(printf '%s' "$input" | node "$script" "$@" 2>&1 >/dev/null) || rc=$?
}
expect() { [ "$rc" = "$1" ] || fail "$2 (exit $rc, expected $1: $err)"; }

# --- path guard ----------------------------------------------------------------
pg() { jq -cn --arg tool "$1" --arg key "$2" --arg path "$3" '{tool_name: $tool, tool_input: {($key): $path}}'; }
run "$pathguard" "$(pg Read file_path /repo/.env)"; expect 2 "Read .env must be blocked"
grep -Fq 'likely-secret path' <<<"$err" || fail "path guard gave no reason"
run "$pathguard" "$(pg Edit file_path /repo/config/.env.production)"; expect 2 "Edit .env.production must be blocked"
run "$pathguard" "$(pg Write file_path /repo/keys/server.pem)"; expect 2 "Write .pem must be blocked"
run "$pathguard" "$(pg Read file_path /repo/aws-credentials.json)"; expect 2 "credentials file must be blocked"
run "$pathguard" "$(pg Read file_path /repo/secrets.yaml)"; expect 2 "secrets file must be blocked"
run "$pathguard" "$(pg Grep path /repo/.env)"; expect 2 "Grep on .env must be blocked"
run "$pathguard" "$(pg NotebookEdit notebook_path /repo/secrets.ipynb)"; expect 2 "notebook secrets must be blocked"
run "$pathguard" "$(pg Grep glob '**/.env.production')"; expect 2 "a Grep glob naming .env.production must be blocked"
run "$pathguard" "$(pg Glob pattern '**/*.pem')"; expect 2 "a Glob pattern naming pem files must be blocked"
run "$pathguard" "$(pg Grep glob '**/*.ts')"; expect 0 "an ordinary glob must pass"
run "$pathguard" "$(pg Grep glob '**/.env.example')"; expect 0 "a glob naming .env.example must pass"
run "$pathguard" "$(pg Read file_path /repo/.env.example)"; expect 0 ".env.example is explicitly allowed"
run "$pathguard" "$(pg Read file_path /repo/src/app.ts)"; expect 0 "ordinary path must pass"
run "$pathguard" '{"tool_name":"Bash","tool_input":{"command":"ls"}}'; expect 0 "tool without a path must pass"
run "$pathguard" 'not json'; expect 0 "malformed input must fail open"
run "$pathguard" ''; expect 0 "empty input must fail open"
echo "hooks probe passed: path-guard"

# --- verify gate ---------------------------------------------------------------
vg() {
  jq -cn --arg event "$1" --arg session "$2" --arg tool "${3:-}" --arg path "${4:-}" --argjson active "${5:-false}" \
    '{hook_event_name: $event, session_id: $session, tool_name: $tool, tool_input: {file_path: $path}, stop_hook_active: $active}'
}
# edit then stop: one reminder, then the continuation finishes.
run "$verifygate" "$(vg PostToolUse s1 Edit /repo/src/a.ts)"; expect 0 "PostToolUse never blocks"
run "$verifygate" "$(vg Stop s1)"; expect 2 "edit without a later shell command must remind once"
grep -Fq 'b-agentic verify gate' <<<"$err" || fail "reminder text missing"
run "$verifygate" "$(vg Stop s1 '' '' true)"; expect 0 "the continuation must be allowed to stop"
# a shell command after the edit counts as a check.
run "$verifygate" "$(vg PostToolUse s2 Write /repo/src/a.ts)"; expect 0 "write"
run "$verifygate" "$(vg PostToolUse s2 Bash)"; expect 0 "bash"
run "$verifygate" "$(vg Stop s2)"; expect 0 "edit then check must not remind"
# an edit after the check re-arms the reminder.
run "$verifygate" "$(vg PostToolUse s3 Bash)"; expect 0 "bash"
run "$verifygate" "$(vg PostToolUse s3 Edit /repo/src/a.ts)"; expect 0 "edit"
run "$verifygate" "$(vg Stop s3)"; expect 2 "edit after the check must remind"
# prose-only edits carry nothing to verify.
run "$verifygate" "$(vg PostToolUse s4 Edit /repo/README.md)"; expect 0 "prose edit"
run "$verifygate" "$(vg Stop s4)"; expect 0 "prose edit must not remind"
# nothing edited, nothing to remind.
run "$verifygate" "$(vg Stop s5)"; expect 0 "no edits must not remind"
# editing again during the continuation earns no second reminder.
run "$verifygate" "$(vg PostToolUse s6 Edit /repo/src/a.ts)"; expect 0 "edit"
run "$verifygate" "$(vg Stop s6)"; expect 2 "first stop reminds"
run "$verifygate" "$(vg PostToolUse s6 Edit /repo/src/b.ts)"; expect 0 "edit during continuation"
run "$verifygate" "$(vg Stop s6 '' '' true)"; expect 0 "no second reminder in the same continuation"
run "$verifygate" "$(vg Stop s6)"; expect 0 "state is cleared after the continuation"
# sessions are independent.
run "$verifygate" "$(vg PostToolUse s7 Edit /repo/src/a.ts)"; expect 0 "edit in s7"
run "$verifygate" "$(vg Stop s8)"; expect 0 "another session is unaffected"
run "$verifygate" 'not json'; expect 0 "malformed input must fail open"
echo "hooks probe passed: verify-gate"

# --- codex guard ---------------------------------------------------------------
make_repo() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q .
  git -C "$dir" config user.email probe@example.invalid
  git -C "$dir" config user.name probe
  printf 'a\n' >"$dir/a.txt"
  git -C "$dir" add .
  git -C "$dir" commit -qm init
}
cg() { jq -cn --arg cwd "$1" --arg command "$2" '{tool_name: "Bash", cwd: $cwd, tool_input: {command: $command}}'; }
review='node "/plugin/scripts/codex-companion.mjs" adversarial-review --wait --scope working-tree check the diff'
repo="$work/repo"
make_repo "$repo"

run "$codexguard" "$(cg "$repo" 'ls -la')"; expect 0 "unrelated Bash must pass"
run "$codexguard" "$(cg "$repo" 'node "/plugin/scripts/codex-companion.mjs" status')"; expect 0 "non-review companion command must pass"
run "$codexguard" "$(cg "$repo" "$review")"; expect 2 "an unapproved repository must be refused"
grep -Fq 'has not approved' <<<"$err" || fail "approval reason missing: $err"
( cd "$repo" && node "$codexguard" --check >"$work/check.json" ) && fail "--check must refuse an unapproved repository" || true
[ "$(jq -r .ok "$work/check.json")" = false ] || fail "--check ok must be false before approval"

( cd "$repo" && node "$codexguard" --approve >"$work/approve.json" )
[ "$(jq -r .approved "$work/approve.json")" = true ] || fail "--approve did not record approval"
( cd "$repo" && node "$codexguard" --check >"$work/check.json" ) || fail "--check must pass after approval"
run "$codexguard" "$(cg "$repo" "$review")"; expect 0 "an approved clean repository must pass"
run "$codexguard" "$(cg "$repo" 'node /p/codex-companion.mjs review --wait --base main')"; expect 0 "native review against a base ref must pass"
run "$codexguard" "$(cg "$repo" 'node "/p/codex-companion.mjs" adversarial-review --background --scope working-tree x')"; expect 2 "--background must be refused"
run "$codexguard" "$(cg "$repo" 'node "/p/codex-companion.mjs" adversarial-review --scope working-tree x')"; expect 2 "a missing --wait must be refused"
run "$codexguard" "$(cg "$repo" 'node "/p/codex-companion.mjs" adversarial-review --wait x')"; expect 2 "an implicit target must be refused"
run "$codexguard" "$(cg "$repo" 'node "/p/codex-companion.mjs" task --wait something')"; expect 0 "task passes the review-flag rules once approved and clean"

# Command interpretation is quote-aware and fails closed on anything ambiguous.
cmd_expect() { run "$codexguard" "$(cg "$repo" "$2")"; expect "$1" "$3"; }
cmd_expect 2 'node "/p/codex-companion.mjs" "review" --background --scope working-tree x' "a quoted subcommand must not hide --background"
cmd_expect 2 'node /p/codex-companion.mjs status; node /p/codex-companion.mjs review --scope working-tree x' "a later invocation must be checked (no --wait)"
cmd_expect 2 'node /p/codex-companion.mjs review --wait --scope working-tree x &' "a backgrounded review must be refused"
cmd_expect 2 'cd /tmp && node /p/codex-companion.mjs review --wait --scope working-tree x' "a directory change must be refused"
cmd_expect 2 'node /p/codex-companion.mjs review --wait --base' "--base without a value must be refused"
cmd_expect 2 'node /p/codex-companion.mjs review --wait --scope' "--scope without a value must be refused"
cmd_expect 2 "bash -c 'node /p/codex-companion.mjs review --wait --scope working-tree'" "a wrapped invocation must be refused"
cmd_expect 2 'node "$P/codex-companion.mjs" review --wait --scope working-tree' "an unresolved expansion must be refused"
cmd_expect 2 'node /p/codex-companion.mjs review "--wait --scope working-tree' "an unbalanced quote must be refused"
cmd_expect 2 'echo $(node /p/codex-companion.mjs review --wait --scope working-tree)' "a subshell must be refused"
cmd_expect 2 'node /p/codex-companion.mjs' "a missing subcommand must be refused"
cmd_expect 0 'node ${CLAUDE_PLUGIN_ROOT}/scripts/codex-companion.mjs review --wait --scope working-tree focus' "the plugin root variable is the one allowed expansion"
cmd_expect 0 'node /p/codex-companion.mjs "review" --wait --scope=working-tree x' "a quoted subcommand with --scope=value must pass when valid"
cmd_expect 2 'node /p/codex-companion.mjs status; node /p/codex-companion.mjs review --wait --scope working-tree x' "two plugin commands in one call must be refused"
cmd_expect 0 'node /p/codex-companion.mjs review --wait --scope working-tree "focus; with ; punctuation" 2>&1' "a quoted focus and a redirection must pass"
run "$codexguard" 'garbage mentioning codex-companion.mjs review'; expect 2 "unreadable input that names the plugin must be refused"
# Quote concatenation is the same word to the shell, so it must be the same word to the guard.
cmd_expect 0 'node /p/codex-compan""ion.mjs review --wait --scope working-tree x' "a quote-concatenated companion name is recognised and valid when approved"
cmd_expect 2 'env -C /other node /p/codex-companion.mjs review --wait --scope working-tree' "an env wrapper must be refused"
cmd_expect 2 'command cd /other; node /p/codex-companion.mjs review --wait --scope working-tree' "a wrapped directory change must be refused"
cmd_expect 2 'timeout 5 node /p/codex-companion.mjs review --wait --scope working-tree' "a timeout wrapper must be refused"
cmd_expect 2 'FOO=1 node /p/codex-companion.mjs review --wait --scope working-tree' "a variable prefix must be refused"
cmd_expect 2 'rm -rf build; node /p/codex-companion.mjs review --wait --scope working-tree' "an unsupported neighbouring command must be refused"
cmd_expect 2 'node /p/codex-companion.mjs review # --wait --scope working-tree' "flags hidden behind a comment must not count"
cmd_expect 2 'node /p/codex-companion.mjs review --wait > --scope working-tree' "a redirect target must not count as an option"
cmd_expect 2 'node /p/codex-companion.mjs review --wait --scope working-tree > out.txt' "a redirect to a file must be refused"
cmd_expect 2 'node /p/codex-companion.mjs review --wait --scope working-tree < in.txt' "input redirection must be refused"
cmd_expect 2 'node /p/codex-companion.mjs review --wait --scope working-tree --cwd /other' "a directory option must be refused"
cmd_expect 2 'node /p/codex-companion.mjs task --wait --cwd=/other do it' "a directory option on task must be refused"
cmd_expect 0 'node /p/codex-companion.mjs review --wait --scope working-tree >/dev/null 2>&1' "redirects to /dev/null are allowed"
cmd_expect 0 'node /p/codex-companion.mjs review --wait --scope working-tree 2>&1' "a descriptor duplication is allowed"
cmd_expect 2 'node /p/codex-companion.mjs review --wait --scope working-tree && echo done' "a neighbouring command must be refused (default-deny)"
cmd_expect 0 'rg -n codex-companion claude/hooks' "mentioning the plugin name in a search is not an invocation"
cmd_expect 2 'git commit -m "document codex-companion.mjs handling"' "a command that carries the script name without being the plugin command is refused (default-deny)"
cmd_expect 2 'rg -n codex-companion.mjs claude/hooks' "a search naming the script is refused; use the Grep tool instead"
cmd_expect 0 'node /p/codex-companion.mjs review --wait --scope working-tree # focus note' "a trailing comment after valid flags is fine"
# Literal-name spellings that earlier slipped through: line continuations and interpreters or
# wrappers that carry the full script name inside one argument.
cmd_expect 2 $'node /p/codex-compan\\\nion.mjs review --background --scope working-tree' "a backslash-newline split of the script name must not bypass the guard"
cmd_expect 2 'node -e '"'"'require("child_process").execSync("node /p/codex-companion.mjs review --background --scope working-tree")'"'"'' "an interpreter carrying the script name must be refused"
cmd_expect 2 "git -c 'alias.scan=!node /p/codex-companion.mjs review --background --scope working-tree' scan" "a git alias carrying the script name must be refused"
cmd_expect 2 'sh -c "node /p/codex-companion.mjs review --background --scope working-tree"' "a shell -c wrapper must be refused"
cmd_expect 2 'xargs node /p/codex-companion.mjs review --background --scope working-tree' "xargs must be refused"
cmd_expect 2 'echo node /p/codex-companion.mjs review --wait --scope working-tree' "echoing the command is not the command"
cmd_expect 2 'node /p/codex-companion.mjs node /p/codex-companion.mjs review --wait --scope working-tree' "the script name repeated in arguments must be refused"
cmd_expect 2 'ls # codex-companion.mjs' "a mention hidden in a comment is refused (default-deny)"
cmd_expect 2 $'node /p/codex-companion.mjs review --wait --scope working-tree\nrm -rf build' "a second line must be refused"
# `>&` takes the next word as its operand: a number duplicates a descriptor, a word is a file.
cmd_expect 2 'node /p/codex-companion.mjs review >& --wait --scope working-tree' "a >& operand must not count as --wait"
cmd_expect 2 'node /p/codex-companion.mjs review --wait >& --scope working-tree' "a >& operand must not count as --scope"
cmd_expect 2 'node /p/codex-companion.mjs review --wait --scope working-tree >&/tmp/output' "a >& file target must be refused"
cmd_expect 2 'node /p/codex-companion.mjs review --wait --scope working-tree >& out.txt' "a spaced >& file target must be refused"
cmd_expect 2 'node /p/codex-companion.mjs review --wait --scope working-tree 2>&' "a >& with no operand must be refused"
cmd_expect 0 'node /p/codex-companion.mjs review --wait --scope working-tree >&2' "a >&2 descriptor duplication is allowed"
cmd_expect 0 'node /p/codex-companion.mjs review --wait --scope working-tree 2>& 1' "a spaced descriptor duplication is allowed"
cmd_expect 0 'node /p/codex-companion.mjs review --wait --scope working-tree >&-' "closing a descriptor is allowed"
cmd_expect 0 'node /p/codex-companion.mjs review --wait --scope working-tree &>/dev/null' "&>/dev/null is allowed"


# Secrets: tracked, untracked, opaque boundaries, and the accepted ignored case.
printf 'TOPSECRET=1\n' >"$repo/.env"
run "$codexguard" "$(cg "$repo" "$review")"; expect 2 "an untracked .env must block"
grep -Fq '.env' <<<"$err" || fail "blocking path not named"
grep -Fq TOPSECRET <<<"$err" && fail "secret content reached the reason"
printf '.env\n' >"$repo/.gitignore"
run "$codexguard" "$(cg "$repo" "$review")"; expect 0 "an ignored .env is the accepted residual risk"
git -C "$repo" add -f .env
run "$codexguard" "$(cg "$repo" "$review")"; expect 2 "a tracked .env must block"
git -C "$repo" rm -q --cached .env
rm "$repo/.env" "$repo/.gitignore"
git init -q "$repo/tools"
run "$codexguard" "$(cg "$repo" "$review")"; expect 2 "an embedded repository must block"
grep -Fq 'opaque' <<<"$err" || fail "opaque reason missing: $err"
mv "$repo/tools" "$work/tools-moved"

# Failure modes.
mkdir -p "$work/plain"
run "$codexguard" "$(cg "$work/plain" "$review")"; expect 2 "a non-repository must be refused"
run "$codexguard" 'not json'; expect 0 "malformed hook input must fail open"
other="$work/other"
make_repo "$other"
run "$codexguard" "$(cg "$other" "$review")"; expect 2 "approval is per repository"
run "$codexguard" "$(cg "$other" 'node /p/codex-companion.mjs "review" --wait --scope working-tree x')"; expect 2 "a quoted subcommand must not bypass the approval check"
run "$codexguard" "$(cg "$other" 'node /p/codex-compan""ion.mjs review --wait --scope working-tree x')"; expect 2 "a quote-concatenated name must not bypass the approval check"
run "$codexguard" "$(cg "$other" $'node /p/codex-compan\\\nion.mjs review --wait --scope working-tree x')"; expect 2 "a line-continuation split must not bypass the approval check"
grep -Fq 'Codex guard refused' <<<"$err" || fail "guard gave no refusal for the line-continuation split: $err"
run "$codexguard" "$(cg "$other" 'node -e '"'"'require("child_process").execSync("node /p/codex-companion.mjs review --wait --scope working-tree")'"'"'')"; expect 2 "an interpreter must not bypass the approval check"
run "$codexguard" "$(cg "$other" "git -c 'alias.scan=!node /p/codex-companion.mjs review --wait --scope working-tree' scan")"; expect 2 "a git alias must not bypass the approval check"
( cd "$repo" && node "$codexguard" --revoke >/dev/null )
run "$codexguard" "$(cg "$repo" "$review")"; expect 2 "a revoked repository must be refused"
( cd "$repo" && node "$codexguard" --bogus 2>/dev/null ) && fail "an unknown argument must fail" || true
echo "hooks probe passed: codex-guard"

# --- verdict mapper --------------------------------------------------------------
vd() { printf '%s' "$1" | node "$verdict" "${@:2}"; }
out=$(vd '{"verdict":"approve","findings":[],"summary":"ok"}'); [ "$(jq -r .provisional_verdict <<<"$out")" = "READY FOR PR" ] || fail "approve with no findings"
out=$(vd '{"verdict":"needs-attention","findings":[{"severity":"high","title":"Leak","file":"a.ts","line_start":3,"line_end":9,"confidence":0.9,"recommendation":"fix","body":"b"}]}' --round 2)
[ "$(jq -r .provisional_verdict <<<"$out")" = "NEEDS FIXES" ] || fail "high finding must need fixes"
[ "$(jq -r '.findings[0].id' <<<"$out")" = "R2-1" ] || fail "finding id must carry the round"
[ "$(jq -r '.findings[0].provisional_class' <<<"$out")" = blocker ] || fail "high must be a provisional blocker"
out=$(vd '{"verdict":"needs-attention","findings":[{"severity":"critical","title":"x"}]}'); [ "$(jq -r .provisional_verdict <<<"$out")" = "NEEDS FIXES" ] || fail "critical must need fixes"
out=$(vd '{"verdict":"needs-attention","findings":[{"severity":"medium","title":"m"},{"severity":"low","title":"l"}]}')
[ "$(jq -r .provisional_verdict <<<"$out")" = "READY WITH FOLLOW-UPS" ] || fail "medium and low are follow-ups"
[ "$(jq -r '[.findings[].provisional_class] | unique | join(",")' <<<"$out")" = "follow-up" ] || fail "medium and low must be follow-ups"
out=$(vd '{"verdict":"approve","findings":[{"severity":"high","title":"x"}]}'); [ "$(jq -r .provisional_verdict <<<"$out")" = "NEEDS FIXES" ] || fail "findings win over an approve"
vd '{"verdict":"needs-attention","findings":[]}' >"$work/void.json" && fail "needs-attention without findings must exit 3" || [ "$?" = 3 ] || fail "void exit code"
[ "$(jq -r .provisional_verdict "$work/void.json")" = VOID ] || fail "needs-attention without findings must be void"
text=$'Target: working tree\nVerdict: needs-attention\nFindings:\n- [high] Token logged (src/a.ts:12-18)\n- [low] Rename helper (src/b.ts:4)\n'
out=$(vd "$text")
[ "$(jq -r .provisional_verdict <<<"$out")" = "NEEDS FIXES" ] || fail "rendered text high finding"
[ "$(jq -r '.findings | length' <<<"$out")" = 2 ] || fail "rendered text findings not parsed"
[ "$(jq -r '.findings[0].file' <<<"$out")" = "src/a.ts" ] || fail "rendered text file not parsed"
[ "$(jq -r '.findings[0].line_end' <<<"$out")" = 18 ] || fail "rendered text range not parsed"
[ "$(jq -r '.findings[1].line_start' <<<"$out")" = 4 ] || fail "rendered text single line not parsed"
for bad in $'Verdict: approve\nVerdict: approve\n' $'Verdict: needs-attention\nVerdict: needs-attention\n- [low] x\n'; do
  rc=0; printf '%s' "$bad" | node "$verdict" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "a repeated verdict line must exit 2 (got $rc)"
done
out=$(vd $'Verdict: approve\nNo issues found.\n'); [ "$(jq -r .provisional_verdict <<<"$out")" = "READY FOR PR" ] || fail "rendered text approve"
for bad in '' 'garbage' '{"verdict":"maybe","findings":[]}' '{"verdict":"approve"}' '{"verdict":"approve","findings":[{"severity":"urgent","title":"x"}]}' '{"verdict":"approve","findings":[{"severity":"low"}]}' '{broken'; do
  if vd "$bad" >/dev/null 2>&1; then fail "invalid input must be refused: $bad"; fi
done
for bad in $'Verdict: approve\n- [urgent] leaked credentials (a.ts:1)\n' $'Verdict: approve\nVerdict: needs-attention\n' $'Verdict: needs-attention\n- [low] x\n- [highish] critical leak\n' $'Verdict: approve\nSee [high] note in the text\n' $'Verdict: approve\n1. [high] numbered finding\n' $'Verdict: maybe\n'; do
  if vd "$bad" >/dev/null 2>&1; then fail "unparseable or conflicting rendered text must be refused: $bad"; fi
  rc=0; printf '%s' "$bad" | node "$verdict" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "unparseable rendered text must exit 2 (got $rc): $bad"
done
rc=0; printf '%s' 'garbage' | node "$verdict" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "invalid input must exit 2 (got $rc)"
rc=0; node "$verdict" --round 0 </dev/null >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "--round 0 must exit 2 (got $rc)"
echo "hooks probe passed: verdict-mapper"

# --- review wrapper (the enforced gate) -------------------------------------------------------------
# A fake plugin script stands in for Codex: it logs its argv and cwd, can touch a tracked file, and
# prints canned output, so every gate decision is observable without a network or credentials.
fake="$work/plugin/codex-companion.mjs"
mkdir -p "$work/plugin"
cat >"$fake" <<'JS'
import { spawn } from "node:child_process";
import { appendFileSync, writeFileSync } from "node:fs";
appendFileSync(process.env.FAKE_LOG, `${JSON.stringify({ argv: process.argv.slice(2), cwd: process.cwd() })}\n`);
if (process.env.FAKE_TOUCH) appendFileSync(process.env.FAKE_TOUCH, "changed\n");
if (process.env.FAKE_CREATE) writeFileSync(process.env.FAKE_CREATE, "TOPSECRET=1\n");
const mode = process.env.FAKE_MODE ?? "";
if (mode === "big") {
  // An approving prefix, enough filler to pass the cap, then the blocking finding in later chunks.
  process.stdout.write("Verdict: approve\n");
  const filler = "x".repeat(1023) + "\n";
  for (let i = 0; i < 9000; i++) process.stdout.write(filler);
  process.stdout.write("- [high] Leak (a.ts:1)\n");
  setTimeout(() => process.exit(0), 20000);
} else if (mode === "big-stderr") {
  const filler = "e".repeat(1023) + "\n";
  for (let i = 0; i < 9000; i++) process.stderr.write(filler);
  process.stdout.write('{"verdict":"approve","findings":[]}');
  setTimeout(() => process.exit(0), 20000);
} else if (mode === "term-approve") {
  // Handles SIGTERM by approving and exiting 0, so the exit status looks like success.
  process.on("SIGTERM", () => {
    process.stdout.write('{"verdict":"approve","findings":[]}');
    process.exit(0);
  });
  setTimeout(() => process.exit(0), 60000);
} else if (mode.startsWith("pipe-holder")) {
  // The companion exits (normally, or by signal) while a detached descendant keeps stdout/stderr open.
  const code = mode === "pipe-holder-big"
    ? "setTimeout(() => { const f = 'x'.repeat(1023) + '\\n'; for (let i = 0; i < 9000; i++) process.stdout.write(f); }, 300); setTimeout(() => {}, 10000);"
    : "setTimeout(() => {}, 10000);";
  const holder = spawn(process.execPath, ["-e", code], { detached: true, stdio: ["ignore", "inherit", "inherit"] });
  holder.unref();
  writeFileSync(process.env.FAKE_PIDFILE, String(holder.pid));
  if (mode === "pipe-holder-signal") process.kill(process.pid, "SIGKILL");
  setTimeout(() => process.exit(0), 100);
} else if (mode === "ignore-term") {
  process.on("SIGTERM", () => {});
  setTimeout(() => process.exit(0), 60000);
} else {
  process.stdout.write(process.env.FAKE_OUT ?? '{"verdict":"approve","findings":[]}');
  process.exit(Number(process.env.FAKE_EXIT ?? 0));
}
JS
export FAKE_LOG="$work/fake.log"
wrap() { # wrap <repo> [args...]: run the wrapper inside <repo>
  local repo=$1
  shift
  rc=0
  err=""
  wout=$(cd "$repo" && B_AGENTIC_CODEX_COMPANION="$fake" node "$wrapper" "$@" 2>"$work/wstderr") || rc=$?
  err=$(cat "$work/wstderr")
}
wexpect() { [ "$rc" = "$1" ] || fail "$2 (exit $rc, expected $1: $err)"; }
wrepo="$work/wrepo"
make_repo "$wrepo"
( cd "$wrepo" && node "$codexguard" --approve >/dev/null )
: >"$FAKE_LOG"

wrap "$wrepo" --scope working-tree --focus 'check the diff'; wexpect 0 "an approved clean repository must be reviewed"
[ "$(jq -r .mapped.provisional_verdict <<<"$wout")" = "READY FOR PR" ] || fail "the approve result was not mapped to READY FOR PR"
[ "$(jq -r .unchanged <<<"$wout")" = true ] || fail "an untouched candidate must report unchanged"
[ "$(jq -r .f0 <<<"$wout")" = "$(jq -r .f1 <<<"$wout")" ] || fail "F0 and F1 must match for an untouched candidate"
[ "$(jq -c '.argv' <(tail -n 1 "$FAKE_LOG"))" = '["adversarial-review","--wait","--scope","working-tree","check the diff"]' ] || fail "plugin argv wrong: $(tail -n 1 "$FAKE_LOG")"
[ "$(jq -r .cwd <(tail -n 1 "$FAKE_LOG"))" = "$(cd "$wrepo" && pwd -P)" ] || fail "the plugin must run in the repository root"
wrap "$wrepo" --base main --kind native; wexpect 0 "a native base review"
[ "$(jq -c '.argv' <(tail -n 1 "$FAKE_LOG"))" = '["review","--wait","--base","main"]' ] || fail "native argv wrong: $(tail -n 1 "$FAKE_LOG")"
wrap "$wrepo/" --scope working-tree --round 3 --focus 'x'; wexpect 0 "a trailing slash cwd"
[ "$(jq -r '.mapped.findings | length' <<<"$wout")" = 0 ] && [ "$(jq -r .round <<<"$wout")" = 3 ] || fail "the round was not carried"
# a focus with shell metacharacters is one argv element, never shell text
: >"$FAKE_LOG"
wrap "$wrepo" --scope working-tree --focus 'a; rm -rf / $(touch pwned) "q" {x,y} *'; wexpect 0 "a focus with metacharacters"
[ "$(jq -r '.argv[4]' <(tail -n 1 "$FAKE_LOG"))" = 'a; rm -rf / $(touch pwned) "q" {x,y} *' ] || fail "the focus was not passed verbatim as one argument"
[ ! -e "$wrepo/pwned" ] || fail "the focus was interpreted by a shell"

# verdicts: findings map, drift and unparseable results void, failures refuse
FAKE_OUT='{"verdict":"needs-attention","findings":[{"severity":"high","title":"Leak"}]}' wrap "$wrepo" --scope working-tree; wexpect 0 "a needs-attention result is still a completed review"
[ "$(jq -r .mapped.provisional_verdict <<<"$wout")" = "NEEDS FIXES" ] || fail "a high finding must map to NEEDS FIXES"
FAKE_OUT='{"verdict":"needs-attention","findings":[]}' wrap "$wrepo" --scope working-tree; wexpect 3 "needs-attention without findings is void"
FAKE_OUT='not a review' wrap "$wrepo" --scope working-tree; wexpect 3 "an unmappable result is void"
[ "$(jq -r .void_reason <<<"$wout")" = "the plugin result could not be mapped" ] || fail "void reason missing for an unmappable result"
FAKE_TOUCH="$wrepo/a.txt" wrap "$wrepo" --scope working-tree; wexpect 3 "a candidate edited during the review is void"
[ "$(jq -r .unchanged <<<"$wout")" = false ] || fail "drift must report unchanged:false"
git -C "$wrepo" checkout -q -- a.txt
FAKE_EXIT=1 wrap "$wrepo" --scope working-tree; wexpect 2 "a failing plugin is an error"
[ "$(jq -r .exit_code <<<"$wout")" = 1 ] || fail "a failing plugin must still report its exit code on stdout (got: $wout)"

# a run that was cut short is never a completed review, whatever its exit status says
FAKE_MODE=big wrap "$wrepo" --scope working-tree --kill-grace-seconds 2; wexpect 3 "output past the cap must void the review"
[ "$(jq -r '.truncated | index("stdout") != null' <<<"$wout")" = true ] || fail "an oversized stdout was not flagged: $wout"
[ "$(jq -r 'has("mapped")' <<<"$wout")" = false ] || fail "a truncated result was mapped"
grep -Fq 'exceeded' <<<"$(jq -r .void_reason <<<"$wout")" || fail "the void reason must name the cap"
FAKE_MODE=big-stderr wrap "$wrepo" --scope working-tree --kill-grace-seconds 2; wexpect 3 "stderr past the cap must void the review"
[ "$(jq -r 'has("mapped")' <<<"$wout")" = false ] || fail "a result with truncated stderr was mapped"
SECONDS=0
FAKE_MODE=term-approve wrap "$wrepo" --scope working-tree --timeout-minutes 0.02 --kill-grace-seconds 2; wexpect 3 "a timeout answered with an approving exit 0 must void the review"
[ "$(jq -r .timed_out <<<"$wout")" = true ] || fail "the expired deadline was not recorded: $wout"
[ "$(jq -r 'has("mapped")' <<<"$wout")" = false ] || fail "a timed-out run was mapped to a verdict"
[ "$(jq -r .exit_code <<<"$wout")" = 0 ] || fail "the fixture should have exited 0 to prove status alone is not trusted"
[ "$SECONDS" -lt 15 ] || fail "the timed-out run took too long ($SECONDS s)"
SECONDS=0
FAKE_MODE=ignore-term wrap "$wrepo" --scope working-tree --timeout-minutes 0.02 --kill-grace-seconds 1; wexpect 3 "a child that ignores SIGTERM must still be stopped and voided"
[ "$(jq -r .timed_out <<<"$wout")" = true ] && [ "$(jq -r .signal <<<"$wout")" = SIGKILL ] || fail "a SIGTERM-ignoring child was not killed: $wout"
[ "$SECONDS" -lt 15 ] || fail "a SIGTERM-ignoring child blocked the wrapper ($SECONDS s)"
# a companion that exits while a descendant keeps the pipes open must not hang the wrapper
export FAKE_PIDFILE="$work/holder.pid"
holder_case() { # holder_case <mode> <expect> <message> [extra wrapper args...]
  local mode=$1 want=$2 message=$3
  shift 3
  : >"$FAKE_PIDFILE"
  SECONDS=0
  rc=0
  wout=$(cd "$wrepo" && FAKE_MODE="$mode" B_AGENTIC_CODEX_COMPANION="$fake" timeout 40 node "$wrapper" --scope working-tree --kill-grace-seconds 1 "$@" 2>"$work/wstderr") || rc=$?
  err=$(cat "$work/wstderr")
  [ -s "$FAKE_PIDFILE" ] && kill -9 "$(cat "$FAKE_PIDFILE")" 2>/dev/null || true
  [ "$rc" = "$want" ] || fail "$message (exit $rc, expected $want after ${SECONDS}s: $err)"
  [ "$SECONDS" -lt 8 ] || fail "$message: took ${SECONDS}s, the wrapper waited for the descendant instead of its own bound"
}
holder_case pipe-holder 3 "an exited companion with a pipe-holding descendant must void at the deadline" --timeout-minutes 0.02
[ "$(jq -r .timed_out <<<"$wout")" = true ] && [ "$(jq -r 'has("mapped")' <<<"$wout")" = false ] || fail "a pipe-held timeout must be recorded and not mapped: $wout"
holder_case pipe-holder-signal 3 "a signal-killed companion with a pipe-holding descendant must void at the deadline" --timeout-minutes 0.02
[ "$(jq -r .timed_out <<<"$wout")" = true ] && [ "$(jq -r .exit_code <<<"$wout")" = null ] || fail "a signal exit with held pipes must be recorded: $wout"
holder_case pipe-holder-big 3 "overflow written by a descendant after the companion exited must void within the bound"
[ "$(jq -r '.truncated | index("stdout") != null' <<<"$wout")" = true ] && [ "$(jq -r 'has("mapped")' <<<"$wout")" = false ] || fail "post-exit overflow must be flagged and not mapped: $wout"
wrap "$wrepo" --scope working-tree --timeout-minutes 1e300; wexpect 2 "an oversized timeout must be refused, not clamped to 1 ms"
wrap "$wrepo" --scope working-tree --kill-grace-seconds 1e300; wexpect 2 "an oversized kill grace must be refused"
wrap "$wrepo" --scope working-tree --timeout-minutes NaN; wexpect 2 "a NaN timeout must be refused"
wrap "$wrepo" --scope working-tree --timeout-minutes 0; wexpect 2 "a zero timeout must be refused"
# an incomplete snapshot after the run voids it; before the run it refuses without calling the plugin
FAKE_CREATE="$wrepo/.env" wrap "$wrepo" --scope working-tree; wexpect 3 "a snapshot that became incomplete during the review must void it"
grep -Fq 'incomplete' <<<"$(jq -r .void_reason <<<"$wout")" || fail "the void reason must say the snapshot was incomplete: $wout"
[ "$(jq -r .f1 <<<"$wout")" = null ] && [ "$(jq -r .unchanged <<<"$wout")" = false ] || fail "an incomplete F1 must be null and not unchanged"
rm -f "$wrepo/.env"
: >"$FAKE_LOG"
wignored="$work/wignored"
make_repo "$wignored"
printf '.env\n' >"$wignored/.gitignore"
git -C "$wignored" add .gitignore && git -C "$wignored" commit -qm ignore-env
( cd "$wignored" && node "$codexguard" --approve >/dev/null )
printf 'TOPSECRET=1\n' >"$wignored/.env"
wrap "$wignored" --scope working-tree --include-ignored .env; wexpect 2 "an incomplete snapshot before the run must refuse"
grep -Fq 'before the plugin runs' <<<"$err" || fail "the pre-run refusal must say so: $err"
[ ! -s "$FAKE_LOG" ] || fail "the plugin ran despite an incomplete first snapshot"
wrap "$wrepo" --scope working-tree --kill-grace-seconds 0; wexpect 2 "a zero kill grace must be refused"
wrap "$wrepo" --scope working-tree; wexpect 0 "the wrapper still works after the cut-short cases"

# refusals: nothing may reach the plugin
: >"$FAKE_LOG"
printf 'TOPSECRET=1\n' >"$wrepo/.env"
wrap "$wrepo" --scope working-tree; wexpect 2 "an untracked .env must block the review"
grep -Fq 'likely-secret' <<<"$err" || fail "secret refusal reason missing: $err"
grep -Fq TOPSECRET <<<"$err$wout" && fail "secret content reached the output"
rm "$wrepo/.env"
wunapproved="$work/wunapproved"
make_repo "$wunapproved"
wrap "$wunapproved" --scope working-tree; wexpect 2 "an unapproved repository must be refused"
grep -Fq 'has not approved' <<<"$err" || fail "approval refusal reason missing: $err"
mkdir -p "$work/wplain"
wrap "$work/wplain" --scope working-tree; wexpect 2 "a non-repository must be refused"
git init -q "$wrepo/tools"
wrap "$wrepo" --scope working-tree; wexpect 2 "an embedded repository must block the review"
mv "$wrepo/tools" "$work/wtools-moved"
[ ! -s "$FAKE_LOG" ] || fail "the plugin ran despite a refusal: $(cat "$FAKE_LOG")"

# argument validation
wrap "$wrepo"; wexpect 2 "no target must be refused"
wrap "$wrepo" --scope working-tree --base main; wexpect 2 "two targets must be refused"
wrap "$wrepo" --scope auto; wexpect 2 "an unsupported scope must be refused"
wrap "$wrepo" --base --evil; wexpect 2 "a --base value starting with a dash must be refused"
wrap "$wrepo" --base; wexpect 2 "a missing --base value must be refused"
wrap "$wrepo" --scope working-tree --focus '--background'; wexpect 2 "a focus starting with a dash must be refused"
wrap "$wrepo" --scope working-tree --focus ''; wexpect 2 "an empty focus must be refused"
wrap "$wrepo" --scope working-tree --kind native --focus 'x'; wexpect 2 "a focus on a native review must be refused"
wrap "$wrepo" --scope working-tree --kind other; wexpect 2 "an unknown kind must be refused"
wrap "$wrepo" --scope working-tree --round 0; wexpect 2 "round 0 must be refused"
wrap "$wrepo" --scope working-tree --bogus; wexpect 2 "an unknown argument must be refused"
rc=0; ( cd "$wrepo" && B_AGENTIC_CODEX_COMPANION="$work/plugin/not-the-script.mjs" node "$wrapper" --scope working-tree >/dev/null 2>&1 ) || rc=$?
[ "$rc" = 2 ] || fail "a companion override with the wrong name must be refused (exit $rc)"
rc=0; ( cd "$wrepo" && HOME="$work/wempty" B_AGENTIC_CODEX_COMPANION='' node "$wrapper" --scope working-tree >/dev/null 2>"$work/wstderr" ) || rc=$?
[ "$rc" = 2 ] || fail "a missing plugin must be refused (exit $rc: $(cat "$work/wstderr"))"
grep -Fq '/plugin install codex@openai-codex' "$work/wstderr" || fail "a missing plugin must be refused with install guidance: $(cat "$work/wstderr")"
[ ! -s "$FAKE_LOG" ] || fail "the plugin ran despite an argument refusal"
echo "hooks probe passed: review-wrapper"
