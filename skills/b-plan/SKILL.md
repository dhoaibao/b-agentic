---
name: b-plan
description: >
  Think before coding. ALWAYS invoke when the goal is already clear but the
  task is non-trivial per AGENTS.md §3, the implementation approach or
  sequencing matters, or the user explicitly asks for a plan, architecture
  direction, or ordered implementation steps. Decomposes work, chooses an
  approach, and writes an execution-ready plan. Unlike b-spec, b-plan
  sequences a clear target rather than discovering it.
compatibility: opencode
metadata:
  suite: b-skills
---

# b-plan

$ARGUMENTS

Think before coding. Lock scope, pick the smallest viable approach, and produce an execution-ready plan.

If `$ARGUMENTS` is present, treat it as the task description and proceed. Ask only for missing context that blocks safe planning.

## When to use

- The task is **non-trivial** per `AGENTS.md` §3.
- The goal is clear, but sequencing, dependency order, or approach is not.
- There are multiple valid approaches and the choice matters.
- The user wants a plan, architecture direction, or ordered implementation steps.
- A refactor is still vague and not yet a concrete rename, extract, move, inline, or delete.

## When NOT to use

- The request meets the **small direct request** threshold in `AGENTS.md` §3 → use **b-implement**.
- The end state or acceptance criteria are still ambiguous → use **b-spec**.
- The user already approved a plan → use **b-implement**.
- The request is a concrete behavior-preserving mechanical transformation → use **b-refactor**.
- The blocker is external docs or library behavior → use **b-research**.
- Something is broken → use **b-debug**.

## Tools required

- `serena-symbol-toolkit` *(preferred for planning against existing code)*
- `gitnexus-radar` *(optional, for graph-shaped planning)*
- `context7-docs` *(optional, for a narrow library/API check discovered during planning)*
- `firecrawl-extraction` *(optional, for an issue or ticket URL the user already provided)*

Fallbacks: `AGENTS.md` §4. If broader external research is required, stop and use **b-research**. Graceful degradation: ✅ Possible — native reads plus reasoning still work.

## Steps

### Step 1 — Pick the planning mode

Use the **non-trivial** definition (`AGENTS.md` §3) as the threshold:

- **Quick mode:** trivial, single area, no public contract/sensitive path, low risk. Return a concise chat plan with verification.
- **Full mode:** non-trivial work or real structural choice. Apply the `.opencode/.gitignore` guard (`AGENTS.md` §6), then write `.opencode/b-skills/b-plan/<task-slug>.md` using `AGENTS.md` §8. Saved plans remain canonical source-of-truth files.

Choose the mode yourself. Only ask when both modes are genuinely valid and the user's preference changes the output.

Escalate quick → full if discovery reveals broad references, public contract risk, security-sensitive behavior, or deployment risk.

### Step 2 — Lock scope and decisions

State the interpreted scope in one sentence.

If the target outcome or acceptance criteria are still ambiguous after that restatement, stop and use **b-spec** before sequencing the work.

If the goal is clear but planning inputs are incomplete, ask the smallest set of questions that blocks safe planning:
- hard constraints
- sequencing or deployment constraints
- required verification expectations

Record confirmed decisions as short implementation-ready statements. If a decision is behavioral, contractual, or naming-related and the codebase cannot answer it, ask the user.

If the task depends on unresolved external research that affects feasibility, architecture, contracts, security, or migration order, stop and use **b-research** before finishing the plan.

### Step 3 — Scan existing code when relevant

Skip this step for greenfield work.

- Use `gitnexus-radar` only when the area is graph-shaped or unfamiliar. Stop once the subsystem, route, consumer set, or boundary is clear.
- Use `serena-symbol-toolkit` to pin owners, declarations, references, or behavior. Pick the cheapest discovery tool for the next question per `AGENTS.md` §4.

If the user already provided an issue URL, you may extract it via `firecrawl-extraction` as planning context.

