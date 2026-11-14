// Evidence gates of the b-state CLI: the candidate fingerprint, spec and plan hashes, artifact
// and scope checks, the step base and delta, and the helpers that read checks, steps, review,
// QA and consent from the state. Imports the core, git and store modules.
import { execFile } from "node:child_process";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { computeSnapshot, isProtected } from "./b-candidate-snapshot.mjs";
import {
  CONTROL,
  QUICK_EVIDENCE,
  QUICK_LIMITS,
  refuse,
  sha256,
} from "./b-state-core.mjs";
import { gitOr, worktreeTree } from "./b-state-git.mjs";
import { readSmall } from "./b-state-store.mjs";

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

// `current` stays on the run's branch; `new:<name>` accepts <name> or the
// numbered variant b-commit appends when <name> already exists.
export function branchAllowed(state, branch) {
  const target = state.consent.branch_target;
  if (target === "current") return branch === state.branch;
  const name = target.slice("new:".length);
  return branch === name || new RegExp(`^${name}-\\d+$`).test(branch);
}

export async function currentFingerprint(state) {
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

export function specHash(dir) {
  try {
    return sha256(readSmall(join(dir, "spec.md")));
  } catch {
    return "";
  }
}

export function planHash(dir) {
  try {
    return sha256(readSmall(join(dir, "plan.md")));
  } catch {
    return "";
  }
}

export function requireSpecUnchanged(dir, state) {
  if (!state.spec.sha256) throw refuse("spec is not approved");
  if (specHash(dir) !== state.spec.sha256) {
    throw refuse("spec.md changed after approval; re-approval is required");
  }
  if (state.spec.plan_sha256 && planHash(dir) !== state.spec.plan_sha256) {
    throw refuse("plan.md changed after approval; re-approval is required");
  }
}

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
export async function artifactsOk(root, state) {
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

export async function scopeOk(root, state) {
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

export const STATE_WRITTEN = "run state was written outside the step";

export const HEAD_MOVED = "HEAD moved during the step";

// Where a plan step starts: the working tree as a tree id, its fingerprint,
// HEAD, and the state revision of the write that stores it. `record step`
// compares the tree after the step with this one, so what a step changed is
// checked when it is recorded rather than on the way to review.
//
// A run without a base records its steps unchecked, as before.
export async function newStepBase(root, state) {
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
export const currentHead = (root) =>
  gitOr(root, ["rev-parse", "--verify", "-q", "HEAD^{commit}"]);

// The paths that differ between two trees, classified by b_run.py against the
// approved scope and the step's own paths.
export async function stepDelta(root, state, base, tree, id) {
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
export const namedPaths = (paths) => {
  const safe = paths
    .filter((p) => !isProtected(p) && !CONTROL.test(p) && p.length <= 80)
    .slice(0, 3);
  const rest = paths.length - safe.length;
  if (safe.length === 0) return `${paths.length} path(s)`;
  return safe.join(", ") + (rest > 0 ? ` and ${rest} more` : "");
};

// The plan checks without a passing result for the recorded candidate.
export function missingChecks(state, plan) {
  return plan.checks.filter(
    (cmd) => !state.candidate.checks.some((c) => c.cmd === cmd && c.exit === 0),
  );
}

// Every approved plan check must have passed, not just the ones that were run.
export function checksPass(state, plan) {
  return plan.checks.length > 0 && missingChecks(state, plan).length === 0;
}

// The plan checks the approval allows to run at the same time.
export const parallelChecks = (art) =>
  art.artifacts.plan?.parallel_checks ?? [];

// The plan steps the approval hands to a worker (ADR-015).
export const workerSteps = (art) => art.artifacts.plan?.worker_steps ?? [];

// The worker steps that may run at the same time, each in its own worktree (ADR-016).
export const parallelSteps = (art) => art.artifacts.plan?.parallel_steps ?? [];

export const CANDIDATE_MOVED = "the candidate changed while the check ran";

// The plan steps not yet recorded as applied, in plan order.
export const missingSteps = (state, plan) =>
  plan.step_ids.filter((id) => !state.steps[id]);

export const checksOwed = (state, plan) =>
  `plan checks without a passing result for the candidate: ${
    missingChecks(state, plan).join("; ") || "the plan lists none"
  }`;

export function reviewCovers(state, fingerprint) {
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
export function consentMatches(state, art) {
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
export const sizeMatches = (state, art) =>
  art.artifacts.spec?.size === state.size;

// Every acceptance result must belong to the candidate being committed.
export function acOpen(state, fingerprint) {
  return Object.entries(state.ac)
    .filter(
      ([, e]) =>
        !["pass", "waived"].includes(e.status) || e.fingerprint !== fingerprint,
    )
    .map(([id]) => id);
}

export function voidEvidence(state) {
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

// What keeps a run small enough for the request to be its approval.
export function quickProblems(art) {
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
