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
import { execFile } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import {
  closeSync,
  constants,
  copyFileSync,
  fstatSync,
  linkSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readlinkSync,
  readSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
  writeSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { computeSnapshot, isProtected } from "./b-candidate-snapshot.mjs";

export const STATE_SCHEMA = 1;
export const PHASES = [
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
// Allowed moves; `blocked` is reachable from every phase but `done`.
const NEXT = {
  clarify: [],
  approved: ["implement"],
  implement: ["verify"],
  verify: ["review", "qa"],
  review: ["fix", "qa"],
  fix: ["verify"],
  qa: ["commit", "fix", "done"],
  commit: ["done"],
  done: [],
  blocked: [],
};
export const REVIEW_VERDICTS = [
  "READY FOR PR",
  "READY WITH FOLLOW-UPS",
  "NEEDS FIXES",
];
export const QA_VERDICTS = ["QA PASS", "QA FAIL", "QA BLOCKED"];
export const AC_STATUSES = ["pending", "pass", "fail", "gap", "waived"];
export const MAX_ROUNDS = 3;
const RUN_ID = /^\d{8}-[a-z0-9][a-z0-9-]{0,40}$/;
const SLUG = /^[a-z0-9][a-z0-9-]{0,40}$/;
const SHA = /^[0-9a-f]{7,64}$/;
const BRANCH_TARGET = /^(current|new:[a-z]+\/[a-z0-9][a-z0-9-]*)$/;
const AC_ID = /^AC-\d+$/;
const FINGERPRINT = /^[0-9a-f]{64}$/;
const OWNER = /^[A-Za-z0-9._:-]{1,80}$/;
const CONSENT_DRIFT = "recorded consent differs from the approved spec";
const SIZE_DRIFT = "recorded run size differs from the approved spec";
const MAX_CMD = 300;
const MAX_TEXT = 300;
const MAX_STATE_BYTES = 1 << 20;
// One entry per write, oldest dropped first; `history_dropped` counts those.
const MAX_HISTORY = 200;
const SHOW_HISTORY = 20;
const HISTORY_OPS = [
  "init",
  "approve",
  "advance",
  "unblock",
  "check",
  "record check",
  "record review",
  "record qa",
  "record ac",
  "record commit",
  "record step",
];
// The only facts an entry may carry: the same kinds the rest of the state holds.
const HISTORY_DETAIL = [
  "cmd",
  "exit",
  "verdict",
  "round",
  "trigger",
  "reason",
  "needs",
  "fingerprint",
  "ac",
  "status",
  "sha",
  "spec",
  "step",
  "tree",
  "paths",
  "outside",
  "by",
];
const STEP_ID = /^S-[1-9]\d*$/;
const TREE_ID = /^[0-9a-f]{40}([0-9a-f]{24})?$/;
// Changes already in the tree at run start, tracked by content digest.
const MAX_DIRTY = 200;
const MAX_DIRTY_BYTES = 64 << 20;
const DIRTY_DIGEST = /^((x:)?[0-9a-f]{64}|link:[0-9a-f]{64}|absent)$/;
// A quick run is small enough that the request itself is the approval: it
// never commits and never enters review. Anything larger is a full run.
export const SIZES = ["quick", "full"];
const QUICK_LIMITS = { steps: 3, criteria: 3, scope_paths: 5 };
const QUICK_EVIDENCE = ["automated", "inspection"];
const CONTROL = /[\u0000-\u001f\u007f]/;

class Refused extends Error {}
class Invalid extends Error {}
const refuse = (message) => new Refused(message);
const invalid = (message) => new Invalid(message);

const sha256 = (value) => createHash("sha256").update(value).digest("hex");
const now = () => new Date().toISOString();

function git(cwd, args, env = process.env) {
  return new Promise((done, fail) => {
    execFile(
      "git",
      args,
      { cwd, env, encoding: "utf8", maxBuffer: 1 << 24 },
      (error, stdout) => (error ? fail(error) : done(stdout)),
    );
  });
}

// The same, with stdout as bytes: for path lists handed back to git unchanged.
function gitBytes(cwd, args, env = process.env) {
  return new Promise((done, fail) => {
    execFile(
      "git",
      args,
      { cwd, env, encoding: "buffer", maxBuffer: 1 << 26 },
      (error, stdout) => (error ? fail(error) : done(stdout)),
    );
  });
}

// The same, with bytes written to stdin: for paths git is to take literally.
function gitInput(cwd, args, input, env = process.env) {
  return new Promise((done, fail) => {
    const child = execFile(
      "git",
      args,
      { cwd, env, encoding: "utf8", maxBuffer: 1 << 24 },
      (error, stdout) => (error ? fail(error) : done(stdout)),
    );
    // git may exit before reading everything; the exit status reports that.
    child.stdin.on("error", () => {});
    child.stdin.end(input);
  });
}

async function gitOr(cwd, args, fallback = "", env = process.env) {
  try {
    return (await git(cwd, args, env)).trim();
  } catch {
    return fallback;
  }
}

async function repoRoot(cwd) {
  try {
    return realpathSync(
      (await git(cwd, ["rev-parse", "--show-toplevel"])).trim(),
    );
  } catch {
    throw refuse("not inside a git worktree");
  }
}

async function worktreeBaseline(root) {
  const status = await gitOr(root, [
    "status",
    "--porcelain=v1",
    "-z",
    "--untracked-files=all",
  ]);
  return {
    head: await gitOr(root, ["rev-parse", "HEAD"]),
    branch: await gitOr(root, ["rev-parse", "--abbrev-ref", "HEAD"]),
    status_digest: sha256(status),
    dirty: status.length > 0,
  };
}

// The identity of one path's content, without keeping the content: the same
// rule as path_digest in b_run.py, which compares against it.
//
// The read never leaves the tree: a link anywhere above the path makes it
// unidentifiable (""), and the path itself is opened without following a link.
// The digest carries the executable bit, which git tracks beside the content.
function pathDigest(root, rel) {
  const parts = rel.split("/");
  if (rel.startsWith("/") || parts.includes("..") || parts.includes(""))
    return "";
  let dir = root;
  for (const part of parts.slice(0, -1)) {
    dir = join(dir, part);
    let above;
    try {
      above = lstatSync(dir);
    } catch {
      return "absent";
    }
    if (above.isSymbolicLink()) return "";
    if (!above.isDirectory()) return "absent";
  }
  const full = join(root, rel);
  let stat;
  try {
    stat = lstatSync(full);
  } catch {
    return "absent";
  }
  if (stat.isSymbolicLink()) return `link:${sha256(readlinkSync(full))}`;
  if (!stat.isFile()) return "";
  let fd;
  try {
    fd = openSync(
      full,
      constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
    );
  } catch {
    return "";
  }
  try {
    const opened = fstatSync(fd);
    if (!opened.isFile() || opened.size > MAX_DIRTY_BYTES) return "";
    const hash = createHash("sha256");
    const buffer = Buffer.alloc(1 << 20);
    for (;;) {
      const n = readSync(fd, buffer, 0, buffer.length, null);
      if (n === 0) break;
      hash.update(buffer.subarray(0, n));
    }
    return `${opened.mode & 0o100 ? "x:" : ""}${hash.digest("hex")}`;
  } finally {
    closeSync(fd);
  }
}

// The changes already in the tree when a run starts: they are the user's, not
// the run's, for as long as their content stays the same. A path whose content
// cannot be identified safely (a likely-secret file, a directory, a very large
// file, an odd name) is left out, so it counts as a change of the run and the
// scope check stops on it.
async function dirtyBaseline(root) {
  // Untrimmed: the first status code may begin with a space.
  const status = await git(root, [
    "status",
    "--porcelain=v1",
    "-z",
    "--untracked-files=all",
  ]).catch(() => {
    throw refuse("git status failed; the tree's changes cannot be recorded");
  });
  const tokens = status.split("\0");
  const paths = [];
  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i];
    if (token.length < 4) continue;
    paths.push(token.slice(3));
    if ("RC".includes(token[0])) paths.push(tokens[++i] ?? "");
  }
  const unique = [...new Set(paths)].filter(Boolean);
  if (unique.length > MAX_DIRTY) {
    throw refuse(
      `the working tree has ${unique.length} changed paths, too many to tell apart from a run's own; commit or stash them first`,
    );
  }
  const dirty = {};
  for (const rel of unique) {
    if (rel.length > MAX_TEXT || CONTROL.test(rel) || isProtected(rel))
      continue;
    const digest = pathDigest(root, rel);
    if (digest) dirty[rel] = digest;
  }
  return dirty;
}

