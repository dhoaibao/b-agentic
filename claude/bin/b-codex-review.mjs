#!/usr/bin/env node
// b-agentic Codex review wrapper. This is the enforced path for the independent
// changed-code gate: the checks run in this code, not in the model's discipline
// and not in a shell-command parser. It
//   1. refuses unless no likely-secret path is tracked, staged, or
//      untracked-and-not-ignored, no submodule or embedded repository hides paths
//      from the name scan, and the user approved sending this repository
//      (b-codex-guard's `evaluate`);
//   2. freezes the candidate (F0) and refuses an incomplete snapshot;
//   3. runs the plugin's review in the foreground against exactly one explicit
//      target, spawned with an argument vector (no shell, no quoting to defeat);
//   4. freezes the candidate again (F1) and voids the review when F0 != F1;
//   5. maps the plugin's verdict with b-codex-verdict's fail-closed parser.
// The Bash hook in b-codex-guard.mjs only catches accidental direct calls to the
// plugin script; it is a tripwire, not the boundary.
//
// Usage: b-codex-review.mjs (--scope working-tree | --base <ref>)
//          [--kind adversarial|native] [--focus <text> | --focus-file <path>]
//          [--round <n>] [--include-ignored <path>]... [--timeout-minutes <n>]
//          [--kill-grace-seconds <n>] [--companion <path>]
// Exit: 0 reviewed, candidate unchanged, verdict mapped; 3 void (the candidate
// changed or could not be re-snapshotted, the run timed out or hit the output
// cap, or the result was unmappable); 2 refused or failed (including an
// incomplete snapshot before the plugin runs). JSON on stdout.
import { spawn } from "node:child_process";
import {
  existsSync,
  readFileSync,
  readdirSync,
  realpathSync,
  statSync,
} from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import { pathToFileURL } from "node:url";
import { evaluate, repositoryRoot } from "../hooks/b-codex-guard.mjs";
import { computeSnapshot } from "./b-candidate-snapshot.mjs";
import { mapVerdict, parseInput } from "./b-codex-verdict.mjs";

const COMPANION = "codex-companion.mjs";
const MAX_OUTPUT = 8 * 1024 * 1024;
// Node timers clamp anything above 2^31-1 ms to 1 ms; bounded values are refused instead.
const MAX_TIMER_MS = 2 ** 31 - 1;
// After the grace period the wrapper stops waiting for the pipes to close.
const FALLBACK_MS = 2000;
const MAX_DEPTH = 9;

export class ReviewError extends Error {}

// The plugin's companion script: an explicit override first, then the newest copy
// under the user's Claude plugin directory.
export function findCompanion(explicit) {
  const candidate = explicit ?? process.env.B_AGENTIC_CODEX_COMPANION;
  if (candidate) {
    if (basename(candidate) !== COMPANION || !existsSync(candidate)) {
      throw new ReviewError(
        `the companion override must be an existing ${COMPANION}: ${candidate}`,
      );
    }
    return realpathSync(candidate);
  }
  const root = join(homedir(), ".claude", "plugins");
  const found = [];
  const walk = (dir, depth) => {
    if (depth > MAX_DEPTH) return;
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (entry.name === "node_modules" || entry.name === ".git") continue;
      const path = join(dir, entry.name);
      if (entry.isDirectory()) walk(path, depth + 1);
      else if (entry.isFile() && entry.name === COMPANION) {
        found.push({ path, mtime: statSync(path).mtimeMs });
      }
    }
  };
  walk(root, 0);
  if (found.length === 0) {
    throw new ReviewError(
      `the Codex plugin script ${COMPANION} was not found under ${root}; install it in Claude Code with /plugin marketplace add openai/codex-plugin-cc and /plugin install codex@openai-codex`,
    );
  }
  found.sort((a, b) => b.mtime - a.mtime);
  return realpathSync(found[0].path);
}

