// The next-step text of the b-state CLI: what the current phase still owes (ADR-009).
// Imports the core, git and gates modules.
import {
  BUDGET_REASON,
  BUDGET_WINDOW_S,
  countedSeconds,
  helperDir,
  onPi,
} from "./b-state-core.mjs";
import {
  currentFingerprint,
  missingChecks,
  missingSteps,
  parallelChecks,
  workerSteps,
} from "./b-state-gates.mjs";
import { gitOr } from "./b-state-git.mjs";

const shellQuote = (value) => `'${value.replaceAll("'", `'\\''`)}'`;

const openBlockers = (followups) =>
  (followups?.items ?? [])
    .filter((item) => item.kind === "blocker" && item.disposition === "open")
    .map((item) => item.id);

// What the user needs to decide on a time-stopped run (ADR-039): where the counted
// time went, the review rounds held, and the blockers still open (null when the
// artifacts could not be read, which is not the same as none).
export const timeReport = (state, art) => ({
  counted_s: countedSeconds(state.budget),
  phase_s: state.budget.phase_s,
  review_rounds: state.review.round,
  open_blockers: art ? openBlockers(art.artifacts.followups) : null,
});

// What the current phase still owes, derived from the state and the validated
// artifacts alone, so a session with no memory of the run can continue it. It
// only reads: every step it names is still checked by its own guard, and it
// grants no approval.
export async function nextSteps(root, state, art, fingerprint = "") {
  const stateCmd = (rest) => `${helperDir()}/b-state ${rest}`;
  const runCmd = (rest) => `${helperDir()}/b-run ${rest}`;
  if (
    state.phase === "blocked" &&
    state.blocked.reason === BUDGET_REASON &&
    state.budget
  ) {
    const report = timeReport(state, art);
    const phases = Object.entries(report.phase_s)
      .map(([phase, seconds]) => `${phase} ${seconds}s`)
      .join(", ");
    return [
      `ask the user: ${state.blocked.reason} (needs: ${state.blocked.needs})`,
      `report to the user: ${report.counted_s}s counted since approval, without clarify and blocked time (${phases}); review rounds: ${report.review_rounds}; open blockers: ${report.open_blockers ? report.open_blockers.join(", ") || "none" : "unknown, the run artifacts could not be read"}`,
      stateCmd(
        `unblock continue --reason R (back to ${state.blocked.from} with its evidence; the next stop is ${BUDGET_WINDOW_S / 60} counted minutes later), or unblock <clarify|implement|fix|verify> --reason R (a changed spec needs clarify and a new approval)`,
      ),
    ];
  }
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
  if (!art)
    return [`the run artifacts could not be read: ${runCmd("validate")}`];
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
          ? `approve --commit ${consent.commit} --branch-target ${consent.branch_target}${quick ? " --size quick" : ""}`
          : "approve --commit yes|no --branch-target T",
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
      `${runCmd("write followups")} with this round's findings as R${round}-<n> (each blocker: kind blocker, disposition open, blocker_class, and escaped_from, unknown when not known; omit what ${runCmd("schema followups")} lacks)`,
      stateCmd(
        onPi()
          ? 'record review --verdict "<verdict>" --gate reviewer --gate-reason R'
          : 'record review --verdict "<verdict>" --gate codex|reviewer [--gate-reason R]',
      ),
    ];
  }
  if (state.phase === "fix") {
    const steps = [];
    const open = openBlockers(followups);
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
        `fix the open blockers inside the approved scope, whole class each, and pass the checks related to them: ${open.join(", ")}`,
        `${runCmd("write followups")} with a disposition and reason for each (a fixed blocker's reason names its violated invariant), and a sweep line for every fixed blocker, with the ways checked in brief`,
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
        `${stateCmd("record ac AC-n <result>")} for each row, then ${stateCmd("record qa --verdict V")}`,
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
