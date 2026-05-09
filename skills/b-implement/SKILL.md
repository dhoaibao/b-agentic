---
name: b-implement
description: >
  Execute approved plans safely. ALWAYS invoke when the user says "implement", "execute plan", "build this", "thực hiện", "làm theo plan", or after /b-plan approval. Reads `.opencode/b-plans/` or a chat plan, applies steps one at a time, verifies each step, and stops for new decisions. Unlike b-plan (decide), b-implement changes code.
compatibility: opencode
metadata:
  suite: b-skills
---

# b-implement

$ARGUMENTS

Execute an approved plan with discipline: read the source of truth, apply the next
small step, verify it, update progress, and stop when a new decision is required.

If `$ARGUMENTS` is provided, treat it as the plan file path, task slug, or approved
chat-plan description. Do not ask the user to restate the plan unless the referenced
plan cannot be found or the implementation target is ambiguous.

## When to use

- A `/b-plan` chat plan or saved `.opencode/b-plans/[task-slug].md` has been approved.
- User says: "implement", "execute plan", "build this", "carry out the plan", "thực hiện", "làm theo plan".
- The task is already scoped and the next action is to modify code or docs.
- You need a disciplined step-by-step executor that verifies each completed step.

## When NOT to use

- Scope, acceptance criteria, or implementation approach is still unclear -> use **b-plan**.
- Something is broken at runtime -> use **b-debug**.
- The requested change is a concrete rename/extract/move/inline/delete -> use **b-refactor**.
- The task is only to write or fix tests -> use **b-test**.
- The task is only external docs or API lookup -> use **b-research**.

## Tools required

- `bash` — inspect git status/diff and run verification commands.
- `check_onboarding_performed`, `onboarding`, `find_symbol`, `get_symbols_overview`, `find_referencing_symbols`, `replace_symbol_body`, `insert_before_symbol`, `insert_after_symbol`, `rename_symbol`, `safe_delete_symbol` — from `serena` MCP server *(preferred for symbol discovery and code edits)*.
- `resolve-library-id`, `query-docs` — from `context7` MCP server *(optional, for narrow library/API checks discovered during implementation)*.
- `sequentialthinking` — from `sequential-thinking` MCP server *(optional, for resolving step-order ambiguity or failure triage)*.

If Serena is unavailable: use native Glob/Grep/Read plus apply_patch-style edits. Note: "WARNING: Serena unavailable — symbol-aware impact tracking is reduced."
If context7 is unavailable: use /b-research for library/API uncertainty instead of guessing.
If sequential-thinking is unavailable: triage inline as `Step -> Failure -> Likely cause -> Next action`.

Graceful degradation: ✅ Possible — implementation can proceed with native file tools, but broad symbol changes are riskier without Serena.

## Steps

### Step 1 — Load the source of truth

Resolve the implementation source in this order:

1. `$ARGUMENTS` points to a `.md` file -> read that plan.
2. `$ARGUMENTS` names a slug -> read `.opencode/b-plans/[slug].md`.
3. `$ARGUMENTS` contains a complete approved chat plan -> use that text directly.
4. No usable source -> ask: "Which approved plan should I implement? Provide a `.opencode/b-plans/...` path, task slug, or paste the approved chat plan."

Extract:
- Confirmed decisions.
- Planned touch points.
- Ordered steps and dependencies.
- Each step's `Done when` verification.
- Unknowns that must be resolved before coding.

If the plan contains unresolved `Need decision` items, ask the user before editing.

---

### Step 2 — Check working state

Run `git status --short` and inspect only the files relevant to the current step.

- If unrelated files are dirty: leave them alone.
- If a planned file already has unrelated edits: read the affected section carefully and preserve those edits.
- If user edits directly conflict with the planned change: stop and ask how to proceed.

Choose the next unchecked or unimplemented step whose dependencies are complete. Work on one step at a time.

---

### Step 3 — Implement one step

For code changes, initialize Serena project knowledge first: call `check_onboarding_performed`; if onboarding has not been performed, call `onboarding` once.

Follow this order:

1. Locate the named symbol or file from the plan.
2. Use `get_symbols_overview` before opening large source files.
3. Use `find_referencing_symbols` when the step changes exported/shared behavior.
4. Apply the smallest edit that satisfies the step.
5. Do not add unplanned abstractions, features, cleanup, or compatibility code.

If implementation reveals a new behavioral/product decision, stop and ask. Do not self-infer.

---

### Step 4 — Verify the step

Run the exact `Done when` command from the plan when available. If the plan lacks a command, run the narrowest relevant check for the touched area.

Classify failures:
- Implementation mistake -> fix within the current step and rerun the check.
- Test setup/assertion/mocking issue -> use **b-test**.
- Runtime/root-cause uncertainty -> use **b-debug**.
- Library/API uncertainty -> use `context7`; if unresolved, use **b-research**.

Maximum 3 fix iterations per step. After that, report what passed, what failed, and the remaining evidence.

---

### Step 5 — Record progress

After verification passes:

- If using a saved plan file, mark the completed checkbox for that step.
- Note any verification command and result in the final response.
- Keep the git diff limited to the current plan scope.

Then continue to the next dependency-ready step until all planned steps are complete or a blocker appears.

---

### Step 6 — Final pass

Before reporting completion:

1. Inspect `git diff` to confirm only planned files changed.
2. Run the final verification command from the plan, if present.
3. If the implementation is non-trivial, recommend `/b-review` before commit or PR.

Do not commit unless the user explicitly requested a commit.

---

## Output format

````
### b-implement: [task name]

**Plan source**: [path / chat plan / slug]
**Step progress**: [completed N/M, blocked at step X if applicable]

#### Changes
- `[file:line]` — [what changed and which plan step it satisfies]

#### Verification
```bash
[command]
```
[result]

#### Blockers / Decisions
- [none / question for user / unresolved failure]

#### Next
- [run /b-review, continue next step, or user decision needed]
````

---

## Rules

- Implement only approved scope. If scope is unclear, go back to `/b-plan`.
- Work one plan step at a time and verify before moving on.
- Never overwrite unrelated user changes.
- Never invent missing requirements or product decisions.
- Prefer symbol-aware edits for code and minimal apply_patch-style edits for prose/config.
- Do not refactor opportunistically while implementing a feature step.
- Do not commit unless explicitly asked.
- Never trigger destructive git commands.
