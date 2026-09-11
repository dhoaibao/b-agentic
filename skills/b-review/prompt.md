# b-review

Independently review a changed-code candidate for blockers, regressions, security risk, and missing evidence. Findings first.

## When to use

- The user requests changed-code review.
- A candidate snapshot needs an independent review gate.

## When NOT to use

- PR title/description prose review or rewriting without changed-code review -> **b-pr-summary**.
- A b-agentic repository/design-conformance audit -> **b-agentic-audit**.
- Root-cause diagnosis -> **b-debug**.
- Writing or fixing tests -> **b-test**.

## Tool guidance

- Use `rtk git status --short`, metadata-only path lists, targeted safe diffs, and native `read`. Select CodeGraph [cap: mcp.codegraph] only for a central repository-wide review question; bounded specialized Brave [cap: mcp.brave-search] tools may substantiate public semantics.

## Steps

1. Confirm the baseline and exact candidate snapshot. It must cover tracked plus relevant untracked/derived content; do not claim requirements coverage without a baseline. Treat the user's review request as the review trigger.
2. Use `rtk git status --short`, metadata-only path lists, and targeted non-protected diffs. Read repository context only when it materially affects a finding.
3. Independently assess the actual diff, acceptance, required check outcomes and freshness, edge cases, security, operability, and residual risk. Check that the solution choice is proportionate to the plan's quality criteria and project conventions; do not turn every review into an architecture report. A skipped or failed required check, changed snapshot, or material gap cannot be ready.
4. Bounded read-only research may substantiate a specific finding only. Keep the repository review read-only: do not edit, patch, run generators/fixers, or otherwise mutate the worktree.
5. Report blocking findings with location, evidence, impact, violated baseline, minimal correction, and regression check. For `NEEDS FIXES`, name the next skill (`b-frontend`, `b-implement`, `b-test`, or `b-refactor`) where applicable. Corrections must return as a reverified candidate for another review.

## Output format

Findings, checked-and-clean areas, snapshot/verification coverage, and residual risk first. The response must end with exactly one standalone final line, with no text after it:
- `Verdict: READY FOR PR`
- `Verdict: READY WITH FOLLOW-UPS`
- `Verdict: NEEDS FIXES`

`READY WITH FOLLOW-UPS` requires explicit disposition and never waives required safety evidence. A verdict is not task acceptance, commit creation, or shipping.

## Rules

- Do not claim `READY FOR PR` without baseline, unchanged candidate, acceptance, fresh passing required checks, and no blockers or material gaps.
- Generic review cannot substitute for this loaded skill's actual review gate.
