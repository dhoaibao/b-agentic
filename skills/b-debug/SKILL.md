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

- `bash` - exact errors, config, repro commands, profilers, and diagnostics.
- `serena-symbol-toolkit` - trace symbols, inspect call sites, and perform focused fixes.

## Steps

### Step 1 - Frame symptom

Capture exact failure, expected vs actual behavior, repro, determinism, environment, and for perf bugs workload/baseline/threshold. Check recent commits, dependency/lockfile changes, config drift, flags, data shape, and environment differences.

For active production impact, data loss, or security risk, read `../../b-agentic/references/contract/safety-tools.md` before containment. Label containment as reversible mitigation, not final fix.

### Step 2 - Rank suspects

Use stack traces and diagnostics first. Otherwise map the path with Serena.

**Serena tracing workflow:**
1. `get_symbols_overview` on the error location file to understand structure.
2. `find_symbol` with `include_body=True` on the failing function, method, or class.
3. `find_referencing_symbols` on that symbol to trace call sites and coupling.
4. `find_implementations` when the symptom spans an interface/implementation boundary.
5. `get_diagnostics_for_file` on files in the suspect path for type errors and warnings.

Bias checks toward swallowed errors, auth/authz gates, config drift, missing awaits, async ordering, shared state, new boundary errors, and for perf N+1 queries, retries, hot allocations, or blocking I/O.

### Step 3 - Confirm root cause

Use the cheapest proof: exact error search, local diagnostics, narrow repro, targeted docs lookup, benchmark/profiler, forced ordering, fake clock, or stress loop.

Temporary probes are allowed only when cheaper evidence is insufficient; tag every probe with `b-debug-probe`. If the symptom cannot be reproduced, capture environment differences and ask for exact repro/logs instead of patching defensively.

Before the final fix, state: `Root cause: <what fails> because <why>`.

### Step 4 - Fix minimally

Use Serena for symbol edits. Do not bundle cleanup or redesign. If the confirmed cause needs structural work, hand off to **b-plan** with root cause, evidence, and attempted minimal fix.

**Serena editing workflow:**
1. `get_symbols_overview` on the target file to locate the symbol.
2. `find_symbol` with `include_body=True` to read the full definition before editing.
3. Perform the edit with `replace_symbol_body` or `replace_content`.
4. `get_diagnostics_for_file` to verify the edit introduced no errors.
5. `find_referencing_symbols` to confirm callers still resolve correctly.

### Step 5 - Verify and clean up

Run the narrowest check that proves the symptom changed. For nondeterminism, run a sufficient stress repro; for perf, report before/after measurements. Remove `b-debug-probe` markers and scan for debug leftovers. Re-run verification after cleanup.

If `git-delta` is configured as `core.pager`, use `GIT_PAGER=cat git diff` or `git --no-pager diff` when parsing diff output.

## Output format

```text
Symptoms -> Root cause -> Fix -> Verification -> Cleanup/next
```

## Rules

- Do not apply the final fix before root cause is confirmed.
- Measure perf bugs before and after.
- Surface cannot-reproduce gaps instead of speculative fixes.
- Stop at the class-aware iteration cap.
- Verify probe removal before reporting success.
- Use Serena for every code trace and edit; do not guess symbol locations or edit without reading definitions first.

## Reference pointers

- Read `./reference.md` before adding temporary probes, framing perf bugs, or when the symptom spans multiple layers.
- Read `../../b-agentic/references/performance-checklist.md` before diagnosing a slowdown that spans layers or lacks a clear measurement playbook.
