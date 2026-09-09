# b-review

Independently review a frozen changed-code candidate for blockers, regressions, security risk, and missing evidence. Findings first.

## When to use

- The user requests changed-code review.
- An executor froze a candidate that needs its independent gate.

## When NOT to use

- PR title/description prose review or rewriting without changed-code review -> **b-pr-summary**.
- A b-agentic repository/design-conformance audit -> **b-agentic-audit**.
- Root-cause diagnosis -> **b-debug**.
- Writing or fixing tests -> **b-test**.

## Tool guidance

- Use `rtk git status --short`, metadata-only path lists, targeted safe diffs, and Pi native `read`. Select CodeGraph only for a central repository-wide review question; bounded specialized Brave tools may substantiate public semantics.

## Steps

1. Confirm the baseline, compatible architect identity, and exact candidate snapshot. It must cover tracked plus relevant untracked/derived content; do not claim requirements coverage without a baseline. The executor's review handoff is exactly one blocking `ask` after a fresh `list-cwd` with the absolute project `cwd` shows exactly one other peer; it omits `to` and then the executor stops and waits. Treat that inbound `ask` as the review trigger and begin **b-review** automatically rather than waiting for another prompt.
2. Use `rtk git status --short`, metadata-only path lists, and targeted non-protected diffs. Read repository context only when it materially affects a finding.
3. Independently assess the actual diff, acceptance, required check outcomes and freshness, edge cases, security, operability, and residual risk. Check that the solution choice is proportionate to the plan's quality criteria and project conventions; do not turn every review into an architecture report. A skipped or failed required check, changed snapshot, wrong architect, or material gap cannot be ready.
4. Bounded read-only research may substantiate a specific finding only. Keep the repository review read-only: do not edit, patch, run generators/fixers, or otherwise mutate the worktree. Before reporting review completion, answer the active review request with `reply` and return the structured disposition and findings for every disposition (`NEEDS FIXES`, `READY FOR PR`, or `READY WITH FOLLOW-UPS`). If no longer in the triggered turn, inspect `pending` and use the exact originating `replyTo`; an ambiguous pending request is a coordination gap. Never open a reverse `ask` or use an unthreaded `send` for the response; return it to the originating executor session in the same CWD. Do not provision a session; report a coordination gap if the executor session or intercom is unavailable.
5. Report blocking findings with location, evidence, impact, violated baseline, minimal correction, and regression check. For `NEEDS FIXES`, name the next owner (`b-frontend`, `b-implement`, `b-test`, or `b-refactor`) where applicable. Corrections must return as a reverified, frozen candidate for another review.

## Output format

Findings, checked-and-clean areas, snapshot/verification coverage, and residual risk first. The response must end with exactly one standalone final line, with no text after it:
- `Verdict: READY FOR PR`
- `Verdict: READY WITH FOLLOW-UPS`
- `Verdict: NEEDS FIXES`

`READY WITH FOLLOW-UPS` requires explicit disposition and never waives required safety evidence. A verdict is not task acceptance, commit creation, or shipping.

## Rules

- Do not claim `READY FOR PR` without baseline, unchanged candidate, acceptance, fresh passing required checks, no blockers/material gaps, and valid independent review.
- Generic review cannot substitute for this loaded skill's actual review gate.
