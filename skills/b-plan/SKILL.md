---
name: b-plan
description: >
  Think before coding when the goal is already clear but the task is
  non-trivial per CLAUDE.md section 3, the implementation approach or
  sequencing matters, or the user explicitly asks for a plan, architecture
  direction, or ordered implementation steps. Decomposes work, chooses an
  approach, and writes an execution-ready plan. Unlike b-spec, b-plan sequences
  a clear target rather than discovering it.
argument-hint: "[task]"
disable-model-invocation: true
---

# b-plan

$ARGUMENTS

Turn a clear goal into the smallest execution-ready plan. Do not implement.

If `$ARGUMENTS` is present, treat it as the task description and proceed.

## When to use

- The task is non-trivial under `CLAUDE.md` section 3.
- The goal is clear, but approach, sequencing, risk, or dependencies matter.
- The user asks for a plan, architecture direction, or ordered implementation steps.
- A refactor is still broad or vague and not yet a concrete mechanical transform.

## When NOT to use

- The end state is unclear -> use **b-spec**.
- The request is small, obvious, and scoped -> use **b-implement**.
- A concrete rename, extract, move, inline, simplify, or delete is requested -> use **b-refactor**.
- External feasibility blocks the decision -> use **b-research**.
- Something is broken -> use **b-debug**.

## Tools required

- `serena-symbol-toolkit` *(preferred for planning against existing code)*
- `gitnexus-radar` *(optional, for graph-shaped planning)*
- `context7-docs` *(optional, for one narrow API check)*
- `firecrawl-extraction` *(optional, for a user-provided issue or ticket URL)*

If required tools are unavailable, read `${CLAUDE_SKILL_DIR}/references/b-agentic/runtime-contract.md` §4 before applying fallbacks. Graceful degradation: possible with native reads and reasoning.

## Steps

### Step 1 - Choose quick or full mode

- **Quick mode:** default for low-risk scoped work. Return a short chat plan and ask for approval.
- **Full mode:** use only for non-trivial work, real structural choice, public/sensitive risk, or durable coordination need. Read `${CLAUDE_SKILL_DIR}/references/b-agentic/runtime-contract.md` §6 and §8 before saving a plan under `.b-agentic/b-plan/<plan-file-slug>.md`.

Default to quick mode when the plan is low/trivial risk, fits in chat, and can be executed in one coherent session. Do not promote to full mode solely because the task has several routine substeps. Use full mode when the plan needs durable approval, spans sessions, has more than about five meaningful steps, has unresolved dependencies, or discovery reveals broad references, public contracts, security-sensitive behavior, deployment risk, or a plan that is no longer readable in chat.

### Step 2 - Lock scope and decisions

State the interpreted scope in one sentence. If the goal or acceptance criteria are ambiguous, hand off to **b-spec**.

If the user explicitly waives planning ("just implement it", "skip the plan"), check the small-direct threshold. If it passes, log the waiver and hand off to **b-implement** with the interpreted scope and `confidence: low — user waived plan`. If it fails the threshold, explain why a plan is needed for safe execution; if the user still insists, log the override and produce a minimal chat plan.

Ask only for missing inputs that change safe planning: hard constraints, deployment/order constraints, required verification, or behavioral decisions the codebase cannot answer.

Keep assumptions from `b-spec` visible. Move them to confirmed decisions only after explicit user confirmation.

### Step 3 - Scan existing code only when useful

Skip code discovery for greenfield or docs-only work. Otherwise use the lightest tool that answers the next planning question:

- GitNexus only for graph-shaped subsystem, route, consumer, or process-flow questions.
- Serena/native tools for exact owners, declarations, references, nearby conventions, and stable anchors for prose/config edits.

### Step 4 - Choose an approach when there is a real choice

If multiple viable approaches matter, compare 2-3 options, pick one, and record why. If the approach is obvious, do not invent alternatives.

### Step 5 - Write dependency-ordered steps

Each step states changes, exact paths/symbols when known, why it comes now, and `Done when` verification. Quick plans should usually stay to 2-5 bullets. Use stable anchors for prose/config plans instead of long quoted text.

Full-mode steps use checkbox style so **b-implement** can update progress:

```markdown
## Steps
- [ ] **<imperative step title>**
  - Changes: <files or symbols>
  - Why now: <ordering reason>
  - Done when: <verification>
```

Read `${CLAUDE_SKILL_DIR}/reference.md` before writing a quick-plan template, saved-plan skeleton, supersede rule, or multi-plan dependency.

### Step 6 - Deliver and request approval

Quick mode stays in chat. For full mode, read `${CLAUDE_SKILL_DIR}/references/b-agentic/runtime-contract.md` §2 before writing durable frontmatter. Show the path and ask for approval.

If approval arrives during the same run, update `status`, `approved_at`, `approved_by`, and `approved_head` when available.

## Output format

- Quick mode: concise chat plan with scope, risk, steps, and verification.
- Full mode: saved Markdown plan using `reference.md`.

Read `${CLAUDE_SKILL_DIR}/references/b-agentic/runtime-contract.md` §9 before closing a non-trivial planning run with a status block.

## Rules

- Do not implement while planning.
- Keep quick plans lean; promote to full mode when the plan grows risk or coordination needs.
- Read `${CLAUDE_SKILL_DIR}/references/b-agentic/runtime-contract.md` §2 and §8 before applying slug, artifact, staleness, revision, or saved-plan filename rules.
- Surface blockers and assumptions explicitly.
- If the user waives planning, log the waiver and lower confidence; never proceed without scope confirmation on non-trivial work.
- Approved plans are the execution source of truth for **b-implement**.
