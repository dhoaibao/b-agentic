# ADR-009: `b-flow`, a bounded automatic run with file-backed state

- Status: Accepted
- Date: 2026-11-12
- Supersedes: none (narrows the "unbounded orchestration" non-goal in
  [ADR-001](ADR-001-b-agentic-design-record.md); that non-goal stays for everything
  outside a `b-flow` run)

[ADR-015](ADR-015-step-writer-worker.md) supersedes two sentences below: "The main
session implements; read-only specialists stay read-only and no writer worker is
added" and "An optional writer worker would need its own ADR". An approved plan step
may be applied by one `b-worker` child while the main session waits.

[ADR-012](ADR-012-run-first-entry.md) supersedes three points below: `b-flow` is no
longer explicit-only (change requests enter a run, as a quick or full run), a run
without commit consent may start on a changed tree and ends at QA, and the commit
consent exception applies to any run rather than to `/b-flow` alone.

## Context

Multi-phase work (clarify, plan, implement, review, fix, QA, commit) is sequenced
today by the main session from memory. Phase progress and the round counters behind
the kernel limits (3 consecutive `NEEDS FIXES`, 3 QA FAIL rounds) vanish when a
session ends or compacts, and a new session cannot tell what was approved or
reviewed. Commits also need an explicit user request each time, which blocks an
otherwise approved, unattended run.

## Decision

- **Orchestrator skill.** `b-flow` is a main-session skill with
  `routing.explicit_request: true`; it runs only on `/b-flow` or an explicit request.
  It sequences the existing skills (`b-plan` via `b-planner`, `b-implement` or
  `b-frontend`, `b-test`, `b-review`, `b-qa`, `b-commit`) and does not merge them. The
  main session implements; read-only specialists stay read-only and no writer worker
  is added.
- **One interactive gate.** Clarification and a single approval are the only user
  interaction. The approval covers the Behavior delta and `AC-n` criteria, scope and
  non-goals, commit consent and branch target, Codex use (standing approval, else
  `b-reviewer`). Push and PR are never part of a run. After approval the run
  continues without questions until `done` or a recorded block.
- **Order.** implement, checks, review (when a kernel trigger applies, else the
  recorded low-risk exception), fix, QA, commit. QA runs before the commit.
- **Run files.** (The four markdown artifacts and their validation are refined by
  [ADR-010](ADR-010-run-artifact-cli.md).) Untracked, under `.b-agentic/runs/<id>/` at the worktree root:
  `spec.md` (what was approved, with a Consent block), `plan.md`, `qa.md`,
  `followups.md`, `state.json` (progress only), and a `lock`. A self-ignoring
  `.b-agentic/.gitignore` (`*`) keeps them out of other repositories without touching
  tracked files. `spec.md` may be promoted to `docs/specs/` after completion.
- **Authority of the files.** `spec.md` plus its recorded sha256 is the approval;
  `state.json` records progress; git is the truth about the tree. Run files are
  untrusted input (kernel rule 7): they never grant approval, never authorize push,
  PR, or any external mutation, and carry no file contents, diffs, command output, or
  secrets (paths pass `isProtected`; hashes, SHAs, approved check commands, and exit
  codes only).
- **State helper.** Only the main session writes state, through
  `claude/bin/b-state.mjs`: schema validation, atomic write, `O_NOFOLLOW`, refusal of
  a symlinked or out-of-root `.b-agentic`, a per-run lock, and step guards that fail
  closed (for example `commit` needs recorded consent, a QA PASS fingerprint equal to
  the current candidate, and a review verdict or low-risk exception for that same
  fingerprint).
