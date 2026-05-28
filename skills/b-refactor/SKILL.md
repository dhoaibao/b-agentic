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

Execute concrete behavior-preserving transforms: lock target, map impact, transform, verify.

## When to use

- The user asks to rename, extract, move, inline, delete dead code, or simplify a named target.
- The work is intended to preserve behavior.
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

Resolve the exact symbol, file, or repeated code shape. For `simplify`, require the target and behavior-preserving boundary to be concrete; otherwise hand back to **b-plan**. If the request remains vague after short inspection, ask the smallest question that makes it concrete.

For `simplify`, `inline`, and `extract`, state the observable behavior that must remain equivalent before editing. If equivalence cannot be named from tests, call sites, or local semantics, treat the work as redesign and hand back to **b-plan**.

### Step 2 - Map impact and risk

Use Serena references as the primary static map, but do not treat them as complete proof for dynamic, config-driven, generated, or prose references. Add exact text search for exported names, config keys, CLI flags, route strings, filenames, docs, and generated consumers when those surfaces could reference the target. Moves across public module boundaries, package boundaries, or published entry points require planning unless the approved scope already names the destination and verification.

Read `../../b-agentic/references/contract/03-definitions.md` before classifying risk. The local fast path is allowed when the refactor is one file, behavior-preserving, non-exported, LSP-supported, covered by direct semantics or narrow tests, has few/no external references, and has no generated-code consumers.

Auto-promote risk when the language is non-LSP, references are dynamic/config/prose, the target is exported/shared, or generated code consumes it. Generated consumers require checking generator source or regeneration.

### Step 3 - Apply the mechanical transform

Pick the smallest matching transform:

- Rename symbol -> symbol rename when supported.
- Delete dead code -> safe delete after zero references.
- Extract helper -> insert helper, update callers, verify.
- Inline local logic -> update callers, then remove old symbol safely.
- Rename + extract -> extract under the old name, verify, then rename.
- Move between files -> add destination first, update imports/re-exports/tests/config/barrels, verify diagnostics, then remove origin and re-check references.

Read `../../b-agentic/references/contract/06-safety.md` before using `apply_patch` for imports, config, prose, or non-symbol glue under the global patch discipline.

If the work becomes behavioral redesign, hand back to **b-plan** with the locked target and reference map. If the map is too broad for one coherent run, hand back to **b-plan** with proposed verifiable slices.

### Step 4 - Verify

Run diagnostics when supported, then the narrowest risk-appropriate typecheck/build/test. Re-check references for shared/exported targets and inspect diff for unintended scope.

Read `../../b-agentic/references/contract/07-execution.md` before applying transform rollback, cascading failure handling, iteration cap, or skipped-check labels. If failures indicate real regression, use **b-debug**; test-mechanic drift goes to **b-test**.

## Output format

```text
Target -> Risk -> Impact -> Changes -> Verification -> Follow-up
```


## Rules

- Preserve behavior; do not add features while refactoring.
- Keep local fast-path refactors low-friction, but promote risk for exports, weak behavior evidence, non-LSP languages, generated consumers, and dynamic/config/prose references.
- Prefer symbol-aware rename/delete tools when reliable.
- Ask before broad directory moves or cascading ecosystem changes.
- Do not push past failing medium/high-risk verification without surfacing the blocker.
