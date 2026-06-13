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
- `serena-symbol-toolkit` - trace symbols, call sites, implementations, and focused fixes.

## Steps

1. Capture exact symptom, expected vs actual behavior, repro, determinism, and environment.
2. Rank suspects from stack traces, diagnostics, recent changes, config, data shape, and call paths.
3. Use CodeGraph for cross-file call paths or impact radius when indexed; otherwise use Serena plus local search.
4. Confirm root cause before fixing. Use probes only when cheaper evidence is insufficient and remove them.
5. Apply the smallest fix that addresses the confirmed cause.
6. Run the narrowest check proving the symptom changed. For perf, measure before and after.

## Output format

Symptom, root cause, fix, verification, and cleanup state.

## Rules

- Do not patch speculatively.
- Do not bundle redesign or cleanup.
- Surface cannot-reproduce gaps instead of guessing.
- Verify probe removal before reporting success.
