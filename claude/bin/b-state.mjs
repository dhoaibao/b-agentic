#!/usr/bin/env node
// b-agentic run state: the file-backed progress record for a `b-flow` run
// (ADR-009). Only the main session runs it. It keeps `.b-agentic/runs/<id>/state.json`
// valid and refuses steps whose evidence is missing or stale. It fails closed:
// an invalid state, a symlinked folder, a spec changed after approval, a
// fingerprint mismatch, or a missing consent is refused and the state is left
// unchanged.
//
// The state records progress only. `spec.md` (with its recorded sha256) is the
// approval and git is the truth about the tree. State holds no file contents,
// diffs, or command output: only phases, counters, verdict words, fingerprints,
// SHAs, approved check commands, and exit codes. It is untrusted input to every
// other reader and never authorizes push, PR, or any external mutation.
//
// The state is enough to continue a run without any memory of it (ADR-009):
// `history` records every write, and `check` prints `next`, the steps the
// current phase still owes.
//
// Usage: b-state.mjs <command> [args] [--run ID] [--owner NAME]
//   init <slug> [--replace]             create a run in phase clarify and lock it; refused
//                                       while another run is unfinished unless the user
//                                       chose to leave that one (--replace)
//   show [--history]                    print the state (the latest history entries,
//                                       or all of them with --history)
//   approve --commit yes|no --branch-target current|new:<type>/<kebab>
//           --codex standing|reviewer [--size quick|full]
//                                       hash spec.md, check the flags against the
//                                       spec's consent block and size, require a
//                                       clean tree unless commit is no, record
//                                       consent and AC-n, phase approved; a quick
//                                       run must be within the quick limits
//   advance <phase> [--reason R --needs N]
//                                       move to a phase when its guard passes;
//                                       `advance review` also needs --trigger T and
//                                       blocks a quick run; `advance done` from qa
//                                       ends a run that has no commit consent
//   unblock <phase> --reason R          leave `blocked` for clarify|implement|fix|verify
//   record check --cmd C --exit N [--include-ignored P]...
//   record review (--verdict V [--trigger T] | --low-risk REASON)
//   record qa --verdict V
//   record ac AC-n pass|fail|gap|waived
//   record commit SHA
//   record step S-n [--by worker|main]  a plan step is applied (phase implement); a step
//                                       waits for the steps it depends on, and is refused
//                                       when it changed a path outside the approved scope;
//                                       a step the plan lists in worker_steps needs --by
//   check [--takeover]                  verify the state against git, void stale evidence,
//                                       and print `next`: what the phase still owes
//   lock [--takeover] | unlock          take or release the run lock
// Exit: 0 done, 3 refused or not ok, 2 invalid input or state.
//
// This file is the entry: argument parsing, `run` and the dispatch. The rest lives
// in flat modules beside it, imported one way and never in a cycle: b-state-core
// (constants, errors), -git, -store (state files, locks), -gates (evidence checks),
// -worktree, -next, then -record and -commands (the commands).
import { realpathSync, rmSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import {
  cmdAdvance,
  cmdApprove,
  cmdCheck,
  cmdInit,
  cmdUnblock,
} from "./b-state-commands.mjs";
import { invalid, Refused, SHOW_HISTORY } from "./b-state-core.mjs";
import { repoRoot } from "./b-state-git.mjs";
import { cmdRecord } from "./b-state-record.mjs";
import {
  acquireMutex,
  defaultOwner,
  loadState,
  requireLock,
  resolveRun,
  takeLock,
} from "./b-state-store.mjs";
import { cmdWorktree } from "./b-state-worktree.mjs";

export {
  STATE_SCHEMA,
  PHASES,
  REVIEW_VERDICTS,
  QA_VERDICTS,
  AC_STATUSES,
  MAX_ROUNDS,
  SIZES,
} from "./b-state-core.mjs";
export { worktreeTree } from "./b-state-git.mjs";
export { captureCommitPlan, captureStep } from "./b-state-gates.mjs";

const VALUE_FLAGS = new Set([
  "run",
  "owner",
  "commit",
  "branch-target",
  "codex",
  "reason",
  "needs",
  "cmd",
  "exit",
  "include-ignored",
  "from",
  "by",
  "verdict",
  "trigger",
  "low-risk",
  "size",
]);

const BOOL_FLAGS = new Set(["takeover", "history", "replace"]);

export function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (!arg.startsWith("--")) {
      args._.push(arg);
      continue;
    }
    const key = arg.slice(2);
    if (BOOL_FLAGS.has(key)) args[key] = true;
    else if (VALUE_FLAGS.has(key)) {
      const value = argv[++i];
      if (value === undefined) throw invalid(`--${key} needs a value`);
      if (key === "include-ignored") (args[key] ??= []).push(value);
      else args[key] = value;
    } else throw invalid(`unknown argument: --${key}`);
  }
  return args;
}

export async function run(argv, cwd = process.cwd(), deps = {}) {
  const args = parseArgs(argv);
  const command = args._[0];
  const root = await repoRoot(cwd);
  if (command === "init") return cmdInit(root, args);
  if (!command) throw invalid("missing command");
  const { dir } = await resolveRun(root, args);
  if (command === "show") {
    const state = loadState(dir);
    // A long run's history would crowd out the rest of the state.
    if (args.history || state.history.length <= SHOW_HISTORY) return state;
    return {
      ...state,
      history: state.history.slice(-SHOW_HISTORY),
      history_shown: `latest ${SHOW_HISTORY} of ${state.history.length}; show --history prints all`,
    };
  }
  const release = acquireMutex(dir);
  try {
    const state = loadState(dir);
    if (command === "lock") {
      takeLock(dir, defaultOwner(args), Boolean(args.takeover));
      return { locked: true };
    }
    if (command === "unlock") {
      requireLock(dir, args);
      rmSync(join(dir, "lock"), { force: true });
      return { locked: false };
    }
    if (command === "check") {
      const result = await cmdCheck(root, dir, state, args);
      // Resume takes the lock only when the run is still the caller's to continue.
      if (result.ok !== false || state.phase === "blocked") {
        takeLock(dir, defaultOwner(args), Boolean(args.takeover));
      }
      return result;
    }
    requireLock(dir, args);
    if (command === "approve") return await cmdApprove(root, dir, state, args);
    if (command === "advance") return await cmdAdvance(root, dir, state, args);
    if (command === "unblock") return await cmdUnblock(root, dir, state, args);
    if (command === "record")
      return await cmdRecord(root, dir, state, args, deps);
    if (command === "worktree")
      return await cmdWorktree(root, dir, state, args, deps);
    throw invalid(`unknown command: ${command}`);
  } finally {
    release();
  }
}

function isEntryPoint() {
  if (!process.argv[1]) return false;
  try {
    return (
      import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href
    );
  } catch {
    return false;
  }
}

if (isEntryPoint()) {
  run(process.argv.slice(2)).then(
    (result) => {
      process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
      process.exitCode = result?.ok === false ? 3 : 0;
    },
    (error) => {
      process.stderr.write(
        `${error instanceof Error ? error.message : String(error)}\n`,
      );
      process.exitCode = error instanceof Refused ? 3 : 2;
    },
  );
}
