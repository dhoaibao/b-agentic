// The init, approve, advance, unblock and check commands of the b-state CLI (ADR-009).
// Imports the core, git, store, gates and next modules.
import { execFile } from "node:child_process";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  block,
  BRANCH_TARGET,
  BUDGET_PHASES,
  BUDGET_REASON,
  BUDGET_WINDOW_S,
  CONSENT_DRIFT,
  countedSeconds,
  helperDir,
  invalid,
  NEXT,
  now,
  PHASES,
  refuse,
  secondsBetween,
  SIZE_DRIFT,
  SIZES,
  SLUG,
  text,
} from "./b-state-core.mjs";
import {
  acOpen,
  artifactsOk,
  branchAllowed,
  captureCommitPlan,
  checksOwed,
  checksPass,
  consentMatches,
  currentFingerprint,
  missingSteps,
  newStepBase,
  planHash,
  quickProblems,
  requireSpecUnchanged,
  reviewCovers,
  scopeOk,
  sizeMatches,
  specHash,
  voidEvidence,
} from "./b-state-gates.mjs";
import {
  dirtyBaseline,
  gitOr,
  isAncestor,
  worktreeBaseline,
  worktreeTree,
} from "./b-state-git.mjs";
import { nextSteps, timeReport } from "./b-state-next.mjs";
import {
  acquireMutex,
  activeUnfinished,
  defaultOwner,
  ensureBase,
  freshState,
  isPlainDir,
  layout,
  loadState,
  readKit,
  readLock,
  runsHint,
  saveState,
  takeLock,
  writeAtomic,
} from "./b-state-store.mjs";

export async function cmdInit(root, args) {
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
    const hint = runsHint(root);
    return hint
      ? { run: id, dir, phase: state.phase, hint }
      : { run: id, dir, phase: state.phase };
  } finally {
    release();
  }
}

