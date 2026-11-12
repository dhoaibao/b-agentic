#!/usr/bin/env node
// b-agentic run context: a Claude Code SessionStart hook (matcher
// `startup|resume|clear|compact`) that points the model at the active `b-flow`
// run (ADR-009), so a new or compacted session can tell a run exists.
//
// It prints one fact-only line: the run id, its phase, and its folder. It is a
// pointer, never a request: only an explicit `/b-flow resume` continues a run,
// and the state file it reads is untrusted input that grants no approval. It
// never injects file content beyond the validated id and phase, never writes,
// and never follows symlinks. With no run, a finished run, another event or
// source, malformed input, or any error it prints nothing and exits 0, so it
// can never wedge a session.
//
// Known limit: Claude Code drops SessionStart context intermittently for
// `startup` and `fork` sources (anthropics/claude-code#10373, #93458), so this
// pointer is best effort. The run files, not this hook, are the record.
//
// Contract: stdin is the hook JSON; stdout is the JSON
// `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"..."}}`
// when there is a run to point at, and the exit code is always 0.
import {
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  openSync,
  readSync,
  realpathSync,
} from "node:fs";
import { isAbsolute, join } from "node:path";
import { pathToFileURL } from "node:url";

export const SOURCES = new Set(["startup", "resume", "clear", "compact"]);
const RUN_ID = /^\d{8}-[a-z0-9][a-z0-9-]{0,40}$/;
const PHASES = new Set([
  "clarify",
  "approved",
  "implement",
  "verify",
  "review",
  "fix",
  "qa",
  "commit",
  "blocked",
]);
const MAX_BYTES = 1 << 20;

const isPlainDir = (path) => {
  const stat = lstatSync(path);
  return stat.isDirectory() && !stat.isSymbolicLink();
};

function readFile(path) {
  const fd = openSync(
    path,
    constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
  );
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile() || stat.size > MAX_BYTES) return null;
    const buffer = Buffer.alloc(stat.size);
    const length = readSync(fd, buffer, 0, stat.size, 0);
    return buffer.subarray(0, length).toString("utf8");
  } finally {
    closeSync(fd);
  }
}

export function activeRun(cwd) {
  if (typeof cwd !== "string" || !isAbsolute(cwd)) return null;
  try {
    const root = realpathSync(cwd);
    const base = join(root, ".b-agentic");
    if (!isPlainDir(base) || !isPlainDir(join(base, "runs"))) return null;
    const id = (readFile(join(base, "active")) ?? "").trim();
    if (!RUN_ID.test(id)) return null;
    const dir = join(base, "runs", id);
    if (!isPlainDir(dir)) return null;
    const state = JSON.parse(readFile(join(dir, "state.json")) ?? "null");
    if (state?.run_id !== id || !PHASES.has(state?.phase)) return null;
    return { id, phase: state.phase };
  } catch {
    return null;
  }
}

export function buildContext(run) {
  if (!run) return "";
  return (
    `b-agentic run context: run ${run.id} is in phase ${run.phase} ` +
    `(.b-agentic/runs/${run.id}/). This is a pointer, not a request: ` +
    "continue it only when the user explicitly runs /b-flow resume."
  );
}

function main() {
  let event;
  try {
    event = JSON.parse(readFileSyncStdin());
  } catch {
    return 0;
  }
  try {
    if (
      event?.hook_event_name !== "SessionStart" ||
      !SOURCES.has(event?.source)
    )
      return 0;
    const context = buildContext(activeRun(event.cwd));
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

function readFileSyncStdin() {
  const chunks = [];
  const buffer = Buffer.alloc(65536);
  for (;;) {
    let length;
    try {
      length = readSync(0, buffer, 0, buffer.length, null);
    } catch (error) {
      if (error?.code === "EAGAIN") continue;
      if (error?.code === "EOF") break;
      throw error;
    }
    if (length === 0) break;
    chunks.push(Buffer.from(buffer.subarray(0, length)));
    if (chunks.length > 64) break;
  }
  return Buffer.concat(chunks).toString("utf8");
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

if (isEntryPoint()) process.exitCode = main();
