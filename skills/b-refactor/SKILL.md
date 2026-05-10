---
name: b-refactor
description: >
  Code refactoring: impact analysis, mechanical transformation, and verification. ALWAYS invoke when the user asks to refactor, tái cấu trúc, rename, extract method, move, inline, simplify, or clean up code. Unlike b-plan (decides what to build), b-refactor owns the mechanical workflow: impact analysis → safe edits → verify. Uses Serena's symbol-aware tools for cross-file impact and safe renaming.
compatibility: opencode
metadata:
  suite: b-skills
---

# b-refactor

$ARGUMENTS

Refactor code with impact analysis and safe mechanical transformation. Owns the full
workflow: map references → plan transformation → apply symbol-aware edits → verify
nothing broke.

If `$ARGUMENTS` is provided, treat it as the refactoring instruction. Proceed directly.

## When to use

- User asks to refactor, rename, extract method, move a function, inline a variable.
- User says: "refactor", "tái cấu trúc", "extract method", "rename", "move", "inline",
  "simplify", "clean up", "tách hàm", "đổi tên".
- Mechanical code transformation that preserves behavior.
- Improving code structure without changing functionality.
- Best when the target change is already concrete: rename, extract, move, inline, or delete with a known scope.

## When NOT to use

- New feature, broad refactor, or unclear scope → use **b-plan** first
- Runtime bug or test failure → use **b-debug**
- Review after implementation → use **b-review**
- Tests fail after refactor → use **b-test** (test-specific) or **b-debug** (real regression)
- Quick library API lookup → use **b-research**

## Tools required

- `bash` — run tests, check compilation, inspect git diff.
- `check_onboarding_performed`, `onboarding`, `find_symbol`, `get_symbols_overview`, `find_referencing_symbols`, `replace_symbol_body`, `insert_before_symbol`, `insert_after_symbol`, `rename_symbol`, `safe_delete_symbol` — from `serena` MCP server *(required for impact analysis and safe symbol-level edits)*
- `sequentialthinking` — from `sequential-thinking` MCP server *(optional, for evaluating trade-offs on large refactors)*
- `gitnexus` — from `gitnexus` MCP server *(optional, preferred first step for broad blast-radius discovery before mechanical edits — only after `gitnexus analyze`)*

If Serena is unavailable: use native `read` + `edit` + bash search for manual refactoring. Note: "⚠️ Serena unavailable — cross-file renames and safe deletes require manual verification."
If sequential-thinking is unavailable: evaluate trade-offs inline with explicit pros/cons.
If gitnexus is unavailable, stale, unindexed, or missing FTS: warn once and fall back to `find_referencing_symbols` and native bash search for impact analysis. Note: "⚠️ GitNexus unavailable — using Serena references for blast-radius check."

Graceful degradation: ⚠️ Partial — mechanical refactoring still possible with native edit, but cross-file renames and safe deletes require manual impact checks.

## Steps

### Step 1 — Impact analysis

1. Call `check_onboarding_performed`. If false, call `onboarding`.

2. Identify the target symbol:
   - User names a function/class → `find_symbol` with that name.
   - User references a file → `get_symbols_overview` to inspect top-level symbols.
   - Vague instruction ("clean up the auth module") → `get_symbols_overview` on the file, then ask the user for a specific target.

3. **Broad blast-radius discovery** *(when gitnexus is connected and the repo is indexed)*:
   - Call `gitnexus impact` or `gitnexus context` on the target symbol first to understand cross-module or cross-package impact beyond direct symbol references.
   - If GitNexus reports the repo is unindexed, stale, or missing FTS, warn once and continue with Serena references alone.
   - Record any hidden callers, event-driven boundaries, or architecture constraints discovered.

4. Call `find_referencing_symbols` on the target to map every call site and usage.
   Record: how many files reference it, whether it's exported/public, whether any references are in tests.

5. Choose a baseline check based on risk:
   - **Low risk**: local rename/extract/inline inside one file, no exported API, no behavior change -> baseline may be skipped; record why.
   - **Medium/high risk**: exported symbol, move across files, delete code, package boundary, or >2 files -> run tests or typecheck before refactoring.

   Suggested baseline commands:
    ```bash
    npm test || pytest || go test ./... || cargo test
    ```
   If baseline checks fail before a medium/high-risk refactor: warn the user and ask whether to proceed.

