---
name: b-debug
description: >
  Systematic hypothesis-driven debugging. ALWAYS invoke when the user reports
  a runtime bug, an error, broken behavior, slow path, memory issue, or
  pastes a stack trace. Traces execution, confirms root cause, then fixes
  minimally and verifies. Unlike b-test, b-debug owns runtime behavior
  failures, not test-mechanic issues such as wrong assertions, mocks, or
  fixtures.
compatibility: opencode
metadata:
  suite: b-skills
---

# b-debug

$ARGUMENTS

Trace the bug, confirm root cause, apply the smallest safe fix, verify, and remove probes. Do not patch before the cause is explicit.

If `$ARGUMENTS` includes a symptom, error, or stack trace, start from it directly. If the user asked only for diagnosis, stop after the confirmed root cause and proposed fix.

## When to use

- The user reports a runtime bug, broken behavior, or error message.
- A test likely exposes a real product bug rather than a test harness issue (`AGENTS.md` §10).
- The failure path may cross middleware, async boundaries, configuration, or multiple modules.
- The bug is non-deterministic (flake, race, time/network dependence) and the test lane has ruled out fixture or harness drift.
- The symptom is **slow**, not wrong — latency regression, memory leak, runaway CPU, or unbounded growth.

## When NOT to use

- The problem is clearly a test assertion, mock, fixture, or setup issue → use **b-test**.
- The task is external docs or API lookup only → use **b-research**.
- The task is a new feature or scoped implementation request → use **b-plan** or **b-implement**.

## Boundary examples

- **Use b-debug:** "This endpoint started returning 500 after the deploy" or "the dashboard got slower after yesterday's merge."
- **Use b-test instead:** "The snapshot changed after the copy update" when production behavior is already known to be correct.

## Tools required

- `serena-symbol-toolkit` *(preferred for tracing and focused fixes)*
- `gitnexus-radar` *(optional radar for unfamiliar cross-module paths)*
- `context7-docs` *(optional, for suspected library/API misuse)*
- `brave-discovery` + `firecrawl-extraction` *(optional, for known public errors; honor `AGENTS.md` §6 privacy gate)*
- Native search and `bash` — exact error strings, config keys, repeated patterns, narrow source reads, reproduction commands, profilers.

Fallbacks: `AGENTS.md` §4 MCP fallback ladder.

Graceful degradation: ✅ Possible — native analysis still works; cross-file tracing is slower without Serena.

## Steps

### Step 1 — Frame the symptom

Collect only what is needed to begin:
- Exact error or observable failure.
- Expected vs actual behavior.
- Reproduction notes.
- Determinism: reproducible every run, intermittent, or one-shot.
- For perf bugs: workload shape, baseline timing, threshold or SLO that was violated.

If the bug is currently production-impacting or risks data loss/security exposure, take a mitigation-first branch: identify the safest immediate containment option (disable path, rollback candidate, feature flag, traffic drain, or user-visible workaround), ask for approval before any shared-environment action, then continue root-cause analysis from the contained state.

If a stack trace or diagnostic already points at one function or file, mark it as a **fast path** and go directly to Step 3.

### Step 2 — Map the path and rank suspects

Use `gitnexus-radar` only when the path is unfamiliar, graph-shaped, or route/consumer oriented. Stop once the likely subsystem or boundary is identified.

Then use `serena-symbol-toolkit` to confirm owners, references, and code shape. Pick the cheapest discovery tool that closes the next question (`AGENTS.md` §4).

**First-suspect heuristic** — bias toward these patterns before broader experimentation:
- Swallowed errors and silent catches.
- Auth/authz gates and middleware short-circuits.
- Config drift and environment-variable defaults.
- Async ordering, missing `await`, race-prone callbacks.
- Shared-state leaks across requests, tests, or threads.
- Off-by-one and boundary conditions in newly added code.
- For perf bugs: N+1 queries, unbounded retries, hot-loop allocations, blocking I/O on the request path.

For non-deterministic bugs, enumerate the candidate non-determinism sources first (shared state, async ordering, time, network, randomness, environment).

Rank remaining hypotheses by likelihood × cheapest verification. Example: a "config default flipped" hypothesis (verifiable in one `grep`) outranks a "race in worker pool" hypothesis (requires stress harness) even when the race is slightly more likely — verify the cheap one first, then move on. Skip ranking when the fast path already isolates one cause.

### Step 3 — Confirm root cause cheaply

Start with the cheapest verification:
- Search the codebase for the exact error string or log text.
- For library/framework errors, check `context7-docs` for exact API/option behavior.
- For known public errors, optionally use `brave-discovery` + `firecrawl-extraction` after honoring the privacy gate (`AGENTS.md` §6).
- Local diagnostics: `get_diagnostics_for_file`.
- A narrow repro command already in the project.
- Targeted temporary logging at one choke point.
- For perf bugs: profiler, `time`/`hyperfine`, runtime tracing, or a tight benchmark — never guess from code shape alone.
- For non-deterministic bugs: forced ordering, fake clock, stress loop. Repro must demonstrate the failure under conditions you control before claiming root cause.

If the symptom **cannot be reproduced** — disappears between sessions, was reported but never returns — do not patch. State this explicitly, capture every state difference between the failing report and current environment (config, version, data), and ask the user whether to (a) instrument and wait, (b) treat as one-shot, or (c) investigate the diff.

State the root cause explicitly before editing:

`Root cause: <what fails> because <why>` (extend with conditions when the bug only fires under Z).

### Step 4 — Apply the minimal fix

Keep the fix narrow:
- Use `serena-symbol-toolkit` edits when the change is symbol-scoped.
- Use `apply_patch` for small line-level fixes inside a larger symbol.
- Add a brief comment only when the fix would otherwise be non-obvious.

Do not roll broader cleanup or unrelated refactors into the bug fix.

### Step 5 — Verify and remove probes

1. Run the narrowest relevant command that proves the symptom changed.
2. For non-deterministic bugs, also run the stress repro from Step 3 long enough to gain confidence the race no longer triggers.
3. For perf bugs, re-run the benchmark and report the before/after delta, not just "feels faster."
4. **Re-scan the diff** for every temporary probe added during Step 3: `console.log`, `print`, breakpoints, extra metrics, debug flags, fake clocks, profiler hooks. Remove each one that was not part of the final fix and re-run verification.
5. If the fix affects config or process startup, tell the user whether a restart or reload is required.
6. If the fix touched several files or a shared boundary, emit a handoff envelope (`AGENTS.md` §9) recommending **b-review**.

Apply the verification ladder and iteration cap from `AGENTS.md` §7.

Close with the skill-exit status block (`AGENTS.md` §9).

## Rules

- Never patch before confirming root cause.
- Use the obvious-stack-trace fast path when one file or function is already strongly implicated.
- For perf bugs, measure before and after; do not infer speed from code structure.
- For cannot-reproduce reports, stop and surface the gap; do not speculate-fix.
- For active production impact, prefer approved containment before deep investigation; do not mutate shared environments without the approval gate in `AGENTS.md` §6.
- Verify probe removal explicitly before reporting success.
- Attach the confidence signal (`AGENTS.md` §3) when the fix relies on indirect or partial evidence.