// The tree object of the whole working tree (tracked and untracked, not ignored),
// built in a throwaway index seeded from the real one so tracked files that an
// ignore rule covers, and sparse entries, are kept; the real index is never
// touched. A finished run must have committed exactly this tree.
//
// No likely-secret file's content may reach the object store through this
// tree, including one that appears while it is being built, so nothing is
// added by walking the working tree:
//   - the changed paths are listed by name, and a protected name refuses;
//   - exactly those index entries are updated (`update-index`, never `add`):
//     a listed path that has meanwhile become a directory is not descended
//     into, a symbolic link is stored as a link, and a path below a link is
//     refused by git;
//   - every entry that then differs from HEAD is checked by name once more,
//     which also covers a protected path that was already staged.
// `between` runs after each listing and before its entries are updated; the
// probes use it to change the tree at exactly that point.
export async function worktreeTree(
  root,
  includeIgnored = [],
  { between = async () => {} } = {},
) {
  const dir = mkdtempSync(join(tmpdir(), "b-state-"));
  const env = { ...process.env, GIT_INDEX_FILE: join(dir, "index") };
  const namesOf = (bytes) => bytes.toString("utf8").split("\0").filter(Boolean);
  const refuseProtected = (names) => {
    if (names.some((name) => isProtected(name))) {
      throw refuse(
        "a protected path is changed in the working tree; no tree is built",
      );
    }
  };
  try {
    const real = await gitOr(root, ["rev-parse", "--git-path", "index"]);
    if (real) {
      try {
        copyFileSync(resolve(root, real), join(dir, "index"));
      } catch {
        // No index yet: an empty one is the correct seed.
      }
    }
    // The list goes back to git as the bytes git printed, so a name that is
    // not valid UTF-8 survives; `update-index` takes paths, never patterns.
    const list = (selection) =>
      gitBytes(
        root,
        ["--literal-pathspecs", "ls-files", "-z", ...selection],
        env,
      );
    const entries = (bytes) => {
      const out = [];
      let start = 0;
      for (let i = 0; i < bytes.length; i++) {
        if (bytes[i] !== 0) continue;
        if (i > start) out.push(bytes.subarray(start, i));
        start = i + 1;
      }
      return out;
    };
    // Updates exactly the listed entries: the tracked ones that changed first,
    // then the untracked ones. A step may turn a file into a directory or a
    // directory into a file; the tracked entry is then no longer a file, and
    // git removes it when it comes first, so the new path no longer conflicts
    // with it (`--replace` covers what the order does not). Neither reads
    // anything from the tree beyond the listed paths.
    const update = async (tracked, untracked) => {
      refuseProtected([...namesOf(tracked), ...namesOf(untracked)]);
      await between();
      const first = entries(tracked);
      const seen = new Set(first.map((entry) => entry.toString("latin1")));
      const ordered = [
        ...first,
        ...entries(untracked).filter(
          (entry) => !seen.has(entry.toString("latin1")),
        ),
      ];
      if (ordered.length === 0) return;
      await gitInput(
        root,
        ["update-index", "--add", "--remove", "--replace", "-z", "--stdin"],
        Buffer.concat(ordered.flatMap((entry) => [entry, Buffer.alloc(1)])),
        env,
      );
    };
    await update(
      await list(["--modified", "--deleted"]),
      await list(["--others", "--exclude-standard"]),
    );
    // Artifacts the candidate names with --include-ignored are part of what was
    // reviewed and QA'd, so they belong to the approved tree too.
    if (includeIgnored.length > 0) {
      await update(
        Buffer.alloc(0),
        await list([
          "--others",
          "--ignored",
          "--exclude-standard",
          "--",
          ...includeIgnored,
        ]),
      );
      // A named artifact that matches nothing fails, as it always did: a typo
      // must not leave it out of the tree silently.
      await git(
        root,
        [
          "--literal-pathspecs",
          "ls-files",
          "--error-unmatch",
          "--",
          ...includeIgnored,
        ],
        env,
      );
    }
    const head = await gitOr(root, ["rev-parse", "--verify", "-q", "HEAD"]);
    refuseProtected(
      namesOf(
        await gitBytes(
          root,
          head
            ? [
                "diff-index",
                "--cached",
                "--name-only",
                "--no-renames",
                "-z",
                head,
              ]
            : ["ls-files", "-z"],
          env,
        ),
      ),
    );
    return (await git(root, ["write-tree"], env)).trim();
  } catch (error) {
    if (error instanceof Refused) throw error;
    throw refuse("cannot compute the working-tree identity");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// Bind the approved fingerprint to the tree that will be committed. The
// fingerprint is recomputed after the tree is captured; a mismatch means the
// working tree changed during capture, so nothing is recorded.
export async function captureCommitPlan(
  root,
  state,
  fingerprint,
  head,
  {
    tree = (r) => worktreeTree(r, state.candidate.include_ignored),
    fingerprintOf = currentFingerprint,
  } = {},
) {
  const captured = await tree(root);
  if ((await fingerprintOf(state)) !== fingerprint) {
    throw refuse("the working tree changed while the commit plan was captured");
  }
  return { base: head, tree: captured, fingerprint };
}

const isAncestor = async (root, ancestor, descendant) => {
  try {
    await git(root, ["merge-base", "--is-ancestor", ancestor, descendant]);
    return true;
  } catch {
    return false;
  }
};

// `current` stays on the run's branch; `new:<name>` accepts <name> or the
// numbered variant b-commit appends when <name> already exists.
function branchAllowed(state, branch) {
  const target = state.consent.branch_target;
  if (target === "current") return branch === state.branch;
  const name = target.slice("new:".length);
  return branch === name || new RegExp(`^${name}-\\d+$`).test(branch);
}

// ---- safe file access -------------------------------------------------------

const isPlainDir = (path) => {
  try {
    const stat = lstatSync(path);
    return stat.isDirectory() && !stat.isSymbolicLink();
  } catch {
    return false;
  }
};

function ensureDir(path) {
  if (isPlainDir(path)) return;
  try {
    lstatSync(path);
    throw refuse(`${path} exists and is not a plain directory`);
  } catch (error) {
    if (error instanceof Refused) throw error;
  }
  mkdirSync(path, { mode: 0o700 });
}

function readSmall(path) {
  const fd = openSync(
    path,
    constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
  );
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile() || stat.size > MAX_STATE_BYTES) {
      throw refuse(`${path} is not a regular file within the size limit`);
    }
    const buffer = Buffer.alloc(stat.size);
    let offset = 0;
    while (offset < stat.size) {
      const n = readSync(fd, buffer, offset, stat.size - offset, offset);
      if (n === 0) break;
      offset += n;
    }
    return buffer.subarray(0, offset);
  } finally {
    closeSync(fd);
  }
}

// Temp file in the same folder, then rename: readers never see a partial write.
function writeAtomic(path, text) {
  const temp = `${path}.${process.pid}.${Date.now()}.tmp`;
  const fd = openSync(
    temp,
    constants.O_WRONLY |
      constants.O_CREAT |
      constants.O_EXCL |
      constants.O_NOFOLLOW,
    0o600,
  );
  try {
    writeSync(fd, text);
  } finally {
    closeSync(fd);
  }
  try {
    renameSync(temp, path);
  } catch (error) {
    rmSync(temp, { force: true });
    throw error;
  }
}

// ---- layout -----------------------------------------------------------------

function layout(root) {
  const base = join(root, ".b-agentic");
  return { base, runs: join(base, "runs"), active: join(base, "active") };
}

function ensureBase(root) {
  const { base, runs } = layout(root);
  ensureDir(base);
  ensureDir(runs);
  // Self-ignoring, so other repositories need no tracked change.
  try {
    writeAtomicIfMissing(join(base, ".gitignore"), "*\n");
  } catch (error) {
    if (error instanceof Refused) throw error;
  }
}

function writeAtomicIfMissing(path, text) {
  try {
    lstatSync(path);
  } catch {
    writeAtomic(path, text);
  }
}

async function resolveRun(root, args) {
  const { runs, active } = layout(root);
  if (!isPlainDir(layout(root).base) || !isPlainDir(runs)) {
    throw refuse("no .b-agentic/runs folder (run init first)");
  }
  let id = args.run;
  if (id === undefined) {
    try {
      id = readSmall(active).toString("utf8").trim();
    } catch {
      throw refuse("no active run (pass --run or run init)");
    }
  }
  if (typeof id !== "string" || !RUN_ID.test(id)) throw invalid("bad run id");
  const dir = join(runs, id);
  if (!isPlainDir(dir)) throw refuse(`run ${id} does not exist`);
  return { id, dir };
}

// ---- state ------------------------------------------------------------------

function validate(state) {
  const fail = (what) => {
    throw invalid(`invalid state: ${what}`);
  };
  const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
  const isInt = (v) => Number.isInteger(v) && v >= 0;
  if (!isObj(state)) fail("not an object");
  if (state.schema !== STATE_SCHEMA) fail("unknown schema");
  if (!RUN_ID.test(state.run_id ?? "")) fail("run_id");
  if (typeof state.repo_root !== "string" || !state.repo_root)
    fail("repo_root");
  if (!PHASES.includes(state.phase)) fail("phase");
  if (!isInt(state.rev)) fail("rev");
  for (const key of [
    "baseline",
    "spec",
    "consent",
    "attempts",
    "candidate",
    "review",
    "qa",
    "ac",
  ]) {
    if (!isObj(state[key])) fail(key);
  }
  for (const key of ["verify", "review_needs_fixes", "qa_fail", "step"]) {
    if (!isInt(state.attempts[key])) fail(`attempts.${key}`);
  }
  const base = state.step_base;
  if (
    base !== null &&
    !(
      isObj(base) &&
      TREE_ID.test(base.tree ?? "") &&
      FINGERPRINT.test(base.fingerprint ?? "") &&
      // Empty in a repository that has no commit yet.
      (base.head === "" || SHA.test(base.head ?? "")) &&
      isInt(base.rev)
    )
  ) {
    fail("step_base");
  }
  if (
    !Array.isArray(state.commits) ||
    !state.commits.every((s) => SHA.test(s)) ||
    !Array.isArray(state.prior_commits) ||
    !state.prior_commits.every((s) => SHA.test(s))
  ) {
    fail("commits");
  }
  if (!Array.isArray(state.candidate.checks)) fail("candidate.checks");
  for (const check of state.candidate.checks) {
    if (typeof check.cmd !== "string" || !Number.isInteger(check.exit))
      fail("check");
  }
  if (!Array.isArray(state.candidate.include_ignored)) fail("include_ignored");
  for (const [id, entry] of Object.entries(state.ac)) {
    if (
      !AC_ID.test(id) ||
      !AC_STATUSES.includes(entry?.status) ||
      typeof entry.fingerprint !== "string"
    )
      fail(`ac ${id}`);
  }
  const { consent } = state;
  if (typeof consent.commit !== "boolean") fail("consent.commit");
  if (!BRANCH_TARGET.test(consent.branch_target ?? ""))
    fail("consent.branch_target");
  if (!["standing", "reviewer"].includes(consent.codex)) fail("consent.codex");
  if (consent.push_pr !== false) fail("consent.push_pr");
  for (const [key, value] of [
    ["branch", state.branch],
    ["baseline.head", state.baseline.head],
    ["spec.sha256", state.spec.sha256],
    ["spec.plan_sha256", state.spec.plan_sha256],
    ["candidate.fingerprint", state.candidate.fingerprint],
    ["review.fingerprint", state.review.fingerprint],
    ["qa.fingerprint", state.qa.fingerprint],
  ]) {
    if (typeof value !== "string") fail(key);
  }
  for (const value of [
    state.spec.sha256,
    state.candidate.fingerprint,
    state.review.fingerprint,
    state.qa.fingerprint,
  ]) {
    if (value !== "" && !FINGERPRINT.test(value)) fail("fingerprint format");
  }
  if (!SIZES.includes(state.size)) fail("size");
  const dirty = state.baseline.dirty;
  if (!isObj(dirty) || Object.keys(dirty).length > MAX_DIRTY)
    fail("baseline.dirty");
  for (const [path, digest] of Object.entries(dirty)) {
    if (
      !path ||
      path.length > MAX_TEXT ||
      CONTROL.test(path) ||
      isProtected(path) ||
      !DIRTY_DIGEST.test(digest)
    )
      fail("baseline.dirty entry");
  }
  if (!isObj(state.steps)) fail("steps");
  for (const [id, entry] of Object.entries(state.steps)) {
    if (
      !STEP_ID.test(id) ||
      entry?.status !== "done" ||
      !FINGERPRINT.test(entry.fingerprint ?? "")
    )
      fail(`step ${id}`);
  }
  if (!isInt(state.review.round) || !isInt(state.qa.round)) fail("round");
  if (!isInt(state.qa.artifact_rev)) fail("qa.artifact_rev");
  if (typeof state.review.required !== "boolean") fail("review.required");
  const plan = state.commit_plan;
  if (
    plan !== null &&
    !(
      isObj(plan) &&
      typeof plan.base === "string" &&
      /^[0-9a-f]{40,64}$/.test(plan.tree ?? "") &&
      FINGERPRINT.test(plan.fingerprint ?? "")
    )
  ) {
    fail("commit_plan");
  }
  if (state.review.verdict && !REVIEW_VERDICTS.includes(state.review.verdict))
    fail("review.verdict");
  if (state.qa.verdict && !QA_VERDICTS.includes(state.qa.verdict))
    fail("qa.verdict");
  if (
    !Array.isArray(state.history) ||
    state.history.length > MAX_HISTORY ||
    !isInt(state.history_dropped)
  ) {
    fail("history");
  }
  for (const entry of state.history) {
    if (
      !isObj(entry) ||
      typeof entry.at !== "string" ||
      !isInt(entry.rev) ||
      !HISTORY_OPS.includes(entry.op) ||
      !(entry.from === "" || PHASES.includes(entry.from)) ||
      !PHASES.includes(entry.to) ||
      !isObj(entry.detail)
    ) {
      fail("history entry");
    }
    for (const [key, value] of Object.entries(entry.detail)) {
      const line =
        typeof value === "string" &&
        value.length <= MAX_TEXT &&
        !CONTROL.test(value);
      if (!HISTORY_DETAIL.includes(key) || !(line || isInt(value)))
        fail("history detail");
    }
  }
  return state;
}

