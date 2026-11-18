#!/usr/bin/env bun
// b-agentic Alexandria guard: a Claude Code PreToolUse hook for firecrawl_scrape. The tool is auto-allowed
// by name, but its `alexandria` argument runs the billed provider calls that the MCP policy keeps behind a
// prompt (alexandria_library_read, people_company_search, people_company_enrich), and permission rules
// cannot match an argument. This hook asks the user when that argument is present and is silent otherwise.
//
// Contract: stdin is the hook JSON; stdout carries a permissionDecision "ask" and exit is 0. The registered
// hook sets `onFailure: "block"`, so a crash or timeout blocks the call, and input it cannot parse asks.
// It reads only the tool name and whether the key exists, and prints a fixed reason, never the tool input,
// which can hold private queries.
import { readFileSync, realpathSync } from "node:fs";
import { pathToFileURL } from "node:url";

export const GUARDED_TOOL = "mcp__firecrawl__firecrawl_scrape";

const REASON =
  "firecrawl_scrape was called with an alexandria argument, which runs billed provider lookups (the same as alexandria_library_read, people_company_search and people_company_enrich). Approve it only if you want those lookups.";

export function needsAsk(event) {
  if (event === null || typeof event !== "object" || Array.isArray(event))
    return true;
  if (event.tool_name !== GUARDED_TOOL) return false;
  const input = event.tool_input;
  if (input === null || typeof input !== "object") return true;
  return Object.hasOwn(input, "alexandria") && input.alexandria != null;
}

function main() {
  let event;
  try {
    event = JSON.parse(readFileSync(0, "utf8"));
  } catch {
    event = null;
  }
  if (!needsAsk(event)) return 0;
  process.stdout.write(
    `${JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "ask",
        permissionDecisionReason: REASON,
      },
    })}\n`,
  );
  return 0;
}

function isEntryPoint() {
  try {
    return (
      import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href
    );
  } catch {
    return false;
  }
}

if (isEntryPoint()) {
  process.exitCode = main();
}
