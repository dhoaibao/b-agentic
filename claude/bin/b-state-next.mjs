// The next-step text of the b-state CLI: what the current phase still owes (ADR-009).
// Imports the core, git, gates and worktree modules.
import {
  currentFingerprint,
  missingChecks,
  missingSteps,
  parallelChecks,
  parallelSteps,
  workerSteps,
} from "./b-state-gates.mjs";
import { gitOr } from "./b-state-git.mjs";
import { runWorktrees, WORKTREE_CAP } from "./b-state-worktree.mjs";

const shellQuote = (value) => `'${value.replaceAll("'", `'\\''`)}'`;

// What the current phase still owes, derived from the state and the validated
// artifacts alone, so a session with no memory of the run can continue it. It
// only reads: every step it names is still checked by its own guard, and it
// grants no approval.
export async function nextSteps(root, state, art, fingerprint = "") {
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
  // Worktrees of parallel worker steps (ADR-016): none exist unless the plan lists such steps.
  const parallel = parallelSteps(art);
  const trees =
    parallel.length > 0 && !["clarify", "approved"].includes(state.phase)
      ? await runWorktrees(root, state, plan)
      : [];
  if (trees.length > 0 && state.phase !== "implement") {
    return [
      `remove each leftover worktree of this run first: ${trees
        .map((w) => stateCmd(`worktree remove ${w.id}`))
        .join("; ")}`,
    ];
  }
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
    // Parallel worker steps: the first two that are ready start together, each
    // in its own worktree; once a worktree exists, collect them in plan order.
    const open = new Set(trees.map((w) => w.id));
    const ready = owed.filter(
      (id) =>
        parallel.includes(id) &&
        !open.has(id) &&
        plan.steps
          .find((s) => s.id === id)
          .depends_on.every((d) => state.steps[d]),
    );
    const batch = open.size === 0 ? ready.slice(0, WORKTREE_CAP) : [];
    const batched = batch.length >= 2;
    const grouped = new Set(batched ? batch : []);
    const batchLines = batched
      ? [
          `these worker steps may run at the same time, each in its own worktree: ${batch.join(", ")}; for each ${stateCmd("worktree add S-n")} and hand it to one b-worker with ${runCmd("handoff implement --step S-n")} (all calls in one message, then end the turn); once every report is in, in plan order for each: ${stateCmd("worktree collect S-n")}, run the apply command it prints, ${stateCmd("record step S-n --by worker")}, ${stateCmd("worktree remove S-n")} (a refusal at any point: apply that step yourself in the main tree, record it --by main, then worktree remove)`,
        ]
      : [];
    const inProgress =
      open.size > 0
        ? [
            `worktrees exist for ${[...open].join(", ")}: once each worker has reported, in plan order ${stateCmd("worktree collect S-n")}, the apply command it prints, ${stateCmd("record step S-n --by worker")}, ${stateCmd("worktree remove S-n")}`,
          ]
        : [];
    return [
      ...(owed.length > 0 ? [runCmd("handoff implement")] : []),
      ...batchLines,
      ...inProgress,
      ...owed
        .filter((id) => !grouped.has(id) && !open.has(id))
        .map((id) =>
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
