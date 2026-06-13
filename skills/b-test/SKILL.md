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
- The issue is assertion, mock, fixture, setup, snapshot, or test coverage.
- Non-browser unit, integration, contract, simulated-DOM, and component tests are in scope.

## When NOT to use

- The failing test likely exposes product behavior -> use **b-debug**.
- Real browser, visual, session, or e2e evidence is needed -> use **b-browser**.
- Intended behavior is unclear -> use **b-plan** or **b-debug**.
- A new test framework is needed -> use **b-plan** first.

## Tools required

- `bash` - run tests and inspect failure output.
- `serena-symbol-toolkit` - map tests to source behavior and edit test symbols.

## Steps

1. Find the test framework and narrowest runnable command from manifests, CI, or existing tests.
2. Confirm intended behavior from user intent, product contract, source change, existing passing tests, framework docs, and relevant repo context (`CONTEXT.md`, `CONTEXT-MAP.md`, `docs/adr/`, `docs/agents/`, or `.b-agentic/` notes).
3. For failing tests, run the narrow target, read the test and exercised source, and classify the failure.
4. For new tests, cover requested or changed behavior through the highest practical public interface first; add edge cases only when risk requires them.
5. For TDD-style work, use vertical tracer bullets: one behavior, one failing test, minimal implementation, then repeat.
6. Run diagnostics when useful, then the narrowest relevant test, and verify the test proves the intended behavior.

## Output format

Test scope, changes, verification, and remaining gaps.

## Rules

- Never change production code only because a test is red.
- Never update assertions, snapshots, or goldens without confirming intended behavior.
- Avoid implementation-coupled tests and mocks derived from buggy implementation instead of the real interface.
- Do not introduce frameworks without approval.
- Keep fixture and mock changes local when practical.
