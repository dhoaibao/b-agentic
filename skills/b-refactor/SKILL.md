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

Handle behavior-preserving mechanical code changes: lock the exact target, map the impact radius, apply the smallest safe transformation, and verify references still hold.

If `$ARGUMENTS` is provided, treat it as the refactoring instruction and proceed directly.

## When to use

- User asks to rename, extract, move, inline, delete dead code, or simplify a named target in a clearly behavior-preserving way.
- The transformation is meant to preserve behavior.
- The scope is concrete enough to execute without re-deciding product behavior.

## When NOT to use

- The request is broad, vague, partly a feature change, or says only "simplify" without naming the exact behavior-preserving transform → use **b-plan** first.
- The work is mainly implementing new behavior → use **b-implement**.
- The task is a runtime bug fix → use **b-debug**.
- The task is a test-only failure or test rewrite → use **b-test**.
- The request is only an external API lookup → use **b-research**.

## Boundary examples

- **Use b-refactor:** "Extract `parseOptions` from `handleArgs` without changing behavior."
- **Use b-plan or b-implement instead:** "Simplify checkout retries so the product gives up sooner" because the request changes behavior, not just structure.

## Tools required

- `bash` — inspect git state and run project-specific checks.
- `serena-symbol-toolkit` *(preferred for exact target locking, reference mapping, and symbol-aware edits)*
- `gitnexus-radar` *(optional, for broad exported/shared impact)*

Fallbacks: `AGENTS.md` §4 MCP fallback ladder. Serena's LSP-coverage caveat applies — for non-LSP languages, treat every rename, safe-delete, and diagnostics result as **not authoritative** and widen verification.

Graceful degradation: ⚠️ Partial — small local refactors remain possible with native search plus `apply_patch`, but cross-file renames and safe deletes are riskier without symbol-aware tooling.

## Steps

### Step 1 — Lock the target

1. Resolve the exact symbol or file to change.
2. Initialize Serena per `AGENTS.md` §4 (once per session, only when symbol-aware work first becomes necessary).
3. If the request starts from a usage site, helper import, interface, or repeated code shape, use the cheapest Serena discovery tool that closes the next question.
4. If the request is still vague after a short inspection, ask the smallest question needed to make the target concrete.

### Step 2 — Assess impact and choose verification depth

1. Run `find_referencing_symbols` on the locked target to enumerate impact. This is the single canonical mapping step — do not repeat it under different framings.
2. Classify the refactor on the **risk rubric** in `AGENTS.md` §3 (trivial / low / medium / high).
3. **Trivial-local fast path** is allowed only when **all** of:
   - One file.
   - No exported/public contract change.
   - Few or no external references.
   - Behavior clearly preserved.
   - Language is **LSP-supported by Serena**.

   This is intentional: non-LSP languages (Bash, YAML, Markdown, Lua, many DSLs) auto-promote to **low** risk at minimum. The fast path is locked behind LSP support because rename/safe-delete results in non-LSP languages are not authoritative.
4. For medium or high-risk refactors, optionally use `gitnexus-radar` to scope blast radius before editing. Discover the baseline verification command from project scripts or CI config. If baseline checks are already failing, stop and ask.
5. For non-LSP languages, generated glue, config-driven references, or text-discovered references outside Serena's graph, add a targeted text search to the verification worklist before editing.

### Step 3 — Apply the mechanical transform

Choose the smallest matching transformation:

- **Rename symbol** → `rename_symbol`.
- **Delete dead code** → `safe_delete_symbol` after confirming zero references.
- **Extract function** → insert the helper, then update callers.
- **Inline local logic** → update callers, then remove the old symbol safely.
- **Rename + extract** (common combo): extract first under the **old** name, verify references, then `rename_symbol` to the new name. Keeps the two transforms independently verifiable.
- **Move code between files** (highest mechanical risk):
  1. Add the new destination first with `insert_after_symbol` or `apply_patch`; do not delete the origin yet.
  2. Update every import or re-export, using the reference map from Step 2.
  3. Update test-only imports, fixtures, and mocks — these often live outside the LSP graph; grep the suite explicitly.
  4. Update build config, path aliases, barrel files, and route registries when present.
  5. Remove the origin symbol via `safe_delete_symbol` only after diagnostics on every touched file are clean.
  6. Re-run `find_referencing_symbols` on the moved symbol; if any references still point at the old location, stop and investigate.

Use `apply_patch` only for import updates, config, prose, or non-symbol glue.

If the work turns into a behavioral redesign instead of a mechanical transform, stop and hand it back to **b-plan** via the handoff envelope in `AGENTS.md` §9. Include the locked target, the reference map produced in Step 2, and the specific decision that turned mechanical.

### Step 4 — Verify

1. Run `get_diagnostics_for_file` on touched files when supported (LSP caveat per `AGENTS.md` §4).
2. Run the narrowest typecheck, build, or test command that matches the risk band (verification ladder in `AGENTS.md` §7).
3. Re-check references when the target is shared or exported.
4. Inspect `git diff` to confirm the change stayed within intended scope.
5. If failures indicate a real regression, use **b-debug**. If they indicate test-mechanic drift, use **b-test**.
6. **Partial-completion recovery:** if verification fails partway through a multi-file transform (e.g., a move with imports half-updated, a rename that missed a re-export), do not paper over the broken state with more edits. Either (a) finish the transform to a coherent baseline in one focused pass using the Step 2 reference map as the worklist, or (b) manually roll back only the in-flight edits for the current transform. If a file-level restore is truly required, stop and ask for approval first because it can discard unrelated user changes in the same path. Never exit the skill with the tree mid-transform — surface the rollback to the user.
7. Apply the iteration cap from `AGENTS.md` §7.

Close with the skill-exit status block (`AGENTS.md` §9).

## Output format

```text
### b-refactor: [transformation]

**Target:** [symbol or file]
**Risk:** [trivial / low / medium / high]   (per AGENTS.md §3)
**Impact:** [key references or boundaries]

#### Changes
- `[path:line]` — [what changed]

#### Verification
```bash
[command]
```
[result]

#### Follow-up
- [none / remaining step / user decision needed]
```

## Rules

- Keep the task behavior-preserving; do not quietly add features while refactoring.
- Use the trivial-local fast path only when the contract is untouched and the language is LSP-supported.
- For non-LSP languages, treat every rename or safe-delete as at least **low** risk and verify with broader text-grep plus the project's existing test suite.
- Treat vague "simplify" requests as planning work until the exact behavior-preserving transform is locked.
- Use symbol-aware rename/delete tools whenever they fit the transformation.
- For rename + extract, do extract first, then rename — keep transforms independently verifiable.
- Ask before broad directory moves or other cascading changes through tooling, docs, and imports.
- Do not push past failing medium/high-risk verification without surfacing the blocker.
- Do not commit unless the user explicitly asks.
