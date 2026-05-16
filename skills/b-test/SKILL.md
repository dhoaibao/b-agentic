---
name: b-test
description: >
  Test-driven development, test debugging, and test coverage evaluation.
  ALWAYS invoke when the user asks to write tests, fix failing tests,
  evaluate coverage, or work TDD-style. Unlike b-debug, which traces runtime
  bugs, b-test owns test-specific failures: wrong assertions, missing mocks,
  fixture or setup issues, and coverage gaps. Use the test-vs-bug decision in
  AGENTS.md section 10 when a red test could go either way.
compatibility: opencode
metadata:
  suite: b-skills
---

# b-test

$ARGUMENTS

Own code-level tests: add coverage, fix test-only failures, and avoid confusing red tests with product bugs.

## When to use

- The user asks to write tests, fix failing tests, evaluate coverage, or work TDD-style.
- The global test-vs-bug decision routes a failing test to the test lane.
- DOM-rendered unit tests and hybrid component tests are in scope.

## When NOT to use

- The failing test likely exposes real runtime behavior -> use **b-debug**.
- The task drives a real browser -> use **b-e2e**.
- Scope or acceptance is unclear -> use **b-plan**.
- The task is pre-PR logic review -> use **b-review**.
- The task needs a new test strategy/framework -> use **b-plan** first.

## Tools required

- `bash` - run tests/coverage and inspect failure output.
- Native file tools - discover manifests, test files, and focused source/test sections.
- `serena-symbol-toolkit` *(preferred for mapping tests to source behavior and editing existing tests)*
- `context7-docs` *(optional, for testing-framework API or matcher behavior)*

Fallbacks: `AGENTS.md` section 4. Graceful degradation: possible with native tools and `apply_patch`.

## Steps

### Step 1 - Discover framework and scope

Find relevant test files and project commands from manifests or CI. If a failing test is named, start with the narrowest runnable target. If no test framework exists, ask before adding one.

### Step 2 - Choose the lane

Use the global test-vs-bug decision:

- **Failing test:** fix assertion, mock, fixture, setup, async, snapshot, or harness drift only after intended behavior is confirmed.
- **Write tests:** add regression/unit/integration coverage for known behavior. For TDD or regression work, make the test fail first when feasible before changing implementation.
- **Coverage review:** rank missing tests by user impact, changed behavior, risk boundary, and edge-case value; add only the requested/highest-value gaps.
- **Flaky test:** use the global flake procedure before rewriting or skipping.

If product behavior is uncertain, hand off to **b-debug**.

### Step 3 - Fix or add tests

For failing tests, run the narrow command, read the test and exercised source, classify the failure, and apply snapshot/golden confirmation before updating derived artifacts.

For new tests, cover behavior that matters: happy path, edge cases, error handling, and the regression that would catch an accidental revert. Prefer local fixtures unless an existing shared fixture fits.

For coverage review, stop when changed behavior is covered, the next gap is opportunistic, or five gaps have been added with no required gap remaining.

Use Serena for existing test bodies. Use `apply_patch` for new test files or small non-symbol edits under global patch discipline. If `apply_patch` reports missing expected lines, treat it as stale context and retry with smaller verified context.

### Step 4 - Verify

Run diagnostics on touched test/source files when supported, then the narrowest relevant test. Widen only for shared fixtures/helpers, public contracts, or the repo's normal workflow. Use global skipped-check labels when broader checks are intentionally skipped.

## Output format

```text
Type -> Framework -> Findings -> Changes -> Verification -> Remaining gaps
```

## Rules

- Never change production code just because a test is red.
- Never update assertions, snapshots, or goldens without confirming intended behavior.
- Real-browser flows belong to **b-e2e**.
- Do not introduce test, coverage, property-based, fuzzing, or contract-test frameworks without approval.
- Keep fixture and mock changes local when practical.
- Use global patch discipline, stale context recovery, verification ladder, and iteration cap.
- Test utilities belong here when created or changed to support an in-scope test; mechanical relocation belongs to **b-refactor**.

## Reference pointers

- `references/testing-patterns.md` - fallback guidance when local conventions are weak or conflicting.
