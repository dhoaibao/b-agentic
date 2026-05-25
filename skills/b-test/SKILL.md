---
name: b-test
description: >
  Test-driven development, test debugging, and test coverage evaluation.
  Use for writing tests, fixing failing tests, evaluating coverage, or
  working TDD-style. Unlike b-debug, which traces runtime bugs, b-test
  owns test-specific failures and simulated-DOM/component-test work: wrong
  assertions, missing mocks, fixture or setup issues, and coverage gaps.
  Real-browser, visual, browser-session, and e2e verification belongs to
  b-browser.
argument-hint: "[test-task-or-failure]"
---

<!-- Generated from skills/registry.yaml and skills/b-test/prompt.md. Edit those sources, not this file. -->

# b-test

$ARGUMENTS

Own code-level and simulated-DOM tests: add coverage, fix test-only failures, and avoid confusing red tests with product bugs.

## When to use

- The user asks to write tests, fix failing tests, evaluate coverage, or work TDD-style.
- The global test-vs-bug decision routes a failing test to the test lane.
- Non-browser unit, integration, contract, simulated-DOM, and component tests are in scope when the repo already has the relevant test style.

## When NOT to use

- The failing test likely exposes real runtime behavior -> use **b-debug**.
- The task drives a real browser, performs visual testing, depends on browser/session state, or runs e2e/browser-only tooling -> use **b-browser**; simulated-DOM and component tests stay here. Stop rather than adding browser or DOM tooling. See `../../b-agentic/references/contract/10-decisions.md` for the boundary table with concrete examples.
- Scope, acceptance, or intended behavior is unclear -> use **b-plan** (Clarification mode) or **b-debug** per the global test-vs-bug decision.
- The task is pre-PR logic review -> use **b-review**.
- The task needs a new test strategy/framework -> use **b-plan** first.

## Tools required

- `bash` - run tests/coverage and inspect failure output.
- Native file tools - discover manifests, test files, and focused source/test sections.
- `serena-symbol-toolkit` *(preferred for mapping tests to source behavior and editing existing tests)*
- `context7-docs` *(optional, for testing-framework API or matcher behavior)*


## Steps

### Step 1 - Discover framework and scope

Find relevant test files and project commands from manifests or CI. If a failing test is named, start with the narrowest runnable target. If no test framework exists, ask before adding one.

### Step 2 - Choose the lane

Read `../../b-agentic/references/contract/10-decisions.md` before applying the test-vs-bug decision. Read `../../b-agentic/references/contract/05-evidence.md` before using the baseline source taxonomy. Acceptable behavior confirmation sources are user-confirmed intent, an approved spec/plan, existing product contract, existing passing tests that define the behavior, source change that intentionally updates behavior, or fetched framework docs for API semantics. If no behavior baseline exists, stop and hand off to **b-plan** (Clarification mode) for unclear intent or **b-debug** for uncertain product behavior, unless the user explicitly asks for structural coverage only.

- **Failing test:** fix assertion, mock, fixture, setup, async, snapshot, or harness drift only after intended behavior is confirmed.
- **Write tests:** add regression/unit/integration coverage for known behavior. For TDD or regression work, make the test fail first when feasible, then hand off with the intended behavior, failing test path, command, current failure, likely source area, and verification target before production changes.
- **Coverage review:** rank missing tests by user impact, changed behavior, risk boundary, and edge-case value; add only the requested/highest-value gaps.
- **Flaky test:** read `../../b-agentic/references/contract/10-decisions.md` before applying flake handling, rewriting, or skipping.

Choose test type by the behavior boundary: pure logic gets unit tests, simulated-DOM/component behavior stays here, and cross-module contracts get integration or contract tests if the repo already has them.

If product behavior is uncertain, hand off to **b-debug**.

### Step 3 - Fix or add tests

For failing tests, run the narrow command, read the test and exercised source, classify the failure, and apply snapshot/golden confirmation before updating derived artifacts.

For new tests, cover behavior that matters: happy path, edge cases, error handling, and the regression that would catch an accidental revert. Prefer local fixtures unless an existing shared fixture fits. Read `../../b-agentic/references/contract/07-execution.md` before applying the test data lifecycle rule when tests create, mutate, or rely on persistent data.

For coverage review, stop when changed behavior is covered, the next gap is opportunistic, or five gaps have been added with no required gap remaining.

Use Serena for existing test bodies. Read `../../b-agentic/references/contract/06-safety.md` before using `apply_patch` for new test files or small non-symbol edits under the global patch discipline.

### Step 4 - Verify

Run diagnostics on touched test/source files when supported, then the narrowest relevant test. Widen only for shared fixtures/helpers, public contracts, or the repo's normal workflow. Read `../../b-agentic/references/contract/07-execution.md` before using skipped-check labels.

## Output format

```text
Type -> Framework -> Findings -> Changes -> Verification -> Remaining gaps
```


## Rules

- Never change production code just because a test is red.
- Never update assertions, snapshots, or goldens without confirming intended behavior.
- Add `baseline-missing` tests only when the user explicitly asks for structural coverage; otherwise stop or hand off before writing them.
- Do not introduce test, coverage, property-based, fuzzing, or contract-test frameworks without approval.
- Keep fixture and mock changes local when practical.
- Read `../../b-agentic/references/contract/06-safety.md` before manual patches and `../../b-agentic/references/contract/07-execution.md` before applying the verification ladder or iteration cap.
- Test utilities belong here when created or changed to support an in-scope test; mechanical relocation belongs to **b-refactor**.
