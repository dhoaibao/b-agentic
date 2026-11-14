// Run store of the b-state CLI: file helpers, state validation, load and save, the run lock
// and the run mutex. Imports the core and git modules.
import { randomBytes } from "node:crypto";
import {
  closeSync,
  constants,
  fstatSync,
  linkSync,
  lstatSync,
  mkdirSync,
  openSync,
  readSync,
  renameSync,
  rmSync,
  writeSync,
} from "node:fs";
import { join } from "node:path";
import { isProtected } from "./b-candidate-snapshot.mjs";
import {
  AC_ID,
  AC_STATUSES,
  BRANCH_TARGET,
  CONTROL,
  DIRTY_DIGEST,
  FINGERPRINT,
  HISTORY_DETAIL,
  HISTORY_OPS,
  invalid,
  Invalid,
  MAX_DIRTY,
  MAX_HISTORY,
  MAX_STATE_BYTES,
  MAX_TEXT,
  now,
  OWNER,
  PHASES,
  QA_VERDICTS,
  refuse,
  Refused,
  REVIEW_VERDICTS,
  RUN_ID,
  SHA,
  SIZES,
  STATE_SCHEMA,
  STEP_ID,
  TREE_ID,
} from "./b-state-core.mjs";

export const isPlainDir = (path) => {
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

export function readSmall(path) {
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
export function writeAtomic(path, text) {
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

export function layout(root) {
  const base = join(root, ".b-agentic");
  return { base, runs: join(base, "runs"), active: join(base, "active") };
}

export function ensureBase(root) {
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

export async function resolveRun(root, args) {
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
      // `worktree` is a flag: the step's worker had its own worktree (ADR-016).
      const flag = key === "worktree" && value === true;
      if (!HISTORY_DETAIL.includes(key) || !(line || isInt(value) || flag))
        fail("history detail");
    }
  }
  return state;
}

export function loadState(dir) {
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
export function saveState(dir, state, op, detail = {}) {
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

export function freshState(runId, root, baseline) {
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

export function defaultOwner(args) {
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

export function readLock(dir) {
  try {
    const lock = JSON.parse(readSmall(join(dir, "lock")).toString("utf8"));
    return typeof lock?.owner === "string" ? lock : null;
  } catch {
    return null;
  }
}

export function takeLock(dir, owner, takeover) {
  const held = readLock(dir);
  if (held && held.owner !== owner && !takeover) {
    throw refuse(
      `run is locked by another session (${held.owner}); an explicit resume may use --takeover`,
    );
  }
  writeAtomic(join(dir, "lock"), `${JSON.stringify({ owner, at: now() })}\n`);
}

export function requireLock(dir, args) {
  const owner = defaultOwner(args);
  const held = readLock(dir);
  if (!held) throw refuse("run is not locked; run lock first");
  if (held.owner !== owner) {
    throw refuse(`run is locked by another session (${held.owner})`);
  }
  return owner;
}

// The run `active` names when it is not finished; an unreadable one counts.
export function activeUnfinished(root) {
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

export function acquireMutex(dir, where = ".b-agentic/runs/<id>/mutex") {
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
