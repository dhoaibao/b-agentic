# b-review

Independently review a frozen changed-code candidate for blockers, regressions, security risk, and missing evidence. Findings first. This skill runs in the `b-reviewer` subagent.

## When to use

- The user requests changed-code review.
- The main session froze a candidate that needs its independent gate.

## When NOT to use

- PR title/description prose review or rewriting without changed-code review -> **b-pr-summary**.
- A b-agentic repository/design-conformance audit -> **b-agentic-audit**.
- Root-cause diagnosis -> **b-debug**.
- Writing or fixing tests -> **b-test**.

## Tool guidance

- Use the main session's frozen snapshot, metadata-only path list, targeted safe diff evidence, and Pi native `read`. The child guard blocks Bash; if the handoff lacks the necessary candidate evidence, report that gap rather than collecting it. Select CodeGraph only for a central repository-wide review question; bounded specialized Brave tools may substantiate public semantics.

## Steps

1. Confirm the baseline and exact frozen candidate snapshot. It must cover tracked plus relevant untracked/derived content; do not claim requirements coverage without a baseline.
2. Inspect the supplied metadata-only path list and targeted non-protected diff evidence. Read repository context only when it materially affects a finding.
3. Independently assess the actual diff, acceptance, required check outcomes and freshness, edge cases, security, operability, and residual risk. Check that the solution choice is proportionate to the plan's quality criteria and project conventions; do not turn every review into an architecture report. A skipped or failed required check, changed snapshot, or material gap cannot be ready.
4. Bounded read-only research may substantiate a specific finding only. Keep the repository review read-only: do not edit, patch, run generators/fixers, or otherwise mutate the worktree. Return the structured disposition and findings to the main session; do not ask users questions, message peers, or implement a correction.
5. Report blocking findings with location, evidence, impact, violated baseline, minimal correction, and regression check. For `NEEDS FIXES`, name the next skill (`b-frontend`, `b-implement`, `b-test`, or `b-refactor`) where applicable. Corrections must return as a reverified, frozen candidate for another review.

## Output format

Findings, checked-and-clean areas, snapshot/verification coverage, and residual risk first. The response must end with exactly one standalone final line, with no text after it:
- `Verdict: READY FOR PR`
- `Verdict: READY WITH FOLLOW-UPS`
- `Verdict: NEEDS FIXES`

`READY WITH FOLLOW-UPS` requires explicit disposition and never waives required safety evidence. A verdict is not task acceptance, commit creation, or shipping.

## Rules

- Do not claim `READY FOR PR` without baseline, unchanged candidate, acceptance, fresh passing required checks, no blockers/material gaps, and valid independent review.
- Generic review cannot substitute for this loaded skill's actual review gate.
