---
name: b-orchestrate
description: >
  End-to-end PR readiness orchestration. ALWAYS invoke when the user asks for
  one workflow that spans spec, plan, implementation, optional tests, review,
  and review-fix loops until ready for PR. Coordinates phase skills and stops
  at approval, blocker, or readiness. Unlike b-implement, b-orchestrate owns
  sequencing across multiple skills rather than changing code itself.
compatibility: opencode
metadata:
  suite: b-agentic
---

# b-orchestrate

$ARGUMENTS

Coordinate a complete PR-readiness workflow across the phase skills. `b-orchestrate` owns phase selection, handoffs, checkpoints, and final synthesis only; the phase owner does the actual spec, plan, implementation, test, debug, refactor, research, or review work.

If `$ARGUMENTS` is present, treat it as the workflow goal plus any explicit constraints such as skipped tests, required verification, or a known plan path.

## When to use

- The user asks for one end-to-end workflow from unclear request through PR readiness.
- The work needs spec, plan, build, optional tests, review, and review-fix sequencing.
- The user wants review findings fixed and re-reviewed until ready for PR or blocked.

## When NOT to use

- The user asks for only one phase -> use that phase skill directly.
- The request is a simple scoped edit with no workflow loop -> use **b-implement**.
- The user asks only for a code review or audit -> use **b-review** or **b-audit**.
- The user asks only to diagnose a runtime bug -> use **b-debug**.
- The user asks only for a named behavior-preserving transform -> use **b-refactor**.

## Tools required

- Native tools - inspect status, diffs, docs, and verification commands.
- Phase skills - **b-spec**, **b-plan**, **b-implement**, **b-test**, **b-browser**, **b-review**, plus **b-debug**, **b-refactor**, and **b-research** when a phase routes there. These skills receive the actual work; `b-orchestrate` only coordinates their handoffs and results.
- `serena-symbol-toolkit` *(optional, through the active phase skill when symbol work matters)*
- `gitnexus-radar` *(optional, through the active phase skill for graph-shaped risk)*

If required tools are unavailable, read `references/b-agentic/runtime-contract.md` §4 before applying fallbacks. Graceful degradation: possible when native evidence and phase-skill handoffs can still prove progress; stop rather than simulating a phase whose required evidence is unavailable.

## Steps

### Step 1 - Start the workflow

Run `git status --short`, name the source of truth, and define success as a **b-review** verdict of **READY FOR PR** with required verification complete for suite-supported scope. If UI/browser-relevant work needs browser, DOM, visual, or e2e evidence, require **b-browser**-verified evidence from supplied/CI evidence, existing repo tooling, or approved live-browser operation before **READY FOR PR**; if the user explicitly accepts skipped checks or follow-ups, success may be **READY WITH FOLLOW-UPS** instead.

For non-trivial workflows, read `references/b-agentic/runtime-contract.md` §8, mint a run-id, and checkpoint phase state when the workflow pauses or needs durable resume state.

Read `references/b-agentic/runtime-contract.md` §1 and §9 before routing across phase skills. Keep exactly one phase owner active at a time; every phase transition is a stop condition plus handoff, not parallel execution.

For each phase transition, emit the handoff envelope, invoke the receiving skill as the only active owner, and wait for that skill's output, status block, or next handoff before continuing. Validate the returned state against the workflow goal: continue only from `complete` or an explicit next-skill handoff, stop on `blocked` or `needs-input`, and ask once if the returned state is absent or ambiguous instead of simulating the phase inside `b-orchestrate`.

### Step 2 - Route the spec phase

If the goal, constraints, acceptance criteria, non-goals, or intended behavior are unclear, hand off to **b-spec** and resume only after the spec output is concrete enough to plan. If the request is already clear, skip this phase; do not author a substitute spec inside `b-orchestrate`.

If external feasibility blocks the spec, hand off to **b-research** and resume only after the evidence is sufficient or the blocker is reported.

### Step 3 - Route the plan or direct-build phase

Hand off to **b-plan** for non-trivial work, sequencing, risk, public contracts, multi-file edits, or any workflow that needs durable coordination. Read `references/b-agentic/runtime-contract.md` §3 before applying the small-direct threshold. For a small direct workflow, hand off to **b-implement** with the current source of truth, expected scope, and verification need; do not write an execution outline inside `b-orchestrate`.

Read `references/b-agentic/runtime-contract.md` §2 before treating a saved or chat plan as approved. Do not implement from an unapproved non-trivial plan unless the user explicitly delegated that exact approval after seeing the plan.

### Step 4 - Route implementation and verification

Hand off approved build steps to **b-implement**. If a step becomes a runtime root-cause problem, route that phase to **b-debug**. If the needed change is a concrete behavior-preserving rename, extract, move, inline, simplify, or delete, route that phase to **b-refactor**.

After each build phase, require the phase skill's verification result before continuing. If verification fails because the plan is wrong, return to **b-plan** instead of widening implementation scope silently.

### Step 5 - Route test coverage work

Hand off to **b-test** when changed behavior needs non-browser unit, integration, or contract coverage, when the user requested tests, or when review confidence depends on tests. Hand off to **b-browser** when browser, DOM-rendered, visual, screenshot, browser-session, live UI, or e2e evidence is required. Skip this phase when the change is docs-only or tests are explicitly skipped; record any accepted browser follow-up instead of treating it as covered.

If **b-test** finds likely product behavior failure, route to **b-debug** before changing assertions, snapshots, or fixtures.

### Step 6 - Route review and fix findings

Hand off to **b-review** against the current diff with the spec or approved plan as baseline. Findings decide the next phase:

- Implementation gap -> **b-implement**.
- Runtime behavior failure -> **b-debug**.
- Test-only gap or harness failure -> **b-test**.
- Browser/DOM/visual/e2e evidence gap -> **b-browser**.
- Concrete behavior-preserving transform, including simplify -> **b-refactor**.
- New product decision or broad redesign -> **b-spec** or **b-plan**.

Read `references/b-agentic/runtime-contract.md` §7 before applying the review-fix loop or stopping on repeated failures. Re-review after each coherent fix set until **b-review** returns **READY FOR PR**, returns **READY WITH FOLLOW-UPS** accepted by the user, or reports a blocker.

### Step 7 - Close the workflow

Read `references/b-agentic/runtime-contract.md` §9 before reporting non-trivial workflow status or handing off unresolved work. Report the final review verdict, verification run, skipped checks, blockers, and remaining follow-ups. Do not claim **READY FOR PR** when the review had no baseline, required verification was skipped, or browser/DOM/e2e evidence remains relevant but absent.

## Output format

```text
Workflow goal -> Phase state -> Changes/verification -> Review verdict -> Blockers/follow-ups -> Next
```

Read `references/b-agentic/runtime-contract.md` §9 before closing a non-trivial orchestration with status or handoff schemas.

## Rules

- Orchestrate phases; do not bypass phase-skill rules or required read gates.
- Do not spec, plan, implement, test, debug, refactor, research, or review inside `b-orchestrate`; route that work to the owning phase skill and resume from its output.
- Do not auto-approve a plan the user has not seen.
- Preserve unrelated worktree changes and stop on direct conflicts.
- Keep review fixes scoped to findings or approved follow-up decisions.
- Do not add browser, DOM-rendered, visual, or e2e test tooling as part of the optional test phase.
- Do not treat browser, DOM, visual, or e2e checks as covered without **b-browser**-verified supplied/CI evidence, existing-tool evidence, approved live-browser evidence, or an accepted follow-up.
- Do not commit unless explicitly asked.
