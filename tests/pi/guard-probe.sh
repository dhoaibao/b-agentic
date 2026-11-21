#!/usr/bin/env bash
# Exercise pi/extensions/b-agentic in real Pi with a scripted local model. Needs the Pi CLI,
# node, and jq: no credentials or network. Everything runs under a temporary HOME and agent
# directory, so no real ~/.pi or ~/.claude is read or written.
#
# Without `pi` the probe prints a skip line and exits 0; PI_PROBE_REQUIRE=1 turns every skip
# (including the specialist-child case below) into a failure. The specialist-child case also needs
# the npm packages: point PI_PROBE_NPM_DIR at a directory that holds `node_modules` with
# pi-subagents and @gotgenes/pi-permission-system (an agent directory's `npm` folder works).
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fail() { echo "pi guard probe failed: $*" >&2; exit 1; }
skip() {
  if [ "${PI_PROBE_REQUIRE:-}" = 1 ]; then fail "skipped but required: $*"; fi
  echo "pi guard probe skipped: $*"
}

if ! command -v pi >/dev/null 2>&1; then
  skip "pi is not installed"
  exit 0
fi

work=$(mktemp -d)
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT
home="$work/agent"
mkdir -p "$home/extensions/b-agentic" "$home/b-agentic/hooks" "$home/b-agentic/bin" "$home/agents" "$work/cwd" "$work/h"
for hook in b-path-guard b-verify-gate b-spec-context b-run-context b-alexandria-guard; do
  cp "$root/claude/hooks/$hook.mjs" "$home/b-agentic/hooks/"
done
cp "$root/claude/bin/b-protected.mjs" "$home/b-agentic/bin/"
cp "$root/pi/extensions/b-agentic/index.ts" "$root/pi/extensions/b-agentic/guard.mjs" "$home/extensions/b-agentic/"
printf 'SECRET=1\n' >"$work/cwd/.env"
printf 'EXAMPLE=1\n' >"$work/cwd/.env.example"
printf 'hello\n' >"$work/cwd/notes.txt"
mkdir -p "$work/cwd/.b-agentic/runs/x"
printf 'spec\n' >"$work/cwd/.b-agentic/runs/x/spec.md"
export HOME="$work/h" PI_CODING_AGENT_DIR="$home" PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0
unset B_AGENTIC_GATE_MODE B_AGENTIC_HELPER_DIR

# run_pi NAME STEPS PROMPT [DIR]: one scripted Pi run; events go to $work/NAME.jsonl, model calls to NAME.log.
# stdin comes from /dev/null: `pi -p` waits for EOF on an open non-terminal stdin.
run_pi() {
  local name=$1 steps=$2 prompt=$3 dir=${4:-$work/cwd}
  # Pi occasionally exits or stalls at startup on a cold cache; one retry keeps the probe from flaking.
  for _ in 1 2; do
    : >"$work/$name.log"
    if ( cd "$dir" && PI_PROBE_STEPS="$steps" PI_PROBE_LOG="$work/$name.log" timeout 60 pi \
        -e "$root/tests/pi/stub-provider.ts" --model probe/probe-1 --tools "*" --mode json --no-session "$prompt" \
        >"$work/$name.jsonl" 2>"$work/$name.err" </dev/null ); then
      return 0
    fi
  done
  fail "$name: pi exited non-zero twice: $(head -c 400 "$work/$name.err")"
}
# result NAME TOOL N FIELD: field of the Nth (0-based) tool result for TOOL.
result() {
  jq -rs --arg t "$2" --argjson n "$3" "[.[] | select(.type == \"tool_execution_end\" and .toolName == \$t)][\$n] | $4" "$work/$1.jsonl"
}
calls() { jq -s 'map(select(.type == "model_call")) | length' "$work/$1.log"; }

# --- secret paths --------------------------------------------------------------
run_pi secret '[{"name":"read","arguments":{"path":".env"}},{"name":"read","arguments":{"path":".env.example"}},"text"]' go
[ "$(result secret read 0 .isError)" = true ] || fail "read .env must be an error result"
result secret read 0 '.result.content[0].text' | grep -Fq 'likely-secret path' || fail "read .env gave no guard reason"
[ "$(result secret read 1 .isError)" = false ] || fail "read .env.example must be allowed"
result secret read 1 '.result.content[0].text' | grep -Fq 'EXAMPLE=1' || fail ".env.example was not read"
echo "pi guard probe passed: secret paths"

