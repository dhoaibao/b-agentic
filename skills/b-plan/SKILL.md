---
name: b-plan
description: >
  Think before coding. ALWAYS invoke when the task is non-trivial per
  global/AGENTS.md §3, scope or acceptance is unclear, or the user explicitly
  asks for a plan, architecture direction, or ordered implementation steps.
  Decomposes work, chooses an approach, and writes an execution-ready plan.
  Unlike b-implement, b-plan decides what to build; it does not execute
  approved steps.
compatibility: opencode
metadata:
  suite: b-skills
---

# b-plan

$ARGUMENTS

Think before coding. Lock scope, choose the smallest viable approach, and produce a plan that a fresh agent can execute without re-deciding the work.

If `$ARGUMENTS` is present, treat it as the task description and proceed. Ask only for missing context that blocks safe planning.

## When to use

- The task is **non-trivial** per `global/AGENTS.md` §3.
- Scope or acceptance criteria are unclear.
- There are multiple valid approaches and the choice matters.
- The user wants a plan, architecture direction, or ordered implementation steps.
- A refactor is still vague and not yet a concrete rename, extract, move, inline, or delete.

## When NOT to use

- The request meets the **small direct request** threshold in `global/AGENTS.md` §3 → use **b-implement**.
- The user already approved a plan → use **b-implement**.
- The request is a concrete behavior-preserving mechanical transformation → use **b-refactor**.
- The blocker is external docs or library behavior → use **b-research**.
- Something is broken → use **b-debug**.

## Tools required

- `serena-symbol-toolkit` *(preferred for planning against existing code)*
- `gitnexus-radar` *(optional, for graph-shaped planning)*
- `context7-docs` *(optional, for a narrow library/API check discovered during planning)*
- `firecrawl-extraction` *(optional, for an issue or ticket URL the user already provided)*

Fallbacks: `global/AGENTS.md` §4 MCP fallback ladder. If the task depends on broader external research, stop and use **b-research** instead of stretching planning into research.

Graceful degradation: ✅ Possible — planning still works with native reads plus inline reasoning.

## Steps

### Step 1 — Pick the planning mode

Use the **non-trivial** definition (`global/AGENTS.md` §3) as the threshold:

- **Quick mode**: the task is trivial — single area, no public contract, no sensitive path, low risk. Return a concise chat plan with a verification step.
- **Full mode**: anything **non-trivial**, or where a real structural choice exists. Write a saved plan to `.opencode/b-skills/b-plan/<task-slug>.md` using the slug algorithm in `global/AGENTS.md` §8. Saved plans are canonical source-of-truth files and are not rerouted by the repo-local runtime-artifact fallback.

Choose the mode yourself. Only ask when both modes are genuinely valid and the user's preference changes the output.

Escalate quick → full if discovery reveals broad references, public contract risk, security-sensitive behavior, or deployment risk.

### Step 2 — Lock scope and decisions

State the interpreted scope in one sentence.

If the task is still ambiguous, ask the smallest set of questions that blocks safe planning:
- end state
- hard constraints
- success criteria

Record confirmed decisions as short implementation-ready statements. If a decision is behavioral, contractual, or naming-related and the codebase cannot answer it, ask the user.

If the task depends on unresolved external research that affects feasibility, architecture, contracts, security, or migration order, stop and use **b-research** before finishing the plan.

### Step 3 — Scan existing code when relevant

Skip this step for greenfield work.

- Use `gitnexus-radar` only when the area is graph-shaped or unfamiliar. Stop once the subsystem, route, consumer set, or boundary is clear.
- Use `serena-symbol-toolkit` to pin owners, declarations, references, or behavior. Pick the cheapest discovery tool for the next question per `global/AGENTS.md` §4.

If the user already provided an issue URL, you may extract it via `firecrawl-extraction` as planning context.

### Step 4 — Choose the approach only if it matters

If there is a real structural choice, list 2–3 viable approaches, compare them against the current constraints, pick one, and record why.

When a real alternative was considered and rejected, record it briefly in the plan under `## Confirmed decisions` (or a short `## Alternatives considered` block for full mode) — one line for the rejected option and one line for why it lost. This gives reviewers and future agents the rejected-option context without re-litigating it.

If the approach is obvious, skip this step. Do not invent fake alternatives.

### Step 5 — Decompose into execution steps

Produce dependency-ordered steps as short as the work actually is. Each step says:
- what changes
- exact file paths or symbol names when known
- why now
- `Done when` — how to verify

For saved plans, format execution steps as Markdown task-list items so progress can be updated in place during implementation.

For full-mode plans, follow this saved-plan skeleton:

```markdown
# <task title>

**Slug:** <task-slug>   (per global/AGENTS.md §8)
**Created:** <YYYY-MM-DD>
**Risk:** <trivial | low | medium | high>   (per global/AGENTS.md §3)

## Goal
<one paragraph stating the end state>

## Confirmed decisions
- <decision> — <one-line rationale>

## Planned touch points
- `<path>` — <what changes here>

## Dependencies
- <upstream constraint, feature flag, migration order, external readiness>

## Risks
- <risk> — <mitigation or accepted residual>

## Unknowns
- <open question> — <how it will be resolved or who owns it>

## Steps
- [ ] **<imperative step title>**
  - Changes: <files or symbols>
  - Why now: <ordering reason>
  - Done when: <verification>
...

## Verification
- <project-specific command or procedure>

## Rollback
- <how to revert if Step N fails after merge>   (only when real)

## Revisions
- <YYYY-MM-DD> — <one-line delta>   (added when the plan is revised)
```

Add deployment notes only when they are real: feature flags, migration order, external dependency readiness, or rollback risk.

If the task involves field mapping or protocol translation, add a small mapping outline instead of burying it in prose.

### Step 6 — Deliver the plan

**Quick mode:**
- Keep the plan in chat.
- Ask for approval.
- Hand approved execution to **b-implement** via the handoff envelope in `global/AGENTS.md` §9.

**Full mode:**
- Write an English plan to `.opencode/b-skills/b-plan/<task-slug>.md`.
- Show the saved path.
- Ask for approval.

The plan is complete only when a fresh agent could execute it without re-deriving the design.

### Step 7 — Revisions (if the user asks to revise)

Follow the **plan revision protocol** in `global/AGENTS.md` §2:
- Edit the plan file in place.
- Append the change to the `## Revisions` section with the date and a one-line delta.
- Re-request approval only when the revision changes confirmed decisions, planned touch points, or steps.

Close the run with the skill-exit status block (`global/AGENTS.md` §9).

## Rules

- Do not implement while planning.
- Keep quick plans lean; do not turn every small task into a full document.
- Save only full-mode plans to `.opencode/b-skills/b-plan/`. The legacy `.opencode/b-plans/` path is deprecated; do not write there.
- Use the slug algorithm in `global/AGENTS.md` §8; do not invent ad-hoc filenames.
- Surface blocking unknowns instead of hiding them in vague prose.
- Broad or unclear refactors stay in **b-plan** until they reduce to concrete mechanical steps for **b-refactor**.
- After approval, treat the approved plan as the execution source of truth (`global/AGENTS.md` §2). If the touched files change before execution begins, re-plan rather than improvise.
- Revisions go in place under `## Revisions`; never write `plan-v2.md`.
