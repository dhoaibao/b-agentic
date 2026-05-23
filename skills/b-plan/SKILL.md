---
name: b-plan
description: >
  Turn goals into execution-ready plans. Handles both underspecified
  requests (clarify first) and clear goals (plan directly). Decomposes
  work, chooses an approach, and writes ordered steps. Unlike b-implement,
  b-plan does not change code.
argument-hint: "[task]"
---

<!-- Generated from skills/registry.yaml and skills/b-plan/prompt.md. Edit those sources, not this file. -->

# b-plan

$ARGUMENTS

Turn a goal into the smallest execution-ready plan. Clarify first when the target is unclear. Do not implement.

If `$ARGUMENTS` is present, treat it as the task description and proceed.

## When to use

- The task is non-trivial under the shared §3 glossary.
- The goal is clear, but approach, sequencing, risk, or dependencies matter.
- The end state, acceptance criteria, constraints, or non-goals are unclear.
- The user asks for a plan, architecture direction, or ordered implementation steps.
- A refactor is still broad or vague and not yet a concrete mechanical transform.

## When NOT to use

- The request is small, obvious, and scoped -> use **b-implement**.
- A concrete rename, extract, move, inline, simplify, or delete is requested -> use **b-refactor**.
- External feasibility blocks the decision -> use **b-research**.
- Something is broken -> use **b-debug**.

## Tools required

- `serena-symbol-toolkit` *(preferred for planning against existing code)*
- `gitnexus-radar` *(optional, for graph-shaped planning)*
- `context7-docs` *(optional, for one narrow API check)*
- `firecrawl-extraction` *(optional, for a user-provided issue or ticket URL)*


## Steps

### Step 1 - Choose quick or full mode

- **Quick mode:** default for low-risk scoped work. Return a short chat plan and ask for approval.
- **Full mode:** use only for non-trivial work, real structural choice, public/sensitive risk, or durable coordination need. Read `${CLAUDE_SKILL_DIR}/references/b-agentic/contract/06-safety.md` and `${CLAUDE_SKILL_DIR}/references/b-agentic/contract/08-artifacts.md` before saving a plan under `.b-agentic/b-plan/<plan-file-slug>.md`.

Default to quick mode when the plan is low/trivial risk, fits in chat, and can be executed in one coherent session. Do not promote to full mode solely because the task has several routine substeps. Use full mode when the plan is non-trivial per the shared §3 glossary (touches more than 3 files, a public contract, a sensitive path, CI/build config, or adds/changes a dependency), needs durable approval, spans sessions, has unresolved dependencies, or discovery reveals broad references, security-sensitive behavior, deployment risk, or a plan that is no longer readable in chat.

### Step 2 - Lock scope and decisions

State the interpreted scope in one sentence. If the goal or acceptance criteria are ambiguous, enter **Clarification mode** (below) before planning.

If the user explicitly waives planning ("just implement it", "skip the plan"), check the small-direct threshold. If it passes, log the waiver and hand off to **b-implement** with the interpreted scope and `confidence: low — user waived plan`. If it fails the threshold, explain why a plan is needed for safe execution; if the user still insists, log the override and produce a minimal chat plan.

Ask only for missing inputs that change safe planning: hard constraints, deployment/order constraints, required verification, or behavioral decisions the codebase cannot answer.

Keep assumptions visible. Move them to confirmed decisions only after explicit user confirmation.

### Step 3 - Scan existing code only when useful

Skip code discovery for greenfield or docs-only work. Otherwise use the lightest tool that answers the next planning question:

- GitNexus only for graph-shaped subsystem, route, consumer, or process-flow questions.
- Serena/native tools for exact owners, declarations, references, nearby conventions, and stable anchors for prose/config edits.
- For small or obvious 1-3 file plans, keep discovery local; do not spend MCP budget unless shared-boundary risk appears.
- For cross-module, exported, or route/tool planning, do at most one targeted GitNexus pass to map blast radius, then switch back to Serena/native tools for exact files and symbols.
- Use Context7 only when a versioned third-party API detail changes the plan, step ordering, or acceptance criteria; otherwise keep planning grounded in repo evidence.
- Use Firecrawl only for user-provided issue/ticket/docs URLs where exact remote text affects scope; do not turn ordinary planning into open-web research.

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

Quick mode stays in chat. For full mode, read `${CLAUDE_SKILL_DIR}/references/b-agentic/contract/02-source-of-truth.md` before writing durable frontmatter. Show the path and ask for approval.

If approval arrives during the same run, update `status`, `approved_at`, `approved_by`, and `approved_head` when available.

## Clarification mode

Use this sub-mode when the target outcome is underdetermined. Clarify before planning; do not sequence work until the goal is concrete.

### C1 - Confirm this is a clarification problem

- If the target is clear and the work is small, hand off to **b-implement**.
- If the user explicitly waives clarification ("just do it", "skip spec"), log the waiver, restate the interpreted scope and assumptions, lower confidence, and hand off to **b-implement** or continue planning accordingly.
- If two or more plausible outcomes remain, continue.

### C2 - Ask only blocking questions

Restate the ask in one sentence, then ask only what blocks a concrete spec:

- user-visible outcome
- hard constraints
- success criteria
- non-goals when scope could sprawl

Read `${CLAUDE_SKILL_DIR}/references/b-agentic/contract/01-routing.md` before applying the clarification budget. Prefer one blocking question at a time when the answer changes the next question. After two unresolved rounds, stop asking open questions: offer two concrete interpretations with named assumptions and ask the user to pick or override.

### C3 - Use local evidence before asking

Before asking the user something the repo can answer, inspect nearby code, naming, docs, or ownership. If `CONTEXT.md` or `CONTEXT-MAP.md` exists, reuse its terminology and surface contradictions with code instead of guessing.

If the remaining blocker is external feasibility, hand off to **b-research**.

### C4 - Produce the spec and continue

Return a compact chat spec:

```text
### Spec: <goal>

**Goal:** <what should exist or change>
**Constraints:** <hard boundaries>
**Acceptance criteria:**
- <testable outcome>
**Non-goals:** <excluded scope>
**Assumptions:** <unconfirmed assumptions, or none>
```

Carry confirmed decisions and assumptions back into the plan. Do not hand off to a separate skill.

## Output format

- Quick mode: concise chat plan with scope, risk, steps, and verification.
- Full mode: saved Markdown plan using `reference.md`.


## Rules

- Do not implement while planning.
- Keep quick plans lean; promote to full mode when the plan grows risk or coordination needs.
- Read `${CLAUDE_SKILL_DIR}/references/b-agentic/contract/02-source-of-truth.md` and `${CLAUDE_SKILL_DIR}/references/b-agentic/contract/08-artifacts.md` before applying slug, artifact, staleness, revision, or saved-plan filename rules.
- Surface blockers and assumptions explicitly.
- If the user waives planning, log the waiver and lower confidence; never proceed without scope confirmation on non-trivial work.
- Approved plans are the execution source of truth for **b-implement**.
- In Clarification mode: prefer repo evidence over extra questions; keep assumptions explicit; if external feasibility blocks the spec, use **b-research** instead of guessing.