# --- run artifacts -------------------------------------------------------------
run_pi agentic '[{"name":"write","arguments":{"path":".b-agentic/runs/x/spec.md","content":"x"}},{"name":"read","arguments":{"path":".b-agentic/runs/x/spec.md"}},"text"]' go
[ "$(result agentic write 0 .isError)" = true ] || fail "write under .b-agentic must be refused"
result agentic write 0 '.result.content[0].text' | grep -Fq 'b-run write' || fail "the .b-agentic refusal must name b-run write"
[ "$(result agentic read 0 .isError)" = false ] || fail "read under .b-agentic must be allowed"
[ "$(cat "$work/cwd/.b-agentic/runs/x/spec.md")" = spec ] || fail "the refused write changed the spec"
echo "pi guard probe passed: .b-agentic"

# --- spellings Pi normalizes, symlinks, and directory searches ----------------------
ln -s .env "$work/cwd/notes-link"
printf 'TOKEN=1 needle\n' >"$work/cwd/.env.local"
ln -s .env "$work/cwd/it’s.txt"
printf 'needle in code\n' >"$work/cwd/code.txt"
run_pi spelled '[{"name":"write","arguments":{"path":"@.b-agentic/runs/x/spec.md","content":"x"}},{"name":"read","arguments":{"path":"@.env"}},{"name":"read","arguments":{"path":"notes-link"}},{"name":"read","arguments":{"path":"it'"'"'s.txt"}},{"name":"grep","arguments":{"pattern":"needle","path":"."}},{"name":"grep","arguments":{"pattern":"needle","path":".","glob":"code.txt"}},"text"]' go
[ "$(result spelled write 0 .isError)" = true ] || fail "write through an @ prefix under .b-agentic must be refused"
[ "$(cat "$work/cwd/.b-agentic/runs/x/spec.md")" = spec ] || fail "the @-prefixed write changed the spec"
[ "$(result spelled read 0 .isError)" = true ] || fail "read @.env must be refused"
[ "$(result spelled read 1 .isError)" = true ] || fail "read through a symlink to .env must be refused"
result spelled read 1 '.result.content[0].text' | grep -Fq 'likely-secret path' || fail "the symlink refusal gave no guard reason"
[ "$(result spelled read 2 .isError)" = true ] || fail "read of a spelling whose fallback is a link to .env must be refused"
result spelled read 2 '.result.content[0].text' | grep -Fq 'likely-secret path' || fail "the fallback-spelling refusal gave no guard reason"
[ "$(result spelled grep 0 .isError)" = true ] || fail "a directory grep over an unignored likely-secret file must be refused"
result spelled grep 0 '.result.content[0].text' | grep -Fq '.env.local' || fail "the grep refusal did not name the file"
! result spelled grep 0 '.result.content | map(.text) | join("\n")' | grep -Fq 'TOKEN=1' || fail "the refused grep still returned secret content"
[ "$(result spelled grep 1 .isError)" = false ] || fail "a grep narrowed by a glob must run"
grep_text=$(result spelled grep 1 '.result.content | map(.text) | join("\n")')
grep -Fq 'code.txt' <<<"$grep_text" || fail "the narrowed grep lost the ordinary match: $grep_text"
! grep -Fq 'TOKEN' <<<"$grep_text" || fail "the narrowed grep returned secret content: $grep_text"
echo "pi guard probe passed: normalized paths and grep"

