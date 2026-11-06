#!/usr/bin/env node
// b-agentic Codex hook adapter: one command for the Codex PreToolUse,
// PostToolUse, and Stop hooks. It maps Codex's tool events onto the shared
// verify gate installed beside it (`b-verify-gate.mjs`), applies the snapshot
// CLI's likely-secret path rules (`isProtected`) to patches and shell words,
// and adds a read-only check for the managed specialists.
//
// Contract (Codex hooks): stdin is the hook JSON; exit 2 with a stderr reason
// denies a tool call or blocks a stop, and any other exit lets it continue.
// A Codex hook cannot ask, errors never block a tool call, and hooks do not
// run for hosted tools, so this is a guardrail rather than an enforcement
// boundary. It reads only names and command text, never file content, and
// fails open on malformed input.
//
// Codex edits arrive as `apply_patch` with the patch text in
// `tool_input.command`; file reads go through the shell, so the shell command
// text is scanned for likely-secret file names on a best-effort basis.
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { isProtected } from "../bin/b-candidate-snapshot.mjs";
import { handle as gate } from "./b-verify-gate.mjs";

// The verify gate's state belongs to this runtime, not to ~/.claude.
process.env.B_AGENTIC_GATE_DIR ||= join(
  homedir(),
  ".codex",
  "b-agentic",
  "verify-gate",
);

// The managed specialists, used when the generated allowlist file is missing.
const DEFAULT_SPECIALISTS = [
  "b-planner",
  "b-researcher",
  "b-debugger",
  "b-auditor",
  "b-reviewer",
];
const EDIT_TOOLS = new Set(["apply_patch", "Edit", "Write"]);
const asRaw = (value) => Buffer.from(value, "utf8").toString("latin1");

// `*** Add File: p`, `*** Update File: p`, `*** Delete File: p`, `*** Move to: p`.
const PATCH_HEADER =
  /^\*\*\* (?:Add File|Update File|Delete File|Move to): (.+)$/gm;

export function patchPaths(patch) {
  if (typeof patch !== "string") return [];
  return [...patch.matchAll(PATCH_HEADER)].map((match) => match[1].trim());
}

// Words of a shell command that name a likely-secret file. Shell syntax is not
// interpreted: quotes and separators are stripped and each word is checked, so
// `cat .env`, `rg x ./app/.env`, and `bash -lc 'cat .env'` are all caught while
// `cat .env.example` stays allowed (the snapshot CLI's rules). Property
// accessors such as `process.env.API_KEY` look like `*.env.*` but name no file.
const ENV_ACCESSOR = /^(?:process|import\.meta|Deno)\.env(?:[.[]|$)/;

export function secretWords(command) {
  if (typeof command !== "string") return [];
  return command
    .split(/[\s;&|<>()"'`=]+/)
    .filter(
      (word) =>
        word !== "" &&
        !(ENV_ACCESSOR.test(word) && !word.includes("/")) &&
        isProtected(asRaw(word)),
    );
}

export function blockedForCall(event) {
  const tool = event?.tool_name;
  const input = event?.tool_input;
  if (!input || typeof input !== "object") return [];
  if (EDIT_TOOLS.has(tool)) {
    const paths = [
      ...patchPaths(input.command),
      ...[input.file_path, input.path].filter((p) => typeof p === "string"),
    ];
    return paths.filter((path) => isProtected(asRaw(path)));
  }
  if (tool === "Bash") return secretWords(input.command);
  return [];
}

// The MCP tools each specialist may call, keyed by specialist name, generated
// from the policy and the registry and installed beside the hooks. A missing or
// unreadable file leaves the built-in names and only the edit denial in force.
function loadAllowlist() {
  try {
    const file = fileURLToPath(
      new URL("../references/specialist-tools.json", import.meta.url),
    );
    if (!existsSync(file)) return null;
    const table = JSON.parse(readFileSync(file, "utf8"));
    return table && typeof table === "object" ? table : null;
  } catch {
    return null;
  }
}

export function specialistViolation(event, load = loadAllowlist) {
  const agent = event?.agent_type;
  if (typeof agent !== "string") return null;
  const table = load();
  const managed = table ? Object.keys(table) : DEFAULT_SPECIALISTS;
  if (!managed.includes(agent)) return null;
  const tool = event?.tool_name;
  if (EDIT_TOOLS.has(tool)) {
    return `${agent} is a read-only specialist; ${tool} is denied. Report the needed change to the main session.`;
  }
  if (typeof tool === "string" && tool.startsWith("mcp__")) {
    const list = table?.[agent];
    if (Array.isArray(list) && !list.includes(tool)) {
      return `${agent} is a read-only specialist; ${tool} is not on its MCP allowlist. Report the needed operation to the main session.`;
    }
  }
  return null;
}

// Map a Codex apply_patch event onto the shared gate's Edit events.
function gateEvents(event) {
  if (event.hook_event_name !== "PostToolUse") return [event];
  if (EDIT_TOOLS.has(event.tool_name)) {
    const paths = patchPaths(event.tool_input?.command);
    const targets = paths.length ? paths : [event.tool_input?.file_path];
    return targets.map((file_path) => ({
      ...event,
      tool_name: "Edit",
      tool_input: { file_path },
    }));
  }
  return [event];
}

export function handle(event) {
  const name = event?.hook_event_name;
  if (name === "PreToolUse") {
    const violation = specialistViolation(event);
    if (violation) return { code: 2, message: `b-agentic: ${violation}` };
    const blocked = blockedForCall(event);
    if (blocked.length > 0) {
      return {
        code: 2,
        message: `b-agentic path guard: ${event.tool_name} refused on likely-secret path ${blocked.join(", ")}. Likely-secret files (.env, *.pem, credentials.*, secrets.*) need explicit user permission to read or change; ask the user first.`,
      };
    }
    return { code: 0 };
  }
  if (name === "PostToolUse" || name === "Stop") {
    let result = { code: 0 };
    for (const mapped of gateEvents(event)) {
      const next = gate(mapped);
      if (next.code !== 0) result = next;
    }
    return result;
  }
  return { code: 0 };
}

function main() {
  let event;
  try {
    event = JSON.parse(readFileSync(0, "utf8"));
  } catch {
    return 0;
  }
  const result = handle(event ?? {});
  if (result.message) process.stderr.write(`${result.message}\n`);
  return result.code;
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
