#!/usr/bin/env node
// b-agentic spec context: a Claude Code SessionStart hook (matcher `compact`)
// that points the model back at the user-approved specs after compaction, so
// confirmed acceptance criteria (AC-n) do not survive only as a summary.
//
// It lists the paths of `docs/specs/*.md` whose first lines carry a
// `Status: approved` line (at most 5, newest first, 2000 characters). It never
// injects file content, never writes, creates or follows symlinks, and skips
// likely-secret names. With no specs folder, no approved spec, another event or
// source, malformed input, or any error it prints nothing and exits 0, so it
// can never wedge a session.
//
// Contract: stdin is the hook JSON; stdout is the JSON
// `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"..."}}`
// when there is something to say, and the exit code is always 0. The hook also
// fires when a subagent compacts (its payload has no agent_id), which is
// accepted: the output is a short, fact-only pointer.
//
// Residual risk: Node has no openat, so a process with concurrent write access
// to the project could swap `docs` or `docs/specs` for a link between the
// checks and the open. The hook reads only the first 4 KiB to test one line and
// emits a path, never content, so the worst case is a mislabeled local path.
import {
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  openSync,
  readdirSync,
  readFileSync,
  readSync,
  realpathSync,
} from "node:fs";
import { isAbsolute, join } from "node:path";
import { pathToFileURL } from "node:url";
import { isProtected } from "../bin/b-candidate-snapshot.mjs";

export const MAX_SPECS = 5;
export const MAX_CHARS = 2000;
const HEAD_BYTES = 4096;
const HEAD_LINES = 40;
// `Status: approved`, tolerating list/quote prefixes and bold or code markup.
const APPROVED =
  /^\s*(?:[-*>]\s*)?[*_]{0,2}status[*_]{0,2}\s*:[*_`]{0,2}\s*[*_`]{0,2}approved(?![\w-])/i;
// Only plain file names are listed, so a crafted name cannot add text to the context.
const SAFE_NAME = /^[A-Za-z0-9][A-Za-z0-9._ -]*\.md$/;
const asRaw = (value) => Buffer.from(value, "utf8").toString("latin1");

const isPlainDir = (path) => {
  const stat = lstatSync(path);
  return stat.isDirectory() && !stat.isSymbolicLink();
};

function readHead(path) {
  // O_NONBLOCK keeps open() from waiting on a FIFO with no writer; the
  // descriptor check below then rejects anything that is not a regular file.
  const fd = openSync(
    path,
    constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
  );
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile()) return null;
    // The name must still resolve to the very file that was opened.
    const named = lstatSync(path);
    if (
      named.isSymbolicLink() ||
      named.dev !== stat.dev ||
      named.ino !== stat.ino
    ) {
      return null;
    }
    const buffer = Buffer.alloc(HEAD_BYTES);
    const length = readSync(fd, buffer, 0, HEAD_BYTES, 0);
    return {
      head: buffer.subarray(0, length).toString("utf8"),
      mtimeMs: stat.mtimeMs,
    };
  } finally {
    closeSync(fd);
  }
}

export function approvedSpecs(cwd) {
  if (typeof cwd !== "string" || !isAbsolute(cwd)) return [];
  const dir = join(cwd, "docs", "specs");
  try {
    if (!isPlainDir(join(cwd, "docs")) || !isPlainDir(dir)) return [];
    // Both folders must also resolve inside the project root, so a linked
    // parent (or a root reached through a link) cannot point at another tree.
    if (realpathSync(dir) !== join(realpathSync(cwd), "docs", "specs")) {
      return [];
    }
  } catch {
    return [];
  }
  const found = [];
  for (const name of readdirSync(dir).sort()) {
    if (!SAFE_NAME.test(name) || /^readme\.md$/i.test(name)) continue;
    if (isProtected(asRaw(name))) continue;
    try {
      const entry = readHead(join(dir, name));
      if (!entry) continue;
      const lines = entry.head.split(/\r?\n/).slice(0, HEAD_LINES);
      if (lines.some((line) => APPROVED.test(line))) {
        found.push({ path: `docs/specs/${name}`, mtimeMs: entry.mtimeMs });
      }
    } catch {
      // A symlink, unreadable, or vanished file is skipped silently.
    }
  }
  return found.sort(
    (a, b) => b.mtimeMs - a.mtimeMs || (a.path < b.path ? -1 : 1),
  );
}

export function buildContext(specs) {
  if (specs.length === 0) return "";
  const shown = specs.slice(0, MAX_SPECS);
  const more = specs.length - shown.length;
  const tail = more > 0 ? ` (+${more} more)` : "";
  const intro =
    "b-agentic spec context: these specs have Status approved, so their Acceptance criteria (AC-n) are the user-confirmed acceptance for the current work: ";
  const outro =
    ". The Status line and Acceptance criteria section of each file are the source of record.";
  let list = shown.map((spec) => spec.path).join(", ");
  const room = MAX_CHARS - intro.length - outro.length - tail.length;
  if (list.length > room) list = `${list.slice(0, Math.max(0, room - 1))}…`;
  return `${intro}${list}${tail}${outro}`.slice(0, MAX_CHARS);
}

function main() {
  let event;
  try {
    event = JSON.parse(readFileSync(0, "utf8"));
  } catch {
    return 0;
  }
  try {
    if (
      event?.hook_event_name !== "SessionStart" ||
      event?.source !== "compact"
    )
      return 0;
    const context = buildContext(approvedSpecs(event.cwd));
    if (context === "") return 0;
    process.stdout.write(
      `${JSON.stringify({
        hookSpecificOutput: {
          hookEventName: "SessionStart",
          additionalContext: context,
        },
      })}\n`,
    );
  } catch {
    // Fail open: a broken hook must never block startup or compaction.
  }
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
