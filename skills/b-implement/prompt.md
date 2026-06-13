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
3. State expected files/symbols, invariant behavior, and success criteria; infer narrow criteria only when obvious.
4. Use CodeGraph for cross-file impact or affected-test mapping when indexed; otherwise use Serena plus local search.
5. Edit the smallest coherent slice. Use Serena for symbol work and native edits for prose/config/string changes.
6. Run the narrowest useful verification.
7. Inspect the diff and report changes, verification, and remaining gaps.

## Output format

Changes, verification, and any blockers or follow-up. Recommend **b-review** for non-trivial changes.

## Rules

- Stay within approved scope.
- Every changed line should trace to the approved scope or cleanup made necessary by this change.
- Ask before dependencies, services, destructive commands, commits, pushes, PRs, or broad refactors.
- Do not add opportunistic cleanup or compatibility code.
- Do not claim done when required verification is missing or failed.