- **Continuing without memory.** (Refined 2026-11-13.) A session must be able to
  continue a run from the run folder alone. `b-state check` therefore prints `next`,
  the steps the current phase still owes, derived from the state and the validated
  artifacts; it only reads, and every step it names is still checked by its own guard.
  The helper also refuses what the skill text alone used to ask for: review and QA
  need every approved plan check passing for the candidate, and a `NEEDS FIXES` or
  `READY WITH FOLLOW-UPS` verdict needs that round's findings already in
  `followups.md`. `state.json` keeps a bounded `history` (one entry per write, in the
  same atomic write as the change, holding only the kinds of facts the state already
  holds), so earlier verdicts, blocks, and unblock reasons are not lost. Progress
  inside `implement` is recorded too: `record step S-n` marks a plan step applied (a
  step waits for the steps it depends on, and is refused when it changed a path
  outside the approved scope, [ADR-014](ADR-014-checked-plan-steps.md)),
  `advance verify` needs every step recorded,
  and a new approval or a return to `implement` or `clarify` clears the record. Each
  phase is briefed from its packet, `b_run.py handoff <phase>`, and each skill's
  place in a run (phase skill, evidence provider, utility, or orchestrator) is its
  registry `contract`, from which the generator renders the phase table in the
  `b-flow` skill.
- **Resume.** Only an explicit `/b-flow resume` continues a run. `b-state check` first
  re-verifies repo root and branch, lock, spec hash, HEAD against recorded commits,
  and the current candidate fingerprint; any mismatch voids evidence tied to the old
  fingerprint and returns the run to `verify`, or blocks it. A hook may print the
  active run's path and phase as a pointer but never resumes a run.
- **Bounds.** The run stops and asks after 3 failed verify checks (one verify round
  with three failing checks counts, and so does a check whose candidate changed while
  it ran, [ADR-013](ADR-013-concurrent-plan-checks.md); the count resets when the
  candidate reaches review or QA), 3 consecutive
  `NEEDS FIXES` rounds, or 3 consecutive QA FAIL rounds (all persisted), on any path
  outside the approved scope, on a finding that would change approved behavior or
  `AC-n`, on an `AC-n` without evidence, on a protected file, and on any destructive,
  external, or native-permission prompt. Evidenced in-scope blockers are fixed as a
  whole class; other findings go to `followups.md`. There is no Stop-hook
  auto-continue.
- **Commit consent exception.** Commit consent recorded in the approved spec counts as
  the explicit commit request for that run's QA-passed fingerprint only. It does not
  extend to another candidate, another run, push, or PR. Outside `/b-flow` the explicit
  request rule is unchanged.

## Consequences

- Round counters and approval survive sessions and compaction; limits become
  enforceable.
- The kernel gains one commit-consent bullet; `b-commit` and `b-qa` read run state as
  inputs; changing commit and approval policy requires independent `b-review`.
- A new CLI, a skill, a hook extension, installer coverage, and tests must be
  maintained.
- Long runs consume main-session context; state files and `/b-flow resume` are the
  mitigation. An optional writer worker would need its own ADR.
- Rejected: a Stop-hook auto-continue loop (runaway risk, fights `b-verify-gate`);
  JSON as the spec source of truth (unreadable, drifts from the approval); tracked
  `docs/specs/` as the run spec (status edits churn the fingerprint and void reviews);
  every skill reading and writing state itself (spreads authority); automatic push or
  PR (shared external mutation); a read-only planner writing `.b-agentic/` (breaks the
  agent boundary); state under `~/.claude/b-agentic/` (does not follow the worktree);
  a separate event log file (a second write that can drift from the state); continuing
  after compaction without `/b-flow resume` (session id and skill text surviving
  compaction are unverified).

Evidence: [`references/kernel.template.md`](../../references/kernel.template.md),
[`skills/b-commit/prompt.md`](../../skills/b-commit/prompt.md),
[`skills/b-qa/prompt.md`](../../skills/b-qa/prompt.md),
[`claude/bin/b-candidate-snapshot.mjs`](../../claude/bin/b-candidate-snapshot.mjs),
[`claude/hooks/b-spec-context.mjs`](../../claude/hooks/b-spec-context.mjs).
