# b-qa

Run the acceptance gate on a reviewed, frozen candidate: map every acceptance criterion to fresh evidence and return a QA verdict. This skill runs in the main session; it never writes product code or tests, drives a browser, commits, or pushes.

## When to use

- The user asks for QA, an acceptance check, or a criterion-to-evidence matrix.
- An approved plan names a QA gate after **b-review**.

## When NOT to use

- Changed-code review, or a triggered candidate with no ready verdict -> **b-review**.
- Writing or fixing tests -> **b-test**.
- Browser, visual, or e2e evidence, including a stand-alone visual check -> **b-browser**.
- A runtime failure -> **b-debug**.
- Missing or ambiguous acceptance criteria -> **b-plan**, or ask the user.
- Staging, commit, or PR -> **b-commit** / **b-pr** on explicit request.

## Tool guidance

- Main session only. Use `node ~/.claude/b-agentic/bin/b-candidate-snapshot.mjs` for candidate identity, with the same `--include-ignored <path>` set the review used.
- Run existing repository commands through `rtk`; never invent commands. Use native `Read` and `Grep` (or `rg`) for inspection evidence.
- In an indexed project, use `codegraph_explore` (read-only) for affected tests and routes; report an absent or stale index as a gap and never initialize one.
- No Playwright tools, no edits.

## Steps

1. Confirm the inputs: baseline, numbered acceptance criteria with their source, candidate paths, and either the **b-review** verdict with its final fingerprint, recorded target, and resolved baseline, or the recorded low-risk review exception. If any is missing, return `QA BLOCKED` and ask with `AskUserQuestion`.
2. Freeze the candidate as Q0. With a review, compare Q0 with the review fingerprint and confirm the review's recorded target and resolved baseline cover the whole QA candidate; a matching fingerprint over a narrower review scope is not coverage. A mismatch, a narrower scope, or `complete: false` means `QA BLOCKED`: the review does not cover this candidate, so it needs fresh checks and a new **b-review**. With the recorded low-risk review exception, reconfirm that it still applies and that required checks pass, then use Q0 as the only baseline. `NEEDS FIXES`, or no verdict for a candidate that required review, is also blocked.
3. Build the matrix: criterion -> evidence type (automated check, browser, CI, inspection, user-confirmed) -> exact command or source -> owning skill. Reuse check results already produced for the same fingerprint and run only what is missing. CI evidence counts only when the CI run's SHA equals the committed HEAD that is the candidate.
4. Choose regression scope by impact, narrowest first. State where the selection came from; an affected-only run is never full coverage.
5. Collect evidence with existing non-mutating commands (no snapshot updates, no fixers). Hand browser, e2e, and dev-server evidence to **b-browser** and missing or failing tests to **b-test** as separate phases. Keep artifacts outside the candidate. Do not edit during QA.
6. Mark each row met, not met, or gap. A gap is never a pass. Route failures: product behavior to **b-debug**, test mechanics to **b-test**, a known fix to **b-implement** or **b-frontend**, environment or tool problems to `QA BLOCKED`. The user may waive a criterion; record it as waived by user.
7. Freeze the candidate again as Q1. If Q1 differs from Q0, the evidence is void: `QA BLOCKED` with the changed paths.
8. Hand off. Any fix re-enters its change phase, then fresh checks, a fresh **b-review** when required, and a new QA round on the new fingerprint. After 3 consecutive `QA FAIL` rounds, stop and ask the user.

## Output format

Matrix (`# | Criterion | Evidence type | Command/source | Result | Status`), regression scope with what was not covered, snapshot identities (review fingerprint, Q0, Q1), routed follow-ups, and residual risk. The response must end with exactly one standalone final line, with no text after it:
- `Verdict: QA PASS`
- `Verdict: QA FAIL`
- `Verdict: QA BLOCKED`

## Rules

- A criterion without evidence is a gap, never an implicit pass.
- Evidence must belong to the current fingerprint; a changed candidate needs fresh checks and a new **b-review**.
- A **b-review** verdict is input, not acceptance, and QA never waives a required review.
- Do not do **b-test** or **b-browser** work yourself.
- QA never stages, commits, or pushes, and `Verdict: QA PASS` does not authorize a commit or shipping.
