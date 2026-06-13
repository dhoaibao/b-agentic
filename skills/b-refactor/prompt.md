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
- `serena-symbol-toolkit` - lock targets, references, renames, diagnostics, and symbol edits.

## Steps

1. Lock the exact target and state the behavior that must remain unchanged.
2. Map structure and impact with CodeGraph when indexed; map declarations/references with Serena; use exact text search for exports, routes, config keys, docs, and generated consumers.
3. Apply the smallest matching transform.
4. Re-check references and run diagnostics or the narrowest risk-appropriate test/build.
5. Inspect the diff for unintended behavior changes.

## Output format

Target, impact, changes, verification, and follow-up risk.

## Rules

- Preserve behavior.
- Prefer symbol-aware tools when reliable.
- Ask before broad moves or cascading ecosystem changes.
- Stop if redesign or behavior change appears.
