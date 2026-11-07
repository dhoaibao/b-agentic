#!/usr/bin/env node
// b-agentic status line for Claude Code. Reads the status JSON on stdin and prints one line:
// model and effort, repo and git branch, context used, session cost, the prompt cache hit ratio,
// and the 5-hour and weekly limits as coloured percents with time to reset.
// Read-only: it writes nothing and never touches the network.
import { readFileSync, statSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

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

export function render(input, now = Date.now() / 1000, branch = null) {
  const parts = [];
  const model = [
    [input.model?.display_name, "1"],
    [input.effort?.level, "35"],
  ]
    .filter(([value]) => value != null && value !== "")
    .map(([value, code]) => paint(code, value));
  if (model.length > 0) parts.push(model.join(dim(" · ")));
  const repo =
    input.workspace?.repo?.name ||
    (input.workspace?.project_dir ? basename(input.workspace.project_dir) : "");
  if (repo !== "")
    parts.push(
      branch
        ? `${paint("36", repo)}${dim("@")}${paint("32", branch)}`
        : paint("36", repo),
    );
  const context = input.context_window;
  if (context?.used_percentage != null) {
    const usage = context.current_usage ?? {};
    const used =
      (usage.input_tokens ?? 0) +
      (usage.cache_creation_input_tokens ?? 0) +
      (usage.cache_read_input_tokens ?? 0);
    parts.push(
      `${dim("context")} ${pct(context.used_percentage)} ${dim(`(${tokens(used)}/${tokens(context.context_window_size ?? 0)})`)}`,
    );
  }
  const cost = input.cost?.total_cost_usd;
  if (Number.isFinite(cost)) parts.push(paint("33", `$${cost.toFixed(2)}`));
  // Claude Code 2.1.251+ reports the ratio in `prompt_cache`; older versions omit it.
  // A high hit ratio is good, so the colours run the other way from the usage percents.
  const hit = input.prompt_cache?.hit_ratio;
  if (Number.isFinite(hit)) {
    const percent = Math.round(hit * 100);
    parts.push(
      `${dim("cache")} ${paint(percent >= 80 ? "32" : percent >= 50 ? "33" : "31", `${percent}%`)} ${dim("hit")}`,
    );
  }
  for (const [label, limit] of [
    ["5h", input.rate_limits?.five_hour],
    ["week", input.rate_limits?.seven_day],
  ]) {
    if (limit?.used_percentage == null) continue;
    const reset =
      limit.resets_at == null
        ? ""
        : ` ${dim(`· ${left(limit.resets_at, now)}`)}`;
    parts.push(`${dim(label)} ${pct(limit.used_percentage)}${reset}`);
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
  const branch = gitBranch(input.workspace?.current_dir ?? input.cwd);
  process.stdout.write(`${render(input, undefined, branch)}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href)
  await main();
