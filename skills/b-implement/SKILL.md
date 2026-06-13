---
name: b-implement
description: >
  Execute approved or scoped work safely after b-plan approval, when the
  user asks to execute or implement scoped work, or when a direct request
  is small and clearly scoped. Reads the approved plan, applies the next
  small step, verifies it, and stops for new decisions. Unlike b-plan,
  b-implement changes code.
argument-hint: "[plan-path-or-task]"
---

<!-- Generated from skills/registry.yaml and skills/b-implement/prompt.md. Edit those sources, not this file. -->

# b-implement

$ARGUMENTS

Execute approved or clearly scoped work in the smallest coherent step.

## When to use

- The user approved a plan or gave a small direct request.
- The next action is an edit within known scope.

## When NOT to use

- Scope or behavior is unclear -> use **b-plan**.
- The primary task is a named refactor -> use **b-refactor**.
- The task is only tests -> use **b-test**.
- Root cause is unknown -> use **b-debug**.
- External lookup blocks the edit -> use **b-research**.

## Tools required

- `bash` - inspect git state, diffs, and verification output.
- `codegraph` - architecture, call graph, and affected-test evidence when indexed.
- `serena-symbol-toolkit` - symbol-aware code edits and diagnostics.
- `context7-docs` - narrow third-party API checks when needed.

## Steps

1. Resolve the source of truth: approved plan, approved chat instruction, or small direct request.
2. Run `git status --short` and preserve unrelated changes.
3. Read relevant repo context when present: `CONTEXT.md`, `CONTEXT-MAP.md`, nearby `docs/adr/`, `docs/agents/`, or `.b-agentic/` notes.
4. State expected files/symbols, invariant behavior, and success criteria; infer narrow criteria only when obvious.
5. Use CodeGraph for cross-file impact or affected-test mapping when indexed; otherwise use Serena plus local search.
6. Edit the smallest coherent slice. Use Serena for symbol work and native edits for prose/config/string changes.
7. Run the narrowest useful verification that proves the requested observable outcome.
8. Inspect the diff and report changes, verification, and remaining gaps.

For substantial approved plans where subagents are available, use them only when they reduce risk or context pressure. Provide full task text and curated context, implement one task at a time, verify subagent claims independently, and review requirements compliance before code quality.

## Output format

Changes, verification, and any blockers or follow-up. Recommend **b-review** for non-trivial changes.

## Rules

- Stay within approved scope.
- Every changed line should trace to the approved scope or cleanup made necessary by this change.
- Ask before dependencies, services, destructive commands, commits, pushes, PRs, or broad refactors.
- Do not add opportunistic cleanup or compatibility code.
- Do not make subagent orchestration mandatory for small direct edits.
- Do not claim done when required verification is missing or failed.
