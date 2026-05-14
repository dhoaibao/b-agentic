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

Execute approved or clearly scoped work with discipline: load the source of truth, change the next smallest step, verify it, and stop when a new decision appears.

If `$ARGUMENTS` is present, treat it as the plan path, plan slug, approved chat plan, or **small direct request** as defined in `AGENTS.md` §3.

## When to use

- The user approved a saved plan or chat plan.
- The task is already scoped and the next action is to edit code or docs.
- The request meets the **small direct request** threshold from `AGENTS.md` §3 (≤3 files, no public contract, no sensitive path, no remaining design decision).

## When NOT to use

- The request fails the **small direct request** threshold and is not backed by an approved plan → use **b-plan**.
- The request is a named rename, extract, move, inline, or delete → use **b-refactor**.
- The task is only external lookup → use **b-research**.
- The task is only tests → use **b-test**.
- Something is broken and root cause is not confirmed → use **b-debug**.

## Boundary examples

- **Use b-implement:** "Implement the approved rate-limiting plan" or "wire the new settings copy into the existing page."
- **Use b-refactor instead:** "Rename `UserService` to `UserRepository` across the codebase" because the primary job is a mechanical transform.

## Tools required

- `bash` — inspect status, diff, and run verification commands.
- `serena-symbol-toolkit` *(preferred for symbol-aware edits)*
- `gitnexus-radar` *(optional, for shared-route/tool/exported-boundary changes)*
- `context7-docs` *(optional, for a narrow API uncertainty discovered mid-step)*

Fallbacks: `AGENTS.md` §4 MCP fallback ladder. If execution reveals a new research blocker, stop and use **b-research**.

Graceful degradation: ✅ Possible — native tools can still implement, but broad symbol changes are riskier without Serena.

## Steps

### Step 1 — Load the source of truth

Resolve scope in this order:
1. A saved plan path under `.opencode/b-skills/b-plan/`.
2. A plan slug under `.opencode/b-skills/b-plan/` (resolved via the slug algorithm in `AGENTS.md` §8).
3. An explicitly approved chat plan.
4. A request that meets the **small direct request** threshold (`AGENTS.md` §3).

If the request fails the threshold and no plan exists, stop and route to **b-plan** via the handoff envelope (`AGENTS.md` §9).

Apply the **plan staleness gate** (`AGENTS.md` §2) before executing. A stale plan must be re-planned, not improvised against.

Extract only what execution needs: frontmatter approval state when present, confirmed decisions, planned touch points, ordered steps or the single scoped request, verification expectations, unresolved blockers.

For saved plans with frontmatter, require `status: approved`, `status: in-progress`, or explicit approval in the current conversation before editing. If approval arrives in chat for a draft plan, update `status`, `approved_at`, and `approved_by` before the first source edit. Legacy plans without frontmatter may execute from explicit current-chat approval per `AGENTS.md` §2.

### Step 2 — Check the working state

Run `git status --short` and inspect only the files relevant to the current step.

- Leave unrelated changes alone (`AGENTS.md` §6 worktree safety).
- If the target file already has unrelated edits, patch around them.
- If user changes directly conflict with the approved scope, stop and ask.

If the request asks to implement, finish, or continue an approved plan, proceed through dependency-ready steps while verification passes and no new decision appears. If the request asks for only the next step, stop after one verified step. If the request is a small direct task, treat it as a one-step implementation; do not invent extra ceremony.

### Step 3 — Implement the next smallest step

Use `serena-symbol-toolkit` for symbol-aware edits and the cheapest discovery tool that closes the next question (`AGENTS.md` §4). Use `gitnexus-radar` only when the step crosses a shared route, tool, or exported boundary, subject to the freshness gate.

Apply the smallest edit that satisfies the step.

If the step turns into an unplanned rename, move, extract, inline, or delete → stop and hand off to **b-refactor**.

If a new behavioral or product decision appears → stop and ask.

If the plan itself is wrong (touch points missing, ordering incorrect, decisions invalidated by current code) → trigger the **plan revision protocol** in `AGENTS.md` §2. Do not improvise against the stale plan.

### Step 4 — Verify before moving on

Run the exact plan verification when available. Otherwise run the narrowest relevant check for the touched area, following the verification ladder in `AGENTS.md` §7.

Use `get_diagnostics_for_file` on the touched source file (production code, not just tests) before broader commands when the language supports it. Honor the LSP-coverage caveat in `AGENTS.md` §4.

Classify failures:
- Implementation mistake → fix and rerun.
- Test harness problem → **b-test**.
- Runtime/root-cause uncertainty → **b-debug**.
- Unresolved library/API behavior → `context7-docs`, then **b-research** if still unclear.
- External (CI down, registry outage, dep yanked) → record the blocker, do not retry inside the iteration cap.

**Mid-step rollback:** if a partial edit has left the tree in a broken state (compile failure, import cycle, half-renamed symbol) and the next iteration cannot move forward without first restoring a coherent baseline, stop attempting to push through. Either (a) finish the edit to a coherent state in one more focused pass, or (b) manually roll back only the edits made in the current step using patch-based reversals. If a file-level restore is truly required, stop and ask for approval first because it can discard unrelated user changes in the same path. Never leave the working tree mid-transform across a skill exit — surface the rollback explicitly to the user.

Apply the iteration cap from `AGENTS.md` §7.

### Step 5 — Record progress and finish cleanly

After a step passes verification:
- Update saved-plan checkboxes when present. If the saved plan predates checkbox-style steps, append a short progress note under the completed step instead of rewriting the whole plan format.
- For frontmatter plans, set `status: in-progress` after the first completed step and `status: complete` only when every approved step is done.
- Keep the diff limited to approved scope.
- Continue to the next step only if there is one.

At the end:
- Inspect `git diff`.
- Run the final relevant verification.
- For non-trivial changes (`AGENTS.md` §3), emit a handoff envelope (`AGENTS.md` §9) recommending **b-review**.
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
