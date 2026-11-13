#!/usr/bin/env bash
# Exercise pi/extensions/b-agentic in real Pi with a scripted local model. Needs the Pi CLI
# (the probe skips without it), node, and jq: no credentials or network. The specialist-child
# case also needs the pinned npm packages: point PI_PROBE_NPM_DIR at an agent directory's `npm`
# folder (for example ~/.pi/agent/npm after `pi install`); without it that case is skipped.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fail() { echo "pi guard probe failed: $*" >&2; exit 1; }

if ! command -v pi >/dev/null 2>&1; then
  echo "pi guard probe skipped: pi is not installed"
  exit 0
fi

work=$(mktemp -d)
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT
home="$work/home"
mkdir -p "$home/extensions/b-agentic" "$home/b-agentic/hooks" "$home/b-agentic/bin" "$home/agents" "$work/cwd"
for hook in b-path-guard b-verify-gate b-spec-context b-run-context; do
  cp "$root/claude/hooks/$hook.mjs" "$home/b-agentic/hooks/"
done
cp "$root/claude/bin/b-candidate-snapshot.mjs" "$home/b-agentic/bin/"
cp "$root/pi/extensions/b-agentic/index.ts" "$root/pi/extensions/b-agentic/guard.mjs" "$home/extensions/b-agentic/"
printf 'SECRET=1\n' >"$work/cwd/.env"
printf 'EXAMPLE=1\n' >"$work/cwd/.env.example"
printf 'hello\n' >"$work/cwd/notes.txt"
mkdir -p "$work/cwd/.b-agentic/runs/x"
printf 'spec\n' >"$work/cwd/.b-agentic/runs/x/spec.md"
export PI_CODING_AGENT_DIR="$home" PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0

# run_pi NAME STEPS PROMPT [DIR]: one scripted Pi run; events go to $work/NAME.jsonl, model calls to NAME.log.
run_pi() {
  local name=$1 steps=$2 prompt=$3 dir=${4:-$work/cwd}
  # Pi occasionally exits or stalls at startup on a cold cache; one retry keeps the probe from flaking.
  for _ in 1 2; do
    : >"$work/$name.log"
    if ( cd "$dir" && PI_PROBE_STEPS="$steps" PI_PROBE_LOG="$work/$name.log" timeout 60 pi \
        -e "$root/tests/pi/stub-provider.ts" --model probe/probe-1 --mode json --no-session "$prompt" \
        >"$work/$name.jsonl" 2>"$work/$name.err" ); then
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
result agentic write 0 '.result.content[0].text' | grep -Fq 'b_run.py' || fail "the .b-agentic refusal must name b_run.py"
[ "$(result agentic read 0 .isError)" = false ] || fail "read under .b-agentic must be allowed"
[ "$(cat "$work/cwd/.b-agentic/runs/x/spec.md")" = spec ] || fail "the refused write changed the spec"
echo "pi guard probe passed: .b-agentic"

# --- verify reminder -----------------------------------------------------------
run_pi gate-edit '[{"name":"write","arguments":{"path":"src.ts","content":"export {};\n"}},"text","text"]' go
[ "$(calls gate-edit)" = 3 ] || fail "an edit with no check must buy exactly one extra turn (calls=$(calls gate-edit))"
grep -Fq 'verify gate' "$work/gate-edit.log" || fail "the reminder text never reached the model"
run_pi gate-check '[{"name":"write","arguments":{"path":"src2.ts","content":"export {};\n"}},{"name":"bash","arguments":{"command":"npm test"}},"text"]' go
[ "$(calls gate-check)" = 3 ] || fail "edit then check must settle without a reminder (calls=$(calls gate-check))"
! grep -Fq 'verify gate' "$work/gate-check.log" || fail "a checked edit must not draw a reminder"
run_pi gate-prose '[{"name":"write","arguments":{"path":"notes2.md","content":"n\n"}},"text"]' go
[ "$(calls gate-prose)" = 2 ] || fail "a prose edit must not draw a reminder (calls=$(calls gate-prose))"
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

# --- specialist child ----------------------------------------------------------
if [ -n "${PI_PROBE_NPM_DIR:-}" ]; then
  ln -s "$PI_PROBE_NPM_DIR" "$home/npm"
  cp "$root/pi/configs/settings.packages.json" "$home/settings.json"
  mkdir -p "$home/extensions/pi-permission-system"
  cp "$root/pi/configs/permission.json" "$home/extensions/pi-permission-system/config.json"
  printf -- '---\nname: probe-reader\ndescription: "probe"\ntools: read, write, bash\nexcludeTools: edit, subagent, ask_user_question\nsystemPromptMode: replace\nallowNestedSubagents: false\n---\n\nYou are a probe agent.\n' >"$home/agents/probe-reader.md"
  run_pi child '{"go":[{"name":"subagent","arguments":{"agent":"probe-reader","task":"CHILD-1 probe","async":false}},"text"],"CHILD-1":[{"name":"read","arguments":{"path":".env"}},{"name":"write","arguments":{"path":".b-agentic/runs/x/spec.md","content":"x"}},{"name":"read","arguments":{"path":"notes.txt"}},"text"]}' go
  denied=$(jq -rs 'map(select(.type == "model_call" and ((.messages | map(select(.role == "user")) | .[0].text) | test("CHILD-1")) and .n == 1)) | .[0].messages | last | .text' "$work/child.log")
  grep -Eq 'likely-secret path|Denied by policy' <<<"$denied" || fail "the specialist child read .env ungated: $denied"
  # The permission config has no .b-agentic rule, so only the guard can refuse this write.
  owned=$(jq -rs 'map(select(.type == "model_call" and ((.messages | map(select(.role == "user")) | .[0].text) | test("CHILD-1")) and .n == 2)) | .[0].messages | last | .text' "$work/child.log")
  grep -Fq 'b_run.py' <<<"$owned" || fail "the guard did not gate the specialist child's .b-agentic write: $owned"
  allowed=$(jq -rs 'map(select(.type == "model_call" and ((.messages | map(select(.role == "user")) | .[0].text) | test("CHILD-1")) and .n == 3)) | .[0].messages | last | .text' "$work/child.log")
  grep -Fq 'hello' <<<"$allowed" || fail "the gated child could not read an ordinary file: $allowed"
  echo "pi guard probe passed: specialist child"
else
  echo "pi guard probe skipped: specialist child (set PI_PROBE_NPM_DIR to an agent npm directory)"
fi

echo "Pi guard probe passed."
