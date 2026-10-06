#!/usr/bin/env node
// b-agentic verify gate: an advisory, one-shot reminder at the end of a turn.
//
// When the main session edited files after its last shell command and is about
// to stop, block the stop once with a short message restating the kernel's
// verify/review rule. It never blocks a tool call and never repeats within one
// session turn.
//
// Wired as a PostToolUse hook (Edit|Write|NotebookEdit|Bash) that tracks the
// state and a Stop hook that emits the reminder. Contract: stdin is the hook
// JSON; exit 2 with a stderr reason blocks the stop, any other exit lets it
// finish. It fails open on malformed input and unreadable state.
import {
  mkdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

// Prose-only edits carry no behavior to verify.
const PROSE_PATH = /\.(md|mdx|txt|rst)$/i;

export const REMINDER = [
  "b-agentic verify gate: files were edited after the last shell command in this run.",
  "Before finishing, run the applicable checks and inspect the changed paths and diff.",
  "If the change touches a kernel review trigger (security, permissions, contracts,",
  "dependencies, installer or config merge, workflow policy), freeze the checked candidate",
  "and run the independent b-review gate; otherwise state the low-risk exception.",
  "If the work is already verified, or there is nothing to verify, say so in one line and finish.",
].join(" ");

function stateFile(sessionId) {
  const dir =
    process.env.B_AGENTIC_STATE_DIR || join(tmpdir(), "b-agentic-verify-gate");
  return join(dir, `${String(sessionId).replace(/[^A-Za-z0-9_-]/g, "_")}.json`);
}

function readState(file) {
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return { dirty: false, reminded: false };
  }
}

function writeState(file, state) {
  try {
    mkdirSync(join(file, ".."), { recursive: true });
    writeFileSync(file, JSON.stringify(state));
  } catch {
    // Advisory only: an unwritable state directory disables the gate.
  }
}

export function handle(event) {
  const file = stateFile(event.session_id ?? "default");
  const state = readState(file);
  if (event.hook_event_name === "PostToolUse") {
    if (event.tool_name === "Bash") {
      // Any shell command counts as a check attempt, pass or fail.
      writeState(file, { ...state, dirty: false });
    } else if (["Edit", "Write", "NotebookEdit"].includes(event.tool_name)) {
      const path =
        event.tool_input?.file_path ?? event.tool_input?.notebook_path;
      if (!(typeof path === "string" && PROSE_PATH.test(path))) {
        writeState(file, { ...state, dirty: true });
      }
    }
    return { code: 0 };
  }
  if (event.hook_event_name === "Stop") {
    // The gate's own continuation, or a later stop, never re-arms it.
    if (event.stop_hook_active || state.reminded || !state.dirty) {
      rmSync(file, { force: true });
      return { code: 0 };
    }
    writeState(file, { dirty: false, reminded: true });
    return { code: 2, message: REMINDER };
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