# Pi collapses `..` before the OS follows links, and a write through a dangling link creates its target.
mkdir -p "$work/cwd/deep/sub"
ln -s deep/sub "$work/cwd/d"
ln -s .env "$work/cwd/envlink"
ln -s .b-agentic/runs/x/created.md "$work/cwd/dangling"
printf 'needle TOKEN=2\n' >"$work/cwd/w-1- n.env"
printf 'needle TOKEN=3\n' >"$work/cwd/$(printf 'foo.env.\nbar')"
ln -s toruns/../created.md "$work/cwd/nested"
ln -s .b-agentic/runs "$work/cwd/toruns"
run_pi aliases '[{"name":"read","arguments":{"path":"d/../envlink"}},{"name":"write","arguments":{"path":"dangling","content":"x"}},{"name":"write","arguments":{"path":"nested","content":"x"}},{"name":"grep","arguments":{"pattern":"needle","path":"."}},"text"]' go
[ "$(result aliases read 0 .isError)" = true ] || fail "read through d/../envlink must be refused"
[ "$(result aliases write 0 .isError)" = true ] || fail "write through a dangling link into .b-agentic must be refused"
[ ! -e "$work/cwd/.b-agentic/runs/x/created.md" ] || fail "the dangling-link write created a run artifact"
[ "$(result aliases write 1 .isError)" = true ] || fail "write through a link whose target holds .. into .b-agentic must be refused"
[ ! -e "$work/cwd/.b-agentic/created.md" ] || fail "the nested-link write created a file under .b-agentic"
alias_grep=$(result aliases grep 0 '.result.content | map(.text) | join("\n")')
[ "$(result aliases grep 0 .isError)" = true ] || fail "grep over files whose names hold a delimiter or a newline must be refused: $alias_grep"
! grep -Fq 'TOKEN=2' <<<"$alias_grep" || fail "grep leaked a file whose name holds the row delimiter: $alias_grep"
! grep -Fq 'TOKEN=3' <<<"$alias_grep" || fail "grep leaked a file whose name holds a newline: $alias_grep"
echo "pi guard probe passed: aliases"

# --- verify reminder -----------------------------------------------------------
run_pi gate-edit '[{"name":"write","arguments":{"path":"src.ts","content":"export {};\n"}},"text","text"]' go
[ "$(calls gate-edit)" = 3 ] || fail "an edit with no check must buy exactly one extra turn (calls=$(calls gate-edit))"
grep -Fq 'verify gate' "$work/gate-edit.log" || fail "the reminder text never reached the model"
run_pi gate-check '[{"name":"write","arguments":{"path":"src2.ts","content":"export {};\n"}},{"name":"bash","arguments":{"command":"npm test"}},"text"]' go
[ "$(calls gate-check)" = 3 ] || fail "edit then check must settle without a reminder (calls=$(calls gate-check))"
! grep -Fq 'verify gate' "$work/gate-check.log" || fail "a checked edit must not draw a reminder"
run_pi gate-prose '[{"name":"write","arguments":{"path":"notes2.md","content":"n\n"}},"text"]' go
[ "$(calls gate-prose)" = 2 ] || fail "a prose edit must not draw a reminder (calls=$(calls gate-prose))"
B_AGENTIC_GATE_MODE=off run_pi gate-off '[{"name":"write","arguments":{"path":"src3.ts","content":"export {};\n"}},"text"]' go
[ "$(calls gate-off)" = 2 ] || fail "gate mode off must not draw a reminder (calls=$(calls gate-off))"
echo "pi guard probe passed: verify gate"

# --- run context at startup ----------------------------------------------------
mkdir -p "$work/ctx/.b-agentic/runs/20261113-demo"
printf '20261113-demo\n' >"$work/ctx/.b-agentic/active"
printf '{"run_id":"20261113-demo","phase":"implement"}' >"$work/ctx/.b-agentic/runs/20261113-demo/state.json"
run_pi context '["text"]' go "$work/ctx"
grep -Fq 'b-agentic run context: run 20261113-demo is in phase implement' "$work/context.log" || fail "the run context never reached the model"
run_pi no-context '["text"]' go
! grep -Fq 'b-agentic run context' "$work/no-context.log" || fail "a project without a run must get no run context"
echo "pi guard probe passed: startup context"

# --- Alexandria argument, headless ----------------------------------------------
run_pi alexandria '[{"name":"mcp__firecrawl__firecrawl_scrape","arguments":{"url":"https://example.test","alexandria":{"q":1}}},{"name":"mcp__firecrawl__firecrawl_scrape","arguments":{"url":"https://example.test"}},"text"]' go
[ "$(result alexandria mcp__firecrawl__firecrawl_scrape 0 .isError)" = true ] || fail "an alexandria argument must be refused without a prompt"
result alexandria mcp__firecrawl__firecrawl_scrape 0 '.result.content[0].text' | grep -Fq 'confirmation prompt' || fail "the alexandria refusal gave no reason"
[ "$(result alexandria mcp__firecrawl__firecrawl_scrape 1 .isError)" = false ] || fail "a scrape without alexandria must run"
result alexandria mcp__firecrawl__firecrawl_scrape 1 '.result.content[0].text' | grep -Fq 'probe-scrape-ran' || fail "the plain scrape did not run"
echo "pi guard probe passed: alexandria"

