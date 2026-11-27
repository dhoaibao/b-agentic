#!/usr/bin/env bun
// b-agentic status line for Claude Code. Reads the status JSON on stdin and prints one line:
// model and effort, repo and git branch, context used, session cost, the prompt cache hit ratio,
// and the 5-hour and weekly limits as coloured percents with time to reset, the weekly one beside
// the budget up to the current day. Where a b-flow run is recorded it also adds a short compaction
// hint, chosen from the run phase and the context size.
// Read-only: it writes nothing and never touches the network; it reads only the stdin JSON,
// .git/HEAD, and the phase and lock owner of the run in .b-agentic.
import {
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  openSync,
  readFileSync,
  readSync,
  statSync,
} from "node:fs";
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

// The phases of a b-flow run, as in claude/bin/b-state-core.mjs. They are copied, not imported,
// because `--statusline-only` installs this script alone; the status line probe keeps both lists equal.
export const RUN_PHASES = [
  "clarify",
  "approved",
  "implement",
  "verify",
  "review",
  "fix",
  "qa",
  "commit",
  "done",
  "blocked",
];
// Claude Code's docs name no percentage for compacting by hand. Hints start at 40% of the window
// and turn red at 80%, where the context percent does.
export const HINT_PERCENT = 40;
export const NEAR_LIMIT_PERCENT = 80;

// Run files are untrusted project content and the status line must always print, so they are read
// with the flags of the run-context hook: no symlink, no blocking open of a FIFO, and a size cap.
// The cap equals MAX_STATE_BYTES in b-state-core.mjs: a state the writer accepts must stay readable,
// or the hint would vanish silently. Typical state files are about 13 KB. It is copied, not imported,
// because `--statusline-only` installs this file alone.
const MAX_RUN_FILE_BYTES = 1 << 20;

export function readRunFile(path) {
  let fd = null;
  try {
    fd = openSync(
      path,
      constants.O_RDONLY | constants.O_NONBLOCK | constants.O_NOFOLLOW,
    );
    const info = fstatSync(fd);
    if (!info.isFile() || info.size > MAX_RUN_FILE_BYTES) return null;
    // One byte more than fstat saw: a file another process grew since then reads longer and is dropped.
    const buffer = Buffer.alloc(info.size + 1);
    const count = readSync(fd, buffer, 0, buffer.length, 0);
    return count === info.size ? buffer.toString("utf8", 0, count) : null;
  } catch {
    return null;
  } finally {
    if (fd !== null) closeSync(fd);
  }
}

const exists = (path) => {
  try {
    lstatSync(path);
    return true;
  } catch {
    return false;
  }
};

// A real directory, not a symlink to somewhere else (the run-context hook applies the same rule).
const isPlainDir = (path) => {
  try {
    const info = lstatSync(path);
    return info.isDirectory() && !info.isSymbolicLink();
  } catch {
    return false;
  }
};

// The id format b-state writes, as in claude/hooks/b-run-context.mjs; the probe checks every copy.
export const RUN_ID = /^\d{8}-[a-z0-9][a-z0-9-]{0,40}$/;

// The pointer keeps naming a finished run, so these phases say nothing about a later conversation.
// They count only in the session that holds the run's lock; elsewhere the phase reads as
// OTHER_SESSION, which keeps the near-limit warning and drops the run-specific hints.
const SESSION_BOUND_PHASES = ["approved", "done"];
export const OTHER_SESSION = "other-session";

function lockedBy(runDir, sessionId) {
  if (typeof sessionId !== "string" || sessionId === "") return false;
  try {
    return JSON.parse(readRunFile(join(runDir, "lock")))?.owner === sessionId;
  } catch {
    return false;
  }
}

// Phase of the run recorded under .b-agentic, or null when there is no run state or it cannot be
// read. The pointer lives at the worktree root, so the search stops at the first directory that has
// a `.git`: a nested repository never borrows an enclosing project's run. Only a known phase name is
// returned, so nothing else from the state file reaches the output. An approved or done run is
// returned only when its lock owner is `sessionId`; otherwise it reads as OTHER_SESSION.
export function runPhase(start, sessionId = null) {
  let dir = typeof start === "string" && start !== "" ? resolve(start) : null;
  for (let depth = 0; dir !== null && depth < 32; depth++) {
    const base = join(dir, ".b-agentic");
    const pointer = join(base, "active");
    if (exists(pointer)) {
      if (!isPlainDir(base)) return null;
      const id = readRunFile(pointer)?.trim();
      if (!id || !RUN_ID.test(id)) return null;
      const runDir = join(base, "runs", id);
      if (![join(base, "runs"), runDir].every(isPlainDir)) return null;
      try {
        const state = JSON.parse(readRunFile(join(runDir, "state.json")));
        if (state?.run_id !== id || !RUN_PHASES.includes(state?.phase))
          return null;
        return SESSION_BOUND_PHASES.includes(state.phase) &&
          !lockedBy(runDir, sessionId)
          ? OTHER_SESSION
          : state.phase;
      } catch {
        return null;
      }
    }
    if (exists(join(dir, ".git"))) return null;
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return null;
}

// A fixed hint, or null. A break is where the run state on disk already holds what a compaction
// would drop: a finished run, or a run just approved. Mid-run it says to finish the phase first.
export function compactHint(phase, percent) {
  if (phase == null || !(percent >= HINT_PERCENT)) return null;
  const color = percent >= NEAR_LIMIT_PERCENT ? "31" : "33";
  if (phase === "done") return paint(color, "run done: /compact or /clear");
  if (phase === "approved")
    return paint(color, "plan on disk: /compact before implement");
  if (phase === OTHER_SESSION)
    return paint(color, "context high: /compact soon");
  return paint(color, "context high: finish this phase, then /compact");
}

// Percent of the weekly limit that an even pace allows by the end of the current day. A day is
// 24 hours counted from the start of the window, seven days before its reset.
export function weekBudget(resetsAt, now = Date.now() / 1000) {
  if (!Number.isFinite(resetsAt)) return null;
  const day = Math.floor((now - resetsAt) / 86400) + 8;
  return Math.floor((Math.min(7, Math.max(1, day)) * 100) / 7);
}

export function render(
  input,
  now = Date.now() / 1000,
  branch = null,
  phase = null,
) {
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
    const hint = compactHint(phase, context.used_percentage);
    if (hint !== null) parts.push(hint);
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
    const budget = label === "week" ? weekBudget(limit.resets_at, now) : null;
    const allowed = budget === null ? "" : dim(`/${budget}%`);
    parts.push(`${dim(label)} ${pct(limit.used_percentage)}${allowed}${reset}`);
  }
  return parts.join("   ");
}

function main() {
  let input;
  try {
    input = JSON.parse(readFileSync(0, "utf8"));
  } catch {
    return;
  }
  const start = input.workspace?.current_dir ?? input.cwd;
  process.stdout.write(
    `${render(input, undefined, gitBranch(start), runPhase(start, input.session_id))}\n`,
  );
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href)
  main();
