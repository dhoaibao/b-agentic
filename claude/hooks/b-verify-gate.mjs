#!/usr/bin/env node
// b-agentic verify gate: an advisory, one-shot reminder at the end of a turn.
//
// When the main session edited files after its last non-inspection shell
// command (read-only searches and listings do not count) and is about
// to stop, block the stop once with a short message restating the kernel's
// verify/review rule. It never blocks a tool call and never repeats within one
// session turn. Subagents share the session, so their shell commands (which
// carry an agent_id) never count as the main session's check.
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
  "b-agentic verify gate: files were edited after the last non-inspection shell command in this run.",
  "Before finishing, run the applicable checks and inspect the changed paths and diff.",
  "If the change touches a kernel review trigger (security, permissions, contracts,",
  "dependencies, installer or config merge, workflow policy), freeze the checked candidate",
  "and run the independent b-review gate; otherwise state the low-risk exception.",
  "If the work is already verified, or there is nothing to verify, say so in one line and finish.",
].join(" ");

// Read-only searches and listings are not check attempts. Native builds run
// content and name searches through Bash, so counting them would silence the
// reminder after every edit. Anything ambiguous counts as a check, as before.
const INSPECTION = new Set([
  "rg",
  "grep",
  "egrep",
  "fgrep",
  "ugrep",
  "bfs",
  "fd",
  "fdfind",
  "find",
  "ls",
  "eza",
  "cat",
  "head",
  "tail",
  "wc",
  "jq",
  "pwd",
  "echo",
  "stat",
  "diff",
]);
const GIT_READS = new Set([
  "status",
  "diff",
  "log",
  "show",
  "ls-files",
  "rev-parse",
]);

// Options that run another command or write a file, wherever they appear.
const EXECUTING =
  /^(-(exec|execdir|ok|okdir|delete|fprint0?|fprintf|fls)|--(pre|filter|pager|hostname-bin|exec|exec-batch|output|ext-diff|textconv)(=.*)?)$/;
// A cluster of fd/fdfind short options that includes -x or -X.
const FD_EXEC = /^-[A-Za-z0-9]*[xX]/;

// Splits a command into simple commands of decoded words (quotes and escapes
// resolved), or returns null when it holds anything this hook does not
// interpret: redirection, expansion, substitution, or a subshell.
function simpleCommands(command) {
  const commands = [];
  let words = [];
  let word = null;
  // A word that starts with an unquoted glob character could expand to an
  // option name; tracked per simple command.
  let wild = false;
  const endWord = () => {
    if (word !== null) words.push(word);
    word = null;
  };
  const endCommand = () => {
    endWord();
    if (words.length > 0) commands.push({ words, wild });
    words = [];
    wild = false;
  };
  for (let i = 0; i < command.length; i++) {
    const c = command[i];
    if (c === "'") {
      const end = command.indexOf("'", i + 1);
      if (end < 0) return null;
      word = (word ?? "") + command.slice(i + 1, end);
      i = end;
    } else if (c === '"') {
      let text = "";
      let j = i + 1;
      for (; j < command.length && command[j] !== '"'; j++) {
        if (command[j] === "`" || command[j] === "$") return null;
        if (command[j] === "\\") {
          j += 1;
          if (j >= command.length) return null;
          if (command[j] === "\n") continue;
          if (!'$`"\\'.includes(command[j])) text += "\\";
        }
        text += command[j];
      }
      if (j >= command.length) return null;
      word = (word ?? "") + text;
      i = j;
    } else if (c === "\\") {
      if (i + 1 >= command.length) return null;
      i += 1;
      if (command[i] !== "\n") word = (word ?? "") + command[i];
    } else if (c === " " || c === "\t") {
      endWord();
    } else if (c === "\n" || c === ";" || c === "|" || c === "&") {
      endCommand();
    } else if ("<>`$()".includes(c)) {
      return null;
    } else if (c === "{") {
      // Brace expansion can build an option name; a literal `{}` is fine.
      if (command[i + 1] !== "}") return null;
      word = (word ?? "") + "{}";
      i += 1;
    } else if ("*?[".includes(c)) {
      // A glob could expand to an option name.
      if ((word ?? "").startsWith("-")) return null;
      if ((word ?? "") === "") wild = true;
      word = (word ?? "") + c;
    } else {
      word = (word ?? "") + c;
    }
  }
  endCommand();
  return commands;
}

// Tools whose options can run a command or write a file.
const OPTION_EXECUTORS = new Set([
  "rg",
  "ugrep",
  "bfs",
  "fd",
  "fdfind",
  "find",
  "git",
]);

function inspectionWords({ words, wild }) {
  const rest = words[0] === "rtk" ? words.slice(1) : words;
  const [name, ...args] = rest;
  if (wild && OPTION_EXECUTORS.has(name)) return false;
  if (args.some((arg) => EXECUTING.test(arg))) return false;
  if (name === "git") {
    let i = 0;
    for (;;) {
      if (args[i] === "--no-pager" || args[i] === "--no-optional-locks") i += 1;
      else if (args[i] === "-C" && args.length > i + 1) i += 2;
      else break;
    }
    return GIT_READS.has(args[i]);
  }
  if (name === "fd" || name === "fdfind") {
    if (args.some((arg) => FD_EXEC.test(arg))) return false;
  }
  return INSPECTION.has(name);
}

export function isInspection(command) {
  if (typeof command !== "string") return false;
  const commands = simpleCommands(command);
  return (
    commands !== null && commands.length > 0 && commands.every(inspectionWords)
  );
}

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

function clearState(file) {
  try {
    // Never delete through a state directory that readState/writeState reject.
    if (privateDir(join(file, ".."), false)) rmSync(file, { force: true });
  } catch {
    // Advisory only.
  }
}

export function handle(event) {
  const file = stateFile(event.session_id ?? "default");
  const state = readState(file);
  if (event.hook_event_name === "PostToolUse") {
    if (event.tool_name === "Bash") {
      // A main-session shell command counts as a check attempt, pass or fail,
      // unless it is plain read-only inspection.
      if (!event.agent_id && !isInspection(event.tool_input?.command)) {
        writeState(file, { ...state, dirty: false });
      }
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
      clearState(file);
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
