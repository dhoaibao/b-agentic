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
// Usage: b-state.mjs <command> [args] [--run ID] [--owner NAME]
//   init <slug>                         create a run in phase clarify and lock it
//   show                                print the state
//   approve --commit yes|no --branch-target current|new:<type>/<kebab>
//           --codex standing|reviewer
//                                       hash spec.md, record consent and AC-n, phase approved
//   advance <phase> [--reason R --needs N]
//                                       move to a phase when its guard passes
//   unblock <phase> --reason R          leave `blocked` for clarify|implement|fix|verify
//   record check --cmd C --exit N [--include-ignored P]...
//   record review (--verdict V [--trigger T] | --low-risk REASON)
//   record qa --verdict V
//   record ac AC-n pass|fail|gap|waived
//   record commit SHA
//   check [--takeover]                  verify the state against git and void stale evidence
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
  readFileSync,
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
  qa: ["commit", "fix"],
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
const MAX_CMD = 300;
const MAX_TEXT = 300;
const MAX_STATE_BYTES = 1 << 20;

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
  };
}

// The tree object of the whole working tree (tracked and untracked, not ignored),
// built in a throwaway index seeded from the real one so tracked files that an
// ignore rule covers, and sparse entries, are kept; the real index is never
// touched. A finished run must have committed exactly this tree.
export async function worktreeTree(root, includeIgnored = []) {
  const dir = mkdtempSync(join(tmpdir(), "b-state-"));
  const env = { ...process.env, GIT_INDEX_FILE: join(dir, "index") };
  try {
    const real = await gitOr(root, ["rev-parse", "--git-path", "index"]);
    if (real) {
      try {
        copyFileSync(resolve(root, real), join(dir, "index"));
      } catch {
        // No index yet: an empty one is the correct seed.
      }
    }
    await git(root, ["add", "-A", "--", "."], env);
    // Artifacts the candidate names with --include-ignored are part of what was
    // reviewed and QA'd, so they belong to the approved tree too.
    if (includeIgnored.length > 0) {
      await git(root, ["add", "-f", "--", ...includeIgnored], env);
    }
    return (await git(root, ["write-tree"], env)).trim();
  } catch {
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
  for (const key of ["verify", "review_needs_fixes", "qa_fail"]) {
    if (!isInt(state.attempts[key])) fail(`attempts.${key}`);
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
  }
  return validate(state);
}

// `rev` is an optimistic check: a concurrent writer between our read and our
// rename makes this write refuse rather than silently drop its change.
function saveState(dir, state) {
  const current = loadState(dir);
  if (current.rev !== state.rev) {
    throw refuse("state changed during the operation; rerun");
  }
  state.rev += 1;
  state.updated_at = now();
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
    baseline: { head: baseline.head, status_digest: baseline.status_digest },
    spec: { path: "spec.md", sha256: "", plan_sha256: "", approved_at: "" },
    consent: {
      commit: false,
      branch_target: "current",
      codex: "reviewer",
      push_pr: false,
    },
    phase: "clarify",
    attempts: { verify: 0, review_needs_fixes: 0, qa_fail: 0 },
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
    updated_at: now(),
  };
}

// ---- lock -------------------------------------------------------------------

