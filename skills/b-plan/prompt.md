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

- Use Pi native `read` and local search for routine evidence. Select CodeGraph only for a concrete repository-wide architecture, impact, or affected-test question. Recover compacted prior planning context only from a supplied memory ID.

## Steps

1. State the interpreted goal, constraints, non-goals, and success criteria.
2. Inspect only the local evidence needed to avoid guessing. Select CodeGraph only for a concrete central repository-wide question; use an available index or state the fallback gap.
3. For non-trivial or risky work, compare viable paths and relevant quality dimensions, including the simpler option, then recommend the smallest safe one with evidence-backed rationale and accepted trade-offs. Keep small obvious tasks free of forced comparison or research.
4. Specify ordered implementation steps, affected paths/symbols, invariants, and `Done when` verification that proves observable behavior.
5. For a material user-facing decision, resolve it directly with `ask_user_question` using 2–4 concrete options and a recommended first option; otherwise ask one focused plain-text fallback when unavailable. Ask for user approval before implementation.
6. In the explicit architect/Architect role, if an Executor `ask` triggered the plan, after the user approves it answer that originating request with `reply`; if the triggered turn has ended, inspect `pending` and use the exact `replyTo`. Only when no inbound ask exists, before initiating a new thread obtain a fresh `list-cwd` with the absolute project `cwd`; it must show exactly one other peer. Use exactly one proactive `send` with that `cwd` and omit `to` for the compact approved-plan handoff covering scope, acceptance, affected paths, invariants, verification, risks, and open items. This is not a blocking exchange: do not issue an `ask` or pair `send` plus `ask`. Zero/multiple peers, missing Intercom, or an ambiguous roster is a coordination gap. The Architect remains read-only. In Off mode, return the approved plan without an automatic handoff.
7. For non-trivial changed work, include the future candidate-review gate: freeze the exact tracked plus relevant untracked/derived snapshot, pass fresh required checks, then obtain independent **b-review**. This is not authorization to commit or push.

## Output format

Concise scope, recommended path, ordered steps, verification, and explicit blockers. Ask for approval before implementation.

## Rules

- Do not implement.
- Keep plans short unless risk requires detail.
- Do not invent behavior, names, acceptance criteria, or commands.
- The Architect directly resolves planning decisions and remains read-only; the Executor receives an approved plan rather than relaying those decisions. Review-specific auxiliary research remains bounded to substantiating a concrete finding.
