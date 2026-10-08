#!/usr/bin/env node
// b-agentic ClickUp guard: a Claude Code PreToolUse hook that asks before a
// ClickUp task create or update whose markdown carries an image reference.
// `createTask` and `updateTask` run without a prompt, but the ClickUp MCP reads
// and uploads a local image path, uploads a `data:` URI, and downloads and
// re-uploads an external http(s) image, so such a reference can move a local
// file or fetch a URL without the user seeing it. An existing ClickUp
// attachment URL (https, `*.clickup-attachments.com`) is reused as is and does
// not ask.
//
// Contract: stdin is the hook JSON; stdout carries a `permissionDecision: "ask"`
// when an image reference needs approval, otherwise nothing; the exit code is
// always 0. It reads only the description strings, fails open on malformed
// input so it cannot wedge the session, and matches markdown and `<img>`
// references by pattern, so an unusual spelling may escape it.
import { readFileSync, realpathSync } from "node:fs";
import { pathToFileURL } from "node:url";

const TEXT_KEYS = ["description", "append_description"];
const MAX_SHOWN = 3;
const MAX_TARGET = 80;
// `![alt](target "title")`, `![alt][ref]` with a `[ref]: target` definition, `<img src=...>`.
const INLINE_IMAGE = /!\[[^\]]*\]\(\s*<?([^)\s>]*)/g;
const REFERENCE_IMAGE = /!\[[^\]]*\]\[([^\]]*)\]/g;
const REFERENCE_DEFINITION = /^\s{0,3}\[([^\]]+)\]:\s*<?(\S+?)>?(?:\s|$)/gm;
const HTML_IMAGE = /<img\b[^>]*?\bsrc\s*=\s*["']?([^"'\s>]*)/gi;

function isClickUpAttachment(target) {
  try {
    const url = new URL(target);
    return (
      url.protocol === "https:" &&
      url.hostname.toLowerCase().endsWith(".clickup-attachments.com")
    );
  } catch {
    return false;
  }
}

export function imageTargets(text) {
  const targets = [];
  for (const match of text.matchAll(INLINE_IMAGE)) targets.push(match[1]);
  for (const match of text.matchAll(HTML_IMAGE)) targets.push(match[1]);
  const definitions = new Map();
  for (const match of text.matchAll(REFERENCE_DEFINITION)) {
    definitions.set(match[1].toLowerCase(), match[2]);
  }
  for (const match of text.matchAll(REFERENCE_IMAGE)) {
    // An undefined reference label still marks an image the server might resolve.
    targets.push(definitions.get(match[1].toLowerCase()) ?? `[${match[1]}]`);
  }
  return targets;
}

export function riskyImages(toolInput) {
  if (!toolInput || typeof toolInput !== "object") return [];
  return TEXT_KEYS.flatMap((key) => {
    const value = toolInput[key];
    return typeof value === "string" ? imageTargets(value) : [];
  }).filter((target) => !isClickUpAttachment(target));
}

function main() {
  let event;
  try {
    event = JSON.parse(readFileSync(0, "utf8"));
  } catch {
    return 0;
  }
  const risky = riskyImages(event?.tool_input);
  if (risky.length === 0) return 0;
  const shown = risky
    .slice(0, MAX_SHOWN)
    .map((target) =>
      target.length > MAX_TARGET ? `${target.slice(0, MAX_TARGET)}...` : target,
    )
    .map((target) => (target === "" ? "(empty)" : target))
    .join(", ");
  const more =
    risky.length > MAX_SHOWN ? ` and ${risky.length - MAX_SHOWN} more` : "";
  process.stdout.write(
    `${JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "ask",
        permissionDecisionReason: `b-agentic ClickUp guard: this task markdown references ${shown}${more}. The ClickUp MCP reads and uploads a local image path or data: URI and downloads and re-uploads an external image URL. Approve only if you intend that upload.`,
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