function loadState(dir) {
  let state;
  try {
    state = JSON.parse(readSmall(join(dir, "state.json")).toString("utf8"));
  } catch (error) {
    if (error instanceof Refused || error instanceof Invalid) throw error;
    throw invalid("state.json is unreadable or not JSON");
  }
  // A run made before ADR-010 lacks the artifact fields. Fill them so the run can
  // load, be checked (its unrecorded artifacts then block it), and be unblocked to
  // clarify for new artifacts and a new approval.
  if (state && typeof state === "object") {
    if (state.spec && typeof state.spec === "object")
      state.spec.plan_sha256 ??= "";
    if (state.qa && typeof state.qa === "object") state.qa.artifact_rev ??= 0;
    // A run made before the history existed starts one from here.
    // Nor a step cursor: only `implement` asks for it, so a run already past
    // that phase is not sent back.
    state.steps ??= {};
    // Nor a step base: its steps are recorded unchecked, as they were, until
    // the run enters implement again.
    state.step_base ??= null;
    if (state.attempts && typeof state.attempts === "object")
      state.attempts.step ??= 0;
    // Before run sizes every run was a full run that started on a clean tree.
    state.size ??= "full";
    if (state.baseline && typeof state.baseline === "object")
      state.baseline.dirty ??= {};
    state.history ??= [];
    state.history_dropped ??= 0;
  }
  return validate(state);
}

// `rev` is an optimistic check: a concurrent writer between our read and our
// rename makes this write refuse rather than silently drop its change.
//
// Every write appends one history entry in the same atomic write as the change
// it describes, so the record cannot drift from the state. A new or replaced
// block always records why: `unblock` clears the reason from the state.
function saveState(dir, state, op, detail = {}) {
  const current = loadState(dir);
  if (current.rev !== state.rev) {
    throw refuse("state changed during the operation; rerun");
  }
  state.rev += 1;
  state.updated_at = now();
  const blockedAnew =
    state.phase === "blocked" &&
    (current.phase !== "blocked" ||
      current.blocked.reason !== state.blocked.reason ||
      current.blocked.needs !== state.blocked.needs);
  const facts = blockedAnew
    ? { ...detail, reason: state.blocked.reason, needs: state.blocked.needs }
    : detail;
  state.history.push({
    at: state.updated_at,
    rev: state.rev,
    op,
    from: current.phase,
    to: state.phase,
    detail: Object.fromEntries(
      Object.entries(facts).filter(([, v]) => v !== "" && v !== undefined),
    ),
  });
  if (state.history.length > MAX_HISTORY) {
    state.history_dropped += state.history.length - MAX_HISTORY;
    state.history = state.history.slice(-MAX_HISTORY);
  }
  validate(state);
  writeAtomic(join(dir, "state.json"), `${JSON.stringify(state, null, 2)}\n`);
}

function freshState(runId, root, baseline) {
  return {
    schema: STATE_SCHEMA,
    rev: 0,
    run_id: runId,
    repo_root: root,
    branch: baseline.branch,
    baseline: {
      head: baseline.head,
      status_digest: baseline.status_digest,
      dirty: baseline.dirty_paths,
    },
    size: "full",
    spec: { path: "spec.md", sha256: "", plan_sha256: "", approved_at: "" },
    consent: {
      commit: false,
      branch_target: "current",
      codex: "reviewer",
      push_pr: false,
    },
    phase: "clarify",
    attempts: { verify: 0, review_needs_fixes: 0, qa_fail: 0, step: 0 },
    candidate: { fingerprint: "", include_ignored: [], checks: [] },
    review: {
      required: true,
      trigger: "",
      round: 0,
      verdict: "",
      low_risk_exception: "",
      fingerprint: "",
    },
    ac: {},
    qa: { round: 0, verdict: "", fingerprint: "", artifact_rev: 0 },
    commits: [],
    prior_commits: [],
    commit_plan: null,
    blocked: { reason: "", needs: "", from: "" },
    steps: {},
    step_base: null,
    history: [
      { at: now(), rev: 0, op: "init", from: "", to: "clarify", detail: {} },
    ],
    history_dropped: 0,
    updated_at: now(),
  };
}

// ---- lock -------------------------------------------------------------------

function defaultOwner(args) {
  // Claude Code sets CLAUDE_CODE_SESSION_ID; Pi sets PI_SESSION_ID for its bash tool.
  const owner =
    args.owner ??
    process.env.CLAUDE_CODE_SESSION_ID ??
    process.env.PI_SESSION_ID ??
    "";
  if (!OWNER.test(owner)) {
    throw invalid(
      "pass --owner NAME (letters, digits, . _ : -) or set CLAUDE_CODE_SESSION_ID or PI_SESSION_ID",
    );
  }
  return owner;
}

function readLock(dir) {
  try {
    const lock = JSON.parse(readSmall(join(dir, "lock")).toString("utf8"));
    return typeof lock?.owner === "string" ? lock : null;
  } catch {
    return null;
  }
}

function takeLock(dir, owner, takeover) {
  const held = readLock(dir);
  if (held && held.owner !== owner && !takeover) {
    throw refuse(
      `run is locked by another session (${held.owner}); an explicit resume may use --takeover`,
    );
  }
  writeAtomic(join(dir, "lock"), `${JSON.stringify({ owner, at: now() })}\n`);
}

function requireLock(dir, args) {
  const owner = defaultOwner(args);
  const held = readLock(dir);
  if (!held) throw refuse("run is not locked; run lock first");
  if (held.owner !== owner) {
    throw refuse(`run is locked by another session (${held.owner})`);
  }
  return owner;
}

// ---- evidence ---------------------------------------------------------------

async function currentFingerprint(state) {
  const snapshot = await computeSnapshot(
    state.repo_root,
    undefined,
    state.candidate.include_ignored,
  );
  if (!snapshot.complete) {
    throw refuse(
      "candidate snapshot is incomplete; resolve the uncovered paths first",
    );
  }
  return snapshot.fingerprint;
}

function specHash(dir) {
  try {
    return sha256(readSmall(join(dir, "spec.md")));
  } catch {
    return "";
  }
}

function planHash(dir) {
  try {
    return sha256(readSmall(join(dir, "plan.md")));
  } catch {
    return "";
  }
}

function requireSpecUnchanged(dir, state) {
  if (!state.spec.sha256) throw refuse("spec is not approved");
  if (specHash(dir) !== state.spec.sha256) {
    throw refuse("spec.md changed after approval; re-approval is required");
  }
  if (state.spec.plan_sha256 && planHash(dir) !== state.spec.plan_sha256) {
    throw refuse("plan.md changed after approval; re-approval is required");
  }
}

// ---- run artifacts (b_run.py, ADR-010) -----------------------------------------

const RUN_CLI = fileURLToPath(new URL("./b_run.py", import.meta.url));

// Runs the artifact CLI. A missing interpreter or CLI fails closed.
function runArtifacts(root, args) {
  return new Promise((done) => {
    execFile(
      "python3",
      ["-I", "-B", RUN_CLI, ...args],
      { cwd: root, encoding: "utf8", maxBuffer: 1 << 24 },
      (error, stdout, stderr) =>
        done({
          code: error ? (typeof error.code === "number" ? error.code : 2) : 0,
          stdout,
          stderr: stderr || (error ? String(error.message) : ""),
        }),
    );
  });
}

// The recorded artifacts must still be exactly what b_run.py wrote.
async function artifactsOk(root, state) {
  const result = await runArtifacts(root, [
    "validate",
    "--run",
    state.run_id,
    "--json",
  ]);
  let parsed;
  try {
    parsed = JSON.parse(result.stdout);
  } catch {
    throw refuse(
      `the artifact CLI failed: ${result.stderr.trim().split("\n")[0] || "no output"}`,
    );
  }
  if (result.code !== 0 || parsed.ok !== true) {
    throw refuse(
      `run artifacts are not valid: ${(parsed.problems ?? [])[0] ?? "unknown problem"}`,
    );
  }
  return parsed;
}

