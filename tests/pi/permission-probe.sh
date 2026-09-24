#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
probe=${PI_PROBE_DIR:-"$root/node_modules/.pi-migration-probe"}
mkdir -p "$probe/home/extensions/pi-permission-system" "$probe/home/agents"
export PI_CODING_AGENT_DIR="$probe/home" PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0

cd "$probe"
if [[ "${1:-}" == --setup ]]; then
  # Each source is unpinned; Pi installs the newest release available at setup time.
  for source in \
    npm:@gotgenes/pi-subagents \
    npm:@gotgenes/pi-permission-system \
    npm:pi-mcp-adapter \
    npm:@juicesharp/rpiv-ask-user-question \
    npm:@gotgenes/pi-anthropic-auth \
    npm:@sreetej510/pi-usage; do
    pi install -l --approve "$source"
  done
  pi update --extensions --approve
fi

if [[ ! -f .pi/settings.json ]]; then
  echo "Pi probe packages missing; first run tests/pi/permission-probe.sh --setup" >&2
  exit 2
fi
for source in \
  npm:@gotgenes/pi-subagents \
  npm:@gotgenes/pi-permission-system \
  npm:pi-mcp-adapter \
  npm:@juicesharp/rpiv-ask-user-question \
  npm:@gotgenes/pi-anthropic-auth \
  npm:@sreetej510/pi-usage; do
  jq -e --arg source "$source" '.packages | index($source)' .pi/settings.json >/dev/null || {
    echo "Pi probe package missing: $source" >&2
    exit 2
  }
done

cat >"$probe/home/mcp.json" <<JSON
{"mcpServers":{"fake":{"command":"node","args":["$root/tests/pi/fake-mcp-server.mjs"],"directTools":true,"exposeResources":false}},"settings":{"toolPrefix":"server","allowInstall":false}}
JSON

run_case() {
  local name=$1 policy=$2 child_policy=$3 prompt=$4 expected=$5
  cat >"$probe/home/extensions/pi-permission-system/config.json" <<JSON
{"permission":{"*":"ask","subagent":"allow","fake_lookup":"allow","path":{"*":"allow","*.env":"deny"},"bash":{"echo permission-probe":"$policy"},"mcp":{"*":"ask","mcp_connect":"allow","fake":"deny"}}}
JSON
  cat >"$probe/home/agents/probe-reader.md" <<MD
---
description: Probe read-only specialist policy
tools: read, bash
model: stub/stub-1
permission:
  bash: $child_policy
  edit: deny
  write: deny
---

Report the observed tool result.
MD
  pi -a -e "$root/tests/pi/stub-provider.ts" --model stub/stub-1 \
    --mode json --no-session "$prompt" >"$probe/$name.jsonl"
  if ! jq -r 'select(.type == "tool_execution_end") | .result.content[]? | select(.type == "text") | .text' \
    "$probe/$name.jsonl" | grep -Fq "$expected"; then
    echo "Pi permission probe failed: $name (expected $expected)" >&2
    exit 1
  fi
  echo "Pi permission probe passed: $name"
}

run_case parent-deny deny deny shell "Denied by policy"
run_case parent-allow allow deny shell "permission-probe"
run_case child-allow allow allow child-shell "done: false permission-probe"
run_case child-deny allow deny child-deny "Tool bash not found"
run_case child-ask allow ask child-ask "no interactive UI is available"
run_case child-write allow deny child-write "Tool write not found"
run_case child-nested allow deny child-nested "Tool subagent not found"
run_case child-question allow deny child-question "Tool ask_user_question not found"
run_case child-path allow allow child-path "Denied by policy"
run_case mcp-proxy allow deny mcp "Denied by policy: 'mcp' for target 'fake'"
run_case mcp-direct allow deny direct "requires approval"
run_case mcp-direct-allow allow deny direct-allow "server-called:lookup"
run_case protected-path allow deny path "Denied by policy"

# A denied bash result contains the command text in its rule description. Check
# the tool's error flag as well as its output so denial cannot pass as success.
jq -e 'select(.type == "tool_execution_end" and .toolName == "bash" and .isError == false and any(.result.content[]?; .type == "text" and (.text | contains("permission-probe"))))' \
  "$probe/parent-allow.jsonl" >/dev/null
if jq -e 'select(.type == "tool_execution_end" and .toolName == "bash" and .isError == false)' \
  "$probe/parent-deny.jsonl" >/dev/null; then
  echo "Pi permission probe failed: denied parent bash reported success" >&2
  exit 1
fi
jq -e 'select(.type == "tool_execution_end" and .toolName == "subagent" and .isError == false and any(.result.content[]?; .type == "text" and (.text | contains("done: false permission-probe"))))' \
  "$probe/child-allow.jsonl" >/dev/null

# An unknown direct MCP tool must fail before the server handles it. A named
# read-only direct tool must reach the same local server through the adapter.
jq -e 'select(.type == "tool_execution_end" and .toolName == "fake_erase" and .isError == true)' \
  "$probe/mcp-direct.jsonl" >/dev/null
if grep -Fq 'server-called:erase' "$probe/mcp-direct.jsonl"; then
  echo "Pi permission probe failed: direct MCP erase reached the server" >&2
  exit 1
fi
jq -e 'select(.type == "tool_execution_end" and .toolName == "fake_lookup" and .isError == false)' \
  "$probe/mcp-direct-allow.jsonl" >/dev/null
