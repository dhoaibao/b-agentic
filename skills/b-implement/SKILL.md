---
name: b-implement
description: >
  Execute approved or scoped work safely. ALWAYS invoke after /b-plan
  approval, when the user asks to execute or implement scoped work, or when a
  small direct request meets the threshold in AGENTS.md section 3. Reads the
  approved plan, applies the next small step, verifies it, and stops for new
  decisions. Unlike b-plan, b-implement changes code.
compatibility: opencode
metadata:
  suite: b-skills
---

# b-implement

$ARGUMENTS

Execute approved or clearly scoped work one coherent step at a time.

If `$ARGUMENTS` is present, treat it as a plan path, plan slug, approved chat plan, or small direct request.

## When to use

- The user approved a saved or chat plan.
- The next action is to edit code or docs within known scope.
- The request meets the small direct request threshold in `AGENTS.md` section 3.

## When NOT to use

- Scope is unclear -> use **b-spec** or **b-plan**.
- The primary job is a named mechanical transform -> use **b-refactor**.
- The task is only tests -> use **b-test**.
- A runtime root cause is unknown -> use **b-debug**.
- The blocker is external lookup -> use **b-research**.

## Tools required

- `bash` - inspect status/diff and run verification.
- `serena-symbol-toolkit` *(preferred for symbol-aware edits and diagnostics)*
- `gitnexus-radar` *(optional, for shared route/tool/exported-boundary changes)*
- `context7-docs` *(optional, for one narrow API uncertainty)*

Fallbacks: `AGENTS.md` section 4. Graceful degradation: possible with native tools; broad symbol work is riskier without Serena.

## Steps

### Step 1 - Load source of truth

Resolve scope in this order: saved plan path, plan slug, explicitly approved chat plan, then small direct request.

For saved plans, require an executable approval state or current-chat approval. Apply the global plan staleness gate before editing. If approval arrives for a draft plan, update durable metadata before the first source edit.

If scope fails the small-direct threshold and no approved plan exists, hand off to **b-plan**. If the goal itself is ambiguous, hand off to **b-spec**.

### Step 2 - Check worktree and choose execution surface

Run `git status --short`. Preserve unrelated changes, patch around unrelated edits in touched files, and stop if user changes directly conflict.

For non-trivial work, decide whether the current checkout is safe or whether isolation would materially reduce risk. Follow the global worktree and isolation rules.

### Step 3 - Implement the smallest coherent step

Use Serena for symbol-aware edits and `apply_patch` for small prose/config/glue edits under the global patch discipline. If `apply_patch` reports missing expected lines, treat it as stale context: re-read and retry with smaller verified context.

Stay within approved scope. Stop for new product decisions, stale/wrong plans, or unplanned broad transforms. Tiny local mechanical edits required to complete the approved step may stay here; broad or primary mechanical transforms go to **b-refactor**.

### Step 4 - Verify before continuing

Run the plan's check when available; otherwise use the global verification ladder. Prefer touched-file diagnostics when supported, then the narrowest relevant command.

Classify failures: implementation mistake, stale context, test harness issue, runtime uncertainty, unresolved API behavior, or external outage. Apply the global iteration cap, cascading-failure rule, transform rollback rule, skipped-check labels, and high-risk challenge gate.

### Step 5 - Record progress and close

After verification passes, update saved-plan checkboxes and frontmatter progress without stripping metadata. Continue only when the user asked to implement or finish the plan, the next step is already approved, dependency-ready, no higher risk than the completed step, and its verification remains local or already approved. Stop after one step when asked for only the next step, or before the next step crosses a review checkpoint, new decision, broader verification, or risk increase.

At completion, inspect the diff, run final relevant verification, report cleanup/worktree state, and recommend **b-review** for non-trivial or risky changes.

## Output format

```text
Plan source -> Step progress -> Changes -> Verification -> Blockers/Decisions -> Next
```

Close non-trivial runs with the status/handoff schemas from `AGENTS.md`.

## Rules

- Implement only approved or clearly scoped work.
- Preserve unrelated user changes.
- Do not add opportunistic refactors, compatibility code, or side cleanup.
- Stop for new decisions instead of guessing.
- A small direct request still needs real verification.
- Do not commit unless explicitly asked.
- Use the global patch discipline and stale context recovery for manual edits.
