---
name: b-spec
description: >
  Clarify what to build before planning. ALWAYS invoke when the request is
  underspecified, the desired end state or acceptance criteria are unclear, or
  the user has a rough idea that needs a concrete scope. Extract goals,
  constraints, and success criteria, then hand off to b-plan or b-implement.
  Unlike b-plan, b-spec decides the target outcome before sequencing work.
compatibility: opencode
metadata:
  suite: b-skills
---

# b-spec

$ARGUMENTS

Clarify the end state before planning or coding. Turn a rough ask into a concrete goal, constraints, and acceptance criteria.

If `$ARGUMENTS` is present, treat it as the rough request and proceed directly. Ask only the smallest questions needed to make the target outcome concrete.

## When to use

- The request is underspecified or has multiple plausible interpretations.
- The desired end state, acceptance criteria, or non-goals are still unclear.
- The user has a rough feature idea and needs it turned into something plannable.
- The codebase context may answer part of the ambiguity, but not the intended outcome.

## When NOT to use

- The goal is already clear and the next question is sequencing or implementation approach → use **b-plan**.
- The request already meets the **small direct request** threshold in `AGENTS.md` §3 and the behavior is obvious → use **b-implement**.
- The blocker is external feasibility, vendor docs, or library behavior → use **b-research**.
- Something is broken and needs diagnosis → use **b-debug**.

## Tools required

- `serena-symbol-toolkit` *(preferred for checking existing behavior, ownership, or nearby conventions before asking the user)*
- `gitnexus-radar` *(optional, for unfamiliar shared surfaces or route/tool context)*
- `context7-docs` *(optional, for a narrow feasibility check discovered during clarification)*

Fallbacks: `AGENTS.md` §4. If clarification reveals a genuine external-knowledge blocker, stop and use **b-research**. Graceful degradation: ✅ Possible — native reads plus a short clarification loop still work.

## Steps

### Step 1 — Decide whether discovery is actually needed

Stay in **b-spec** only while the target outcome is underdetermined.

- If the goal, constraints, and success criteria are already clear, hand off immediately:
  - **b-implement** when the request meets the **small direct request** threshold in `AGENTS.md` §3.
  - **b-plan** when the work is non-trivial and the open question is how to sequence it.
- If two or more plausible outcomes remain, continue.

### Step 2 — Clarify the target outcome

Restate the ask in one sentence, then ask only the blocking questions needed to lock:

- user-visible outcome
- hard constraints
- success criteria
- explicit non-goals when scope could sprawl

Use the clarification budget from `AGENTS.md` §1. Do not turn this into an open-ended interview.

### Step 3 — Collapse ambiguity from local evidence

Before asking the user to decide something the codebase already answers:

- Use `serena-symbol-toolkit` to inspect the existing behavior, naming, nearby patterns, or owning area.
- Use `gitnexus-radar` only when the question is graph-shaped or the area is unfamiliar.
- If a single narrow docs/API check would settle feasibility, use `context7-docs` inline.

If the remaining blocker is broader external research, stop and hand off to **b-research**.

### Step 4 — Produce the minimal spec

Keep the output in chat by default. Produce a compact, execution-ready spec:

```text
### Spec: <goal>

**Goal:** <what should exist or change>
**Constraints:** <hard boundaries>
**Acceptance criteria:**
- <testable outcome>
- <testable outcome>
**Non-goals:** <what this request is not asking for>
```

Do not create a separate saved artifact by default; this spec is the input to the next skill.

### Step 5 — Hand off cleanly

- Hand off to **b-implement** when the clarified request is now small and obvious.
- Hand off to **b-plan** when the goal is now clear but the work still needs sequencing, dependencies, or risk management.

Close with the handoff envelope and, for non-trivial clarification work, the skill-exit status block (`AGENTS.md` §9).

## Output format

```text
### Spec: [goal]

**Goal:** [what should happen]
**Constraints:** [hard boundaries]
**Acceptance criteria:**
- [testable outcome]
- [testable outcome]
**Non-goals:** [excluded scope]
**Next:** [b-plan / b-implement / b-research]
```

## Rules

- Clarify the end state; do not turn this skill into implementation planning.
- Prefer repository evidence over user questions when the codebase already answers the ambiguity.
- Ask only the minimum questions needed to make the work safely plannable.
- Keep the output compact; avoid writing a second durable artifact unless the user explicitly asks for one.
- If clarification reveals that the real blocker is external feasibility, stop and use **b-research** instead of guessing.
