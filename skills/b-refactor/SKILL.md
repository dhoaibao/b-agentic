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

Execute concrete behavior-preserving transforms: rename, extract, move, inline, delete, or simplify.

## When to use

- The user asks for a named behavior-preserving transform.
- The target is concrete enough to execute without product decisions.

## When NOT to use

- The request is broad, vague, or changes behavior -> use **b-plan**.
- The work mainly implements new behavior -> use **b-implement**.
- The task is a bug fix -> use **b-debug**.
- The task is test-only work -> use **b-test**.
- The request is external lookup only -> use **b-research**.

## Tools required

- `bash` - inspect git state and run checks.
- `serena-symbol-toolkit` *(preferred for target locking, references, diagnostics, and symbol edits)*

## Steps

### Step 1 - Lock target

Resolve the exact symbol, file, or repeated code shape. For simplify/inline/extract, state the observable behavior that must remain equivalent. If the target or equivalence is unclear, hand back to **b-plan**.

### Step 2 - Map impact and risk

Use Serena references first, plus exact text search for exported names, config keys, CLI flags, routes, filenames, docs, and generated consumers. Promote risk for public/module boundaries, dynamic references, non-LSP languages, weak coverage, generated consumers, or partial behavior evidence.

**Serena rename/move workflow:**
1. `find_symbol` to lock the target symbol and confirm it exists.
2. `find_implementations` to discover overrides or interface realizations.
3. `find_referencing_symbols` to map all call sites and imports.
4. Perform the transform with `rename_symbol` (or manual edits when the language lacks LSP support).
5. `find_referencing_symbols` again to confirm references resolved.
6. `get_diagnostics_for_file` on affected files to catch type errors.

Skip the Serena sequence for non-LSP languages (e.g., plain shell, CSS, protobuf); use exact text search and manual edits instead.

### Step 3 - Transform

Pick the smallest matching transform. For moves, add destination, update imports/re-exports/tests/config/barrels, verify, then remove origin and re-check references. If the map grows too broad or behavioral redesign appears, hand back to **b-plan** with the locked target and reference map.

### Step 4 - Verify

Run diagnostics when supported, then the narrowest risk-appropriate typecheck/build/test. Re-check references for shared/exported targets and inspect diff for unintended scope. If failures show real regression, use **b-debug**; test-mechanic drift goes to **b-test**.

## Output format

```text
Target -> Risk -> Impact -> Changes -> Verification -> Follow-up
```

## Rules

- Preserve behavior; do not add features.
- Prefer symbol-aware rename/delete tools when reliable.
- Ask before broad directory moves or cascading ecosystem changes.
- Do not push past failing medium/high-risk verification without surfacing the blocker.
