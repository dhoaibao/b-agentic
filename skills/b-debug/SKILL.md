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

Confirm root cause, fix minimally, verify, and remove probes. If the user asks only for diagnosis, stop after root cause and proposed fix.

## When to use

- The user reports a runtime bug, broken behavior, error, stack trace, race, memory issue, or slowdown.
- A test likely exposes a real product bug under the global test-vs-bug decision.
- The failure may cross middleware, async boundaries, configuration, or multiple modules.

## When NOT to use

- The problem is a test assertion, mock, fixture, or setup issue -> use **b-test**.
- The task is external docs/API lookup only -> use **b-research**.
- The task is new scoped work -> use **b-plan** or **b-implement**.

## Tools required

- `serena-symbol-toolkit` *(preferred for tracing and focused fixes)*
- `context7-docs` *(optional, for suspected API misuse)*
- `brave-search` + `firecrawl-extraction` *(optional, for public errors, recent deprecations, or upstream advisories after the privacy gate)*
- Native search and `bash` - exact errors, config, repro commands, profilers, and diagnostics.


## Steps

### Step 1 - Frame the symptom

Collect exact failure, expected vs actual behavior, repro notes, determinism, and for perf bugs workload/baseline/threshold. Read `../../b-agentic/references/contract/05-evidence.md` before using the baseline source taxonomy when expected behavior is disputed or weak. Check the regression window when available: recent commits, dependency or lockfile changes, config drift, feature flags, data shape changes, and environment differences.

For non-trivial or blocked bugs, keep a repro record: command or interaction, workspace or target, relevant versions/config flags, data mode, expected behavior, actual behavior, determinism, and strongest evidence. Do not include secret values or private data.

If production impact, data loss, or security risk is active, read `../../b-agentic/references/contract/06-safety.md` before identifying containment or asking for shared-environment action. Treat containment as a reversible mitigation, not the final fix; record what remains unproven until root cause is confirmed.

### Step 2 - Rank suspects only as needed

Use the stack trace or diagnostic fast path when one file/function is already strongly implicated. Otherwise map the path with the lightest tool: Serena/native reads for exact owners and references.

Bias first checks toward swallowed errors, auth/authz gates, config drift, missing `await`, async ordering, shared-state leaks, and new boundary errors. For perf, measure N+1 queries, unbounded retries, hot-loop allocations, or blocking I/O before guessing.

### Step 3 - Confirm root cause

Use the cheapest proof: exact error search, local diagnostics, narrow repro command, targeted docs lookup, benchmark/profiler, forced ordering, fake clock, or stress loop.

Temporary probes are allowed only when cheaper evidence is insufficient. Use instrumentation when the symptom is intermittent, remote-only, timing-dependent, or hidden behind swallowed errors and a bounded probe can collect decisive evidence; otherwise request the missing repro data or hand off to **b-plan** for structural diagnosis work. Tag every probe with `b-debug-probe` in the language-appropriate comment form.

If the agent cannot reproduce a user-reproducible symptom, read `../../b-agentic/references/contract/10-decisions.md` before applying the cannot-reproduce protocol; do not patch defensively.

Read `../../b-agentic/references/contract/09-output.md` before handing off to another skill or closing a non-trivial debug run with a status block.

Before applying the final fix, state: `Root cause: <what fails> because <why>`.

### Step 4 - Apply the minimal fix

Use Serena for symbol edits. Read `../../b-agentic/references/contract/06-safety.md` before applying small line/prose/config patches under the global patch discipline.

Do not bundle cleanup or redesign. If urgent containment was applied before root cause, continue diagnosis or hand off with the mitigation clearly labeled as containment. If the confirmed cause needs a structural change, hand off to **b-plan** with root cause, evidence, and any attempted minimal fix.

### Step 5 - Verify and clean up

Read `../../b-agentic/references/contract/07-execution.md` before choosing verification or applying skipped-check labels. Run the narrowest check that proves the symptom changed. For nondeterminism, run the stress repro long enough to support confidence. For perf, report before/after measurements.

Remove all `b-debug-probe` markers and scan for untagged debug leftovers (`console.log`, `print`, breakpoints, fake clocks, profiler hooks). Run `rg --hidden 'b-debug-probe' -- <touched-paths>` and verify zero matches before reporting success. Re-run verification after cleanup. Mention restart/reload requirements when config or startup changed.

## Output format

```text
Symptoms -> Root cause -> Fix -> Verification -> Cleanup/next
```


## Rules

- Do not apply the final fix before root cause is confirmed. Approved containment may happen first only to reduce active production, data-loss, or security impact, and must be labeled as containment.
- Measure perf bugs before and after.
- Surface cannot-reproduce gaps instead of speculative fixes.
- Read `../../b-agentic/references/contract/06-safety.md` before manual patches under the global patch discipline and `../../b-agentic/references/contract/07-execution.md` before applying the verification ladder, iteration cap, or skipped-check labels.
- Verify probe removal before reporting success.

## Reference pointers

- Read `../../b-agentic/references/performance-checklist.md` before diagnosing a slowdown that spans layers or lacks a clear measurement playbook.
