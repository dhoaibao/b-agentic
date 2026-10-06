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
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeSync,
} from "node:fs";
import { homedir } from "node:os";
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
    process.env.B_AGENTIC_GATE_DIR ||
    join(homedir(), ".claude", "b-agentic", "verify-gate");
  return join(dir, `${String(sessionId).replace(/[^A-Za-z0-9_-]/g, "_")}.json`);
}

// The state directory must be a real directory owned by the current user with
// no group/other access, and state files are opened without following symlinks
// and only when regular, so another local user cannot redirect, tamper with, or
// block on the state. Anything else disables the gate (fail open).
const NOFOLLOW = constants.O_NOFOLLOW ?? 0;

function privateDir(dir, create) {
  try {
    if (create) mkdirSync(dir, { recursive: true, mode: 0o700 });
    const info = lstatSync(dir);
    if (!info.isDirectory()) return false;
    if (typeof process.getuid === "function") {
      if (info.uid !== process.getuid() || (info.mode & 0o077) !== 0) {
        return false;
      }
    }
    return true;
  } catch {
    return false;
  }
}

function readState(file) {
  const fallback = { dirty: false, reminded: false };
  let fd;
  try {
    if (!privateDir(join(file, ".."), false)) return fallback;
    fd = openSync(file, constants.O_RDONLY | NOFOLLOW | constants.O_NONBLOCK);
    if (!fstatSync(fd).isFile()) return fallback;
    return JSON.parse(readFileSync(fd, "utf8"));
  } catch {
    return fallback;
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
}

function writeState(file, state) {
  let fd;
  try {
    if (!privateDir(join(file, ".."), true)) return;
    fd = openSync(
      file,
      constants.O_WRONLY |
        constants.O_CREAT |
        constants.O_TRUNC |
        NOFOLLOW |
        constants.O_NONBLOCK,
      0o600,
    );
    if (!fstatSync(fd).isFile()) return;
    writeSync(fd, JSON.stringify(state));
  } catch {
    // Advisory only: an unusable state directory disables the gate.
  } finally {
    if (fd !== undefined) closeSync(fd);
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