async function scopeOk(root, state) {
  const result = await runArtifacts(root, [
    "scope-check",
    "--run",
    state.run_id,
  ]);
  let parsed;
  try {
    parsed = JSON.parse(result.stdout);
  } catch {
    throw refuse("the scope check failed to run");
  }
  if (parsed.ok !== true) {
    const bad = [...(parsed.outside_scope ?? []), ...(parsed.protected ?? [])];
    throw refuse(
      `changed paths outside the approved scope: ${bad.slice(0, 5).join(", ")}`,
    );
  }
}

// ---- plan steps ---------------------------------------------------------------

const STATE_WRITTEN = "run state was written outside the step";
const HEAD_MOVED = "HEAD moved during the step";

// Where a plan step starts: the working tree as a tree id, its fingerprint,
// HEAD, and the state revision of the write that stores it. `record step`
// compares the tree after the step with this one, so what a step changed is
// checked when it is recorded rather than on the way to review.
//
// A run without a base records its steps unchecked, as before.
async function newStepBase(root, state) {
  const { snapshot, tree, head } = await captureStep(root, state);
  if (!snapshot.complete) return null;
  return {
    tree,
    fingerprint: snapshot.fingerprint,
    head,
    rev: state.rev + 1,
  };
}

// One consistent view of the working tree for a plan step: its snapshot, its
// tree, and HEAD.
//
// The snapshot comes first: it is incomplete while a likely-secret path is
// changed, and then no tree is built. It is taken again after the tree: a
// different fingerprint means the tree changed while it was captured, so the
// tree and the fingerprint would not describe the same content, and nothing
// is recorded. HEAD is the snapshot's own (empty before the first commit): it
// is part of the fingerprint, so the three always describe one moment.
export async function captureStep(
  root,
  state,
  {
    tree = (r) => worktreeTree(r, []),
    snapshotOf = (s) =>
      computeSnapshot(s.repo_root, undefined, s.candidate.include_ignored),
  } = {},
) {
  const snapshot = await snapshotOf(state);
  const head = snapshot.head ?? "";
  if (!snapshot.complete) return { snapshot, tree: "", head };
  const captured = await tree(root);
  if ((await snapshotOf(state)).fingerprint !== snapshot.fingerprint) {
    throw refuse("the working tree changed while the step was captured; rerun");
  }
  return { snapshot, tree: captured, head };
}

// HEAD as the snapshot reads it: the commit id, or empty before the first commit.
const currentHead = (root) =>
  gitOr(root, ["rev-parse", "--verify", "-q", "HEAD^{commit}"]);

// The paths that differ between two trees, classified by b_run.py against the
// approved scope and the step's own paths.
async function stepDelta(root, state, base, tree, id) {
  const result = await runArtifacts(root, [
    "scope-check",
    "--run",
    state.run_id,
    "--base",
    base,
    "--tree",
    tree,
    "--step",
    id,
  ]);
  try {
    const parsed = JSON.parse(result.stdout);
    if (
      Array.isArray(parsed.outside_scope) &&
      Array.isArray(parsed.protected) &&
      Number.isInteger(parsed.changed) &&
      Number.isInteger(parsed.outside_step)
    )
      return parsed;
  } catch {
    // Reported below.
  }
  throw refuse(
    `the step's changes could not be compared with its base: ${
      result.stderr.trim().split("\n")[0] || "no output"
    }`,
  );
}

// Path names fit for the state: never a protected one, never one that would
// not survive as a printable line.
const namedPaths = (paths) => {
  const safe = paths
    .filter((p) => !isProtected(p) && !CONTROL.test(p) && p.length <= 80)
    .slice(0, 3);
  const rest = paths.length - safe.length;
  if (safe.length === 0) return `${paths.length} path(s)`;
  return safe.join(", ") + (rest > 0 ? ` and ${rest} more` : "");
};

// The plan checks without a passing result for the recorded candidate.
function missingChecks(state, plan) {
  return plan.checks.filter(
    (cmd) => !state.candidate.checks.some((c) => c.cmd === cmd && c.exit === 0),
  );
}

// Every approved plan check must have passed, not just the ones that were run.
function checksPass(state, plan) {
  return plan.checks.length > 0 && missingChecks(state, plan).length === 0;
}

// The plan checks the approval allows to run at the same time.
const parallelChecks = (art) => art.artifacts.plan?.parallel_checks ?? [];
// The plan steps the approval hands to a worker (ADR-015).
const workerSteps = (art) => art.artifacts.plan?.worker_steps ?? [];
const CANDIDATE_MOVED = "the candidate changed while the check ran";

// The plan steps not yet recorded as applied, in plan order.
const missingSteps = (state, plan) =>
  plan.step_ids.filter((id) => !state.steps[id]);

const checksOwed = (state, plan) =>
  `plan checks without a passing result for the candidate: ${
    missingChecks(state, plan).join("; ") || "the plan lists none"
  }`;

function reviewCovers(state, fingerprint) {
  if (state.review.fingerprint !== fingerprint) return false;
  return (
    state.review.verdict === "READY FOR PR" ||
    state.review.verdict === "READY WITH FOLLOW-UPS" ||
    Boolean(state.review.low_risk_exception)
  );
}

// The consent in state must equal the consent in the approved spec. Every
// step that acts on it (the commit gate, recording commits, completion, and
// `check`) compares all three fields, so a state.json edit cannot widen it.
function consentMatches(state, art) {
  const approved = art.artifacts.spec?.consent;
  return Boolean(
    approved &&
    approved.commit === (state.consent.commit ? "yes" : "no") &&
    approved.branch_target === state.consent.branch_target &&
    approved.codex === state.consent.codex,
  );
}

// The run size in state must equal the size in the approved spec, for the same
// reason: a quick run was approved by the request alone, and only a new
// approval makes it a full one.
const sizeMatches = (state, art) => art.artifacts.spec?.size === state.size;

// Every acceptance result must belong to the candidate being committed.
function acOpen(state, fingerprint) {
  return Object.entries(state.ac)
    .filter(
      ([, e]) =>
        !["pass", "waived"].includes(e.status) || e.fingerprint !== fingerprint,
    )
    .map(([id]) => id);
}

function voidEvidence(state) {
  state.commit_plan = null;
  state.candidate.fingerprint = "";
  state.candidate.checks = [];
  state.review.verdict = "";
  state.review.low_risk_exception = "";
  state.review.fingerprint = "";
  state.qa.verdict = "";
  state.qa.fingerprint = "";
  for (const entry of Object.values(state.ac)) {
    entry.status = "pending";
    entry.fingerprint = "";
  }
}

function block(state, reason, needs) {
  if (state.phase !== "blocked") state.blocked.from = state.phase;
  state.phase = "blocked";
  state.blocked.reason = reason.slice(0, MAX_TEXT);
  state.blocked.needs = needs.slice(0, MAX_TEXT);
}

const text = (value, name, max = MAX_TEXT) => {
  if (
    typeof value !== "string" ||
    !value.trim() ||
    value.length > max ||
    CONTROL.test(value)
  ) {
    throw invalid(`${name} must be one line of 1-${max} printable characters`);
  }
  return value.trim();
};

// ---- commands ---------------------------------------------------------------

// The run `active` names when it is not finished; an unreadable one counts.
function activeUnfinished(root) {
  const { runs, active } = layout(root);
  let id;
  try {
    id = readSmall(active).toString("utf8").trim();
  } catch {
    return "";
  }
  if (!RUN_ID.test(id) || !isPlainDir(join(runs, id))) return "";
  try {
    return loadState(join(runs, id)).phase === "done" ? "" : id;
  } catch {
    return id;
  }
}

