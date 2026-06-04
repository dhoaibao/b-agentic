# b-implement

$ARGUMENTS

Execute approved or clearly scoped work one coherent step at a time.

If `$ARGUMENTS` is present, treat it as a plan path, plan slug, approved chat plan, or small direct request.

## When to use

- The user approved a saved or chat plan.
- The next action is to edit code or docs within known scope.
- The request meets the small direct request threshold in the shared runtime contract.

## When NOT to use

- Scope is unclear -> use **b-plan** (Clarification mode).
- The primary job is a named mechanical transform -> use **b-refactor**.
- The task is only tests -> use **b-test**.
- A runtime root cause is unknown -> use **b-debug**.
- The blocker is external lookup -> use **b-research**.

## Tools required

- `bash` - inspect status/diff and run verification.
- `serena-symbol-toolkit` *(preferred for symbol-aware edits and diagnostics)*
- `context7-docs` *(optional, for one narrow API uncertainty)*

## Steps

### Step 1 - Load source of truth

Resolve scope: saved plan path, plan slug, approved chat plan, then small direct request.

For saved plans, validate durable frontmatter, explicit approval, matching touch points, staleness, and every unchecked step's `Done when`. Stop with `cause: user_blocked` when approval is missing; stop with `cause: conflict` for invalid metadata, stale touch points, blocked dependencies, or missing step verification.

Legacy saved plans without frontmatter may execute only when the current conversation contains explicit approval. Use the current-chat approval time for staleness checks, require unchecked steps to include `Done when`, and do not rewrite the legacy plan solely to add metadata.

If no plan exists and the request fails the small-direct threshold, hand off to **b-plan**. Read `{{runtime_reference_root}}/contract/safety-tools.md` before editing.

### Step 2 - Check worktree

Run `git status --short`. Preserve unrelated changes; patch around unrelated edits; stop if user changes directly conflict.

### Step 3 - Implement the smallest coherent step

Before editing, state source of truth, files/symbols expected to change, behavior that must not change, planned verification, and any approval/review checkpoint.

Use native tools for simple prose/config/string edits; use Serena for declarations, references, diagnostics, and symbol-aware edits. Use Context7 only when a third-party API uncertainty blocks the next local edit or verification choice.

**Serena editing workflow:**
1. `get_symbols_overview` on the target file to locate the symbol.
2. `find_symbol` with `include_body=True` to read the full definition before editing.
3. Perform the edit with the appropriate Serena tool (`replace_symbol_body`, `insert_after_symbol`, `insert_before_symbol`, or `rename_symbol`).
4. `get_diagnostics_for_file` to verify the edit introduced no errors.
5. `find_referencing_symbols` to confirm callers still resolve correctly.

Prefer symbol-level edits for functions, methods, classes, and fields. Use file-level native tools for config, prose, or when Serena reports the language has no LSP support.

Stay within approved scope. Classify adjacent discoveries as Required, Blocking decision, or Follow-up.

### Step 4 - Verify

Run the plan's check when available; otherwise use touched-file diagnostics and the narrowest relevant command. Classify failures before another edit. Read `{{runtime_reference_root}}/contract/output.md` before emitting a status block.

### Step 5 - Record progress and close

After verification passes, update saved-plan checkboxes/progress without stripping metadata. Continue only when the next step is approved, dependency-ready, no higher risk, and locally verifiable. Stop before new decisions, broader verification, or review checkpoints.

At completion, inspect the diff, report verification and cleanup state, and recommend **b-review** for non-trivial or risky changes.

## Output format

```text
Plan source -> Step progress -> Changes -> Verification -> Blockers/Decisions -> Next
```

## Rules

- Implement only approved or clearly scoped work.
- Do not add opportunistic refactors, compatibility code, or side cleanup.
- Stop for new decisions instead of guessing.
- A small direct request still needs real verification.

## Reference pointers

- Read `./reference.md` before validating saved plans, classifying adjacent discoveries, or when the small-direct-request threshold is unclear.
