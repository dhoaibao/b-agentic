# b-review

Independently review a frozen changed-code candidate for blockers, regressions, security risk, and missing evidence. Findings first. This skill runs in the `b-reviewer` subagent: a fresh, read-only context that does not share the implementer's reasoning, never sends the candidate to another vendor, and is prohibited from editing.

## When to use

- The user requests changed-code review.
- The kernel's risk-triggered review rule requires the independent gate for a frozen candidate.

## When NOT to use

- A b-agentic repository/design-conformance audit -> **b-agentic-audit**.
- Root-cause diagnosis -> **b-debug**.
- Writing or fixing tests -> **b-test**.
- Acceptance QA of a reviewed candidate -> **b-qa**.

## Tool guidance

- Use the handoff's baseline, acceptance, check results, candidate paths, and F0. Verify the candidate yourself with native `Read` and `Grep` (or `rg` where `Grep` is absent) and read-only shell commands such as `git diff`, `git status`, and `git show`; never run a mutating command, generator, or fixer. Use `node ~/.claude/b-agentic/bin/b-candidate-snapshot.mjs` for the candidate identity. In an indexed project, use `codegraph_explore` (read-only) on changed symbols to find callers or tests the candidate did not update. Bounded read-only research may substantiate a specific finding only.
- Main session: always call this skill with the named `b-reviewer` subagent type, never a forked context, and pass only the evidence listed above, never the implementer's rationale or a verdict to confirm. Never replace the independent review with a self-review. If the reviewer is unavailable, fails, or returns no verdict, report the gap and ask the user.

## Steps

1. Confirm the baseline, acceptance, exact candidate paths, fresh passing required-check results, and the F0 fingerprint from the handoff. Recompute the identity with the snapshot CLI at the start, passing every relevant ignored/derived artifact the handoff names with `--include-ignored <path>`, and compare only its `fingerprint` with F0: HEAD, SHA-256 digests of staged and unstaged binary diffs, and sorted relevant untracked paths, types, and content digests. The CLI omits git-ignored files unless they are named: block the review, reporting the uncovered paths, when a relevant ignored artifact cannot be named. Treat `complete: false` (exit 3) or a mismatch as blocking, and block when protected content's identity cannot safely be checked. If the CLI is unavailable, block the review (no verdict) and report the gap; never fall back to a hand-computed identity. Do not claim requirements coverage without a baseline.
2. Inspect the candidate's path list and the targeted diff for non-protected paths only; for a base review, use the commit id the handoff resolved. Read repository context only when it materially affects a finding. Never read likely-secret files (`.env`, `*.pem`, `credentials.*`, `secrets.*`); report them as a coverage gap.
3. Independently assess the actual diff, acceptance, required check outcomes and freshness, edge cases, security, operability, and residual risk. Check that the solution choice is proportionate to the plan's quality criteria and project conventions; flag speculative abstractions, duplicated existing helpers, and new dependencies a repository, standard-library, or native alternative would cover, only with evidence; do not turn every review into an architecture report. A skipped or failed required check, changed snapshot, or blocker cannot be ready.
4. Keep the repository read-only: do not edit, patch, run generators or fixers, ask the user questions, message peers, or implement a correction. Return the structured findings and verdict to the main session.
5. Classify every finding and give each an ID `R<round>-<n>`, using the round number from the handoff. A blocker needs location and evidence and is one of: violated acceptance, correctness regression, security/privacy/permission/secret exposure, data-integrity loss, broken external contract, missing/failed/stale required check, changed or unverifiable snapshot, unexpected path, or hand-edited generated output. Everything else (maintainability, style, optional tests, speculative edge cases without evidence) is a follow-up unless it falls in a blocker class with evidence, and issues that predate the diff are out-of-scope notes that never block. Be exhaustive for blockers in one pass: for each, sweep every location of the same defect class, including generated outputs, validators, tests, docs, and size budgets, rather than stopping at the first example. Report each blocker with location, evidence, impact, violated baseline, minimal correction, and regression check. For `NEEDS FIXES`, name the next skill (`b-frontend`, `b-implement`, `b-test`, or `b-refactor`) where applicable.
6. For a re-review, the handoff carries prior finding IDs, dispositions, correction paths, and the main session's sibling-sweep scope and regression-check results; verify the sweep covered each class you listed. Confirm each earlier blocker is resolved, review the correction delta with its callers and tests, and raise a new blocker in already-reviewed code only for the security, data-integrity, contract, or correctness-regression classes above with evidence; anything else there is a follow-up.
7. Recompute the snapshot before returning as F1 with the same `--include-ignored` paths and confirm it equals F0; report a mismatch as a void review with no verdict, using the `Review void` line below.
8. Main session, after the reviewer returns: recompute the snapshot yourself as F1 and confirm it equals F0 and the reviewer's reported F1; otherwise the review is void, so refresh the checks and run a new review. Verify each blocker against the candidate with `Read` and `Grep` before acting; dispute one only through a fresh round, and do not edit while a review is pending. This evaluates the returned result; it does not redo the review. A `Review void` line is not a verdict: report its reason and ask the user. Review does not authorize staging or committing; `b-commit` separately inspects the exact staged paths and commit plan without repeating validation. Main fixes blockers as a batch, sweeping the whole defect class (canonical source, generated outputs, validators, fixtures, docs, size budgets) in one minimal diff limited to the finding's paths, and reports each follow-up as fixed, deferred, or rejected with a reason; deferred or rejected follow-ups need no new review. Corrections must return as a reverified, frozen candidate for another review. After 3 consecutive `NEEDS FIXES` rounds, stop and ask the user.

## Output format

Findings, checked-and-clean areas, snapshot and verification coverage (F0 and F1, review target, resolved base, and round), and residual risk first. The response must end with exactly one standalone final line, with no text after it, which is one of:
- `Verdict: READY FOR PR`
- `Verdict: READY WITH FOLLOW-UPS`
- `Verdict: NEEDS FIXES`
- `Review void: <reason>` for a blocked or void review (missing CLI, incomplete snapshot, F0/F1 mismatch, or an unnameable ignored artifact), with no `Verdict:` line.

`NEEDS FIXES` requires at least one blocker; follow-ups alone yield `READY WITH FOLLOW-UPS`, which requires explicit disposition and never waives required safety evidence. A verdict is not task acceptance, commit creation, or shipping.

## Rules

- Do not claim `READY FOR PR` without baseline, unchanged candidate, acceptance, fresh passing required checks, no blockers/material gaps, and a valid independent review.
- Self-review or generic review cannot substitute for this loaded skill's review gate.