export async function cmdApprove(root, dir, state, args) {
  if (state.phase !== "clarify")
    throw refuse("approve is only valid in phase clarify");
  const commit = args.commit;
  if (!["yes", "no"].includes(commit))
    throw invalid("--commit yes|no is required");
  if (!BRANCH_TARGET.test(args["branch-target"] ?? "")) {
    throw invalid("--branch-target must be current or new:<type>/<kebab>");
  }
  const art = await artifactsOk(root, state);
  const missing = ["spec", "plan"].filter((kind) => !art.artifacts[kind]);
  if (missing.length > 0)
    throw refuse(
      `write the missing artifact first: ${missing.map((kind) => `${helperDir()}/b-run write ${kind}`).join(" and ")}`,
    );
  // The consent the user approved is the spec's; the flags only repeat it.
  const specConsent = art.artifacts.spec.consent;
  if (
    specConsent.commit !== commit ||
    specConsent.branch_target !== args["branch-target"]
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
    push_pr: false,
  };
  // A new approval is a new plan: none of its steps is applied yet.
  state.steps = {};
  state.step_base = null;
  // The budget measures the whole run, so a re-approval keeps what it counted (ADR-039).
  state.budget ??= { phase_s: {}, stop_at_s: BUDGET_WINDOW_S };
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

export async function cmdAdvance(root, dir, state, args) {
  const target = args._[1];
  if (!PHASES.includes(target)) throw invalid("unknown phase");
  if (target === "blocked") {
    if (state.phase === "done")
      throw refuse("a finished run cannot be blocked");
    const reason = text(args.reason, "--reason");
    if (reason === BUDGET_REASON)
      throw refuse("that reason is reserved for the run time budget");
    block(state, reason, text(args.needs ?? "user decision", "--needs"));
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
  // The helpers that finish a run can differ from the ones that started it (ADR-036).
  if (target === "done") {
    const kit = readKit(state.runtime);
    if (kit) state.kit = { ...state.kit, done: kit };
  }
  saveState(dir, state, "advance", {
    trigger: target === "review" ? state.review.trigger : "",
    fingerprint,
  });
  const result = { phase: state.phase };
  if (state.phase === "done") {
    const { outcome, notice } = await recordRunStats(root, state);
    result.run_stats = outcome;
    if (notice) result.notice = notice;
  }
  return result;
}

const RUN_CLI = fileURLToPath(new URL("./b_run.py", import.meta.url));

// Appends the finished run's numbers-only line to the local run-stats store (ADR-035). It
// runs after the done state is saved and never fails the advance: any problem is only a
// missing line that `b-run stats --record` adds later. Returns the outcome (written, already,
// skipped:<reason>, or failed) and the one-time notice printed when the store is first created.
function recordRunStats(root, state) {
  return new Promise((done) => {
    execFile(
      "python3",
      ["-I", "-B", RUN_CLI, "stats", "--record", "--run", state.run_id],
      { cwd: root, encoding: "utf8", maxBuffer: 1 << 20, timeout: 10_000 },
      (_error, stdout) => {
        try {
          const parsed = JSON.parse(stdout);
          const reason = Object.keys(parsed.skipped ?? {})[0];
          const outcome =
            parsed.appended > 0
              ? "written"
              : parsed.already > 0
                ? "already"
                : `skipped:${reason ?? "unknown"}`;
          done({
            outcome,
            notice: typeof parsed.notice === "string" ? parsed.notice : "",
          });
        } catch {
          done({ outcome: "failed", notice: "" });
        }
      },
    );
  });
}

// The phases a time stop interrupts. Not clarify or blocked, which are not counted, and
// not commit or done: once commits begin, the run finishes.
const TIME_STOPPABLE = [
  "approved",
  "implement",
  "verify",
  "review",
  "fix",
  "qa",
];

// The next stop comes a full window after the user's latest decision.
const openWindow = (state) => {
  state.budget.stop_at_s = countedSeconds(state.budget) + BUDGET_WINDOW_S;
};

// The run time budget (ADR-039). It runs after a successful check, advance or record
// call, inside the same mutex: the call's own result stays recorded, then a run past
// its mark is blocked for the user. It only acts when the helper is called.
export async function applyTimeStop(root, dir, command, result) {
  if (
    !["check", "advance", "record"].includes(command) ||
    result.ok === false
  ) {
    return result;
  }
  const state = loadState(dir);
  if (!state.budget || !TIME_STOPPABLE.includes(state.phase)) return result;
  // A review may be running until its verdict is recorded, and a blocked run
  // would refuse that verdict.
  if (command === "check" && state.phase === "review" && !state.review.verdict)
    return result;
  const live = BUDGET_PHASES.includes(state.phase)
    ? secondsBetween(state.updated_at, now())
    : 0;
  if (countedSeconds(state.budget) + live < state.budget.stop_at_s)
    return result;
  // When the artifacts cannot be read, the run stops all the same: a stop loses
  // nothing, and a skipped one could let the run commit without the user.
  let art;
  try {
    art = await artifactsOk(root, state);
  } catch {
    // The report then says the open blockers are unknown.
  }
  block(state, BUDGET_REASON, "user decision");
  saveState(dir, state, "advance");
  return {
    ...result,
    ok: false,
    phase: state.phase,
    blocked: state.blocked,
    time_stop: {
      note: "this command's own result is recorded; the run then stopped on its time budget",
      ...timeReport(state, art),
    },
  };
}

// Whether HEAD sits on a commit the run recorded.
async function recordedHead(root, state, head) {
  for (const sha of [...state.commits, ...state.prior_commits])
    if ((await gitOr(root, ["rev-parse", sha])) === head) return true;
  return false;
}

// Back to the phase the time stop interrupted. Nothing is voided and no counter
// resets: the tree gates and the next check judge the candidate as always.
async function continueStopped(root, dir, state, reason) {
  if (state.blocked.reason !== BUDGET_REASON || !state.budget) {
    throw refuse(
      "unblock continue leaves only a run stopped by its time budget",
    );
  }
  // The checkout must still be the one check accepts: continuing elsewhere could
  // take the run's evidence into a commit on another branch.
  const here = await worktreeBaseline(root);
  if (state.repo_root !== root || state.branch !== here.branch) {
    throw refuse(
      "repository root or branch differs from the run: switch back, then continue",
    );
  }
  if (
    here.head !== state.baseline.head &&
    !(await recordedHead(root, state, here.head))
  ) {
    throw refuse("HEAD moved outside the recorded commits");
  }
  requireSpecUnchanged(dir, state);
  const art = await artifactsOk(root, state);
  if (!sizeMatches(state, art)) throw refuse(SIZE_DRIFT);
  if (!consentMatches(state, art)) throw refuse(CONSENT_DRIFT);
  const phase = state.blocked.from;
  if (!TIME_STOPPABLE.includes(phase))
    throw refuse("the run was not stopped in a phase it can continue");
  // A step base that was current until the stop stays current. Any other write
  // leaves it stale, so the step gate still sees it.
  if (state.step_base?.rev === state.rev - 1)
    state.step_base = { ...state.step_base, rev: state.rev + 1 };
  state.blocked = { reason: "", needs: "", from: "" };
  state.phase = phase;
  openWindow(state);
  saveState(dir, state, "unblock", { reason });
  return { phase: state.phase };
}

export async function cmdUnblock(root, dir, state, args) {
  if (state.phase !== "blocked") throw refuse("run is not blocked");
  const target = args._[1];
  if (!["continue", "clarify", "implement", "fix", "verify"].includes(target)) {
    throw invalid(
      "unblock target must be continue, clarify, implement, fix, or verify",
    );
  }
  const reason = text(args.reason, "--reason");
  if (target === "continue") return continueStopped(root, dir, state, reason);
  // A quick run that met a review trigger has outgrown the request that
  // approved it: the only way on is a new approval, as a full run.
  const outgrown = state.size === "quick" && state.review.trigger !== "";
  if (outgrown && target !== "clarify") {
    throw refuse(
      "a quick run that met a review trigger continues only through unblock clarify and a full-run approval",
    );
  }
  if (target === "verify") {
    requireSpecUnchanged(dir, state);
    const art = await artifactsOk(root, state);
    if (!sizeMatches(state, art)) throw refuse(SIZE_DRIFT);
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
  // One user decision is never followed at once by a time stop.
  if (state.budget && countedSeconds(state.budget) >= state.budget.stop_at_s)
    openWindow(state);
  saveState(dir, state, "unblock", { reason });
  return { phase: state.phase };
}

export async function cmdCheck(root, dir, state, args) {
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
  // The artifact validation is a python process: start it beside the git reads.
  // Every path below that needs it awaits this promise; an unused one is
  // swallowed, and the validation is read-only.
  const artifactsPromise = artifactsOk(root, state);
  artifactsPromise.catch(() => {});
  const baseline = await worktreeBaseline(root);
  let changed = false;
  let why = "";
  let art = null;
  const blockedFor = (s) =>
    s.phase === "blocked" ? `${s.blocked.reason}\n${s.blocked.needs}` : null;
  const wasBlockedFor = blockedFor(state);
  let artifactProblem = "";
  let fingerprint = "";
  // A time-stopped run keeps its reason: another one would take `unblock continue`
  // away, over a failure that may pass. The problem is still reported, continue
  // repeats the spec and artifact gates, and the next check judges the rest.
  const timeStopped =
    state.phase === "blocked" && state.blocked.reason === BUDGET_REASON;
  const blockRun = (reason, needs) => {
    if (timeStopped) return;
    block(state, reason, needs);
    changed = true;
  };
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
    blockRun("repository root or branch changed", "user decision");
  } else if (
    state.phase !== "clarify" &&
    (specHash(dir) !== state.spec.sha256 ||
      (state.spec.plan_sha256 && planHash(dir) !== state.spec.plan_sha256))
  ) {
    problems.push("spec.md or plan.md changed after approval");
    blockRun("spec or plan changed after approval", "re-approval");
  } else if (
    state.phase !== "clarify" &&
    (artifactProblem = await artifactsPromise.then(
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
    blockRun(problem, drift ? "re-approval" : "user decision");
  } else {
    if (adoptable) {
      state.branch = baseline.branch;
      why = "adopted the approved branch";
      changed = true;
    }
    let headMoved = false;
    if (baseline.head !== state.baseline.head) {
      if (await recordedHead(root, state, baseline.head)) {
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
        blockRun("HEAD moved outside the run", "user decision");
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
        blockRun("candidate changed after commits began", "user decision");
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
  // The report of a time stop names the open blockers, whatever else was found.
  if (state.phase === "clarify" || timeStopped) {
    art = await artifactsPromise.catch(() => null);
  }
  const result = {
    ok: state.phase !== "blocked",
    phase: state.phase,
    problems,
    actions,
    blocked: state.phase === "blocked" ? state.blocked : undefined,
  };
  // The time stop comes before the next lines: a failure while building them must
  // not refuse a check that is past the mark.
  const checked = await applyTimeStop(root, dir, "check", result);
  const guided = checked === result ? state : loadState(dir);
  return {
    ...checked,
    next: await nextSteps(root, guided, art, fingerprint),
  };
}
