---
name: b-implement
description: >
  Execute approved or scoped work safely. ALWAYS invoke after /b-plan
  approval, when the user asks to execute or implement scoped work, or when a
  small direct request meets the threshold in AGENTS.md §3. Reads the
  approved plan, applies the next small step, verifies it, and stops for new
  decisions. Unlike b-plan, b-implement changes code.
compatibility: opencode
metadata:
  suite: b-skills
---

# b-implement

$ARGUMENTS

Execute approved/scoped work: load source of truth, change the next smallest step, verify, and stop for new decisions.

If `$ARGUMENTS` is present, treat it as the plan path, plan slug, approved chat plan, or **small direct request** as defined in `AGENTS.md` §3.

## When to use

- The user approved a saved plan or chat plan.
- The task is already scoped and the next action is to edit code or docs.
- The request meets the **small direct request** threshold from `AGENTS.md` §3 (≤3 files, no public contract, no sensitive path, no remaining design decision).

## When NOT to use

- The request fails the **small direct request** threshold and is not backed by an approved plan → use **b-plan**.
- The request still has an unclear end state or acceptance criteria → use **b-spec**.
- The request is a named rename, extract, move, inline, or delete → use **b-refactor**.
- The task is only external lookup → use **b-research**.
- The task is only tests → use **b-test**.
- Something is broken and root cause is not confirmed → use **b-debug**.

## Tools required

- `bash` — inspect status, diff, and run verification commands.
- `serena-symbol-toolkit` *(preferred for symbol-aware edits)*
- `gitnexus-radar` *(optional, for shared-route/tool/exported-boundary changes)*
- `context7-docs` *(optional, for a narrow API uncertainty discovered mid-step)*

Fallbacks: `AGENTS.md` §4. If execution reveals a research blocker, stop and use **b-research**. Graceful degradation: ✅ Possible — native tools work, broad symbol changes are riskier without Serena.

## Steps

### Step 1 — Load the source of truth

Resolve scope in this order:
1. A saved plan path under `.opencode/b-skills/b-plan/`.
2. A plan slug under `.opencode/b-skills/b-plan/` (resolved via the slug algorithm in `AGENTS.md` §8).
3. An explicitly approved chat plan.
4. A request that meets the **small direct request** threshold (`AGENTS.md` §3).

If the request fails the threshold and no plan exists, stop and route to **b-plan** via the handoff envelope (`AGENTS.md` §9).

If the request is still ambiguous at the goal level rather than the sequencing level, stop and route to **b-spec**.

Apply the **plan staleness gate** (`AGENTS.md` §2) before executing. A stale plan must be re-planned, not improvised against.

Extract only execution-critical data: approval state, decisions, touch points, steps/request, verification, blockers.

For saved plans with frontmatter, require `status: approved`, `status: in-progress`, or explicit approval in the current conversation before editing. If approval arrives in chat for a draft plan, update `status`, `approved_at`, `approved_by`, and `approved_head` when available before the first source edit. Legacy plans without frontmatter may execute from explicit current-chat approval per `AGENTS.md` §2.

### Step 2 — Check the working state

Run `git status --short` and inspect only the files relevant to the current step.

- Leave unrelated changes alone (`AGENTS.md` §6 worktree safety).
- If the target file already has unrelated edits, patch around them.
- If user changes directly conflict with the approved scope, stop and ask.

For implement/finish/continue, proceed through dependency-ready steps while checks pass and no decision appears. For next-step requests, stop after one verified step. Treat small direct tasks as one step.

### Step 3 — Implement the next smallest step

Use `serena-symbol-toolkit` for symbol-aware edits and the cheapest discovery tool that closes the next question (`AGENTS.md` §4). Use `gitnexus-radar` only when the step crosses a shared route, tool, or exported boundary, subject to the freshness gate.

Apply the smallest edit that satisfies the step. For manual `apply_patch` edits, follow the patch discipline in `AGENTS.md` §6.

If the step turns into an unplanned rename, move, extract, inline, or delete → stop and hand off to **b-refactor**.

If a new behavioral or product decision appears → stop and ask.