**Goal**: know the full impact radius before touching any code.

---

### Step 2 — Plan transformation

Choose the mechanical transformation pattern that matches the request:

- **Rename symbol** → `rename_symbol`, then verify.
- **Rename file/directory** → use native rename/move operations, then use Serena reference checks plus import verification before proceeding.
- **Extract method** → add the new helper with `insert_before_symbol`, then update the caller with `replace_symbol_body`.
- **Inline variable** → substitute the expression with `replace_symbol_body`, then remove the symbol with `safe_delete_symbol`.
- **Move to new file** → insert or replace the declaration in the destination, update imports, then delete from the old location.
- **Delete dead code** → confirm zero usages, then `safe_delete_symbol`.
- **Split large function** → insert helpers first, then update the original function to call them.

If the refactor affects >3 files or crosses package boundaries:
- Use `sequentialthinking` to evaluate rollback risk and choose the safest order.
- Consider splitting into phases such as rename → move → extract.

---

### Step 3 — Execute safely

Apply edits in dependency order. Prefer Serena's symbol-aware tools over native `edit`:

1. **`rename_symbol`** — for renaming functions, classes, and variables. Safest when the refactor is a real symbol rename across references.
2. **`safe_delete_symbol`** — for removing dead code. Returns remaining usages; address them before retrying.
3. **`replace_symbol_body`** — for changing the full body of a function or method while keeping the signature.
4. **`insert_before_symbol` / `insert_after_symbol`** — for adding new functions or moving declarations.
5. **Native `edit`** — only for line-level import updates, config changes, or prose modifications that are not symbol-relative.

**Execution order rule**: apply changes from the inside out — inner helpers first, then outer callers. This prevents broken references during intermediate states.

**Import update rule**: if the refactor moves code across files, update imports manually via native `edit` after the symbol-level changes are done.

---

### Step 4 — Verify

After every mechanical step:

1. **Compilation check** *(compiled languages)*:
   ```bash
   npx tsc --noEmit || go build ./... || cargo check
   ```

2. **Test check**:
   ```bash
   npm test || pytest || go test ./... || cargo test
   ```

3. **Git diff inspection**: `git diff` to confirm only intended changes. Look for accidental deletions, wrong import paths, unintended formatting.

4. **Impact re-check**: if the refactor changed a public/exported symbol, re-run `find_referencing_symbols` to confirm references resolve.

**Iteration rule**: if tests or compilation fail, fix before proceeding. Maximum 2 fix iterations per step. If a failure looks like a real bug introduced by the refactor → handoff to /b-debug. If it's a test-mechanic failure (assertion drift, snapshot, mock) → handoff to /b-test.

---

## Output format

```
### b-refactor: [transformation name]

**Target**: `[symbol name]` in `[file]`
**Impact**: [N references across M files]
**Risk**: [low / medium / high]

#### Transformation plan
- [Step 1 description]
- [Step 2 description]
- ...

#### Changes
- `[file:line]` — [what changed]

#### Verification
\`\`\`bash
[test command and result]
\`\`\`
✅ Tests pass / ❌ [N failures] — [fix status]

#### Next steps
- [any remaining cleanup, import fixes, or follow-up refactors]
```

---

## Rules

- Never perform a medium/high-risk refactor without a green baseline check — warn and ask if checks are already failing. Low-risk single-file mechanical edits may skip baseline with an explicit note.
- Always use `find_referencing_symbols` before renaming or deleting — cross-file impact is the most common source of refactoring bugs.
- Prefer `rename_symbol` over manual `edit` for symbol renames — it updates all references atomically.
- Prefer `safe_delete_symbol` over manual deletion — it prevents accidental removal of still-used code.
- Apply edits from the inside out — inner helpers first, then outer callers.
- If code moves across files, update imports after the symbol-level changes are done.
- Do not refactor and add new features in the same session — split into two tasks.
- If the refactor affects >3 files: use `sequentialthinking` to evaluate rollback strategy.
- Run compilation check after every mechanical step — do not wait until the end.
- Run the full test suite after the last step, not just the unit test for the changed function.
- Never trigger destructive git commands.
- Keep git history clean — one commit per logical transformation (rename, extract, move).
- If too large to verify in one session: stop after a safe checkpoint, run tests, and tell the user: "Safe checkpoint reached. Remaining transformations: [list]."