# --- user's own bash command (RPC `bash`, as `!` in the terminal) ----------------
rpc_out="$work/rpc.jsonl"
# Pi drops commands still queued when stdin reaches EOF, so the feed stays open until the answers arrive.
( cd "$work/cwd" && { printf '%s\n' \
    '{"id":"1","type":"bash","command":"cat .env"}' \
    '{"id":"2","type":"bash","command":"echo x > .b-agentic/active"}' \
    '{"id":"3","type":"bash","command":"cat notes.txt"}'; sleep 6; } \
  | timeout 60 pi -e "$root/tests/pi/stub-provider.ts" --model probe/probe-1 --mode rpc --no-session \
    >"$rpc_out" 2>"$work/rpc.err" ) || fail "rpc: pi exited non-zero: $(head -c 400 "$work/rpc.err")"
rpc() { jq -rs --arg id "$1" "map(select(.type == \"response\" and .id == \$id)) | .[0] | $2" "$rpc_out"; }
[ "$(rpc 1 .data.exitCode)" = 1 ] || fail "user bash cat .env must be refused (exit $(rpc 1 .data.exitCode))"
rpc 1 .data.output | grep -Fq 'likely-secret path' || fail "user bash cat .env gave no guard reason"
! rpc 1 .data.output | grep -Fq 'SECRET=1' || fail "user bash cat .env leaked the secret"
[ "$(rpc 2 .data.exitCode)" = 1 ] || fail "user bash writing .b-agentic must be refused"
[ ! -e "$work/cwd/.b-agentic/active" ] || fail "the refused user bash command ran"
[ "$(rpc 3 .data.exitCode)" = 0 ] || fail "an ordinary user bash command must run"
rpc 3 .data.output | grep -Fq 'hello' || fail "the ordinary user bash command gave no output"
echo "pi guard probe passed: user bash"

# --- specialist child ----------------------------------------------------------
if [ -n "${PI_PROBE_NPM_DIR:-}" ]; then
  ln -s "$PI_PROBE_NPM_DIR" "$home/npm"
  printf '{"packages":["npm:pi-subagents","npm:@gotgenes/pi-permission-system"]}\n' >"$home/settings.json"
  mkdir -p "$home/extensions/pi-permission-system"
  # No secret or .b-agentic rule: only the owned guard can refuse those calls.
  printf '{"yoloMode":false,"permission":{"read":"allow","write":"allow","edit":"allow","find":"allow","grep":"allow","ls":"allow","bash":{"*":"allow"},"external_directory":"allow","subagent":"allow","bg_wait":"allow"}}\n' \
    >"$home/extensions/pi-permission-system/config.json"
  printf -- '---\nname: probe-reader\ndescription: "probe"\ntools: read, write, bash\nexcludeTools: edit, subagent\nsystemPromptMode: replace\nallowNestedSubagents: false\n---\n\nYou are a probe agent.\n' >"$home/agents/probe-reader.md"
  run_pi child '{"go":[{"name":"subagent","arguments":{"agent":"probe-reader","task":"CHILD-1 probe","async":false}},"text"],"CHILD-1":[{"name":"read","arguments":{"path":".env"}},{"name":"write","arguments":{"path":".b-agentic/runs/x/spec.md","content":"x"}},{"name":"read","arguments":{"path":"notes.txt"}},"text"]}' go
  child_reply() {
    jq -rs --argjson n "$1" 'map(select(.type == "model_call" and ((.messages | map(select(.role == "user")) | .[0].text) | test("CHILD-1")) and .n == $n)) | .[0].messages | last | .text' "$work/child.log"
  }
  denied=$(child_reply 1)
  grep -Fq 'likely-secret path' <<<"$denied" || fail "the specialist child read .env ungated: $denied"
  owned=$(child_reply 2)
  grep -Fq 'b-run write' <<<"$owned" || fail "the guard did not gate the specialist child's .b-agentic write: $owned"
  allowed=$(child_reply 3)
  grep -Fq 'hello' <<<"$allowed" || fail "the gated child could not read an ordinary file: $allowed"
  [ "$(cat "$work/cwd/.b-agentic/runs/x/spec.md")" = spec ] || fail "the child changed the spec"
  echo "pi guard probe passed: specialist child"
else
  skip "specialist child (set PI_PROBE_NPM_DIR to a directory holding node_modules with pi-subagents and @gotgenes/pi-permission-system)"
fi

echo "Pi guard probe passed."
