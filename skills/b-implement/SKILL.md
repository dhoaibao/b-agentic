---
name: b-implement
description: >
  Execute approved or scoped work safely after /b-plan approval, when the
  user asks to execute or implement scoped work, or when a small direct
  request meets the shared §3 threshold. Reads the approved plan, applies
  the next small step, verifies it, and stops for new decisions. Unlike
  b-plan, b-implement changes code.
argument-hint: "[plan-path-or-task]"
---

<!-- Generated from skills/registry.yaml and skills/b-implement/prompt.md. Edit those sources, not this file. -->

# b-implement

$ARGUMENTS

Execute approved or clearly scoped work one coherent step at a time.

If `$ARGUMENTS` is present, treat it as a plan path, plan slug, approved chat plan, or small direct request.

## When to use

- The user approved a saved or chat plan.
- The next action is to edit code or docs within known scope.
- The request meets the small direct request threshold in the shared §3 glossary.

## When NOT to use

- Scope is unclear -> use **b-plan** (Clarification mode).
- The primary job is a named mechanical transform -> use **b-refactor**.
- The task is only tests -> use **b-test**.
- A runtime root cause is unknown -> use **b-debug**.
- The blocker is external lookup -> use **b-research**.

## Tools required

- `bash` - inspect status/diff and run verification.
- `serena-symbol-toolkit` *(preferred for symbol-aware edits and diagnostics)*
- `gitnexus-radar` *(optional, for shared route/tool/exported-boundary changes)*
- `context7-docs` *(optional, for one narrow API uncertainty)*


## Steps

### Step 1 - Load source of truth

Resolve scope in this order: saved plan path, plan slug, explicitly approved chat plan, then small direct request.

For saved plans, validate before executing:

1. **Frontmatter check:** `status` is `approved` or `in-progress`; `touch_points` lists at least one path; every unchecked step has `Done when` verification. If validation fails, stop with `cause: conflict` and report the failing check.
2. **Approval check:** The plan has explicit user approval (current-chat or durable frontmatter `approved_at`). If unapproved, stop with `cause: user_blocked` and request approval.
3. **Staleness check:** Run `git diff --name-only <approved_head>..HEAD -- <touch_points>` and `git diff --name-only <approved_head> -- <touch_points>` when `approved_head` exists. If any touched file has drift, stop with `cause: conflict` and report the stale plan.
4. **Blocked-by check:** If the plan has a `blocked_by` array, verify every listed plan reports `status: complete`. If any blocker is not complete, stop with `cause: conflict` and report the blocking plan slug and status.

For **small direct requests** (no saved plan), verify all four §3 criteria before executing: (1) ≤ 3 files touched, (2) no exported/public contract change, (3) no sensitive path (auth, security, billing, migration), (4) no remaining design decision — behavior is obvious. If any criterion fails, stop with `cause: conflict` and route to **b-plan**.

If scope fails the small-direct threshold and no approved plan exists, hand off to **b-plan**. If the goal itself is ambiguous, hand off to **b-plan** (Clarification mode).

Read `../../b-agentic/references/contract/06-safety.md` once as a preflight before any editing begins — it covers safety gates, command risk classes, worktree isolation decisions, and patch discipline for all subsequent steps.

### Step 2 - Check worktree and choose execution surface

Run `git status --short`. Preserve unrelated changes, patch around unrelated edits in touched files, and stop if user changes directly conflict.

### Step 3 - Implement the smallest coherent step

Before editing, state the current step in one line: source of truth, files or symbols expected to change, behavior that must not change, planned verification, and whether approval or a review checkpoint is required.

Use Serena for symbol-aware edits.

- Keep native tools first for one-file prose/config/string edits where symbol or graph evidence adds nothing.
- Use Serena first when the step needs exact declarations, references, diagnostics, or symbol-aware edits.
- Reach for GitNexus only when the approved step crosses shared/exported, route/tool, or multi-module boundaries and blast-radius evidence will change how you execute the step.
- Use Context7 only when one narrow third-party API uncertainty blocks the next local edit or verification choice; pin the relevant version before trusting the result.
- Do not widen scope or add MCP calls just because the runtime bundle is installed.

Stay within approved scope. Stop for new product decisions, stale/wrong plans, or unplanned broad transforms. Tiny local mechanical edits required to complete the approved step may stay here; broad or primary mechanical transforms go to **b-refactor**.

### Step 4 - Verify before continuing

Run the plan's check when available. Otherwise read `../../b-agentic/references/contract/07-execution.md` before choosing verification from the ladder. Prefer touched-file diagnostics when supported, then the narrowest relevant command.

Classify failures: implementation mistake, stale local context, test harness issue, runtime uncertainty, unresolved API behavior, or external outage. Read `../../b-agentic/references/contract/07-execution.md` before applying iteration cap, cascading-failure, transform rollback, or skipped-check labels. Read `../../b-agentic/references/contract/10-decisions.md` before high-risk completion claims.

### Step 5 - Record progress and close

After verification passes, update saved-plan checkboxes and frontmatter progress without stripping metadata. Continue only when the user asked to implement or finish the plan, the next step is already approved, dependency-ready, no higher risk than the completed step, and its verification remains local or already approved. Stop after one step when asked for only the next step, or before the next step crosses a review checkpoint, new decision, broader verification, or risk increase.

At completion, inspect the diff, run final relevant verification, report cleanup/worktree state, and recommend **b-review** for non-trivial or risky changes.

## Output format

```text
Plan source -> Step progress -> Changes -> Verification -> Blockers/Decisions -> Next
```


## Rules

- Implement only approved or clearly scoped work.
- Do not add opportunistic refactors, compatibility code, or side cleanup.
- Stop for new decisions instead of guessing.
- A small direct request still needs real verification.
- Safety gates and patch discipline: read `../../b-agentic/references/contract/06-safety.md` as the Step 1 preflight (not at each later step).