// What keeps a run small enough for the request to be its approval.
function quickProblems(art) {
  const { spec, plan } = art.artifacts;
  const problems = [];
  if (plan.step_ids.length > QUICK_LIMITS.steps)
    problems.push(`more than ${QUICK_LIMITS.steps} plan steps`);
  if (spec.criteria.length > QUICK_LIMITS.criteria)
    problems.push(`more than ${QUICK_LIMITS.criteria} criteria`);
  if (spec.criteria.some((c) => !QUICK_EVIDENCE.includes(c.evidence)))
    problems.push(`evidence other than ${QUICK_EVIDENCE.join(" or ")}`);
  if (spec.scope_paths.length > QUICK_LIMITS.scope_paths)
    problems.push(`more than ${QUICK_LIMITS.scope_paths} scope paths`);
  if (spec.scope_paths.some((path) => /[*?[]/.test(path)))
    problems.push("a scope path that is a glob");
  if (spec.answers > 0) problems.push("clarifying answers");
  // Nobody approves a quick run's claim that its checks can run together.
  if (parallelChecks(art).length > 0) problems.push("parallel checks");
  if (workerSteps(art).length > 0) problems.push("worker steps");
  if (
    spec.consent.commit !== "no" ||
    spec.consent.branch_target !== "current" ||
    spec.consent.codex !== "reviewer"
  )
    problems.push("a consent other than commit no, current, reviewer");
  return problems;
}

async function cmdInit(root, args) {
  const slug = args._[1];
  if (!SLUG.test(slug ?? "")) throw invalid("init needs a kebab-case <slug>");
  const owner = defaultOwner(args);
  ensureBase(root);
  // One init at a time per worktree: the check for an unfinished run and the
  // write of `active` must not interleave with another session's.
  const release = acquireMutex(layout(root).base, ".b-agentic/mutex");
  try {
    const stamp = new Date().toISOString().slice(0, 10).replaceAll("-", "");
    const id = `${stamp}-${slug}`;
    const dir = join(layout(root).runs, id);
    if (isPlainDir(dir)) throw refuse(`run ${id} already exists`);
    // One unfinished run per worktree: a second one would share its tree and
    // its evidence. Only the user decides to leave a run behind.
    const unfinished = activeUnfinished(root);
    if (unfinished && !args.replace) {
      throw refuse(
        `run ${unfinished} is not finished; resume it, or pass --replace on the user's answer to leave it`,
      );
    }
    const baseline = await worktreeBaseline(root);
    baseline.dirty_paths = await dirtyBaseline(root);
    mkdirSync(dir, { mode: 0o700 });
    const state = freshState(id, root, baseline);
    writeAtomic(join(dir, "state.json"), `${JSON.stringify(state, null, 2)}\n`);
    takeLock(dir, owner, false);
    writeAtomic(layout(root).active, `${id}\n`);
    return { run: id, dir, phase: state.phase };
  } finally {
    release();
  }
}

async function cmdApprove(root, dir, state, args) {
  if (state.phase !== "clarify")
    throw refuse("approve is only valid in phase clarify");
  const commit = args.commit;
  if (!["yes", "no"].includes(commit))
    throw invalid("--commit yes|no is required");
  if (!BRANCH_TARGET.test(args["branch-target"] ?? "")) {
    throw invalid("--branch-target must be current or new:<type>/<kebab>");
  }
  if (!["standing", "reviewer"].includes(args.codex)) {
    throw invalid("--codex must be standing or reviewer");
  }
  const art = await artifactsOk(root, state);
  if (!art.artifacts.spec || !art.artifacts.plan)
    throw refuse("write the spec and the plan with b_run.py first");
  // The consent the user approved is the spec's; the flags only repeat it.
  const specConsent = art.artifacts.spec.consent;
  if (
    specConsent.commit !== commit ||
    specConsent.branch_target !== args["branch-target"] ||
    specConsent.codex !== args.codex
  ) {
    throw refuse("approve flags differ from the consent recorded in spec.md");
  }
  // The size the user's approval covers is the spec's too.
  const size = args.size ?? "full";
  if (!SIZES.includes(size)) throw invalid("--size must be quick or full");
  if (size !== art.artifacts.spec.size)
    throw refuse("approve --size differs from the size recorded in spec.md");
  if (size === "quick") {
    const problems = quickProblems(art);
    if (state.review.trigger !== "" || state.review.round > 0)
      problems.push("a review trigger this run already met");
    if (problems.length > 0) {
      throw refuse(
        `this needs a full run with an approval round: ${problems.join("; ")}`,
      );
    }
  }
  // A commit must contain the run's work and nothing else, so a run that may
  // commit starts clean. Without commit consent the changes already in the
  // tree stay the user's: the run records and leaves them (ADR-012).
  const baseline = await worktreeBaseline(root);
  if (baseline.dirty && commit === "yes") {
    throw refuse(
      "the working tree has changes; commit or stash them before a run that may commit, or approve with commit no",
    );
  }
  const ids = art.artifacts.spec.criteria.map((c) => c.id);
  state.size = size;
  state.spec.sha256 = art.hashes.spec;
  state.spec.plan_sha256 = art.hashes.plan;
  state.spec.approved_at = now();
  state.consent = {
    commit: commit === "yes",
    branch_target: args["branch-target"],
    codex: args.codex,
    push_pr: false,
  };
  // A new approval is a new plan: none of its steps is applied yet.
  state.steps = {};
  state.step_base = null;
  state.ac = Object.fromEntries(
    ids.map((id) => [id, { status: "pending", fingerprint: "" }]),
  );
  // `dirty` stays what it was when the run started: a re-approval must not
  // turn the run's own edits into changes that were there before it.
  state.baseline = {
    head: baseline.head,
    status_digest: baseline.status_digest,
    dirty: state.baseline.dirty,
  };
  state.phase = "approved";
  saveState(dir, state, "approve", { spec: state.spec.sha256 });
  return { phase: state.phase, ac: ids, spec_sha256: state.spec.sha256 };
}

async function cmdAdvance(root, dir, state, args) {
  const target = args._[1];
  if (!PHASES.includes(target)) throw invalid("unknown phase");
  if (target === "blocked") {
    if (state.phase === "done")
      throw refuse("a finished run cannot be blocked");
    block(
      state,
      text(args.reason, "--reason"),
      text(args.needs ?? "user decision", "--needs"),
    );
    saveState(dir, state, "advance");
    return { phase: state.phase };
  }
  if (!NEXT[state.phase].includes(target)) {
    throw refuse(`cannot move from ${state.phase} to ${target}`);
  }
  let art = null;
  if (state.phase !== "clarify") {
    requireSpecUnchanged(dir, state);
    art = await artifactsOk(root, state);
    // The size the user approved is the spec's: an edited state cannot turn a
    // quick run into a full one.
    if (!sizeMatches(state, art)) throw refuse(SIZE_DRIFT);
  }
  // A quick run was approved by the request alone, which cannot cover a change
  // that needs review: it stops for the approval round of a full run. The
  // trigger is recorded as the run's review obligation, so no later step can
  // record a low-risk exception instead.
  if (target === "review" && state.size === "quick") {
    const trigger = text(args.trigger, "--trigger");
    state.review.trigger = trigger;
    state.review.required = true;
    block(state, "a quick run met a review trigger", "full-run approval");
    saveState(dir, state, "advance", { trigger });
    return { phase: state.phase, blocked: state.blocked };
  }
  // A run without commit consent ends at QA; one with it ends through commit.
  const finishing = target === "done" && state.phase === "qa";
  if (finishing && state.consent.commit) {
    throw refuse("a run with commit consent finishes through commit");
  }
  // Every move toward review, QA, a commit, or the end re-checks the scope: the
  // tree can change between phases.
  const evidenced = ["review", "qa", "commit"].includes(target) || finishing;
  if (evidenced) await scopeOk(root, state);
  const fingerprint = evidenced ? await currentFingerprint(state) : "";
  if (target === "review") {
    if (!checksPass(state, art.artifacts.plan))
      throw refuse(checksOwed(state, art.artifacts.plan));
    if (state.candidate.fingerprint !== fingerprint) {
      throw refuse("candidate changed since the checks; record fresh checks");
    }
    // The trigger is what makes the review required; the handoff carries it.
    state.review.trigger = text(args.trigger, "--trigger");
    state.review.required = true;
  }
  if (target === "qa") {
    if (
      state.review.fingerprint !== fingerprint ||
      !reviewCovers(state, fingerprint)
    ) {
      throw refuse(
        "no review verdict or recorded low-risk exception for the current candidate",
      );
    }
    if (!checksPass(state, art.artifacts.plan))
      throw refuse(checksOwed(state, art.artifacts.plan));
  }
  if (target === "qa") state.qa.artifact_rev = art.revs.qa ?? 0;
  if (target === "fix") {
    const reviewFix =
      state.phase === "review" && state.review.verdict === "NEEDS FIXES";
    const qaFix = state.phase === "qa" && state.qa.verdict === "QA FAIL";
    if (!reviewFix && !qaFix)
      throw refuse("fix needs a NEEDS FIXES or QA FAIL result");
  }
  if (target === "commit" || target === "done") {
    if (!consentMatches(state, art)) throw refuse(CONSENT_DRIFT);
  }
  if (target === "commit") {
    if (
      state.consent.commit !== true ||
      art.artifacts.spec.consent.commit !== "yes"
    )
      throw refuse("commit consent was not recorded in the approved spec");
  }
  // The same evidence ends a run whether or not it may commit.
  if (target === "commit" || finishing) {
    if (
      state.qa.verdict !== "QA PASS" ||
      state.qa.fingerprint !== fingerprint
    ) {
      throw refuse("no QA PASS for the current candidate");
    }
    if (art.artifacts.qa?.verdict !== "QA PASS") {
      throw refuse("qa.md does not record a QA PASS");
    }
    if (!reviewCovers(state, fingerprint)) {
      throw refuse(
        "no review verdict or low-risk exception for the current candidate",
      );
    }
    const open = acOpen(state, fingerprint);
    if (open.length > 0) {
      throw refuse(`criteria without a current pass: ${open.join(", ")}`);
    }
  }
  if (target === "commit") {
    const head = await gitOr(root, ["rev-parse", "HEAD"]);
    if (!head) throw refuse("the repository has no commit to build on");
    state.commit_plan = await captureCommitPlan(root, state, fingerprint, head);
  }
  if (target === "done" && !finishing) {
    const plan = state.commit_plan;
    if (!plan || state.commits.length === 0)
      throw refuse("no commit recorded for the approved candidate");
    const head = await gitOr(root, ["rev-parse", "HEAD"]);
    if (!state.commits.includes(head))
      throw refuse("HEAD is not a recorded commit");
    for (const sha of state.commits) {
      if (!(await isAncestor(root, plan.base, sha)) || sha === plan.base) {
        throw refuse(`recorded commit ${sha} does not build on the run's base`);
      }
    }
    if (
      !branchAllowed(
        state,
        await gitOr(root, ["rev-parse", "--abbrev-ref", "HEAD"]),
      )
    ) {
      throw refuse("commits are not on the approved branch");
    }
    if ((await gitOr(root, ["rev-parse", "HEAD^{tree}"])) !== plan.tree) {
      throw refuse("the commits do not contain the approved candidate");
    }
    if (
      (await worktreeTree(root, state.candidate.include_ignored)) !== plan.tree
    ) {
      throw refuse("the working tree differs from the approved candidate");
    }
  }
  // Implementation is finished only when every plan step is recorded; a fix
  // round corrects findings and owes no step.
  if (target === "verify" && state.phase === "implement") {
    const owed = missingSteps(state, art.artifacts.plan);
    if (owed.length > 0)
      throw refuse(`plan steps not recorded: ${owed.join(", ")}`);
  }
  // Entering implement fixes where the first step starts.
  if (target === "implement") {
    state.attempts.step = 0;
    state.step_base = await newStepBase(root, state);
  }
  // Entering verify starts a new evidence round for a new candidate.
  if (target === "verify") voidEvidence(state);
  if (["review", "qa"].includes(target) && state.phase === "verify")
    state.attempts.verify = 0;
  state.phase = target;
  saveState(dir, state, "advance", {
    trigger: target === "review" ? state.review.trigger : "",
    fingerprint,
  });
  return { phase: state.phase };
}

async function cmdUnblock(root, dir, state, args) {
  if (state.phase !== "blocked") throw refuse("run is not blocked");
  const target = args._[1];
  if (!["clarify", "implement", "fix", "verify"].includes(target)) {
    throw invalid("unblock target must be clarify, implement, fix, or verify");
  }
  const reason = text(args.reason, "--reason");
  // A quick run that met a review trigger has outgrown the request that
  // approved it: the only way on is a new approval, as a full run.
  const outgrown = state.size === "quick" && state.review.trigger !== "";
  if (outgrown && target !== "clarify") {
    throw refuse(
      "a quick run that met a review trigger continues only through unblock clarify and a full-run approval",
    );
  }
  if (target === "clarify") {
    state.spec = {
      path: "spec.md",
      sha256: "",
      plan_sha256: "",
      approved_at: "",
    };
    state.ac = {};
    // A review trigger the run has met stays its obligation for good: no later
    // approval, quick or full, drops it, however many times the run returns to
    // clarify. The round count stays too, so finding ids remain unique.
  } else {
    requireSpecUnchanged(dir, state);
  }
  // Going back to implement or clarify redoes the plan; fix and verify keep
  // the record of the steps already applied.
  if (target === "clarify" || target === "implement") state.steps = {};
  voidEvidence(state);
  // Commits made under the old plan stay as an audit record; the next plan
  // starts from the current HEAD and validates only its own commits.
  state.prior_commits.push(
    ...state.commits.filter((sha) => !state.prior_commits.includes(sha)),
  );
  state.commits = [];
  state.attempts = { verify: 0, review_needs_fixes: 0, qa_fail: 0, step: 0 };
  state.blocked = { reason: "", needs: "", from: "" };
  state.phase = target;
  // The steps start again from the tree as it is now; only implement has steps.
  state.step_base =
    target === "implement" ? await newStepBase(root, state) : null;
  saveState(dir, state, "unblock", { reason });
  return { phase: state.phase };
}

// `capture` is how a step's tree is captured; the probes replace it to change
// the repository at exactly that point.
async function cmdRecord(
  root,
  dir,
  state,
  args,
  { capture = captureStep } = {},
) {
  const kind = args._[1];
  requireSpecUnchanged(dir, state);
  const art = await artifactsOk(root, state);
  if (!sizeMatches(state, art)) throw refuse(SIZE_DRIFT);
  // qa.md must have been written during this QA phase and must say what is recorded.
  const freshQa = () => {
    if (!art.artifacts.qa || (art.revs.qa ?? 0) <= state.qa.artifact_rev) {
      throw refuse("write qa.md with b_run.py in this QA phase first");
    }
    return art.artifacts.qa;
  };
  if (kind === "check") {
    if (state.phase !== "verify")
      throw refuse("checks are recorded in phase verify");
    const cmd = text(args.cmd, "--cmd", MAX_CMD);
    if (!art.artifacts.plan.checks.includes(cmd)) {
      throw refuse("that command is not one of the approved plan checks");
    }
    const exit = Number(args.exit);
    if (!Number.isInteger(exit) || exit < 0 || exit > 255)
      throw invalid("--exit must be 0-255");
    // A check that ran beside others says which candidate it started on: its
    // result counts only while that is still the candidate.
    const from = args.from;
    if (from !== undefined && !FINGERPRINT.test(from))
      throw invalid("--from must be a candidate fingerprint");
    if (from === undefined && parallelChecks(art).includes(cmd)) {
      throw refuse(
        "a check that may run together is recorded with --from <the fingerprint it started on>",
      );
    }
    if (args["include-ignored"]?.length) {
      const included = args["include-ignored"].map((p) => {
        const rel = String(p).replaceAll("\\", "/");
        if (
          !rel ||
          rel.startsWith("/") ||
          rel.split("/").includes("..") ||
          isProtected(rel)
        ) {
          throw refuse(`--include-ignored path not allowed: ${rel}`);
        }
        return rel;
      });
      // A different set is a different candidate, so `--from` could not match.
      if (
        from !== undefined &&
        JSON.stringify(included) !==
          JSON.stringify(state.candidate.include_ignored)
      ) {
        throw invalid(
          "--from cannot be combined with a changed --include-ignored set",
        );
      }
      state.candidate.include_ignored = included;
    }
    const fingerprint = await currentFingerprint(state);
    if (state.candidate.fingerprint !== fingerprint)
      state.candidate.checks = [];
    state.candidate.fingerprint = fingerprint;
    if (from !== undefined && from !== fingerprint) {
      // The result belongs to no candidate: nothing is recorded, and the lost
      // round counts like a failed check so the retries stay bounded.
      state.attempts.verify += 1;
      if (state.attempts.verify >= MAX_ROUNDS) {
        block(state, `${MAX_ROUNDS} failed verify attempts`, "user decision");
      }
      saveState(dir, state, "record check", {
        cmd,
        fingerprint,
        reason: CANDIDATE_MOVED,
      });
      return {
        phase: state.phase,
        attempts: state.attempts.verify,
        recorded: false,
        reason: CANDIDATE_MOVED,
      };
    }
    // Latest result per command: a successful retry supersedes a failure, while
    // `attempts.verify` keeps counting failures.
    state.candidate.checks = state.candidate.checks.filter(
      (check) => check.cmd !== cmd,
    );
    state.candidate.checks.push({ cmd, exit });
    if (exit !== 0) {
      state.attempts.verify += 1;
      if (state.attempts.verify >= MAX_ROUNDS) {
        block(state, `${MAX_ROUNDS} failed verify attempts`, "user decision");
      }
    }
    saveState(dir, state, "record check", { cmd, exit, fingerprint });
    return { phase: state.phase, attempts: state.attempts.verify };
  }
  if (kind === "review") {
    const fingerprint = await currentFingerprint(state);
    if (args["low-risk"] !== undefined) {
      if (state.phase !== "verify")
        throw refuse("a low-risk exception is recorded in phase verify");
      // Once a review was triggered or held, a correction goes back to review.
      if (
        state.review.trigger !== "" ||
        state.review.round > 0 ||
        state.attempts.review_needs_fixes > 0
      ) {
        throw refuse(
          "a review was already triggered or held for this run; record a fresh review verdict",
        );
      }
      if (
        !checksPass(state, art.artifacts.plan) ||
        state.candidate.fingerprint !== fingerprint
      ) {
        throw refuse(
          `record passing checks for the current candidate first (${checksOwed(state, art.artifacts.plan)})`,
        );
      }
      state.review.required = false;
      state.review.low_risk_exception = text(args["low-risk"], "--low-risk");
      state.review.verdict = "";
      state.review.fingerprint = fingerprint;
    } else {
      if (state.phase !== "review")
        throw refuse("a review verdict is recorded in phase review");
      const verdict = args.verdict;
      if (!REVIEW_VERDICTS.includes(verdict))
        throw invalid("unknown review verdict");
      // A verdict binds to the current candidate, which must have fresh passing checks.
      if (
        !checksPass(state, art.artifacts.plan) ||
        state.candidate.fingerprint !== fingerprint
      ) {
        throw refuse(
          `record passing checks for the current candidate first (${checksOwed(state, art.artifacts.plan)})`,
        );
      }
      // The findings are written before the verdict that depends on them, so a
      // session lost after this step can still read what the round found.
      const round = state.review.round + 1;
      const found = (art.artifacts.followups?.items ?? []).filter((item) =>
        item.id.startsWith(`R${round}-`),
      );
      if (
        verdict === "NEEDS FIXES" &&
        !found.some((item) => item.kind === "blocker")
      ) {
        throw refuse(
          `write this round's blockers with b_run.py write followups first (ids R${round}-<n>, kind blocker)`,
        );
      }
      if (verdict === "READY WITH FOLLOW-UPS" && found.length === 0) {
        throw refuse(
          `write this round's follow-ups with b_run.py write followups first (ids R${round}-<n>)`,
        );
      }
      state.review.required = true;
      state.review.trigger = args.trigger
        ? text(args.trigger, "--trigger")
        : state.review.trigger;
      state.review.low_risk_exception = "";
      state.review.round += 1;
      state.review.verdict = verdict;
      state.review.fingerprint = fingerprint;
      if (verdict === "NEEDS FIXES") {
        state.attempts.review_needs_fixes += 1;
        if (state.attempts.review_needs_fixes >= MAX_ROUNDS) {
          block(
            state,
            `${MAX_ROUNDS} consecutive NEEDS FIXES rounds`,
            "user decision",
          );
        }
      } else {
        state.attempts.review_needs_fixes = 0;
      }
    }
    saveState(
      dir,
      state,
      "record review",
      state.review.verdict
        ? {
            verdict: state.review.verdict,
            round: state.review.round,
            trigger: state.review.trigger,
            fingerprint,
          }
        : { reason: state.review.low_risk_exception, fingerprint },
    );
    return {
      phase: state.phase,
      review: state.review.verdict || "low-risk exception",
    };
  }
  if (kind === "qa") {
    if (state.phase !== "qa")
      throw refuse("a QA verdict is recorded in phase qa");
    const verdict = args.verdict;
    if (!QA_VERDICTS.includes(verdict)) throw invalid("unknown QA verdict");
    if (freshQa().verdict !== verdict) {
      throw refuse("the verdict differs from qa.md");
    }
    state.qa.round += 1;
    state.qa.verdict = verdict;
    state.qa.fingerprint = await currentFingerprint(state);
    if (verdict === "QA FAIL") {
      state.attempts.qa_fail += 1;
      if (state.attempts.qa_fail >= MAX_ROUNDS) {
        block(
          state,
          `${MAX_ROUNDS} consecutive QA FAIL rounds`,
          "user decision",
        );
      }
    } else if (verdict === "QA PASS") {
      state.attempts.qa_fail = 0;
    } else {
      block(state, "QA BLOCKED", "user decision");
    }
    saveState(dir, state, "record qa", {
      verdict,
      round: state.qa.round,
      fingerprint: state.qa.fingerprint,
    });
    return { phase: state.phase, qa: verdict };
  }
  if (kind === "ac") {
    const [, , id, status] = args._;
    if (!AC_ID.test(id ?? "") || !state.ac[id]) throw invalid("unknown AC id");
    if (!AC_STATUSES.includes(status) || status === "pending")
      throw invalid("status must be pass|fail|gap|waived");
    if (state.phase !== "qa") {
      throw refuse("criteria are recorded in phase qa");
    }
    const row = freshQa().rows.find((r) => r.ac === id);
    if (!row || row.result !== status) {
      throw refuse(`qa.md records ${row?.result ?? "no row"} for ${id}`);
    }
    state.ac[id] = { status, fingerprint: await currentFingerprint(state) };
    saveState(dir, state, "record ac", {
      ac: id,
      status,
      fingerprint: state.ac[id].fingerprint,
    });
    return { ac: id, status };
  }
  if (kind === "commit") {
    const sha = args._[2];
    if (state.phase !== "commit")
      throw refuse("commits are recorded in phase commit");
    if (!consentMatches(state, art)) throw refuse(CONSENT_DRIFT);
    if (!SHA.test(sha ?? "")) throw invalid("bad commit SHA");
    if ((await gitOr(root, ["cat-file", "-t", sha])) !== "commit") {
      throw refuse(`${sha} is not a commit in this repository`);
    }
    const full = await gitOr(root, ["rev-parse", sha]);
    const plan = state.commit_plan;
    if (!plan) throw refuse("no commit plan recorded");
    if (full === plan.base || !(await isAncestor(root, plan.base, full))) {
      throw refuse("that commit does not build on the run's base");
    }
    if (!(await isAncestor(root, full, "HEAD"))) {
      throw refuse("that commit is not on the checked-out branch");
    }
    const branch = await gitOr(root, ["rev-parse", "--abbrev-ref", "HEAD"]);
    if (!branchAllowed(state, branch)) {
      throw refuse(`commits belong on the approved branch, not ${branch}`);
    }
    if (!state.commits.includes(full)) state.commits.push(full);
    saveState(dir, state, "record commit", { sha: full });
    return { commits: state.commits };
  }
  if (kind === "step") {
    const id = args._[2];
    if (state.phase !== "implement")
      throw refuse("plan steps are recorded in phase implement");
    const step = art.artifacts.plan.steps.find((s) => s.id === id);
    if (!step) throw invalid("unknown plan step");
    // Who applied a step matters only for the steps the approved plan hands to
    // a worker. Every refusal here comes before any write, so a wrong `--by`
    // never counts as a refused step.
    const worker = workerSteps(art).includes(id);
    const by = args.by;
    if (by !== undefined && !["worker", "main"].includes(by))
      throw invalid("--by must be worker or main");
    if (worker && by === undefined)
      throw invalid(
        `${id} is a worker step: record it with --by worker, or --by main when the main session applied it`,
      );
    if (!worker && by !== undefined)
      throw refuse(`${id} is not listed in the plan's worker_steps`);
    if (worker && state.steps[id])
      throw refuse(
        `${id} is already recorded; a worker step is recorded once, by the main session after its report`,
      );
    if (by === "worker" && !state.step_base)
      throw refuse(
        `${id} has no step base for the step gate to check: apply it in the main session and record --by main`,
      );
    const applier = worker ? { by } : {};
    const owed = step.depends_on.filter((dep) => !state.steps[dep]);
    if (owed.length > 0) {
      throw refuse(
        `record the steps ${id} depends on first: ${owed.join(", ")}`,
      );
    }
    const base = state.step_base;
    if (!base) {
      // No base (a run from before the step gate, or one that entered
      // implement with an incomplete snapshot): recorded unchecked, as before.
      const fingerprint = await currentFingerprint(state);
      state.steps[id] = { status: "done", fingerprint };
      saveState(dir, state, "record step", {
        step: id,
        fingerprint,
        ...applier,
      });
      return { step: id, owed: missingSteps(state, art.artifacts.plan) };
    }
    // The step ran between two writes of this helper: anything else that wrote
    // the run state or moved HEAD in between is not a plan step, and the run
    // stops for the user.
    const notAStep = (reason) => {
      block(state, reason, "user decision");
      saveState(dir, state, "record step", { step: id, ...applier });
      return {
        ok: false,
        recorded: false,
        step: id,
        phase: state.phase,
        blocked: state.blocked,
      };
    };
    if (state.rev !== base.rev) return notAStep(STATE_WRITTEN);
    // HEAD is compared as the capture saw it, not as it was before: a commit
    // made while the tree was being captured must not be adopted as the base.
    const captured = await capture(root, state);
    const { snapshot, head } = captured;
    if (head !== base.head) return notAStep(HEAD_MOVED);
    let { tree } = captured;
    let problem = "";
    let delta = null;
    if (!snapshot.complete) {
      // Only a likely-secret path is the step's doing; anything else that
      // leaves the snapshot incomplete is refused as it always was.
      if (snapshot.protected.length === 0) {
        throw refuse(
          "candidate snapshot is incomplete; resolve the uncovered paths first",
        );
      }
      problem = `${snapshot.protected.length} protected path(s) changed`;
    } else {
      delta = await stepDelta(root, state, base.tree, tree, id);
      if (delta.protected.length > 0) {
        problem = `${delta.protected.length} protected path(s) changed`;
        tree = "";
      } else if (delta.outside_scope.length > 0) {
        problem = `outside the approved scope: ${namedPaths(delta.outside_scope)}`;
      }
    }
    if (problem) {
      // Nothing is recorded and the base stays, so restoring the named paths
      // and recording again compares the same step. The refusals are counted:
      // the third in a row is a decision for the user.
      state.attempts.step += 1;
      state.step_base = { ...base, rev: state.rev + 1 };
      if (state.attempts.step >= MAX_ROUNDS) {
        block(
          state,
          `${MAX_ROUNDS} refused plan steps; last: ${problem}`,
          "user decision",
        );
      }
      saveState(dir, state, "record step", {
        step: id,
        reason: problem,
        tree,
        ...applier,
      });
      return {
        ok: false,
        recorded: false,
        step: id,
        reason: problem,
        tree: tree || undefined,
        // What to restore the named paths from before recording again.
        base: base.tree,
        attempts: state.attempts.step,
        phase: state.phase,
      };
    }
    // Once more just before the write: the comparison above took time.
    if ((await currentHead(root)) !== base.head) return notAStep(HEAD_MOVED);
    // The tree as it was when the step was applied: the step's own evidence.
    const fingerprint = snapshot.fingerprint;
    state.steps[id] = { status: "done", fingerprint };
    state.attempts.step = 0;
    state.step_base = { tree, fingerprint, head, rev: state.rev + 1 };
    saveState(dir, state, "record step", {
      step: id,
      fingerprint,
      tree,
      paths: delta.changed,
      outside: delta.outside_step,
      ...applier,
    });
    return { step: id, owed: missingSteps(state, art.artifacts.plan) };
  }
  throw invalid("record needs check|review|qa|ac|commit|step");
}

async function cmdCheck(root, dir, state, args) {
  const owner = defaultOwner(args);
  const problems = [];
  const actions = [];
  const held = readLock(dir);
  if (held && held.owner !== owner && !args.takeover) {
    return {
      ok: false,
      phase: state.phase,
      problems: [`locked by another session (${held.owner})`],
      actions: ["resume with --takeover only on the user's explicit request"],
    };
  }
  if (state.phase === "done")
    return { ok: true, phase: "done", problems, actions, next: [] };
  const baseline = await worktreeBaseline(root);
  let changed = false;
  let why = "";
  let art = null;
  const blockedFor = (s) =>
    s.phase === "blocked" ? `${s.blocked.reason}\n${s.blocked.needs}` : null;
  const wasBlockedFor = blockedFor(state);
  let artifactProblem = "";
  let fingerprint = "";
  // A branch the run was approved to create is not a branch change, but it is
  // adopted only after every other check below has passed: a refused check
  // must never persist branch authority (spec hash, artifacts, and the state's
  // consent against the spec's all come first).
  const adoptable =
    state.repo_root === root &&
    state.branch !== baseline.branch &&
    Boolean(state.commit_plan) &&
    state.consent.branch_target !== "current" &&
    branchAllowed(state, baseline.branch);
  if (
    state.repo_root !== root ||
    (state.branch !== baseline.branch && !adoptable)
  ) {
    problems.push("repository root or branch differs from the run");
    block(state, "repository root or branch changed", "user decision");
    changed = true;
  } else if (
    state.phase !== "clarify" &&
    (specHash(dir) !== state.spec.sha256 ||
      (state.spec.plan_sha256 && planHash(dir) !== state.spec.plan_sha256))
  ) {
    problems.push("spec.md or plan.md changed after approval");
    block(state, "spec or plan changed after approval", "re-approval");
    changed = true;
  } else if (
    state.phase !== "clarify" &&
    (artifactProblem = await artifactsOk(root, state).then(
      (valid) => {
        art = valid;
        if (!consentMatches(state, valid)) return CONSENT_DRIFT;
        return sizeMatches(state, valid) ? "" : SIZE_DRIFT;
      },
      (error) => error.message,
    ))
  ) {
    const drift = [CONSENT_DRIFT, SIZE_DRIFT].includes(artifactProblem);
    const problem = drift
      ? artifactProblem
      : "run artifacts changed outside b_run.py";
    problems.push(problem);
    block(state, problem, drift ? "re-approval" : "user decision");
    changed = true;
  } else {
    if (adoptable) {
      state.branch = baseline.branch;
      why = "adopted the approved branch";
      changed = true;
    }
    let headMoved = false;
    if (baseline.head !== state.baseline.head) {
      const known = [];
      for (const sha of [...state.commits, ...state.prior_commits])
        known.push(await gitOr(root, ["rev-parse", sha]));
      if (known.includes(baseline.head)) {
        state.baseline.head = baseline.head;
        headMoved = true;
        why ||= "HEAD moved to a recorded commit";
        changed = true;
      } else if (state.phase === "commit") {
        headMoved = true;
        actions.push(
          "HEAD moved during commit: inspect git log, then record each commit SHA",
        );
      } else {
        problems.push("HEAD moved outside the recorded commits");
        block(state, "HEAD moved outside the run", "user decision");
        changed = true;
      }
    }
    const plan = state.commit_plan;
    const commitsBegan =
      state.phase === "commit" &&
      plan &&
      (headMoved || baseline.head !== plan.base);
    if (commitsBegan) {
      // Commits do not change the working tree, so it must still equal the
      // approved tree however many commits were made. A different tree after
      // commits began cannot be voided cleanly: the user decides. A tree that
      // cannot be built (a protected path appeared) is a different tree too.
      if (
        (await worktreeTree(root, state.candidate.include_ignored).catch(
          () => "",
        )) !== plan.tree
      ) {
        problems.push("the working tree changed after commits began");
        block(state, "candidate changed after commits began", "user decision");
        changed = true;
      }
    } else if (["verify", "review", "qa", "commit"].includes(state.phase)) {
      // Evidence-bearing phases: any recorded result for another candidate is
      // void. `implement` and `fix` edit the tree on purpose.
      fingerprint = await currentFingerprint(state);
      const recorded = [
        state.candidate.fingerprint,
        state.review.fingerprint,
        state.qa.fingerprint,
        ...Object.values(state.ac).map((entry) => entry.fingerprint),
        plan?.fingerprint,
      ].filter(Boolean);
      // Past verify every plan check must have passed: a run recorded before
      // that rule, or an edited state, goes back for the missing ones rather
      // than being pointed at a step its guard would refuse.
      const incomplete =
        state.phase !== "verify" && !checksPass(state, art.artifacts.plan);
      if (
        recorded.some((f) => f !== fingerprint) ||
        (["review", "qa", "commit"].includes(state.phase) &&
          recorded.length === 0)
      ) {
        voidEvidence(state);
        state.phase = "verify";
        actions.push(
          "evidence is void for the changed candidate: run fresh checks",
        );
        why = "candidate changed: evidence void";
        changed = true;
      } else if (incomplete) {
        voidEvidence(state);
        state.phase = "verify";
        actions.push(
          "a plan check has no passing result for the candidate: run every plan check",
        );
        why = "plan checks incomplete: evidence void";
        changed = true;
      }
    }
  }
  // Re-checking a run that is still blocked for the same reason writes nothing,
  // so repeated checks cannot push the useful history out.
  const stillBlocked =
    wasBlockedFor !== null && wasBlockedFor === blockedFor(state) && !why;
  if (changed && !stillBlocked) saveState(dir, state, "check", { reason: why });
  if (state.phase === "clarify") {
    art = await artifactsOk(root, state).catch(() => null);
  }
  return {
    ok: state.phase !== "blocked",
    phase: state.phase,
    problems,
    actions,
    next: await nextSteps(root, state, art, fingerprint),
    blocked: state.phase === "blocked" ? state.blocked : undefined,
  };
}

const shellQuote = (value) => `'${value.replaceAll("'", `'\\''`)}'`;

// What the current phase still owes, derived from the state and the validated
// artifacts alone, so a session with no memory of the run can continue it. It
// only reads: every step it names is still checked by its own guard, and it
// grants no approval.
async function nextSteps(root, state, art, fingerprint = "") {
  const stateCmd = (rest) => `b-state.mjs ${rest}`;
  const runCmd = (rest) => `b_run.py ${rest}`;
  if (state.phase === "blocked") {
    const outgrown = state.size === "quick" && state.review.trigger !== "";
    return [
      `ask the user: ${state.blocked.reason} (needs: ${state.blocked.needs})`,
      stateCmd(
        outgrown
          ? "unblock clarify --reason R, then write the spec without size quick and run the approval round of a full run"
          : "unblock <clarify|implement|fix|verify> --reason R (a changed spec needs clarify and a new approval)",
      ),
    ];
  }
  if (!art) return ["the run artifacts could not be read: b_run.py validate"];
  const { spec, plan, qa, followups } = art.artifacts;
  if (state.phase === "clarify") {
    const steps = [];
    if (!spec)
      steps.push(`clarify with the user, then ${runCmd("write spec")}`);
    if (!plan) steps.push(runCmd("write plan"));
    const consent = spec?.consent;
    const quick = spec?.size === "quick";
    steps.push(
      `${
        quick
          ? "a quick run: the user's change request is its approval, so"
          : "run the approval round with the user (never skip it), then"
      } ${stateCmd(
        consent
          ? `approve --commit ${consent.commit} --branch-target ${consent.branch_target} --codex ${consent.codex}${quick ? " --size quick" : ""}`
          : "approve --commit yes|no --branch-target T --codex standing|reviewer",
      )}`,
    );
    return steps;
  }
  if (state.phase === "approved") return [stateCmd("advance implement")];
  if (state.phase === "implement") {
    const owed = missingSteps(state, plan);
    const handed = workerSteps(art);
    return [
      ...(owed.length > 0 ? [runCmd("handoff implement")] : []),
      ...owed.map((id) =>
        handed.includes(id)
          ? `hand ${id} to one b-worker with ${runCmd(`handoff implement --step ${id}`)} and wait for its report (or apply it yourself), then ${stateCmd(`record step ${id} --by worker`)} (--by main when the main session applied it)`
          : `apply ${id} inside the approved scope, then ${stateCmd(`record step ${id}`)}`,
      ),
      stateCmd("advance verify"),
    ];
  }
  if (state.phase === "verify") {
    const missing = missingChecks(state, plan);
    if (missing.length > 0) {
      const listed = parallelChecks(art);
      const together = missing.filter((cmd) => listed.includes(cmd));
      const started =
        together.length > 0
          ? fingerprint || (await currentFingerprint(state))
          : "";
      return [
        ...(started
          ? [
              `these checks may run at the same time: ${together
                .map((cmd) => `\`${cmd}\``)
                .join(
                  ", ",
                )}; then for each ${stateCmd(`record check --cmd '<the command>' --exit <its exit code> --from ${started}`)}`,
            ]
          : []),
        ...missing
          .filter((cmd) => !listed.includes(cmd))
          .map(
            (cmd) =>
              `run \`${cmd}\`, then ${stateCmd(`record check --cmd ${shellQuote(cmd)} --exit <its exit code>`)}`,
          ),
      ];
    }
    if (state.review.low_risk_exception) return [stateCmd("advance qa")];
    if (
      state.review.trigger !== "" ||
      state.review.round > 0 ||
      state.attempts.review_needs_fixes > 0
    ) {
      return [
        stateCmd(
          `advance review --trigger ${state.review.trigger ? shellQuote(state.review.trigger) : "<kernel review trigger>"}`,
        ),
      ];
    }
    return [
      `classify risk per the kernel: with a trigger ${stateCmd("advance review --trigger T")}${
        state.size === "quick"
          ? " (it blocks a quick run for a full-run approval)"
          : ""
      }; without one ${stateCmd("record review --low-risk REASON")} then ${stateCmd("advance qa")}`,
    ];
  }
  if (state.phase === "review") {
    if (state.review.verdict === "NEEDS FIXES")
      return [stateCmd("advance fix")];
    if (state.review.verdict) return [stateCmd("advance qa")];
    const round = state.review.round + 1;
    return [
      runCmd("handoff review --out <scratch file outside the repo>"),
      `run b-review, round ${round}`,
      `${runCmd("write followups")} with this round's findings as R${round}-<n> (each blocker: kind blocker, disposition open)`,
      stateCmd('record review --verdict "<verdict>"'),
    ];
  }
  if (state.phase === "fix") {
    const steps = [];
    const open = (followups?.items ?? [])
      .filter((item) => item.kind === "blocker" && item.disposition === "open")
      .map((item) => item.id);
    const failed = Object.entries(state.ac)
      .filter(([, entry]) => ["fail", "gap"].includes(entry.status))
      .map(([id]) => id);
    if (state.qa.verdict === "QA FAIL") {
      steps.push(
        `correct the criteria QA failed, routed per b-qa: ${failed.join(", ") || "see qa.md"}`,
      );
    }
    if (open.length > 0) {
      steps.push(
        `fix the open blockers inside the approved scope, whole class each: ${open.join(", ")}`,
        `${runCmd("write followups")} with a disposition and reason for each, and a sweep line for every fixed blocker`,
      );
    }
    return [runCmd("handoff fix"), ...steps, stateCmd("advance verify")];
  }
  if (state.phase === "qa") {
    if (!qa || (art.revs.qa ?? 0) <= state.qa.artifact_rev) {
      return [
        runCmd("handoff qa"),
        "run b-qa against every AC-n",
        `${runCmd("write qa")} with one row per criterion`,
        stateCmd(
          "record ac AC-n <result> for each row, then record qa --verdict V",
        ),
      ];
    }
    const steps = qa.rows
      .filter((row) => state.ac[row.ac]?.status !== row.result)
      .map((row) => stateCmd(`record ac ${row.ac} ${row.result}`));
    if (state.qa.verdict !== qa.verdict) {
      steps.push(stateCmd(`record qa --verdict "${qa.verdict}"`));
    }
    if (steps.length > 0) return steps;
    if (qa.verdict === "QA FAIL") return [stateCmd("advance fix")];
    return state.consent.commit
      ? [stateCmd("advance commit")]
      : [
          stateCmd("advance done"),
          "report the QA-passed candidate; it is not committed, so offer /b-commit",
        ];
  }
  if (state.phase === "commit") {
    const head = await gitOr(root, ["rev-parse", "HEAD"]);
    if (state.commits.includes(head)) return [stateCmd("advance done")];
    return [
      runCmd("handoff commit"),
      `run b-commit for the whole candidate (branch target ${state.consent.branch_target}); the recorded consent is the commit request`,
      stateCmd("record commit <sha> for every commit"),
      stateCmd("advance done"),
    ];
  }
  return [];
}

