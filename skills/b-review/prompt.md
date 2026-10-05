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

- Use the main session's frozen snapshot, metadata-only path list, targeted safe diff evidence, and native `read`. Read-only shell commands such as `git diff`, `git status`, and `rg` are available for independently inspecting the candidate; do not run mutating commands. If the handoff lacks necessary candidate evidence that inspection cannot supply, report that gap. In an indexed project, use `codegraph_explore` (read-only) on changed symbols to find callers or tests the candidate did not update; bounded specialized Brave tools may substantiate public semantics.

## Steps

1. Confirm the baseline and exact frozen candidate snapshot. Require the main session's identity: HEAD, SHA-256 digests of staged and unstaged binary diffs, and sorted relevant untracked paths, types, and content digests. Independently recompute at the start and end of review and report a mismatch. Prefer `b_candidate_snapshot` when available: compare only its `fingerprint`, and treat `complete: false` or a mismatch as blocking. The tool omits git-ignored files unless they are named in `include_ignored`: require the handoff's list of relevant ignored/derived paths, pass the same list at every checkpoint, and block the fingerprint handoff, reporting the uncovered paths, when a relevant ignored artifact cannot be named. Use one method at every checkpoint; never compare a tool fingerprint with a hand-computed identity, and report a gap if the handoff used the tool but it is unavailable to you. Otherwise use the manual procedure only after this fail-closed preflight, run from the repository root before any `git status` or `git diff` (which can execute programs); if any check fails or cannot be run, block the review (no verdict) and report why. Exit 0 means matches found and 1 means none; any other exit is a failure. (a) `git config --get-regexp '^(extensions\.partialclone|remote\..*\.promisor)$'` exits 1 (a partial clone could fetch objects during diff); (b) `git config --get-regexp '^filter\..*\.(clean|process)$'` exits 1: any configured clean/process program blocks the manual fallback, whichever paths use it; (c) `git ls-files -s -z` lists no mode `160000` entry (a submodule's own filters cannot be checked). Never accept executable-filter side effects for the main session. Run every git command, including these, as `GIT_NO_LAZY_FETCH=1 GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false ...`. Then hash raw stdout from `git diff --no-ext-diff --no-textconv --no-color --no-renames --ignore-submodules=none --submodule=short --binary --cached -- .` and `git diff --no-ext-diff --no-textconv --no-color --no-renames --ignore-submodules=none --submodule=short --binary -- .` (not rendered or truncated diff output); list untracked paths with `git ls-files --others --exclude-standard -z`, sort paths as bytes, and hash each file's bytes or a symlink's target bytes with its path and type. Include explicitly relevant ignored/derived paths. If protected content cannot be inspected or hashed with permission, block rather than claim an unchanged candidate. It must cover tracked plus relevant untracked/derived content; do not claim requirements coverage without a baseline.
2. Inspect the supplied metadata-only path list and targeted non-protected diff evidence. Read repository context only when it materially affects a finding. Review does not authorize staging or committing; `b-commit` separately inspects the exact staged paths and commit plan without repeating validation.
3. Independently assess the actual diff, acceptance, required check outcomes and freshness, edge cases, security, operability, and residual risk. Compare the candidate identity again before returning. Check that the solution choice is proportionate to the plan's quality criteria and project conventions; flag speculative abstractions, duplicated existing helpers, and new dependencies a repository, standard-library, or native alternative would cover, only with evidence; do not turn every review into an architecture report. A skipped or failed required check, changed snapshot, or blocker cannot be ready.
4. Bounded read-only research may substantiate a specific finding only. Keep the repository review read-only: do not edit, patch, run generators/fixers, or otherwise mutate the worktree. Return the structured disposition and findings to the main session; do not ask users questions, message peers, or implement a correction.
5. Classify every finding. A blocker needs location and evidence and is one of: violated acceptance, correctness regression, security/privacy/permission/secret exposure, data-integrity loss, broken external contract, missing/failed/stale required check, changed or unverifiable snapshot, unexpected path, or hand-edited generated output. Everything else (maintainability, style, optional tests, speculative edge cases without evidence) is a follow-up, and issues that predate the diff are out-of-scope notes that never block. Give each finding an ID. Be exhaustive for blockers in one pass: for each, list every location of the same defect class, including generated outputs, validators, tests, docs, and size budgets, rather than stopping at the first example. Report blockers with location, evidence, impact, violated baseline, minimal correction, and regression check. For `NEEDS FIXES`, name the next skill (`b-frontend`, `b-implement`, `b-test`, or `b-refactor`) where applicable. Corrections must return as a reverified, frozen candidate for another review.
6. For a re-review, the handoff carries prior finding IDs, dispositions, correction paths, and the main session's sibling-sweep scope and regression-check results; verify the sweep covered each class you listed. Confirm each earlier blocker is resolved, review the correction delta with its callers and tests, and raise a new blocker in already-reviewed code only for the security, data-integrity, contract, or correctness-regression classes above with evidence; anything else there is a follow-up.

## Output format

Findings, checked-and-clean areas, snapshot/verification coverage, and residual risk first. The response must end with exactly one standalone final line, with no text after it:
- `Verdict: READY FOR PR`
- `Verdict: READY WITH FOLLOW-UPS`
- `Verdict: NEEDS FIXES`

`NEEDS FIXES` requires at least one blocker; follow-ups alone yield `READY WITH FOLLOW-UPS`, which requires explicit disposition and never waives required safety evidence. A verdict is not task acceptance, commit creation, or shipping.

## Rules

- Do not claim `READY FOR PR` without baseline, unchanged candidate, acceptance, fresh passing required checks, no blockers/material gaps, and valid independent review.
- Generic review cannot substitute for this loaded skill's actual review gate.
