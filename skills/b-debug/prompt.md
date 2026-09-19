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

- `read` - inspect repository context and the main session's supplied reproduction evidence only when it materially affects the diagnosis.
- `mcp` - use only one classified read-only or safe conditional-read gateway operation at a time; the child guard blocks `mcpScript` and unclassified calls.
- `codegraph` - select when a concrete repository-wide dependency/call-flow or impact question is central to the diagnosis and likely valuable; use an available index for that question and report an absent-index gap to the main session.
- `context7` - versioned dependency/API behavior only when a library suspect remains after local evidence.
- `recall` - recover compacted repro or prior-diagnosis memory ids when present.

## Steps

1. Establish a feedback loop from the main session's supplied failing test, CLI reproduction, HTTP/browser trace, replay, diagnostic output, or baseline measurement. The read-only child does not run commands or create probes.
2. Capture exact symptom, expected vs actual behavior, repro rate, determinism, and environment. Use read for repo context only when it materially affects the diagnosis; use recall when a compacted prior diagnosis id is available.
3. Rank suspects from stack traces, diagnostics, recent changes, config, data shape, call paths, and the feedback loop.
4. Select CodeGraph when a concrete repository-wide flow or impact question is central to the diagnosis and likely valuable; use an available index for that question and report an absent-index gap to the main session. Use Context7 only for versioned dependency suspects.
5. Confirm the root cause before handing it off. If the supplied evidence cannot prove it, report the exact additional reproduction or diagnostic artifact the main session must collect rather than creating a probe.
6. Produce a diagnosis handoff that names the next skill: **b-frontend** for a UI fix, **b-implement** for a clear non-UI fix, **b-test** for a test-only correction, or **b-plan** when scope remains unclear. Include the exact runnable repro command, the observable that must flip, and the confirmed causal mechanism.
7. Stop without editing product code. For performance work, include the baseline measurement in the handoff; the main session changes product code and reruns the same measurement.
8. If the issue is not yet a confirmed bug, say whether the next step belongs in **b-plan**, **b-research**, or **b-test**.

## Output format

Symptom, confirmed root cause, and evidence. Include the diagnosis handoff: target skill, exact runnable repro command, observable to flip, confirmed causal mechanism, and baseline measurement for performance work. Do not include a product fix.

## Rules

- Do not patch speculatively or edit product code.
- Do not bundle redesign or cleanup.
- Use `mcp` only for a single classified read-only or safe conditional-read gateway operation; report any unavailable or unclassified evidence gap to the main session.
- If no trustworthy feedback loop can be built, report what you tried and what artifact/access is needed instead of guessing.
