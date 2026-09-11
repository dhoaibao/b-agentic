---
name: b-plan
description: >
  Turn goals into execution-ready plans. Handles both underspecified
  requests and fuzzy problem statements by investigating enough to compare
  options, choose a path, and write ordered steps. Unlike b-implement,
  b-plan does not change code. Routing signals: plan, decompose, approach,
  explore, not sure, figure out, "how should I", implementation plan,
  clarify, requirements, scope.
---

<!-- Generated from skills/registry.yaml and skills/b-plan/prompt.md. Edit those sources, not this file. -->

# b-plan

Turn an unclear goal into the smallest execution-ready plan. Do not implement.

## When to use

- The user asks for a plan, approach, decomposition, or requirements clarification.
- Scope, acceptance criteria, risk, sequencing, or constraints are unclear.

## When NOT to use

- A small clear non-UI change -> **b-implement**.
- Clearly scoped frontend/UI work -> **b-frontend**.
- External facts are the blocker -> **b-research**.
- A runtime failure needs diagnosis -> **b-debug**.

## Tool guidance

- Use native `read` and local search for routine evidence. Select CodeGraph [cap: mcp.codegraph] only for a concrete repository-wide architecture, impact, or affected-test question. Recover compacted prior planning context only from a supplied memory ID.

## Steps

1. State the interpreted goal, constraints, non-goals, and success criteria.
2. Inspect only the local evidence needed to avoid guessing. Select CodeGraph only for a concrete central repository-wide question; use an available index or state the fallback gap.
3. For non-trivial or risky work, compare viable paths and relevant quality dimensions, including the simpler option, then recommend the smallest safe one with evidence-backed rationale and accepted trade-offs. Keep small obvious tasks free of forced comparison or research.
4. Specify ordered implementation steps, affected paths/symbols, invariants, and `Done when` verification that proves observable behavior.
5. For a material user-facing decision, resolve it directly with `ask_user_question` [cap: package.pi-ask-user-question] using 2–4 concrete options and a recommended first option; otherwise ask one focused plain-text fallback when unavailable. Ask for user approval before implementation.
6. Return the approved plan to the user covering scope, acceptance, affected paths, invariants, verification, risks, and open items.
7. For non-trivial changed work, include the future candidate-review gate: freeze the exact tracked plus relevant untracked/derived snapshot, pass fresh required checks, then obtain independent **b-review**. This is not authorization to commit or push.

## Output format

Concise scope, recommended path, ordered steps, verification, and explicit blockers. Ask for approval before implementation.

## Rules

- Do not implement.
- Keep plans short unless risk requires detail.
- Do not invent behavior, names, acceptance criteria, or commands.
- Resolve planning decisions directly with the user; review-specific auxiliary research remains bounded to substantiating a concrete finding.
