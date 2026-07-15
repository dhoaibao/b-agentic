---
name: b-refactor
description: >
  Code refactoring: impact analysis, mechanical transformation, and
  verification for named behavior-preserving transforms: rename, extract,
  move, inline, delete dead code, or simplify a specific target. Vague
  cleanups go to b-plan first. Unlike b-plan, which decides what to build,
  b-refactor owns mechanical edits.
argument-hint: "[refactor-target]"
---

<!-- Generated from skills/registry.yaml and skills/b-refactor/prompt.md. Edit those sources, not this file. -->

# b-refactor

$ARGUMENTS

Run concrete behavior-preserving transforms: rename, extract, move, inline, simplify, or delete.

## When to use

- The user names a specific behavior-preserving transform.
- The target is clear enough to change without product decisions.

## When NOT to use

- The request is vague cleanup or changes behavior -> use **b-plan**.
- The work adds behavior -> use **b-implement**.
- The work fixes a bug -> use **b-debug**.
- The work is test-only -> use **b-test**.

## Tools required

- `bash` - inspect git state and run checks.
- `codegraph` - impact radius and cross-file structure when indexed.
- `serena` - lock targets, references, renames, diagnostics, and symbol edits.

## Steps

1. Lock the exact target and state the behavior that must remain unchanged.
2. Read relevant repo context when present: `CONTEXT.md`, `CONTEXT-MAP.md`, nearby `docs/adr/`, `docs/agents/`, or `.b-agentic/` notes.
3. Map structure and impact with CodeGraph when indexed; map declarations/references with Serena; use exact text search for exports, routes, config keys, docs, and generated consumers.
4. When practical, run the narrowest risk-appropriate check to establish a passing behavioral baseline.
5. Apply the smallest matching transform.
6. Re-check references (using Bash if needed), run diagnostics, and rerun the baseline check or equivalent narrow verification.
7. Inspect the diff for unintended behavior changes.

When the refactor target is architectural, use concise design vocabulary: interface, seam, adapter, locality, leverage, shallow abstraction, and deletion test. Stop if the work becomes redesign.

## Output format

Target, impact, changes, verification, and follow-up risk.

## Rules

- Preserve behavior.
- Prefer symbol-aware tools when reliable.
- Ask before broad moves or cascading ecosystem changes.
- Stop if redesign or behavior change appears.
