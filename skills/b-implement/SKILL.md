---
name: b-implement
description: >
  Execute approved or scoped work safely. ALWAYS invoke after /b-plan
  approval, when the user asks to execute or implement scoped work, or when a
  small direct request meets the threshold in global/AGENTS.md §3. Reads the
  approved plan, applies the next small step, verifies it, and stops for new
  decisions. Unlike b-plan, b-implement changes code.
compatibility: opencode
metadata:
  suite: b-skills
---

# b-implement

$ARGUMENTS

Execute approved or clearly scoped work with discipline: load the source of truth, change the next smallest step, verify it, and stop when a new decision appears.

If `$ARGUMENTS` is present, treat it as the plan path, plan slug, approved chat plan, or **small direct request** as defined in `global/AGENTS.md` §3.

## When to use

- The user approved a saved plan or chat plan.
- The task is already scoped and the next action is to edit code or docs.
- The request meets the **small direct request** threshold from `global/AGENTS.md` §3 (≤3 files, no public contract, no sensitive path, no remaining design decision).

## When NOT to use

- The request fails the **small direct request** threshold and is not backed by an approved plan → use **b-plan**.
- The request is a named rename, extract, move, inline, or delete → use **b-refactor**.
- The task is only external lookup → use **b-research**.
- The task is only tests → use **b-test**.
- Something is broken and root cause is not confirmed → use **b-debug**.

## Tools required

- `bash` — inspect status, diff, and run verification commands.
- `serena-symbol-toolkit` *(preferred for symbol-aware edits)*
- `gitnexus-radar` *(optional, for shared-route/tool/exported-boundary changes)*
- `context7-docs` *(optional, for a narrow API uncertainty discovered mid-step)*

Fallbacks: `global/AGENTS.md` §4 MCP fallback ladder. If execution reveals a new research blocker, stop and use **b-research**.

Graceful degradation: ✅ Possible — native tools can still implement, but broad symbol changes are riskier without Serena.

## Steps

### Step 1 — Load the source of truth

Resolve scope in this order:
1. A saved plan path under `.opencode/b-skills/b-plan/`.
2. A plan slug under `.opencode/b-skills/b-plan/` (resolved via the slug algorithm in `global/AGENTS.md` §8).
3. An explicitly approved chat plan.
4. A request that meets the **small direct request** threshold (`global/AGENTS.md` §3).

If the request fails the threshold and no plan exists, stop and route to **b-plan** via the handoff envelope (`global/AGENTS.md` §9).

Apply the **plan staleness gate** (`global/AGENTS.md` §2) before executing. A stale plan must be re-planned, not improvised against.

Extract only what execution needs: confirmed decisions, planned touch points, ordered steps or the single scoped request, verification expectations, unresolved blockers.

### Step 2 — Check the working state

Run `git status --short` and inspect only the files relevant to the current step.

- Leave unrelated changes alone (`global/AGENTS.md` §6 worktree safety).
- If the target file already has unrelated edits, patch around them.
- If user changes directly conflict with the approved scope, stop and ask.

If the plan is multi-step, choose the next dependency-ready step. If the request is a small direct task, treat it as a one-step implementation; do not invent extra ceremony.

### Step 3 — Implement the next smallest step

Use `serena-symbol-toolkit` for symbol-aware edits and the cheapest discovery tool that closes the next question (`global/AGENTS.md` §4). Use `gitnexus-radar` only when the step crosses a shared route, tool, or exported boundary, subject to the freshness gate.

Apply the smallest edit that satisfies the step.

If the step turns into an unplanned rename, move, extract, inline, or delete → stop and hand off to **b-refactor**.

If a new behavioral or product decision appears → stop and ask.

If the plan itself is wrong (touch points missing, ordering incorrect, decisions invalidated by current code) → trigger the **plan revision protocol** in `global/AGENTS.md` §2. Do not improvise against the stale plan.

### Step 4 — Verify before moving on

Run the exact plan verification when available. Otherwise run the narrowest relevant check for the touched area, following the verification ladder in `global/AGENTS.md` §7.

Use `get_diagnostics_for_file` on the touched source file (production code, not just tests) before broader commands when the language supports it. Honor the LSP-coverage caveat in `global/AGENTS.md` §4.

Classify failures:
- Implementation mistake → fix and rerun.
- Test harness problem → **b-test**.
- Runtime/root-cause uncertainty → **b-debug**.
- Unresolved library/API behavior → `context7-docs`, then **b-research** if still unclear.
- External (CI down, registry outage, dep yanked) → record the blocker, do not retry inside the iteration cap.

**Mid-step rollback:** if a partial edit has left the tree in a broken state (compile failure, import cycle, half-renamed symbol) and the next iteration cannot move forward without first restoring a coherent baseline, stop attempting to push through. Either (a) finish the edit to a coherent state in one more focused pass, or (b) manually roll back only the edits made in the current step using patch-based reversals. If a file-level restore is truly required, stop and ask for approval first because it can discard unrelated user changes in the same path. Never leave the working tree mid-transform across a skill exit — surface the rollback explicitly to the user.

Apply the iteration cap from `global/AGENTS.md` §7.

### Step 5 — Record progress and finish cleanly

After a step passes verification:
- Update saved-plan checkboxes when present. If the saved plan predates checkbox-style steps, append a short progress note under the completed step instead of rewriting the whole plan format.
- Keep the diff limited to approved scope.
- Continue to the next step only if there is one.

At the end:
- Inspect `git diff`.
- Run the final relevant verification.
- For non-trivial changes (`global/AGENTS.md` §3), emit a handoff envelope (`global/AGENTS.md` §9) recommending **b-review**.
- Close with the skill-exit status block (`global/AGENTS.md` §9).

## Rules

- Implement only approved or clearly scoped work.
- Preserve unrelated user changes.
- Do not add opportunistic refactors, compatibility code, or side cleanup.
- Stop for new decisions instead of guessing.
- A small direct request must still pass a real verification step.
- Do not commit unless explicitly asked.
- When the plan is wrong, revise it via `global/AGENTS.md` §2 — do not silently drift the implementation.