### Step 4 — Choose the approach only if it matters

If there is a real structural choice, list 2–3 viable approaches, compare them against the current constraints, pick one, and record why.

When a real alternative is rejected, record it briefly under `## Confirmed decisions` or `## Alternatives considered`: option plus why it lost.

If the approach is obvious, skip this step. Do not invent fake alternatives.

### Step 5 — Decompose into execution steps

Produce dependency-ordered steps as short as the work actually is. Each step says: changes, exact paths/symbols when known, ordering reason, and `Done when` verification.

For prose-heavy or config-heavy edits, name stable anchors such as headings, keys, or symbols instead of quoting long paragraphs that may drift before implementation.

For saved plans, format execution steps as Markdown task-list items so progress can be updated in place during implementation.

**Quick-mode** chat plans follow the quick-plan template in `skills/b-plan/reference.md`. **Full-mode** saved plans follow the saved-plan skeleton in the same reference, including durable frontmatter from `AGENTS.md` §2. Do not invent ad-hoc plan shapes; both templates exist so progress and approval are mechanically inspectable.

Full-mode steps are written as Markdown task-list items so `b-implement` can update progress in place:

```markdown
## Steps
- [ ] **<imperative step title>**
  - Changes: <files or symbols>
  - Why now: <ordering reason>
  - Done when: <verification>
```

If the task depends on another plan, record it in `Dependencies` per the multi-plan rule in `skills/b-plan/reference.md`.

### Step 6 — Deliver the plan

**Quick mode:**
- Keep the plan in chat.
- Ask for approval.
- Hand approved execution to **b-implement** via the handoff envelope in `AGENTS.md` §9.

**Full mode:**
- Apply the `.opencode/.gitignore` guard from `AGENTS.md` §6, then write an English plan to `.opencode/b-skills/b-plan/<task-slug>.md`.
- Show the saved path.
- Ask for approval.
- If approval arrives in the same planning run, update the plan frontmatter in place: `status: approved`, `approved_at: <timestamp>`, `approved_by: user`, and `approved_head: <git-sha>` when the repo has a git HEAD.

The plan is complete only when a fresh agent could execute it without re-deriving the design.

### Step 7 — Revise or supersede (if the user asks to change an approved plan)

- **Revise** when the goal and most touch points survive. Follow the **plan revision protocol** in `AGENTS.md` §2: edit the plan file in place, append a one-line `## Revisions` entry, re-request approval only when the revision touches `Confirmed decisions`, `Planned touch points`, or `Steps`.
- **Supersede** when the goal itself changed or the approach is being replaced wholesale. Follow the supersede protocol in `skills/b-plan/reference.md`: set the old plan's `status: superseded`, create a new plan with a distinct slug, and reference the superseded plan in the new plan's `Dependencies` or `Goal`. Do not delete superseded plans.

Close the run with the skill-exit status block (`AGENTS.md` §9).

## Rules

- Do not implement while planning.
- Keep quick plans lean; do not turn every small task into a full document.
- Save only full-mode plans to `.opencode/b-skills/b-plan/` after applying the `.opencode/.gitignore` guard from `AGENTS.md` §6. The legacy `.opencode/b-plans/` path is deprecated; do not write there.
- Include the durable plan frontmatter from `AGENTS.md` §2 in new saved plans; legacy plans without frontmatter remain valid when explicitly approved in chat.
- Use the slug algorithm in `AGENTS.md` §8; do not invent ad-hoc filenames.
- Surface blocking unknowns instead of hiding them in vague prose.
- Broad or unclear refactors stay in **b-plan** until they reduce to concrete mechanical steps for **b-refactor**.
- After approval, treat the approved plan as the execution source of truth (`AGENTS.md` §2). If the touched files change before execution begins, re-plan rather than improvise.
- Revisions go in place under `## Revisions`; never write `plan-v2.md`.
