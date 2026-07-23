---
name: b-implement
description: >
  Execute approved or scoped work safely after b-plan approval, when the
  user asks to implement scoped work, or when a direct request is small
  and clear. Applies the next small step, verifies it, and hands back to
  planning or research instead of guessing when new ambiguity appears.
  Unlike b-plan, b-implement changes code.
argument-hint: "[plan-path-or-task]"
---

<!-- Generated from skills/registry.yaml and skills/b-implement/prompt.md. Edit those sources, not this file. -->

# b-implement

$ARGUMENTS

Make the scoped change in the smallest coherent step, and hand back to planning or research instead of guessing when new ambiguity appears.

## When to use

- The user approved a plan or gave a small direct request.
- The next action is an edit within known scope.

## When NOT to use

- Scope or behavior is unclear -> use **b-plan**.
- The primary task is a named refactor -> use **b-refactor**.
- The task is only tests -> use **b-test**.
- Root cause is unknown -> use **b-debug**.
- External lookup blocks the edit -> use **b-research**.

## Tool guidance

- `bash` - inspect git state, diffs, and verification output.
- `codegraph` - architecture, call graph, and affected-test evidence when indexed.
- `serena` - symbol-aware code edits and diagnostics.
- `context7` - narrow third-party API checks when needed.

## Steps

1. Resolve the source of truth: approved plan, approved chat instruction, or small direct request.
2. Run `rtk git status --short` via Bash and preserve unrelated changes.
3. Read relevant repo context only when it materially affects the scoped change.
4. State expected files/symbols, invariant behavior, and success criteria; infer narrow criteria only when obvious.
5. Use CodeGraph for cross-file impact or affected-test mapping when indexed; otherwise use Serena plus local search.
6. Edit the smallest coherent slice and match the existing local style. Use Serena for symbol work and native edits for prose/config/string changes.
7. Run the narrowest useful verification (using Context7 for third-party API checks if the implementation relies on them) that proves the requested observable outcome.
8. If verification exposes an in-scope defect without new ambiguity or scope drift, correct it and rerun the required check. Otherwise stop rather than guessing.
9. Inspect the diff and report changes, verification, and remaining gaps.
10. If new uncertainty, missing external facts, or scope drift appears, stop and hand back to **b-plan** or **b-research** instead of silently expanding the task.

## Output format

Changes, verification, and any blockers or follow-up. Recommend **b-review** for non-trivial changes.

## Rules

- Stay within approved scope.
- Every changed line should trace to the approved scope or cleanup made necessary by this change.
- Remove imports or helpers made unused by the change; leave pre-existing dead code and adjacent comments or formatting untouched.
- Ask before dependencies, services, destructive commands, commits, pushes, PRs, or broad refactors.
- Do not add opportunistic cleanup, speculative compatibility, single-use abstractions, or handling for impossible scenarios without repo evidence.
- Do not push through newly discovered ambiguity; route it explicitly.
- Do not claim done when required verification is missing or failed.
