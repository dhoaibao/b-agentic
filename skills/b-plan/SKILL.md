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

- `serena-symbol-toolkit` - inspect existing code when the plan depends on current structure.
- `context7-docs` - one narrow versioned API check when it changes the plan.
- `firecrawl-extraction` - user-provided public docs or issue URLs when exact text changes scope.

## Steps

1. State the interpreted goal, constraints, and non-goals.
2. Ask only blocking questions. Prefer repo evidence over questions.
3. Inspect only files/symbols needed to avoid guessing.
4. Choose the smallest safe approach and list ordered steps.
5. Include `Done when` verification for each step.

For plans spanning more than 3 files, public contracts, dependencies, CI/build, or durable coordination, save a plan under `.b-agentic/b-plan/` only if it will materially help execution.

## Output format

Concise scope, risk, ordered steps, and verification. Ask for approval before implementation.

## Rules

- Do not implement.
- Keep plans short unless risk requires detail.
- Do not invent behavior, names, acceptance criteria, or commands.
- Surface assumptions and blockers explicitly.
