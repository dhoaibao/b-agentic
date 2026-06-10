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

- The user asks for a plan, architecture direction, or ordered implementation steps.
- The goal is clear but approach, sequencing, risk, dependencies, or acceptance criteria matter.
- Scope, constraints, non-goals, or end state are unclear.
- A refactor is still broad or vague and not yet a concrete mechanical transform.

## When NOT to use

- The request is small, obvious, and scoped -> use **b-implement**.
- A concrete rename, extract, move, inline, simplify, or delete is requested -> use **b-refactor**.
- External feasibility blocks the decision -> use **b-research**.
- Something is broken -> use **b-debug**.

## Tools required

- `serena-symbol-toolkit` - required for planning against existing code.
- `context7-docs` - use only for one narrow API check that changes the plan.
- `firecrawl-extraction` - use only for user-provided issue, ticket, or docs URLs whose exact text affects scope.
- Optional runtime subagent: `b-explore` may gather bounded repo evidence for broad plans. The active **b-plan** skill owns scope, decisions, saved-plan content, status, and handoff.

## Steps

### Step 1 - Choose mode

Use quick mode for low-risk plans that fit in chat. Use full mode when work touches more than 3 files, public/sensitive contracts, CI/build/dependencies, broad references, durable coordination, or a plan too large for chat. Full mode saves `.b-agentic/b-plan/<plan-file-slug>.md`.

When planning strict or stateful governance work, read `../../b-agentic/references/contract/state-machine.md` and name which runtime surfaces are enforced, advisory, or unsupported.

### Step 2 - Lock scope

State the interpreted scope in one sentence. If the outcome is underdetermined, enter Clarification mode before sequencing work.

If the user waives planning, check the small-direct threshold. If it passes, hand off to **b-implement** with assumptions and lowered confidence when decisions remain; otherwise produce a minimal plan and explain why planning is still needed.

Ask only for inputs that change safe planning: hard constraints, deployment order, required verification, or behavioral decisions the repo cannot answer. Keep assumptions visible until confirmed.

### Step 3 - Inspect only what helps the plan

Skip discovery for greenfield or docs-only work. Otherwise use local/Serena evidence for owners, references, conventions, and stable anchors. Use Context7 only for a versioned API detail that changes the plan. Use Firecrawl only for user-provided issue/ticket/docs URLs whose exact text affects scope.

**Serena discovery workflow for existing code:**
1. `get_symbols_overview` on a key file to understand its structure and identify relevant symbols.
2. `find_symbol` with `include_body=True` on the symbol(s) that own the behavior you need to plan around.
3. `find_referencing_symbols` on those symbols to understand call sites and coupling.

Use this sequence when the plan must account for existing implementations, interfaces, or call graphs. Skip it when the work is purely additive in a greenfield area.

### Step 4 - Choose approach and steps

Compare alternatives only when the choice matters. Steps must be dependency ordered and include changes, why now, and `Done when` verification.

Quick plans stay to 2-5 bullets. Full-mode steps use checkbox style:

```markdown
## Steps
- [ ] **<imperative step title>**
  - Changes: <files or symbols>
  - Why now: <ordering reason>
  - Done when: <verification>
```

Read `./reference.md` before writing a quick-plan template, saved-plan skeleton, supersede rule, or multi-plan dependency.

### Step 5 - Deliver

Quick mode stays in chat and asks for approval. Full mode must include durable frontmatter (`slug`, `status`, `created_at`, `approved_at`, `approved_by`, `approved_head`, `risk`, `touch_points`), show the path, and ask for approval. If state governance is active, request or initialize state through deterministic tooling rather than asking the model to hand-edit `.b-agentic/state.json`. Read `../../b-agentic/references/contract/output.md` before emitting a status block.

If approval arrives in the same run, update `status`, `approved_at`, `approved_by`, and `approved_head` when available.

## Clarification mode

Use when two or more plausible outcomes remain. Restate the ask, ask only blocking questions, and prefer repo evidence before asking. After two unresolved rounds, offer two concrete interpretations and ask the user to pick or override.

Return a compact spec:

```text
### Spec: <goal>

**Goal:** <what should exist or change>
**Constraints:** <hard boundaries>
**Acceptance criteria:**
- <testable outcome>
**Non-goals:** <excluded scope>
**Assumptions:** <unconfirmed assumptions, or none>
```

Carry confirmed decisions into the plan. If external feasibility blocks the spec, hand off to **b-research**.

## Output format

- Quick mode: concise chat plan with scope, risk, steps, and verification.
- Full mode: saved Markdown plan using `reference.md`.

## Rules

- Do not implement while planning.
- Subagents are optional accelerators; never require them for ordinary planning or let them own decisions, status blocks, or phase transitions.
- Keep quick plans lean; promote only for real risk or coordination need.
- Surface blockers and assumptions explicitly.
- Approved plans are the execution source of truth for **b-implement**.
- Strictness claims must distinguish enforced runtime surfaces from advisory-only guidance.