export function parseArgs(argv) {
  const options = {
    scope: null,
    base: null,
    kind: "adversarial",
    focus: null,
    round: 1,
    includeIgnored: [],
    timeoutMinutes: 30,
    killGraceSeconds: 5,
    companion: null,
  };
  const value = (index, name) => {
    const next = argv[index + 1];
    if (next === undefined) throw new ReviewError(`${name} needs a value`);
    return next;
  };
  for (let index = 0; index < argv.length; index++) {
    const arg = argv[index];
    if (arg === "--scope") {
      options.scope = value(index++, arg);
    } else if (arg === "--base") {
      options.base = value(index++, arg);
    } else if (arg === "--kind") {
      options.kind = value(index++, arg);
    } else if (arg === "--focus") {
      options.focus = value(index++, arg);
    } else if (arg === "--focus-file") {
      options.focus = readFileSync(value(index++, arg), "utf8").replace(
        /\n+$/,
        "",
      );
    } else if (arg === "--round") {
      options.round = Number(value(index++, arg));
    } else if (arg === "--include-ignored") {
      options.includeIgnored.push(value(index++, arg));
    } else if (arg === "--timeout-minutes") {
      options.timeoutMinutes = Number(value(index++, arg));
    } else if (arg === "--kill-grace-seconds") {
      options.killGraceSeconds = Number(value(index++, arg));
    } else if (arg === "--companion") {
      options.companion = value(index++, arg);
    } else {
      throw new ReviewError(`unknown argument: ${arg}`);
    }
  }
  if ((options.scope === null) === (options.base === null)) {
    throw new ReviewError(
      "pass exactly one explicit target: --scope working-tree or --base <ref>",
    );
  }
  if (options.scope !== null && options.scope !== "working-tree") {
    throw new ReviewError("--scope must be working-tree");
  }
  if (
    options.base !== null &&
    (options.base === "" || options.base.startsWith("-"))
  ) {
    throw new ReviewError("--base needs a ref that does not start with '-'");
  }
  if (!["adversarial", "native"].includes(options.kind)) {
    throw new ReviewError("--kind must be adversarial or native");
  }
  if (!Number.isInteger(options.round) || options.round < 1) {
    throw new ReviewError("--round needs a positive integer");
  }
  if (
    !Number.isFinite(options.timeoutMinutes) ||
    options.timeoutMinutes <= 0 ||
    options.timeoutMinutes * 60_000 > MAX_TIMER_MS
  ) {
    throw new ReviewError(
      `--timeout-minutes needs a positive number of at most ${Math.floor(MAX_TIMER_MS / 60_000)}`,
    );
  }
  if (
    !Number.isFinite(options.killGraceSeconds) ||
    options.killGraceSeconds <= 0 ||
    options.killGraceSeconds * 1000 + FALLBACK_MS > MAX_TIMER_MS
  ) {
    throw new ReviewError(
      `--kill-grace-seconds needs a positive number of at most ${Math.floor((MAX_TIMER_MS - FALLBACK_MS) / 1000)}`,
    );
  }
  if (options.focus !== null) {
    if (options.kind === "native") {
      throw new ReviewError(
        "a native review takes no focus text; use --kind adversarial",
      );
    }
    if (
      options.focus.trim() === "" ||
      options.focus.startsWith("-") ||
      options.focus.includes("\0")
    ) {
      throw new ReviewError(
        "--focus must be non-empty text that does not start with '-'",
      );
    }
  }
  return options;
}

export function companionArgs(options) {
  return [
    options.kind === "native" ? "review" : "adversarial-review",
    "--wait",
    ...(options.scope !== null
      ? ["--scope", "working-tree"]
      : ["--base", options.base]),
    ...(options.focus !== null ? [options.focus] : []),
  ];
}

// Runs the plugin and reports how it ended. It never trusts the exit status alone:
// a deadline that expired or an output cap that was hit is recorded as its own
// fact (`timedOut`, `truncated`), because a child can handle SIGTERM and still
// exit 0 with a partial or approving result. After SIGTERM the child gets a grace
// period and is then killed; the promise settles even if a grandchild keeps the
// pipes open.
function runCompanion(companion, args, cwd, options) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [companion, ...args], {
      cwd,
      stdio: ["ignore", "pipe", "pipe"],
    });
    const chunks = { stdout: [], stderr: [] };
    const sizes = { stdout: 0, stderr: 0 };
    const state = {
      timedOut: false,
      truncated: [],
      settled: false,
      stopping: false,
    };
    const timers = [];
    const graceMs = options.killGraceSeconds * 1000;
    const settle = (code, signal, extra = "") => {
      if (state.settled) return;
      state.settled = true;
      timers.forEach(clearTimeout);
      const text = (name) => Buffer.concat(chunks[name]).toString("utf8");
      resolve({
        code,
        signal,
        stdout: text("stdout"),
        stderr: `${text("stderr")}${extra}`,
        timedOut: state.timedOut,
        truncated: state.truncated,
      });
    };
    // Idempotent. Termination is bounded whether or not the direct child is still
    // running: a companion that exits while a descendant keeps its stdout or stderr
    // open never emits `close`, so the pipes are destroyed and the promise settled
    // by a fallback timer that does not depend on the child's state. Signals are
    // sent only while the child is alive.
    const alive = () => child.exitCode === null && child.signalCode === null;
    const stop = () => {
      if (state.stopping) return;
      state.stopping = true;
      if (alive()) child.kill("SIGTERM");
      timers.push(
        setTimeout(() => {
          if (alive()) child.kill("SIGKILL");
        }, graceMs),
        setTimeout(() => {
          child.stdout.destroy();
          child.stderr.destroy();
          child.unref();
          settle(
            child.exitCode,
            child.signalCode,
            "\n[wrapper] the plugin's output pipes did not close; they were closed by the wrapper",
          );
        }, graceMs + FALLBACK_MS),
      );
    };
    timers.push(
      setTimeout(() => {
        state.timedOut = true;
        stop();
      }, options.timeoutMinutes * 60_000),
    );
    const collect = (name) => (chunk) => {
      if (sizes[name] >= MAX_OUTPUT) {
        if (!state.truncated.includes(name)) {
          state.truncated.push(name);
          stop();
        }
        return;
      }
      const room = MAX_OUTPUT - sizes[name];
      chunks[name].push(chunk.length > room ? chunk.subarray(0, room) : chunk);
      sizes[name] += Math.min(chunk.length, room);
      if (chunk.length > room && !state.truncated.includes(name)) {
        state.truncated.push(name);
        stop();
      }
    };
    child.stdout.on("data", collect("stdout"));
    child.stderr.on("data", collect("stderr"));
    child.on("error", (error) => settle(null, null, `${error.message}`));
    child.on("close", (code, signal) => settle(code, signal));
  });
}

