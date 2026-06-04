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
- The global test-vs-bug decision routes a failing test to this lane.
- Non-browser unit, integration, contract, simulated-DOM, and component tests are in scope when the repo already has the style.

## When NOT to use

- The failing test likely exposes real runtime behavior -> use **b-debug**.
- Real browser, visual, session, or e2e tooling is needed -> use **b-browser**.
- Scope or intended behavior is unclear -> use **b-plan** or **b-debug** per the global decision.
- The task is pre-PR logic review -> use **b-review**.
- The task needs a new test strategy/framework -> use **b-plan** first.

## Tools required

- `bash` - run tests/coverage and inspect failure output.
- `serena-symbol-toolkit` *(preferred for mapping tests to source behavior and editing existing tests)*
- `context7-docs` *(optional, for testing-framework API or matcher behavior)*
- Optional runtime subagent: `b-verify` may gather existing command, diagnostic, or coverage evidence. The active **b-test** skill owns failure classification, fixes, assertions, status, and handoff.

## Steps

### Step 1 - Discover framework and scope

Find test files and commands from manifests or CI. If a failing test is named, start with the narrowest runnable target. If no framework exists, hand off to **b-plan** before adding one.

### Step 2 - Choose lane

Assertion/mock/fixture/setup drift stays in **b-test**; uncertain product behavior goes to **b-debug**. Confirm intended behavior from user intent, approved spec/plan, product contract, existing passing tests, intentional source change, or framework docs. If no baseline exists, hand off unless the user explicitly asks for structural coverage only.

### Step 3 - Fix or add tests

For failing tests, run the narrow command, read the test and exercised source, classify the failure, and confirm snapshots/goldens before updating derived artifacts.

For new tests, cover requested or changed behavior first. Add edge/error/regression cases only when baseline or risk makes them required; otherwise list follow-up gaps. For coverage review, stop when requested/high-value gaps are covered or the next gap is opportunistic.

Use Serena for existing test bodies.

### Step 4 - Verify

Run diagnostics when supported, then the narrowest relevant test. Widen only for shared fixtures/helpers, public contracts, or normal repo workflow.

## Output format

```text
Type -> Framework -> Findings -> Changes -> Verification -> Remaining gaps
```

## Reference pointers

- Read `./reference.md` for framework detection, snapshot procedures, mock/fixture debugging, assertion failure classifications, and handoff guidance.

## Rules

- Never change production code just because a test is red.
- Subagents are optional accelerators; never let them update assertions, snapshots, goldens, or status blocks.
- Never update assertions, snapshots, or goldens without confirming intended behavior.
- Add `baseline-missing` tests only when the user explicitly asks for structural coverage.
- Do not introduce testing frameworks without **b-plan** and dependency-write approval.
- Keep fixture and mock changes local when practical.
