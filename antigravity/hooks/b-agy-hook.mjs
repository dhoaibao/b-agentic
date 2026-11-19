#!/usr/bin/env bun
// b-agentic hook adapter for the Antigravity CLI (agy). One entry point serves
// PreToolUse, PostToolUse, Stop, and SessionStart by translating agy's camelCase
// events into the inputs the Claude hooks' pure exports expect, then back into
// agy's output JSON. The Claude hooks are imported, never copied or changed.
//
// Contract: stdin is the hook JSON; stdout is one JSON object or nothing, and
// the exit code is 0. The adapter never prints `allow`: "no objection" prints
// nothing so agy permission `ask` rules still apply. PreToolUse is a guard
// event and denies on an internal error or a failed import; the other events
// fail open because the verify gate and the context pointers are advisory.
import { readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));

// Installed layout puts the Claude hook files next to this adapter; the repo
// and the tests find them under claude/hooks instead.
export const HOOK_DIRS = [HERE, join(HERE, "..", "..", "claude", "hooks")];

const HOOK_FILES = {
  pathGuard: "b-path-guard.mjs",
  codexGuard: "b-codex-guard.mjs",
  alexandria: "b-alexandria-guard.mjs",
  gate: "b-verify-gate.mjs",
  runContext: "b-run-context.mjs",
  specContext: "b-spec-context.mjs",
};

async function importFrom(dirs, file) {
  let failure;
  for (const dir of dirs) {
    try {
      return await import(pathToFileURL(join(dir, file)).href);
    } catch (error) {
      failure ??= error;
    }
  }
  throw failure ?? new Error(`cannot import ${file}`);
}

let cached;
export function loadModules(dirs = HOOK_DIRS) {
  if (dirs === HOOK_DIRS && cached) return cached;
  const pending = Promise.all(
    Object.entries(HOOK_FILES).map(async ([key, file]) => [
      key,
      await importFrom(dirs, file),
    ]),
  ).then(Object.fromEntries);
  if (dirs === HOOK_DIRS) {
    cached = pending;
    pending.catch(() => {
      cached = undefined;
    });
  }
  return pending;
}

// The verify gate defaults to a folder under ~/.claude; under agy its state stays in agy's own folder.
function useAgyGateDir() {
  process.env.B_AGENTIC_GATE_DIR ||= join(
    process.env.HOME || homedir(),
    ".gemini",
    "config",
    "b-agentic",
    "verify-gate",
  );
}

// The probes captured `Path` for read_file and write_file; no edit_file call was captured, so the
// other names agy's tool schemas mention are checked too instead of silently skipping the guard.
const PATH_KEYS = ["Path", "TargetFile", "AbsolutePath"];
const targetPaths = (args) =>
  PATH_KEYS.map((key) => args[key]).filter(
    (value) => typeof value === "string" && value !== "",
  );

const FILE_TOOLS = new Set(["read_file", "write_file", "edit_file"]);
const WRITE_FILE_TOOLS = new Set(["write_file", "edit_file"]);
const SECRET_REASON =
  "b-agentic path guard: likely-secret paths (.env, *.pem, credentials.*, secrets.*) need explicit user permission to read or change; ask the user first.";
const AGENTIC_REASON =
  "b-agentic path guard: run artifacts under .b-agentic are written only by the run-state tools (b-state and b_run.py); read them with read_file.";
const ALEXANDRIA_REASON =
  "firecrawl_scrape was called with an alexandria argument, which runs billed provider lookups. Approve it only if you want those lookups.";

const deny = (reason) => ({ decision: "deny", reason });
const asObject = (value) =>
  value !== null && typeof value === "object" && !Array.isArray(value)
    ? value
    : {};

