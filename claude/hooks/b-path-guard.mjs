#!/usr/bin/env node
// b-agentic path guard: a Claude Code PreToolUse hook that refuses file tools
// on likely-secret paths. It applies the same PROTECTED_RULES as the snapshot
// CLI (`*.env`, `*.env.*`, `*.pem`, `*credentials.*`, `*secrets.*`, with
// `*.env.example` allowed), which the settings deny rules can only approximate.
//
// Contract: stdin is the hook JSON; exit 2 with a stderr reason blocks the
// call and exit 0 lets it continue. Under Claude Code the registered hook sets
// `onFailure: "block"`, so a crash, timeout, or other unexpected exit also
// blocks. It reads only path and glob strings, never file content, and fails
// open on malformed input (exit 0) so it cannot wedge the session. It checks the names a tool call carries, not the files a directory
// search would visit; Claude Code's own deny rules cover that best effort.
import { readFileSync, realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import { isProtected } from "../bin/b-candidate-snapshot.mjs";

const PATH_KEYS = ["file_path", "notebook_path", "path"];
// Search tools take a glob that can name a secret file directly. `pattern` is a
// path glob only for Glob; for Grep it is a content regex, so it is not checked.
// Native Linux/macOS builds run searches through Bash instead, which this hook
// does not see.
const asRaw = (value) => Buffer.from(value, "utf8").toString("latin1");

export function blockedPaths(toolInput, toolName) {
  if (!toolInput || typeof toolInput !== "object") return [];
  const globKeys = toolName === "Glob" ? ["glob", "pattern"] : ["glob"];
  const strings = (keys) =>
    keys
      .map((key) => toolInput[key])
      .filter((value) => typeof value === "string" && value !== "");
  return [
    // Match raw bytes like the snapshot CLI so an odd encoding cannot hide a name.
    ...strings(PATH_KEYS).filter((value) => isProtected(asRaw(value))),
    ...strings(globKeys).filter((value) =>
      isProtected(asRaw(value.replace(/^(\*\*\/)+/, ""))),
    ),
  ];
}

// Run artifacts under .b-agentic have a single writer (ADR-010), so the file
// tools may not change them; reads stay allowed. A Bash write is not seen here:
// b-state and b_run.py detect it as a hash mismatch or an unknown file.
const WRITE_TOOLS = new Set(["Edit", "Write", "NotebookEdit"]);

const hasAgentic = (path) =>
  path.replaceAll("\\", "/").split("/").includes(".b-agentic");

// The spelling of a path can hide the folder (a symlinked directory, a relative
// path, `..`), so the nearest existing ancestor is resolved before the check.
export function canonicalPath(path, cwd) {
  // Components are resolved in filesystem order: a symlink is expanded before a
  // later `..` applies, and a part that does not exist yet stays lexical.
  let start = typeof cwd === "string" && cwd.startsWith("/") ? cwd : "/";
  try {
    start = realpathSync(start);
  } catch {
    // A missing cwd stays lexical.
  }
  let resolved = path.startsWith("/") ? "/" : start;
  for (const part of path.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") {
      resolved = dirname(resolved);
      continue;
    }
    const next = join(resolved, part);
    try {
      resolved = realpathSync(next);
    } catch {
      resolved = next;
    }
  }
  return resolved;
}

export function agenticWrites(toolInput, toolName, cwd) {
  if (!WRITE_TOOLS.has(toolName) || !toolInput || typeof toolInput !== "object")
    return [];
  return PATH_KEYS.map((key) => toolInput[key]).filter(
    (value) =>
      typeof value === "string" &&
      value !== "" &&
      (hasAgentic(value) || hasAgentic(canonicalPath(value, cwd))),
  );
}

function main() {
  let event;
  try {
    event = JSON.parse(readFileSync(0, "utf8"));
  } catch {
    return 0;
  }
  const owned = agenticWrites(event?.tool_input, event?.tool_name, event?.cwd);
  if (owned.length > 0) {
    process.stderr.write(
      `b-agentic path guard: ${event.tool_name} refused on ${owned.join(", ")}. Run artifacts under .b-agentic are written only by b_run.py (python3 -I -B ~/.claude/b-agentic/bin/b_run.py write <kind>) and b-state.mjs; read them with Read.\n`,
    );
    return 2;
  }
  const blocked = blockedPaths(event?.tool_input, event?.tool_name);
  if (blocked.length === 0) return 0;
  process.stderr.write(
    `b-agentic path guard: ${event.tool_name ?? "tool"} refused on likely-secret path ${blocked.join(", ")}. Likely-secret files (.env, *.pem, credentials.*, secrets.*) need explicit user permission to read or change; ask the user first.\n`,
  );
  return 2;
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
