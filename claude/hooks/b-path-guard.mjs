#!/usr/bin/env node
// b-agentic path guard: a Claude Code PreToolUse hook that refuses file tools
// on likely-secret paths. It applies the same PROTECTED_RULES as the snapshot
// CLI (`*.env`, `*.env.*`, `*.pem`, `*credentials.*`, `*secrets.*`, with
// `*.env.example` allowed), which the settings deny rules can only approximate.
//
// Contract: stdin is the hook JSON; exit 2 with a stderr reason blocks the
// call, any other exit lets it continue. It reads only path and glob strings,
// never file content, and fails open on malformed input so it cannot wedge the
// session. It checks the names a tool call carries, not the files a directory
// search would visit; Claude Code's own deny rules cover that best effort.
import { readFileSync, realpathSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { isProtected } from "../bin/b-candidate-snapshot.mjs";

const PATH_KEYS = ["file_path", "notebook_path", "path"];
// Search tools take a glob that can name a secret file directly. `pattern` is a
// path glob only for Glob; for Grep it is a content regex, so it is not checked.
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

function main() {
  let event;
  try {
    event = JSON.parse(readFileSync(0, "utf8"));
  } catch {
    return 0;
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
