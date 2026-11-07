#!/usr/bin/env node
// b-agentic status line for Claude Code. Reads the status JSON on stdin and prints one line:
// model and effort, repo and git branch, context used, session cost, how long the prompt cache
// lasts (a red "exp." once it is out) with its hit ratio, and the 5-hour and weekly limits as
// coloured percents with time to reset.
// Read-only: it writes nothing and never touches the network.
import { closeSync, fstatSync, openSync, readFileSync, readSync, statSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const TAIL_BYTES = 512 * 1024;
const TAIL_LINES = 400;

const paint = (code, text) => `\u001b[${code}m${text}\u001b[0m`;
const dim = (text) => paint("2", text);
const pct = (value) =>
  paint(
    value >= 80 ? "31" : value >= 50 ? "33" : "32",
    `${Math.round(value)}%`,
  );

export function tokens(count) {
  if (count >= 1_000_000)
    return `${Math.round(count / 100_000) / 10}M`.replace(/\.0M$/, "M");
  if (count >= 1000) return `${Math.round(count / 1000)}k`;
  return String(count);
}

export function left(epochSeconds, now = Date.now() / 1000) {
  const seconds = epochSeconds - now;
  if (seconds <= 0) return "now";
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  if (seconds < 86400)
    return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`;
  return `${Math.floor(seconds / 86400)}d ${Math.floor((seconds % 86400) / 3600)}h`;
}

function tailLines(path) {
  let fd;
  try {
    fd = openSync(path, "r");
    const { size } = fstatSync(fd);
    const length = Math.min(size, TAIL_BYTES);
    const buffer = Buffer.alloc(length);
    readSync(fd, buffer, 0, length, size - length);
    const lines = buffer.toString("utf8").split("\n");
    if (size > length) lines.shift(); // the first line is cut mid-record
    return lines.filter(Boolean).slice(-TAIL_LINES);
  } catch {
    return [];
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
}

// Claude Code 2.1.251+ reports the cache in the status JSON (`prompt_cache.expires_at`, epoch
// seconds, null when the last response reported no cache tokens). Undefined when the object is
// absent, so the caller falls back to the transcript.
export function promptCacheExpiry(input) {
  const cache = input?.prompt_cache;
  if (cache == null || typeof cache !== "object") return undefined;
  return Number.isFinite(cache.expires_at) ? cache.expires_at : null;
}

// Fallback for older versions. When the prompt cache runs out (epoch seconds): the last cached
// reply's time plus the lifetime its last cache write used (1 hour or 5 minutes). Null when no
// reply in the tail reported cache tokens. Replies without cache tokens are skipped, so an older
// cached reply can still set the countdown after a newer uncached one.
export function cacheExpiry(lines) {
  const replies = [];
  for (const line of lines) {
    try {
      const record = JSON.parse(line);
      const usage = record.type === "assistant" && record.message?.usage;
      if (
        usage &&
        (usage.cache_creation_input_tokens ?? 0) +
          (usage.cache_read_input_tokens ?? 0) +
          (usage.cache_creation?.ephemeral_1h_input_tokens ?? 0) +
          (usage.cache_creation?.ephemeral_5m_input_tokens ?? 0) >
          0
      )
        replies.push(record);
    } catch {
      // a partial or non-JSON line carries no usage
    }
  }
  if (replies.length === 0) return null;
  const at = Date.parse(replies[replies.length - 1].timestamp) / 1000;
  if (!Number.isFinite(at)) return null;
  let ttl = 300;
  for (const reply of replies) {
    const created = reply.message.usage.cache_creation ?? {};
    if ((created.ephemeral_1h_input_tokens ?? 0) > 0) ttl = 3600;
    else if ((created.ephemeral_5m_input_tokens ?? 0) > 0) ttl = 300;
  }
  return at + ttl;
}

// Current git branch, read from .git/HEAD (a worktree's `.git` file points at its own gitdir).
// A detached HEAD gives the short commit; null when there is no repository.
export function gitBranch(start) {
  let dir = typeof start === "string" && start !== "" ? resolve(start) : null;
  for (let depth = 0; dir !== null && depth < 32; depth++) {
    const dotGit = join(dir, ".git");
    let found = null;
    try {
      found = statSync(dotGit);
    } catch {
      // no repository at this level: keep climbing
    }
    if (found) {
      try {
        let gitDir = dotGit;
        if (found.isFile()) {
          const match = /^gitdir:\s*(.+)$/m.exec(readFileSync(dotGit, "utf8"));
          if (!match) return null;
          gitDir = resolve(dir, match[1].trim());
        }
        const head = readFileSync(join(gitDir, "HEAD"), "utf8").trim();
        const ref = /^ref: refs\/heads\/(.+)$/.exec(head);
        if (ref) return ref[1];
        return /^[0-9a-f]{7,}$/.test(head) ? head.slice(0, 7) : null;
      } catch {
        return null;
      }
    }
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return null;
}

export function render(input, expiry, now = Date.now() / 1000, branch = null) {
  const parts = [];
  const model = [input.model?.display_name, input.effort?.level].filter(
    (value) => value != null && value !== "",
  );
  if (model.length > 0) parts.push(model.join(" · "));
  const repo =
    input.workspace?.repo?.name ||
    (input.workspace?.project_dir ? basename(input.workspace.project_dir) : "");
  if (repo !== "") parts.push(branch ? `${repo}@${branch}` : repo);
  const context = input.context_window;
  if (context?.used_percentage != null) {
    const usage = context.current_usage ?? {};
    const used =
      (usage.input_tokens ?? 0) +
      (usage.cache_creation_input_tokens ?? 0) +
      (usage.cache_read_input_tokens ?? 0);
    parts.push(
      `context ${pct(context.used_percentage)} ${dim(`(${tokens(used)}/${tokens(context.context_window_size ?? 0)})`)}`,
    );
  }
  const cost = input.cost?.total_cost_usd;
  if (Number.isFinite(cost)) parts.push(`$${cost.toFixed(2)}`);
  const cache = [];
  if (expiry != null)
    cache.push(expiry > now ? dim(left(expiry, now)) : paint("31", "exp."));
  const hit = input.prompt_cache?.hit_ratio;
  if (Number.isFinite(hit)) cache.push(dim(`${Math.round(hit * 100)}% hit`));
  if (cache.length > 0) parts.push(`cache ${cache.join(dim(" · "))}`);
  for (const [label, limit] of [
    ["5h", input.rate_limits?.five_hour],
    ["week", input.rate_limits?.seven_day],
  ]) {
    if (limit?.used_percentage == null) continue;
    const reset =
      limit.resets_at == null
        ? ""
        : ` ${dim(`· ${left(limit.resets_at, now)}`)}`;
    parts.push(`${label} ${pct(limit.used_percentage)}${reset}`);
  }
  return parts.join("   ");
}

async function main() {
  let raw = "";
  for await (const chunk of process.stdin) raw += chunk;
  let input;
  try {
    input = JSON.parse(raw);
  } catch {
    return;
  }
  const path =
    typeof input.transcript_path === "string" ? input.transcript_path : "";
  const reported = promptCacheExpiry(input);
  const expiry =
    reported !== undefined
      ? reported
      : path
        ? cacheExpiry(tailLines(path))
        : null;
  const branch = gitBranch(input.workspace?.current_dir ?? input.cwd);
  process.stdout.write(`${render(input, expiry, undefined, branch)}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href)
  await main();