// Words of a shell command that could name a file: the tokenizer's decoded
// words and redirect targets, plus a coarse split so an ambiguous command
// (expansions, unbalanced quotes) still has its literal names checked.
function commandWords(command, tokenize) {
  const words = new Set(command.split(/[\s'"=:;|&<>()`$,]+/).filter(Boolean));
  try {
    for (const segment of tokenize(command).segments ?? []) {
      for (const token of segment.tokens ?? []) words.add(token);
      for (const redirect of segment.redirects ?? []) {
        if (typeof redirect?.target === "string") words.add(redirect.target);
      }
    }
  } catch {
    // The coarse split above still applies.
  }
  return [...words];
}

async function preToolUse(event, modules) {
  const call = asObject(event.toolCall);
  const args = asObject(call.args);
  const cwd = typeof event.cwd === "string" ? event.cwd : process.cwd();
  const { pathGuard, codexGuard, alexandria } = modules;

  if (FILE_TOOLS.has(call.name)) {
    for (const path of targetPaths(args)) {
      const input = { file_path: path };
      if (WRITE_FILE_TOOLS.has(call.name)) {
        const owned = pathGuard.agenticWrites(
          input,
          call.name === "write_file" ? "Write" : "Edit",
          cwd,
        );
        if (owned.length > 0) return deny(AGENTIC_REASON);
      }
      if (pathGuard.blockedPaths(input, "Read").length > 0) {
        return deny(SECRET_REASON);
      }
    }
    return null;
  }

  if (call.name === "run_command") {
    const command = args.CommandLine;
    if (typeof command !== "string") return null;
    const verdict = await codexGuard.judgeCommand(command, cwd);
    if (verdict.decision === "refuse") {
      return deny(`b-agentic Codex guard refused: ${verdict.reason}.`);
    }
    for (const word of commandWords(command, codexGuard.tokenize)) {
      if (pathGuard.blockedPaths({ file_path: word }, "Read").length > 0) {
        return deny(SECRET_REASON);
      }
    }
    return null;
  }

  if (call.name === "call_mcp_tool") {
    const name = `mcp__${args.ServerName}__${args.ToolName}`;
    if (alexandria.needsAsk({ tool_name: name, tool_input: args.Arguments })) {
      return { decision: "force_ask", reason: ALEXANDRIA_REASON };
    }
  }
  return null;
}

function postToolUse(event, modules) {
  const call = asObject(event.toolCall);
  const args = asObject(call.args);
  const base = {
    hook_event_name: "PostToolUse",
    session_id: event.conversationId,
    cwd: event.cwd,
  };
  useAgyGateDir();
  if (call.name === "run_command") {
    modules.gate.handle({
      ...base,
      tool_name: "Bash",
      tool_input: { command: args.CommandLine },
    });
  } else if (WRITE_FILE_TOOLS.has(call.name)) {
    modules.gate.handle({
      ...base,
      tool_name: "Write",
      tool_input: { file_path: targetPaths(args)[0] },
    });
  }
  return null;
}

function stop(event, modules) {
  // Stop also fires for subagents while a parent waits; only a fully idle
  // conversation is a real end of turn.
  if (event.fullyIdle !== true) return null;
  useAgyGateDir();
  const result = modules.gate.handle({
    hook_event_name: "Stop",
    session_id: event.conversationId,
    cwd: event.cwd,
    stop_hook_active: event.continuationActive === true,
  });
  return result.code === 2 && result.message
    ? { decision: "continue", reason: result.message }
    : null;
}

function sessionStart(event, modules) {
  const parts = [
    modules.runContext.buildContext(modules.runContext.activeRun(event.cwd)),
    modules.specContext.buildContext(
      modules.specContext.approvedSpecs(event.cwd),
    ),
  ].filter((part) => typeof part === "string" && part !== "");
  if (parts.length === 0) return null;
  return {
    injectSteps: [{ systemMessage: { systemMessage: parts.join("\n") } }],
  };
}

// Returns the output object for agy, or null when there is no objection.
export async function handle(event, { loader = loadModules } = {}) {
  const name = event?.hookEventName;
  if (name === "PreToolUse") {
    try {
      return await preToolUse(event, await loader());
    } catch (error) {
      return deny(
        `b-agentic hook adapter failed closed (${error instanceof Error ? error.message : String(error)}).`,
      );
    }
  }
  if (!["PostToolUse", "Stop", "SessionStart"].includes(name)) return null;
  try {
    const modules = await loader();
    if (name === "PostToolUse") return postToolUse(event, modules);
    if (name === "Stop") return stop(event, modules);
    return sessionStart(event, modules);
  } catch {
    return null;
  }
}

async function main() {
  const raw = readFileSync(0, "utf8");
  let output;
  try {
    output = await handle(JSON.parse(raw));
  } catch {
    // Unreadable input cannot be classified; a PreToolUse envelope is refused.
    output = raw.includes('"PreToolUse"')
      ? deny("b-agentic hook adapter could not read the hook input.")
      : null;
  }
  if (output) process.stdout.write(`${JSON.stringify(output)}\n`);
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
  process.exitCode = await main();
}
