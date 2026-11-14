// Shared constants, error types and small helpers of the b-state CLI (ADR-009).
// No imports from the other b-state modules.
import { createHash } from "node:crypto";

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
export const NEXT = {
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

export const RUN_ID = /^\d{8}-[a-z0-9][a-z0-9-]{0,40}$/;

export const SLUG = /^[a-z0-9][a-z0-9-]{0,40}$/;

export const SHA = /^[0-9a-f]{7,64}$/;

export const BRANCH_TARGET = /^(current|new:[a-z]+\/[a-z0-9][a-z0-9-]*)$/;

export const AC_ID = /^AC-\d+$/;

export const FINGERPRINT = /^[0-9a-f]{64}$/;

export const OWNER = /^[A-Za-z0-9._:-]{1,80}$/;

export const CONSENT_DRIFT = "recorded consent differs from the approved spec";

export const SIZE_DRIFT = "recorded run size differs from the approved spec";

export const MAX_CMD = 300;

export const MAX_TEXT = 300;

export const MAX_STATE_BYTES = 1 << 20;

// One entry per write, oldest dropped first; `history_dropped` counts those.
export const MAX_HISTORY = 200;

export const SHOW_HISTORY = 20;

export const HISTORY_OPS = [
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
export const HISTORY_DETAIL = [
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
  "worktree",
];

export const STEP_ID = /^S-[1-9]\d*$/;

export const TREE_ID = /^[0-9a-f]{40}([0-9a-f]{24})?$/;

// Changes already in the tree at run start, tracked by content digest.
export const MAX_DIRTY = 200;

export const MAX_DIRTY_BYTES = 64 << 20;

export const DIRTY_DIGEST = /^((x:)?[0-9a-f]{64}|link:[0-9a-f]{64}|absent)$/;

// A quick run is small enough that the request itself is the approval: it
// never commits and never enters review. Anything larger is a full run.
export const SIZES = ["quick", "full"];

export const QUICK_LIMITS = { steps: 3, criteria: 3, scope_paths: 5 };

export const QUICK_EVIDENCE = ["automated", "inspection"];

export const CONTROL = /[\u0000-\u001f\u007f]/;

export class Refused extends Error {}

export class Invalid extends Error {}

export const refuse = (message) => new Refused(message);

export const invalid = (message) => new Invalid(message);

export const sha256 = (value) =>
  createHash("sha256").update(value).digest("hex");

export const now = () => new Date().toISOString();

export function block(state, reason, needs) {
  if (state.phase !== "blocked") state.blocked.from = state.phase;
  state.phase = "blocked";
  state.blocked.reason = reason.slice(0, MAX_TEXT);
  state.blocked.needs = needs.slice(0, MAX_TEXT);
}

export const text = (value, name, max = MAX_TEXT) => {
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
