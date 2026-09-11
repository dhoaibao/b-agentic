---
name: b-debug
description: >
  Systematic hypothesis-driven diagnosis for runtime bugs, errors, broken
  behavior, slow paths, memory issues, and stack traces. Confirms root
  cause and produces a handoff with the exact runnable repro command,
  observable to flip, and confirmed causal mechanism, without editing
  product code. When the issue is not yet a confirmed product bug, it
  hands off cleanly instead of guessing. Unlike b-test, b-debug owns
  runtime behavior failures, not test-mechanic issues such as wrong
  assertions, mocks, or fixtures. Routing signals: bug, broken, stack
  trace, "not working", runtime error, regression, product regression,
  product bug, diagnose.
---

<!-- Generated from skills/registry.yaml and skills/b-debug/prompt.md. Edit those sources, not this file. -->

# b-debug

Confirm the real cause of broken runtime behavior, then produce an evidence-backed handoff for the fix. Do not edit product code.

## When to use

- The user reports a runtime bug, broken behavior, error, stack trace, race, memory issue, or slowdown.
- A failing test likely exposes a real product bug.

## When NOT to use

- The problem is only a test assertion, mock, fixture, or setup issue -> use **b-test**.
- The task is external docs/API lookup only -> use **b-research**.
- New scoped frontend/UI work -> use **b-frontend**; a clear non-UI change -> use **b-implement**; an unclear change -> use **b-plan**.

## Tool guidance

- `bash` - reproduce errors and run diagnostics/profilers/checks (`rtk` for test runners and other high-noise families).
- `read` - inspect repository context only when it materially affects the diagnosis.
- OS-temporary scratch files - create disposable probes or harnesses only outside the worktree, then remove them.
- `codegraph` - select when a concrete repository-wide dependency/call-flow or impact question is central to the diagnosis and likely valuable; use an available index for that question and initialize an absent index only for that qualifying question.
- `context7` - versioned dependency/API behavior only when a library suspect remains after local evidence.
- `recall` [cap: package.pi-observational-memory] - recover compacted repro or prior-diagnosis memory ids when present; without it, diagnose from current evidence.

## Steps

1. Build a feedback loop (using Bash to run commands) that can show the bug: failing test, CLI repro, HTTP script, browser script, trace replay, disposable throwaway harness, fuzz/property loop, or bisect harness.
2. Capture exact symptom, expected vs actual behavior, repro rate, determinism, and environment. Use read for repo context only when it materially affects the diagnosis; use recall when a compacted prior diagnosis id is available.
3. Rank suspects from stack traces, diagnostics, recent changes, config, data shape, call paths, and the feedback loop.
4. Select CodeGraph [cap: mcp.codegraph] when a concrete repository-wide flow or impact question is central to the diagnosis and likely valuable; use an available index for that question and initialize an absent index only for that qualifying question. Use Context7 [cap: mcp.context7] only for versioned dependency suspects.
5. Confirm the root cause before handing it off. Use probes only when cheaper evidence is insufficient and remove every scratch artifact.
6. Produce a diagnosis handoff that names the next skill: **b-frontend** for a UI fix, **b-implement** for a clear non-UI fix, **b-test** for a test-only correction, or **b-plan** when scope remains unclear. Include the exact runnable repro command, the observable that must flip, and the confirmed causal mechanism.
7. Stop without editing product code. For performance work, include the baseline measurement in the handoff; the implementing skill changes product code and reruns the same measurement.
8. If the issue is not yet a confirmed bug, say whether the next step belongs in **b-plan**, **b-research**, or **b-test**.

## Output format

Symptom, confirmed root cause, and evidence. Include the diagnosis handoff: target skill, exact runnable repro command, observable to flip, confirmed causal mechanism, and baseline measurement for performance work. State scratch cleanup. Do not include a product fix.

## Rules

- Do not patch speculatively or edit product code.
- Do not bundle redesign or cleanup.
- If no trustworthy feedback loop can be built, report what you tried and what artifact/access is needed instead of guessing.
- Verify scratch cleanup before reporting success.
