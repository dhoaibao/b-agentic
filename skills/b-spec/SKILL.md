---
name: b-spec
description: >
  Clarify what to build before planning when the request is underspecified, the
  desired end state or acceptance criteria are unclear, or the user has a rough
  idea that needs a concrete scope. Extract goals, constraints, and success
  criteria, then hand off to b-plan or b-implement. Unlike b-plan, b-spec
  decides the target outcome before sequencing work.
argument-hint: "[rough-request]"
---

# b-spec

$ARGUMENTS

Clarify the target outcome before planning or coding. Keep the loop short and make assumptions visible.

If `$ARGUMENTS` is present, treat it as the rough request and proceed directly.

## When to use

- The end state, acceptance criteria, constraints, or non-goals are unclear.
- The user has a rough idea that needs to become plannable.
- The codebase can inform terminology or current behavior, but not the user's intent.

## When NOT to use

- The goal is clear and sequencing matters -> use **b-plan**.
- The request is small, obvious, and implementation-ready -> use **b-implement**.
- The blocker is external docs or vendor feasibility -> use **b-research**.
- Something is broken -> use **b-debug**.

## Tools required

- `serena-symbol-toolkit` *(optional, for local behavior, ownership, or naming evidence before asking)*
- `gitnexus-radar` *(optional, for unfamiliar shared surfaces or route/tool context)*
- `context7-docs` *(optional, for one narrow feasibility check)*

If required tools are unavailable, read `${CLAUDE_SKILL_DIR}/references/b-agentic/runtime-contract.md` §4 before applying fallbacks. Graceful degradation: possible with native reads and a short clarification loop.

## Steps

### Step 1 - Confirm this is a spec problem

Stay in **b-spec** only while the target outcome is underdetermined.

- If the target is clear and the work is small, hand off to **b-implement**.
- If the target is clear but the work needs sequencing, hand off to **b-plan**.
- If two or more plausible outcomes remain, continue.

### Step 2 - Clarify the outcome

Restate the ask in one sentence, then ask only what blocks a concrete spec:

- user-visible outcome
- hard constraints
- success criteria
- non-goals when scope could sprawl

Read `${CLAUDE_SKILL_DIR}/references/b-agentic/runtime-contract.md` §1 before applying the clarification budget. Prefer one blocking question at a time when the answer changes the next question. After two unresolved rounds, stop asking open questions: offer two concrete interpretations with named assumptions and ask the user to pick or override.

### Step 3 - Use local evidence before asking

Before asking the user something the repo can answer, inspect nearby code, naming, docs, or ownership. If `CONTEXT.md` or `CONTEXT-MAP.md` exists, reuse its terminology and surface contradictions with code instead of guessing.

If the remaining blocker is external feasibility, hand off to **b-research**.

### Step 4 - Produce the spec and hand off

Return a compact chat spec by default:

```text
### Spec: <goal>

**Goal:** <what should exist or change>
**Constraints:** <hard boundaries>
**Acceptance criteria:**
- <testable outcome>
**Non-goals:** <excluded scope>
**Assumptions:** <unconfirmed assumptions, or none>
**Next:** <b-plan | b-implement | b-research>
```

Read `${CLAUDE_SKILL_DIR}/references/b-agentic/runtime-contract.md` §9 before emitting a handoff envelope when another skill owns the next step. Carry confirmed decisions and assumptions into that envelope.

## Output format

Use the compact spec shape above. Saved artifacts are not created unless the user explicitly asks.

Read `${CLAUDE_SKILL_DIR}/references/b-agentic/runtime-contract.md` §9 before closing a non-trivial spec run with a status block.

## Rules

- Clarify the outcome; do not plan or implement here.
- Prefer repo evidence over extra questions when the repo already answers the ambiguity.
- Keep assumptions explicit; never turn them into confirmed decisions without user confirmation.
- If external feasibility blocks the spec, use **b-research** instead of guessing.
