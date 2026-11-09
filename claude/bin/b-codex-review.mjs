#!/usr/bin/env node
// b-agentic Codex review wrapper. This is the enforced path for the independent
// changed-code gate: the checks run in this code, not in the model's discipline
// and not in a shell-command parser. It
//   1. refuses unless no likely-secret path is tracked, staged, or
//      untracked-and-not-ignored, no submodule or embedded repository hides paths
//      from the name scan, no untracked symlink would be followed, a --base
//      range (merge-base..HEAD and every commit in it) holds no likely-secret
//      path, and the user approved sending this repository (b-codex-guard's
//      `evaluate`);
//   2. freezes the candidate (F0) and refuses an incomplete snapshot;
//   3. runs the plugin's review in the foreground against exactly one explicit
//      target (a --base is resolved once and passed as its commit id), spawned
//      with an argument vector (no shell, no quoting to defeat);
//   4. freezes the candidate again (F1) and voids the review when F0 != F1;
//   5. maps the plugin's verdict with b-codex-verdict's fail-closed parser.
// The Bash hook in b-codex-guard.mjs only catches accidental direct calls to the
// plugin script; it is a tripwire, not the boundary.
// Codex can be missing or out of quota without anything being wrong with the
// candidate. That case has its own exit (4) so b-review can fall back to the
// read-only b-reviewer subagent mechanically; a refusal or a void review never
// maps to it, because falling back there would route around a protection.
//
// Usage: b-codex-review.mjs --available   (probe only: exit 0 when the plugin script
//          is found, exit 4 with status "unavailable" when it is not, exit 2 when an
//          override variable names a missing or wrongly named script; nothing is
//          sent, read, or approved, so b-review can skip the approval question)
//        b-codex-review.mjs (--scope working-tree | --base <ref>)
//          [--kind adversarial] [--focus <text> | --focus-file <path>]
//          [--round <n>] [--include-ignored <path>]... [--timeout-minutes <n>]
//          [--kill-grace-seconds <n>] [--companion <path>]
// Exit: 0 reviewed, candidate unchanged, verdict mapped; 3 void (the candidate
// changed or could not be re-snapshotted, the run timed out or hit the output
// cap, or the result was unmappable); 2 refused or failed (including an
// incomplete snapshot before the plugin runs); 4 Codex unavailable (the plugin
// script is missing, or the plugin exited non-zero: not logged in, usage limit,
// crash), a case where the b-reviewer subagent may stand in. JSON on stdout.
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

// Codex produced no review and nothing was sent or refused: the plugin is not
// installed, or it ran and exited non-zero.
export class UnavailableError extends ReviewError {}

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
    throw new UnavailableError(
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
  if (options.kind === "native") {
    throw new ReviewError(
      "native review has no verdict contract and is not a gate review; use --kind adversarial",
    );
  }
  if (options.kind !== "adversarial") {
    throw new ReviewError("--kind must be adversarial");
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

// `baseTarget` is the immutable commit id the wrapper resolved once, so a ref
// that moves during the review cannot change the reviewed range.
export function companionArgs(options, baseTarget = options.base) {
  return [
    "adversarial-review",
    "--wait",
    ...(options.scope !== null
      ? ["--scope", "working-tree"]
      : ["--base", baseTarget]),
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
  return {
    complete: result.complete,
    fingerprint: result.fingerprint,
    head: result.head,
    // Untracked entries the plugin would read by following a link; a link can
    // appear after the guard's preflight, so the frozen candidate is checked too.
    symlinks: result.untracked
      .filter((item) => item.type === "symlink")
      .map((item) => item.path),
  };
}

export async function review(options, cwd = process.cwd()) {
  const companion = findCompanion(options.companion);
  const root = repositoryRoot(cwd);
  const gate = await evaluate({
    command: null,
    cwd: root,
    base: options.base ?? undefined,
  });
  if (!gate.ok) {
    throw new ReviewError(`the Codex gate refused: ${gate.reasons.join("; ")}`);
  }
  // The range was scanned from this one resolution of the base; the plugin gets
  // its commit id, never the mutable ref.
  const range = options.base !== null ? gate.range : null;
  if (options.base !== null && range === null) {
    throw new ReviewError(
      "the Codex gate refused: the review range could not be resolved",
    );
  }
  const first = await snapshot(root, options.includeIgnored);
  if (!first.complete) {
    throw new ReviewError(
      "the candidate snapshot is incomplete (protected or opaque content, an unhashable path, or a tracked file hidden by an index flag); the review is blocked before the plugin runs",
    );
  }
  if (first.symlinks.length > 0) {
    throw new ReviewError(
      `the frozen candidate holds untracked symlinks the plugin would follow: ${first.symlinks.join(", ")}; stage, ignore, or remove them. The review is blocked before the plugin runs`,
    );
  }
  if (range !== null && first.head !== range.head) {
    throw new ReviewError(
      "HEAD moved between the review range scan and the snapshot; rerun the review",
    );
  }
  const f0 = first.fingerprint;
  const args = companionArgs(options, range?.base_oid);
  const run = await runCompanion(companion, args, root, options);
  const second = await snapshot(root, options.includeIgnored);
  const f1 = second.complete ? second.fingerprint : null;
  const result = {
    schema: "b-codex-review/1",
    root,
    round: options.round,
    kind: options.kind,
    target: options.scope !== null ? "working-tree" : `base:${options.base}`,
    base:
      range === null
        ? null
        : {
            ref: range.base_ref,
            oid: range.base_oid,
            merge_base: range.merge_base,
          },
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
      new UnavailableError(
        `the plugin exited with ${run.code ?? run.signal}; Codex may be signed out, over its usage limit, or failing`,
      ),
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
  if (argv.length === 1 && argv[0] === "--available") {
    const companion = findCompanion(null);
    process.stdout.write(
      `${JSON.stringify({ schema: "b-codex-review/1", status: "available", companion }, null, 2)}\n`,
    );
    return 0;
  }
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
      const message = error instanceof Error ? error.message : String(error);
      process.stderr.write(`${message}\n`);
      const unavailable = error instanceof UnavailableError;
      if (unavailable) {
        process.stdout.write(
          `${JSON.stringify({ schema: "b-codex-review/1", status: "unavailable", unavailable_reason: message, ...error.result }, null, 2)}\n`,
        );
      } else if (error?.result) {
        process.stdout.write(`${JSON.stringify(error.result, null, 2)}\n`);
      }
      process.exitCode = unavailable ? 4 : 2;
    },
  );
}
