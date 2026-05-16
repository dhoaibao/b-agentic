---
name: b-refactor
description: >
  Code refactoring: impact analysis, mechanical transformation, and
  verification. ALWAYS invoke when the user asks for a named
  behavior-preserving transform — rename, extract, move, inline, delete dead
  code, or simplify a specific target. Vague cleanups go to b-plan first.
  Unlike b-plan, which decides what to build, b-refactor owns mechanical
  edits.
compatibility: opencode
metadata:
  suite: b-skills
---

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
- `gitnexus-radar` *(optional, for broad exported/shared impact)*

Fallbacks: `AGENTS.md` section 4. Graceful degradation: partial; native search plus `apply_patch` works for local refactors, cross-file work is riskier.

## Steps

### Step 1 - Lock target

Resolve the exact symbol, file, or repeated code shape. For `simplify`, require the target and behavior-preserving boundary to be concrete; otherwise hand back to **b-plan**. If the request remains vague after short inspection, ask the smallest question that makes it concrete.

### Step 2 - Map impact and risk

Use Serena references as the primary static map, but do not treat them as complete proof for dynamic, config-driven, generated, or prose references. Use GitNexus only for broad shared/exported blast-radius questions. Moves across public module boundaries, package boundaries, or published entry points require planning unless the approved scope already names the destination and verification.

Classify risk with `AGENTS.md`. The local fast path is allowed when the refactor is one file, behavior-preserving, non-exported, LSP-supported, has few/no external references, and has no generated-code consumers.

Auto-promote risk when the language is non-LSP, references are dynamic/config/prose, the target is exported/shared, or generated code consumes it. Generated consumers require checking generator source or regeneration.

### Step 3 - Apply the mechanical transform

Pick the smallest matching transform:

- Rename symbol -> symbol rename when supported.
- Delete dead code -> safe delete after zero references.
- Extract helper -> insert helper, update callers, verify.
- Inline local logic -> update callers, then remove old symbol safely.
- Rename + extract -> extract under the old name, verify, then rename.
- Move between files -> add destination first, update imports/re-exports/tests/config/barrels, verify diagnostics, then remove origin and re-check references.

Use `apply_patch` for imports, config, prose, or non-symbol glue under global patch discipline. If `apply_patch` reports missing expected lines, treat it as stale context: re-read and retry with smaller verified context.

If the work becomes behavioral redesign, hand back to **b-plan** with the locked target and reference map. If the map is too broad for one coherent run, hand back to **b-plan** with proposed verifiable slices.

### Step 4 - Verify

Run diagnostics when supported, then the narrowest risk-appropriate typecheck/build/test. Re-check references for shared/exported targets and inspect diff for unintended scope.

Use global transform rollback, cascading failure handling, iteration cap, and skipped-check labels. If failures indicate real regression, use **b-debug**; test-mechanic drift goes to **b-test**.

## Output format

```text
Target -> Risk -> Impact -> Changes -> Verification -> Follow-up
```

## Rules

- Preserve behavior; do not add features while refactoring.
- Keep local fast-path refactors low-friction, but promote risk for exports, non-LSP languages, generated consumers, and dynamic/config/prose references.
- Prefer symbol-aware rename/delete tools when reliable.
- Ask before broad directory moves or cascading ecosystem changes.
- Do not push past failing medium/high-risk verification without surfacing the blocker.
- Do not commit unless explicitly asked.
