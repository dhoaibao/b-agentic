// The record command of the b-state CLI: check, step, review, QA, criterion and commit results.
// Imports the core, git, store, gates and worktree modules.
import { isProtected } from "./b-candidate-snapshot.mjs";
import {
  AC_ID,
  AC_STATUSES,
  block,
  CONSENT_DRIFT,
  FINGERPRINT,
  invalid,
  MAX_CMD,
  MAX_ROUNDS,
  QA_VERDICTS,
  refuse,
  REVIEW_VERDICTS,
  SHA,
  SIZE_DRIFT,
  text,
} from "./b-state-core.mjs";
import {
  artifactsOk,
  branchAllowed,
  CANDIDATE_MOVED,
  captureStep,
  checksOwed,
  checksPass,
  consentMatches,
  currentFingerprint,
  currentHead,
  HEAD_MOVED,
  missingSteps,
  namedPaths,
  parallelChecks,
  parallelSteps,
  requireSpecUnchanged,
  sizeMatches,
  STATE_WRITTEN,
  stepDelta,
  workerSteps,
} from "./b-state-gates.mjs";
import { gitOr, isAncestor } from "./b-state-git.mjs";
import { saveState } from "./b-state-store.mjs";
import { rawChange, runWorktrees, workerChange } from "./b-state-worktree.mjs";

// `capture` is how a step's tree is captured; the probes replace it to change
// the repository at exactly that point.
export async function cmdRecord(
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
    // A parallel step's worker had its own worktree: the record is then held to
    // that worker's change, and the history says so (ADR-016).
    const trees =
      by === "worker" && parallelSteps(art).includes(id)
        ? await runWorktrees(root, state, art.artifacts.plan)
        : [];
    const apart = trees.find((w) => w.id === id);
    const applier = worker ? { by, ...(apart ? { worktree: true } : {}) } : {};
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
      // A worktree step is applied by the main session instead, and the counted
      // refusal then applies to that record: nothing is written here.
      if (apart)
        throw refuse(
          `${snapshot.protected.length} protected path(s) changed in the main tree: apply ${id} yourself and record --by main`,
        );
      problem = `${snapshot.protected.length} protected path(s) changed`;
    } else {
      delta = await stepDelta(root, state, base.tree, tree, id);
      // A worktree step stays on its own paths, as worktree collect requires. This
      // comes before the counted refusals below, so it writes nothing: such a step
      // is applied by the main session instead.
      if (apart && delta.outside_step > 0)
        throw refuse(
          `${id} changed ${delta.outside_step} path(s) outside its own paths: apply the step yourself and record --by main`,
        );
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
    // The step gate cannot tell two steps applied together apart, so a worker
    // of its own worktree is held to its own change: what the main tree gained
    // since the step base must be exactly what that worker changed. Refused
    // before any write; the step is then applied by the main session.
    if (apart) {
      const theirs = await rawChange(root, base.tree, tree);
      if ((await workerChange(root, state, apart, base)) !== theirs)
        throw refuse(
          `the main-tree change is not ${id}'s worker change: apply what worktree collect printed, or apply the step yourself and record --by main`,
        );
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