// One command at a time per run: the whole read-check-write runs while a
// `mutex` file exists, so a takeover can never interleave with a write that
// passed the owner check earlier. The file appears atomically with its content
// (hard link of a finished temp file), only its owner removes it (checked by
// token), and it is never recovered automatically: a dead holder is reported
// and removed only by hand, so no recovery code can race a new holder.
function mutexHolder(path) {
  try {
    const holder = JSON.parse(readSmall(path).toString("utf8"));
    return Number.isInteger(holder?.pid) ? holder : null;
  } catch {
    return null;
  }
}

const pidAlive = (pid) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
};

function acquireMutex(dir, where = ".b-agentic/runs/<id>/mutex") {
  const path = join(dir, "mutex");
  const token = randomBytes(16).toString("hex");
  const temp = join(dir, `mutex.${process.pid}.${token}.tmp`);
  const fd = openSync(
    temp,
    constants.O_WRONLY |
      constants.O_CREAT |
      constants.O_EXCL |
      constants.O_NOFOLLOW,
    0o600,
  );
  try {
    writeSync(fd, `${JSON.stringify({ pid: process.pid, token })}\n`);
  } finally {
    closeSync(fd);
  }
  try {
    linkSync(temp, path);
  } catch (error) {
    if (error?.code !== "EEXIST") throw error;
    const holder = mutexHolder(path);
    throw refuse(
      holder && !pidAlive(holder.pid)
        ? `a b-state command (pid ${holder.pid}) died holding the mutex; if no other b-state command is running, delete ${where} by hand`
        : `another b-state command holds ${where}`,
    );
  } finally {
    rmSync(temp, { force: true });
  }
  const release = () => {
    if (mutexHolder(path)?.token === token) rmSync(path, { force: true });
  };
  for (const signal of ["SIGINT", "SIGTERM"]) {
    process.once(signal, () => {
      release();
      process.exit(130);
    });
  }
  return release;
}

// ---- entry ------------------------------------------------------------------

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