function defaultOwner(args) {
  const owner = args.owner ?? process.env.CLAUDE_CODE_SESSION_ID ?? "";
  if (!OWNER.test(owner)) {
    throw invalid(
      "pass --owner NAME (letters, digits, . _ : -) or set CLAUDE_CODE_SESSION_ID",
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

function checksPass(state) {
  return (
    state.candidate.checks.length > 0 &&
    state.candidate.checks.every((c) => c.exit === 0)
  );
}

function reviewCovers(state, fingerprint) {
  if (state.review.fingerprint !== fingerprint) return false;
  return (
    state.review.verdict === "READY FOR PR" ||
    state.review.verdict === "READY WITH FOLLOW-UPS" ||
    Boolean(state.review.low_risk_exception)
  );
}

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
    /[\u0000-\u001f\u007f]/.test(value)
  ) {
    throw invalid(`${name} must be one line of 1-${max} printable characters`);
  }
  return value.trim();
};

// ---- commands ---------------------------------------------------------------

async function cmdInit(root, args) {
  const slug = args._[1];
  if (!SLUG.test(slug ?? "")) throw invalid("init needs a kebab-case <slug>");
  const owner = defaultOwner(args);
  ensureBase(root);
  const stamp = new Date().toISOString().slice(0, 10).replaceAll("-", "");
  const id = `${stamp}-${slug}`;
  const dir = join(layout(root).runs, id);
  if (isPlainDir(dir)) throw refuse(`run ${id} already exists`);
  mkdirSync(dir, { mode: 0o700 });
  const state = freshState(id, root, await worktreeBaseline(root));
  writeAtomic(join(dir, "state.json"), `${JSON.stringify(state, null, 2)}\n`);
  takeLock(dir, owner, false);
  writeAtomic(layout(root).active, `${id}\n`);
  return { run: id, dir, phase: state.phase };
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
  const ids = art.artifacts.spec.criteria.map((c) => c.id);
  state.spec.sha256 = art.hashes.spec;
  state.spec.plan_sha256 = art.hashes.plan;
  state.spec.approved_at = now();
  state.consent = {
    commit: commit === "yes",
    branch_target: args["branch-target"],
    codex: args.codex,
    push_pr: false,
  };
  state.ac = Object.fromEntries(
    ids.map((id) => [id, { status: "pending", fingerprint: "" }]),
  );
  state.baseline = {
    head: (await worktreeBaseline(root)).head,
    status_digest: (await worktreeBaseline(root)).status_digest,
  };
  state.phase = "approved";
  saveState(dir, state);
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
    saveState(dir, state);
    return { phase: state.phase };
  }
  if (!NEXT[state.phase].includes(target)) {
    throw refuse(`cannot move from ${state.phase} to ${target}`);
  }
  let art = null;
  if (state.phase !== "clarify") {
    requireSpecUnchanged(dir, state);
    art = await artifactsOk(root, state);
  }
  // Every move toward review, QA, or a commit re-checks the scope: the tree can
  // change between phases.
  if (["review", "qa", "commit"].includes(target)) {
    await scopeOk(root, state);
  }
  const fingerprint = ["review", "qa", "commit"].includes(target)
    ? await currentFingerprint(state)
    : "";
  if (target === "review") {
    if (!checksPass(state))
      throw refuse("no passing checks recorded for the candidate");
    if (state.candidate.fingerprint !== fingerprint) {
      throw refuse("candidate changed since the checks; record fresh checks");
    }
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
    if (state.review.verdict === "" && !checksPass(state)) {
      throw refuse("low-risk exception needs passing checks");
    }
  }
  if (target === "qa") state.qa.artifact_rev = art.revs.qa ?? 0;
  if (target === "fix") {
    const reviewFix =
      state.phase === "review" && state.review.verdict === "NEEDS FIXES";
    const qaFix = state.phase === "qa" && state.qa.verdict === "QA FAIL";
    if (!reviewFix && !qaFix)
      throw refuse("fix needs a NEEDS FIXES or QA FAIL result");
  }
  if (target === "commit") {
    if (state.consent.commit !== true)
      throw refuse("commit consent was not recorded at approval");
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
    const head = await gitOr(root, ["rev-parse", "HEAD"]);
    if (!head) throw refuse("the repository has no commit to build on");
    state.commit_plan = await captureCommitPlan(root, state, fingerprint, head);
  }
  if (target === "done") {
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
  // Entering verify starts a new evidence round for a new candidate.
  if (target === "verify") voidEvidence(state);
  if (["review", "qa"].includes(target) && state.phase === "verify")
    state.attempts.verify = 0;
  state.phase = target;
  saveState(dir, state);
  return { phase: state.phase };
}

function cmdUnblock(dir, state, args) {
  if (state.phase !== "blocked") throw refuse("run is not blocked");
  const target = args._[1];
  if (!["clarify", "implement", "fix", "verify"].includes(target)) {
    throw invalid("unblock target must be clarify, implement, fix, or verify");
  }
  text(args.reason, "--reason");
  if (target === "clarify") {
    state.spec = {
      path: "spec.md",
      sha256: "",
      plan_sha256: "",
      approved_at: "",
    };
    state.ac = {};
  } else {
    requireSpecUnchanged(dir, state);
  }
  voidEvidence(state);
  // Commits made under the old plan stay as an audit record; the next plan
  // starts from the current HEAD and validates only its own commits.
  state.prior_commits.push(
    ...state.commits.filter((sha) => !state.prior_commits.includes(sha)),
  );
  state.commits = [];
  state.attempts = { verify: 0, review_needs_fixes: 0, qa_fail: 0 };
  state.blocked = { reason: "", needs: "", from: "" };
  state.phase = target;
  saveState(dir, state);
  return { phase: state.phase };
}

async function cmdRecord(root, dir, state, args) {
  const kind = args._[1];
  requireSpecUnchanged(dir, state);
  const art = await artifactsOk(root, state);
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
    if (args["include-ignored"]?.length) {
      state.candidate.include_ignored = args["include-ignored"].map((p) => {
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
    }
    const fingerprint = await currentFingerprint(state);
    if (state.candidate.fingerprint !== fingerprint)
      state.candidate.checks = [];
    state.candidate.fingerprint = fingerprint;
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
    saveState(dir, state);
    return { phase: state.phase, attempts: state.attempts.verify };
  }
  if (kind === "review") {
    const fingerprint = await currentFingerprint(state);
    if (args["low-risk"] !== undefined) {
      if (state.phase !== "verify")
        throw refuse("a low-risk exception is recorded in phase verify");
      if (!checksPass(state) || state.candidate.fingerprint !== fingerprint) {
        throw refuse("record passing checks for the current candidate first");
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
      if (!checksPass(state) || state.candidate.fingerprint !== fingerprint) {
        throw refuse("record passing checks for the current candidate first");
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
    saveState(dir, state);
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
    saveState(dir, state);
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
    saveState(dir, state);
    return { ac: id, status };
  }
  if (kind === "commit") {
    const sha = args._[2];
    if (state.phase !== "commit")
      throw refuse("commits are recorded in phase commit");
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
    saveState(dir, state);
    return { commits: state.commits };
  }
  throw invalid("record needs check|review|qa|ac|commit");
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
    return { ok: true, phase: "done", problems, actions };
  const baseline = await worktreeBaseline(root);
  let changed = false;
  // A branch the run was approved to create is not a branch change.
  if (
    state.repo_root === root &&
    state.branch !== baseline.branch &&
    state.commit_plan &&
    state.consent.branch_target !== "current" &&
    branchAllowed(state, baseline.branch)
  ) {
    state.branch = baseline.branch;
    changed = true;
  }
  if (state.repo_root !== root || state.branch !== baseline.branch) {
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
    (await artifactsOk(root, state).then(
      () => "",
      (error) => error.message,
    ))
  ) {
    problems.push("run artifacts changed outside b_run.py");
    block(state, "run artifacts changed outside b_run.py", "user decision");
    changed = true;
  } else {
    let headMoved = false;
    if (baseline.head !== state.baseline.head) {
      const known = [];
      for (const sha of [...state.commits, ...state.prior_commits])
        known.push(await gitOr(root, ["rev-parse", sha]));
      if (known.includes(baseline.head)) {
        state.baseline.head = baseline.head;
        headMoved = true;
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
      // commits began cannot be voided cleanly: the user decides.
      if (
        (await worktreeTree(root, state.candidate.include_ignored)) !==
        plan.tree
      ) {
        problems.push("the working tree changed after commits began");
        block(state, "candidate changed after commits began", "user decision");
        changed = true;
      }
    } else if (["verify", "review", "qa", "commit"].includes(state.phase)) {
      // Evidence-bearing phases: any recorded result for another candidate is
      // void. `implement` and `fix` edit the tree on purpose.
      const fingerprint = await currentFingerprint(state);
      const recorded = [
        state.candidate.fingerprint,
        state.review.fingerprint,
        state.qa.fingerprint,
        ...Object.values(state.ac).map((entry) => entry.fingerprint),
        plan?.fingerprint,
      ].filter(Boolean);
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
        changed = true;
      }
    }
  }
  if (changed) saveState(dir, state);
  return {
    ok: state.phase !== "blocked",
    phase: state.phase,
    problems,
    actions,
    blocked: state.phase === "blocked" ? state.blocked : undefined,
  };
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

function acquireMutex(dir) {
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
        ? `a b-state command (pid ${holder.pid}) died holding the run mutex; if no other b-state command is running, delete .b-agentic/runs/<id>/mutex by hand`
        : "another b-state command is running for this run",
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
  "verdict",
  "trigger",
  "low-risk",
]);
const BOOL_FLAGS = new Set(["takeover"]);

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

export async function run(argv, cwd = process.cwd()) {
  const args = parseArgs(argv);
  const command = args._[0];
  const root = await repoRoot(cwd);
  if (command === "init") return cmdInit(root, args);
  if (!command) throw invalid("missing command");
  const { dir } = await resolveRun(root, args);
  if (command === "show") return loadState(dir);
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
    if (command === "unblock") return cmdUnblock(dir, state, args);
    if (command === "record") return await cmdRecord(root, dir, state, args);
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