If the plan itself is wrong (touch points missing, ordering incorrect, decisions invalidated by current code) → trigger the **plan revision protocol** in `AGENTS.md` §2. Do not improvise against the stale plan.

### Step 4 — Verify before moving on

Run the exact plan verification when available. Otherwise run the narrowest relevant check for the touched area, following the verification ladder in `AGENTS.md` §7.

Use `get_diagnostics_for_file` on the touched source file (production code, not just tests) before broader commands when the language supports it. Honor the LSP-coverage caveat in `AGENTS.md` §4.

Classify failures:
- Implementation mistake → fix and rerun.
- `apply_patch` missing expected lines → stale context; re-read the current target slice and retry only with verified smaller context (`AGENTS.md` §6).
- Test harness problem → **b-test**.
- Runtime/root-cause uncertainty → **b-debug**.
- Unresolved library/API behavior → `context7-docs`, then **b-research** if still unclear.
- External (CI down, registry outage, dep yanked) → record the blocker, do not retry inside the iteration cap.

**High-risk challenge gate.** For auth/authz, security boundaries, migrations, public or external contracts, or irreversible external writes, apply the high-risk challenge gate from `AGENTS.md` §10 before calling the step done.

**Documentation-backed decisions.** If framework, library, or vendor API docs determined the chosen pattern, cite the source in the final report. Add a short inline code comment only when the contract would otherwise be non-obvious to a future reader.

**Mid-step rollback:** if a partial edit has left the tree in a broken state (compile failure, import cycle, half-renamed symbol) and the next iteration cannot move forward without first restoring a coherent baseline, stop attempting to push through. Either (a) finish the edit to a coherent state in one more focused pass, or (b) manually roll back only the edits made in the current step using patch-based reversals. If a file-level restore is truly required, stop and ask for approval first because it can discard unrelated user changes in the same path. Never leave the working tree mid-transform across a skill exit — surface the rollback explicitly to the user.

**Cascading failures:** if fixing the current step's failure introduces a new failure in a previously-passing area, treat the cascade as evidence that the plan or the step's scope is wrong, not as another iteration. After **one** attempted cascade fix that doesn't restore green, stop. Either trigger the plan revision protocol (`AGENTS.md` §2), hand off to **b-debug** for root-cause, or surface the cascade to the user. Do not burn the iteration cap chasing cascades.

Apply the iteration cap from `AGENTS.md` §7.

### Step 5 — Record progress and finish cleanly

After a step passes verification:
- Update saved-plan checkboxes when present. If the saved plan predates checkbox-style steps, append a short progress note under the completed step instead of rewriting the whole plan format.
- For frontmatter plans, set `status: in-progress` after the first completed step and `status: complete` only when every approved step is done.
- Keep the diff limited to approved scope.
- Continue to the next step only if there is one.

**Step atomicity:** a step is normally an independently-verifiable unit and should pass its own check before the next step begins. The exception is a **tightly coupled group** (e.g., split a function and immediately update its one caller) where intermediate verification would fail by design. The plan must mark such groups explicitly ("Steps 3a–3c verify together"); otherwise treat each step as atomic. Never silently merge atomic steps to dodge a failing check.

At the end:
- Inspect `git diff`.
- Run the final relevant verification.
- For non-trivial changes, emit an `AGENTS.md` §9 handoff recommending **b-review**.
- Close with the skill-exit status block (`AGENTS.md` §9).

## Rules

- Implement only approved or clearly scoped work.
- Preserve unrelated user changes.
- Do not add opportunistic refactors, compatibility code, or side cleanup.
- Stop for new decisions instead of guessing.
- A small direct request must still pass a real verification step.
- Do not commit unless explicitly asked.
- When the plan is wrong, revise it via `AGENTS.md` §2 — do not silently drift the implementation.
- Preserve durable plan metadata when editing saved plans; do not strip frontmatter while updating progress.

## Common rationalizations

- "I'll fix this adjacent thing while I'm here." → Only if it is required to satisfy the approved step or make verification pass; otherwise leave it as follow-up.
- "I'll verify after the whole feature lands." → Each step must prove itself before you carry its assumptions into the next step.
- "The framework behavior is obvious." → If docs drove the choice, cite the source instead of relying on memory.
