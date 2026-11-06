#!/usr/bin/env bash
# Exercise the Codex hook adapter (codex/hooks/b-codex-hooks.mjs) with scripted Codex hook JSON in
# the installed layout (adapter, shared hooks, snapshot CLI, and specialist allowlist side by
# side). Needs only node and jq: no credentials, network, or Codex.
# shellcheck disable=SC2016 # Single-quoted patch text with literal $ and quotes is the input under test.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT

# The installed layout: <root>/hooks, <root>/bin, <root>/references.
mkdir -p "$work/b-agentic/hooks" "$work/b-agentic/bin" "$work/b-agentic/references" "$work/home"
cp "$root/codex/hooks/b-codex-hooks.mjs" "$root/claude/hooks/b-verify-gate.mjs" "$work/b-agentic/hooks/"
cp "$root/claude/bin/b-candidate-snapshot.mjs" "$work/b-agentic/bin/"
cp "$root/codex/references/specialist-tools.json" "$work/b-agentic/references/"
adapter="$work/b-agentic/hooks/b-codex-hooks.mjs"
export HOME="$work/home"
unset B_AGENTIC_GATE_DIR

fail() { echo "codex hooks probe failed: $*" >&2; exit 1; }

rc=0
err=""
run() {
  rc=0
  err=$(printf '%s' "$1" | node "$adapter" 2>&1 >/dev/null) || rc=$?
}
expect() { [ "$rc" = "$1" ] || fail "$2 (exit $rc, expected $1: $err)"; }

pre() { jq -cn --arg tool "$1" --arg command "$2" --arg agent "${3:-}" \
  '{hook_event_name: "PreToolUse", session_id: "s1", tool_name: $tool, tool_input: {command: $command}} + (if $agent == "" then {} else {agent_type: $agent} end)'; }
patch() { printf '*** Begin Patch\n*** %s File: %s\n@@\n+x\n*** End Patch\n' "$1" "$2"; }

# --- path guard on apply_patch and shell ------------------------------------------
run "$(pre apply_patch "$(patch Update /repo/.env)")"; expect 2 "apply_patch on .env must be denied"
grep -Fq 'likely-secret path' <<<"$err" || fail "path guard gave no reason"
run "$(pre apply_patch "$(patch Add /repo/keys/server.pem)")"; expect 2 "apply_patch adding a .pem must be denied"
run "$(pre apply_patch "$(patch Delete /repo/config/credentials.json)")"; expect 2 "apply_patch deleting credentials must be denied"
run "$(pre apply_patch "$(printf '*** Begin Patch\n*** Update File: src/a.ts\n*** Move to: secrets.yaml\n@@\n+x\n*** End Patch\n')")"; expect 2 "apply_patch moving to secrets must be denied"
run "$(pre apply_patch "$(patch Update /repo/.env.example)")"; expect 0 ".env.example is explicitly allowed"
run "$(pre apply_patch "$(patch Update /repo/src/app.ts)")"; expect 0 "ordinary patch must pass"
run "$(pre Bash 'cat .env')"; expect 2 "a shell read of .env must be denied"
run "$(pre Bash "bash -lc 'rg token ./app/.env.production'")"; expect 2 "a shell search naming .env.production must be denied"
run "$(pre Bash 'cat .env.example')"; expect 0 "a shell read of .env.example must pass"
run "$(pre Bash 'git status --short')"; expect 0 "an ordinary shell command must pass"
run "$(pre Bash 'node -e "console.log(process.env.API_KEY)"')"; expect 0 "process.env.* names no file and must pass"
run "$(pre Bash 'rg -n import.meta.env.VITE src')"; expect 0 "import.meta.env.* names no file and must pass"
run 'not json'; expect 0 "malformed input must fail open"
run ''; expect 0 "empty input must fail open"
echo "codex hooks probe passed: path-guard"

# --- read-only specialists ----------------------------------------------------------
run "$(pre apply_patch "$(patch Update /repo/src/app.ts)" b-planner)"; expect 2 "a specialist's apply_patch must be denied"
grep -Fq 'read-only specialist' <<<"$err" || fail "specialist denial gave no reason"
run "$(pre apply_patch "$(patch Update /repo/src/app.ts)" worker)"; expect 0 "a non-managed role keeps apply_patch"
run "$(pre mcp__clickup__createTask '' b-reviewer)"; expect 2 "a specialist's mutating MCP tool must be denied"
run "$(pre mcp__codegraph__codegraph_explore '' b-reviewer)"; expect 0 "a specialist's allowlisted MCP tool must pass"
run "$(pre mcp__clickup__createTask '' '')"; expect 0 "the main session's MCP call is left to config.toml approvals"
run "$(pre Bash 'rg foo src' b-debugger)"; expect 0 "a specialist's shell inspection must pass"
jq '. + {"b-newcomer": []}' "$work/b-agentic/references/specialist-tools.json" >"$work/tools.json" && mv "$work/tools.json" "$work/b-agentic/references/specialist-tools.json"
run "$(pre apply_patch "$(patch Update /repo/src/app.ts)" b-newcomer)"; expect 2 "a specialist named only in the generated allowlist must be read-only"
rm "$work/b-agentic/references/specialist-tools.json"
run "$(pre mcp__clickup__createTask '' b-reviewer)"; expect 0 "a missing allowlist leaves only the edit denial"
run "$(pre apply_patch "$(patch Update /repo/src/app.ts)" b-reviewer)"; expect 2 "the edit denial survives a missing allowlist"
echo "codex hooks probe passed: specialists"

# --- verify gate ----------------------------------------------------------------------
post() { jq -cn --arg tool "$1" --arg command "$2" --arg agent "${3:-}" \
  '{hook_event_name: "PostToolUse", session_id: "g1", tool_name: $tool, tool_input: {command: $command}} + (if $agent == "" then {} else {agent_id: $agent} end)'; }
stop() { jq -cn --arg active "${2:-false}" '{hook_event_name: "Stop", session_id: $ARGS.positional[0], stop_hook_active: ($active == "true")}' --args "$1"; }
run "$(stop g1)"; expect 0 "no edits: the stop passes"
run "$(post apply_patch "$(patch Update /repo/src/app.ts)")"; expect 0 "tracking an edit never blocks"
run "$(stop g1)"; expect 2 "an edit without a later check must block the first stop"
grep -Fq 'verify gate' <<<"$err" || fail "verify gate gave no reminder"
[ -d "$work/home/.codex/b-agentic/verify-gate" ] || fail "verify gate state must live under ~/.codex/b-agentic"
[ ! -e "$work/home/.claude" ] || fail "the Codex adapter wrote under ~/.claude"
run "$(stop g1)"; expect 0 "the gate reminds only once"
run "$(post apply_patch "$(patch Update /repo/docs/readme.md)")"; run "$(stop g1)"; expect 0 "a prose-only edit needs no reminder"
run "$(post apply_patch "$(patch Update /repo/src/b.ts)")"; run "$(post Bash 'npm test')"; run "$(stop g1)"; expect 0 "a check after the edit clears the gate"
run "$(post apply_patch "$(patch Update /repo/src/c.ts)")"; run "$(post Bash 'rg foo' '')"; run "$(stop g1)"; expect 2 "read-only inspection is not a check"
run "$(post apply_patch "$(patch Update /repo/src/d.ts)")"; run "$(stop g1 true)"; expect 0 "a stop_hook_active continuation never re-arms the gate"
echo "codex hooks probe passed: verify-gate"
