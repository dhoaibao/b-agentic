# ADR-022: Discussion-first entry, a gate before a `b-flow` run and a split for oversized requests

- Status: Accepted
- Date: 2026-11-18
- Supersedes: none; refines [ADR-012](ADR-012-run-first-entry.md) (the entry of a change request into a run)

## Context

[ADR-012](ADR-012-run-first-entry.md) made a change request enter a `b-flow` run by default,
so that the work has a recorded spec, checks, and result. The entry is decided by the
kernel's routing line, which matches the intent of the request, not whether the user has
finished shaping it.

For a very large request, such as starting a new project, the user is often still
discussing it. Three things then went wrong together:

- The routing line sent the request into `b-flow`, and Start step 1 ran the state
  helper's `init` at once. The clarify step with `AskUserQuestion` and the `b-planner` call only came
  after the run existed.
- `b-planner` is a read-only subagent and cannot ask the user, so a planning call made
  while the idea was still open could only guess at the open decisions. The routing
  signals of `b-plan` (clarify, requirements, scope) also attract such ideas.
- A full run has no size limit below the schema caps of 30 steps and 30 criteria, so one
  spec could cover a whole project, and the approval round locked that scope early.

The kernel template has 58 bytes of headroom (11,942 of 12,000), and ADR-012 already
rejected raising the limit, so the fix could not be a new kernel routing line.

## Decision

- **Entry gate.** `b-flow` starts with an Entry gate before Start step 1. The request
  stays in discussion while it creates a new project or app (or a component with no
  existing code), names more than one feature that could ship on its own, leaves an
  architecture decision open (stack, storage, interface, deployment), or the user's
  latest message asks a question, weighs options, or adds an idea. While the gate holds,
  the main session discusses directly and uses `AskUserQuestion` for material choices; it
  starts no run with `init` and calls no `b-planner` unless the user asks for a plan or
  comparison. Only an explicit go passes it: a typed `/b-flow <goal>`, or words such as
  "go", "start", "settled", "chốt, làm đi". A question, a new idea, or "sounds good" is not
  a go. A small, clear request passes at once, so the quick-run path is unchanged.
- **Split for an oversized request.** At clarify, when the new-project or multi-feature
  condition still holds, the same `AskUserQuestion` round asks whether to run a scaffold
  now and one run per feature (recommended), one full run, or a narrower scope. A planner
  draft over 9 steps, 9 criteria, or 15 scope paths (three times the quick limits) is not
  written until the user has answered the split question for this request: the run
  returns to clarify and asks it, and a user who chose one full run gets the draft as is.
  On a split, the spec
  covers the scaffold only and lists each later run as a `behavior.non_goals` line
  `Later run: FEATURE`. At done, `b-flow` offers to promote that spec to
  `docs/specs/` as the shared vision with `Status: draft`.
- **`b-plan`** gains a "When NOT to use" line: an idea the user is still shaping, with no
  plan or comparison asked for, is discussed in the main session per the Entry gate.
- **Where it lives.** The rules are prompt-level, in `skills/b-flow/prompt.md` and
  `skills/b-plan/prompt.md`, plus one description sentence in `skills/registry.yaml`. The
  kernel template, the routing intent, `QUICK_LIMITS`, the state helper, the schemas, and
  the hooks do not change. `validate_cross_skill_contracts` guards the new clauses.

## Consequences

- The gate costs nothing in the kernel and fires where a run would begin, because the
  main session must read the installed `b-flow` skill before acting on it.
- The gate is a judgement guided by objective conditions, not a helper check. Whether a
  live session holds the discussion and passes on a go cannot be checked by the static
  corpus (as ADR-012 already notes for routing); it needs observation in a real session
  after the install is refreshed.
- The 9, 9, and 15 thresholds are a prompt rule, not enforced by `approve`; a user can
  still choose one full run.
- A promoted vision spec with `Status: draft` is not injected by the compact hook as
  acceptance for later runs, so its criteria do not mix with a feature run's `AC-n`.
- Rejected: a new `b-spec` skill (it needs a kernel routing line the budget cannot pay
  for, duplicates `b-plan` and the `b-flow` clarify step, adds a handoff, and is still
  routed by intent); a user-invoked-only `/b-spec` (every skill still needs a kernel
  routing line, and the gate must fire without the user knowing to type it); a kernel
  rule line (about 95 bytes against 58 bytes of headroom); wording-only changes in
  `b-flow` (no objective test, no go rule, no `b-plan` side, no split); a helper cap that
  makes `approve` refuse a large full spec (it blocks legitimate large runs and changes
  the helper); entering or gating a run from a hook (ADR-012 rejects it, and lexical
  detection of a large request is unreliable); a new run-folder backlog file (the run
  folder keeps its four artifacts; `non_goals` and promotion cover it).

Evidence: [`skills/b-flow/prompt.md`](../../skills/b-flow/prompt.md),
[`skills/b-plan/prompt.md`](../../skills/b-plan/prompt.md),
[`skills/registry.yaml`](../../skills/registry.yaml),
[`tooling/validate/behavior.py`](../../tooling/validate/behavior.py),
[`claude/bin/b-state-core.mjs`](../../claude/bin/b-state-core.mjs).
