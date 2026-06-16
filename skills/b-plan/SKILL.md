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

Turn unclear or high-risk goals into the smallest executable plan. Do not implement.

## When to use

- The user asks for a plan, approach, design, decomposition, or requirements clarification.
- Scope, acceptance criteria, risk, sequencing, or ownership is unclear.
- The change is broad enough that direct implementation would require guessing.

## When NOT to use

- The request is small and clear -> use **b-implement**.
- The request is a concrete behavior-preserving transform -> use **b-refactor**.
- External facts are the blocker -> use **b-research**.
- Something is broken -> use **b-debug**.

## Tools required

- `serena` - inspect existing code when the plan depends on current structure.
- `context7` - one narrow versioned API check when it changes the plan.
- `firecrawl` - user-provided public docs or issue URLs when exact text changes scope.

## Steps

1. State the interpreted goal, constraints, and non-goals.
2. If multiple interpretations are plausible, present them briefly and choose only when the choice is low-risk; otherwise ask.
3. Inspect only files/symbols needed to avoid guessing. Read `CONTEXT.md`, `CONTEXT-MAP.md`, nearby `docs/adr/`, `docs/agents/`, or `.b-agentic/` notes when they are present and relevant.
4. Choose the smallest safe approach, surface material tradeoffs, and push back if a simpler or safer path exists.
5. Include `Done when` verification for each step that proves the intended observable outcome, not just command success.
6. For larger plans, tag steps only when useful: `AFK` for agent-ready work, `HITL` for user decision, approval, external access, or judgment.

For plans spanning more than 3 files, public contracts, dependencies, CI/build, or durable coordination, save a plan under `.b-agentic/b-plan/` only if it will materially help execution.

## Output format

Concise scope, risk, ordered steps, and verification. Ask for approval before implementation.

## Rules

- Do not implement.
- Keep plans short unless risk requires detail.
- Do not invent behavior, names, acceptance criteria, or commands.
- Do not require project context docs or HITL/AFK markers for ordinary small plans.
- Surface assumptions and blockers explicitly.
