---
name: b-implement
description: >
  Execute approved or scoped work safely after b-plan approval, when the
  user asks to execute or implement scoped work, or when a small direct
  request meets the shared §3 threshold. Reads the approved plan, applies
  the next small step, verifies it, and stops for new decisions. Unlike
  b-plan, b-implement changes code.
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
- `serena-symbol-toolkit` - symbol-aware code edits and diagnostics.
- `context7-docs` - narrow third-party API checks when needed.

## Steps

1. Resolve the source of truth: approved plan, approved chat instruction, or small direct request.
2. Run `git status --short` and preserve unrelated changes.
3. State expected files/symbols, invariant behavior, and verification.
4. Edit the smallest coherent slice. Use Serena for symbol work and native edits for prose/config/string changes.
5. Run the narrowest useful verification.
6. Inspect the diff and report changes, verification, and remaining gaps.

## Output format

Changes, verification, and any blockers or follow-up. Recommend **b-review** for non-trivial changes.

## Rules

- Stay within approved scope.
- Ask before dependencies, services, destructive commands, commits, pushes, PRs, or broad refactors.
- Do not add opportunistic cleanup or compatibility code.
- Do not claim done when required verification is missing or failed.