async function snapshot(cwd, includeIgnored) {
  const result = await computeSnapshot(cwd, undefined, includeIgnored);
  return { complete: result.complete, fingerprint: result.fingerprint };
}

export async function review(options, cwd = process.cwd()) {
  const companion = findCompanion(options.companion);
  const root = repositoryRoot(cwd);
  const gate = await evaluate({ command: null, cwd: root });
  if (!gate.ok) {
    throw new ReviewError(`the Codex gate refused: ${gate.reasons.join("; ")}`);
  }
  const first = await snapshot(root, options.includeIgnored);
  if (!first.complete) {
    throw new ReviewError(
      "the candidate snapshot is incomplete (protected or opaque content, or an unhashable path); the review is blocked before the plugin runs",
    );
  }
  const f0 = first.fingerprint;
  const args = companionArgs(options);
  const run = await runCompanion(companion, args, root, options);
  const second = await snapshot(root, options.includeIgnored);
  const f1 = second.complete ? second.fingerprint : null;
  const result = {
    schema: "b-codex-review/1",
    root,
    round: options.round,
    kind: options.kind,
    target: options.scope !== null ? "working-tree" : `base:${options.base}`,
    companion_args: args.map((item, index) =>
      index === args.length - 1 && options.focus !== null ? "<focus>" : item,
    ),
    f0,
    f1,
    unchanged: f1 !== null && f0 === f1,
    exit_code: run.code,
    signal: run.signal,
    timed_out: run.timedOut,
    truncated: run.truncated,
    stderr: run.stderr.slice(0, 4000),
    raw: run.stdout,
  };
  const voidResult = (reason) => ({
    code: 3,
    result: { ...result, void_reason: reason },
  });
  // A run that was cut short is never a completed review, whatever status it exited with.
  if (run.timedOut) {
    return voidResult(
      `the plugin did not finish within ${options.timeoutMinutes} minutes and was stopped`,
    );
  }
  if (run.truncated.length > 0) {
    return voidResult(
      `the plugin ${run.truncated.join(" and ")} exceeded ${MAX_OUTPUT} bytes and was stopped; the result is incomplete`,
    );
  }
  if (run.code !== 0) {
    throw Object.assign(
      new ReviewError(`the plugin exited with ${run.code ?? run.signal}`),
      { result },
    );
  }
  if (f1 === null) {
    return voidResult(
      "the candidate snapshot after the review is incomplete; the candidate may have changed",
    );
  }
  if (!result.unchanged) {
    return voidResult("the candidate changed during the review (F0 != F1)");
  }
  try {
    result.mapped = mapVerdict(parseInput(run.stdout), options.round);
  } catch (error) {
    return {
      code: 3,
      result: {
        ...result,
        void_reason: "the plugin result could not be mapped",
        mapper_error: error instanceof Error ? error.message : String(error),
      },
    };
  }
  return { code: result.mapped.provisional_verdict === "VOID" ? 3 : 0, result };
}

async function main(argv) {
  const options = parseArgs(argv);
  const { code, result } = await review(options);
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  return code;
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
  main(process.argv.slice(2)).then(
    (code) => {
      process.exitCode = code;
    },
    (error) => {
      process.stderr.write(
        `${error instanceof Error ? error.message : String(error)}\n`,
      );
      if (error?.result)
        process.stdout.write(`${JSON.stringify(error.result, null, 2)}\n`);
      process.exitCode = 2;
    },
  );
}
