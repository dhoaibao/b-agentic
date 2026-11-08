---
name: b-review
description: >
  Pre-PR changed-code review for architect-style reads of working-tree
  changes or changes since a base ref after implementation. Do NOT invoke
  for PR-prose review, b-agentic repository or design-conformance audits,
  UI/design review, plan review, or research synthesis review. Routing
  signals: code review, review diff, review my diff, review changes,
  review these changes, working tree diff, pre-PR, "what would an
  architect". Delegated: runs only in the `b-reviewer` subagent; the main
  session never executes it itself.
metadata:
  phase: Validate
  execution_mode: subagent
  agent: b-reviewer
---

<!-- Generated from skills/registry.yaml and skills/b-review/prompt.md. Edit those sources, not this file. -->

# b-review

Independently review a frozen changed-code candidate for blockers, regressions, security risk, and missing evidence. Findings first. This skill runs in the `b-reviewer` subagent: a fresh, read-only context that does not share the implementer's reasoning and is prohibited from editing.

## Delegation boundary

`b-review` runs only in the `b-reviewer` subagent.

- Main session: reading this file prepares the handoff; it never authorizes running the steps below yourself. Gather the parent-owned evidence and confirm the effective `b-reviewer.md` (project `.opencode/agents/` over `~/.config/opencode/agents/`) is readable and its `permissions` list denies `edit`, `subagent`, `question` for resource `*` (a missing `permissions` list grants every tool), then launch the `b-reviewer` subagent with a bounded task naming `b-review`. Do not do this skill's work with your own tools, even for a quick, small, or single-lookup request. If the subagent is unavailable or fails, or its result notes an unknown agent type or `general` fallback (discard that result), report the gap and ask the user; never fall back to self-execution. Evaluate the returned result before any user-facing or worktree action.
- `b-reviewer` child: execute the steps below read-only, return this skill's Output format to the main session, and do not delegate again.

Parent-owned evidence to gather and pass to the child (or state what is unavailable):

- baseline (branch, HEAD, ahead/behind, git status) and the review target: the working tree, or a base ref the main session resolved to a commit id
- the review round number (1 for a first review; it prefixes finding IDs), acceptance criteria, fresh required-check results, the kernel risk triggers that apply, and the exact candidate paths
- the frozen candidate fingerprint F0 from `node ~/.config/opencode/b-agentic/bin/b-candidate-snapshot.mjs` and every relevant ignored/derived path to pass as `--include-ignored`; never the implementer's rationale or a verdict to confirm
- for a re-review: prior finding IDs, dispositions, correction paths, the main session's sibling-sweep scope, and regression-check results

User arguments for the bounded task: the user's request

## When to use

- The user requests changed-code review.
- The kernel's risk-triggered review rule requires the independent gate for a frozen candidate.

## When NOT to use

- A b-agentic repository/design-conformance audit -> **b-agentic-audit**.
- Root-cause diagnosis -> **b-debug**.
- Writing or fixing tests -> **b-test**.
- Acceptance QA of a reviewed candidate -> **b-qa**.

## Tool guidance

- Use the handoff's baseline, acceptance, check results, candidate paths, and F0. Verify the candidate yourself with native `Read` and `Grep` (or `rg` where `Grep` is absent) and read-only shell commands such as `git diff`, `git status`, and `git show`; never run a mutating command, generator, or fixer. Use `node ~/.config/opencode/b-agentic/bin/b-candidate-snapshot.mjs` for the candidate identity. In an indexed project, use `codegraph_explore` (read-only) on changed symbols to find callers or tests the candidate did not update. Bounded read-only research may substantiate a specific finding only.
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
