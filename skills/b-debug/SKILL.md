---
name: b-debug
description: >
  Systematic hypothesis-driven debugging for runtime bugs, errors, broken
  behavior, slow paths, memory issues, and stack traces. Traces execution,
  confirms root cause, then fixes minimally and verifies. Unlike b-test,
  b-debug owns runtime behavior failures, not test-mechanic issues such as
  wrong assertions, mocks, or fixtures.
argument-hint: "[symptom-or-error]"
---

<!-- Generated from skills/registry.yaml and skills/b-debug/prompt.md. Edit those sources, not this file. -->

# b-debug

$ARGUMENTS

Confirm root cause, fix minimally, verify, and remove probes.

## When to use

- The user reports a runtime bug, broken behavior, error, stack trace, race, memory issue, or slowdown.
- A failing test likely exposes a real product bug.

## When NOT to use

- The problem is only a test assertion, mock, fixture, or setup issue -> use **b-test**.
- The task is external docs/API lookup only -> use **b-research**.
- The task is new scoped work -> use **b-plan** or **b-implement**.

## Tools required

- `bash` - reproduce errors, run diagnostics, profilers, and checks.
- `codegraph` - call paths, dependency flows, and impact radius when indexed.
- `serena` - trace symbols, call sites, implementations, and focused fixes.

## Steps

1. Build a feedback loop that can show the bug: failing test, CLI repro, HTTP script, browser script, trace replay, throwaway harness, fuzz/property loop, or bisect harness.
2. Capture exact symptom, expected vs actual behavior, repro rate, determinism, and environment. Read relevant `CONTEXT.md`, `CONTEXT-MAP.md`, `docs/adr/`, `docs/agents/`, or `.b-agentic/` notes when present.
3. Rank suspects from stack traces, diagnostics, recent changes, config, data shape, call paths, and the feedback loop.
4. Use CodeGraph for cross-file call paths or impact radius when indexed; otherwise use Serena plus local search.
5. Confirm root cause before fixing. Use probes only when cheaper evidence is insufficient and remove them.
6. Apply the smallest fix that addresses the confirmed cause.
7. Run the original feedback loop or narrowest check proving the intended symptom changed. For perf, measure before and after.

## Output format

Symptom, root cause, fix, verification, and cleanup state.

## Rules

- Do not patch speculatively.
- Do not bundle redesign or cleanup.
- If no trustworthy feedback loop can be built, report what you tried and what artifact/access is needed instead of guessing.
- Verify probe removal before reporting success.
