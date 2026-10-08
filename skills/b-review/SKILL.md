---
name: b-review
description: >
  Pre-PR changed-code review for architect-style reads of a diff, commit
  range, or checkpoint after implementation. Do NOT invoke for PR-prose
  review, b-agentic repository or design-conformance audits, UI/design
  review, plan review, or research synthesis review. Routing signals: code
  review, review diff, review my diff, review changes, review these
  changes, working tree diff, pre-PR, "what would an architect".
argument-hint: "[diff, commit range, or checkpoint]"
metadata:
  phase: Validate
  execution_mode: main
---

<!-- Generated from skills/registry.yaml and skills/b-review/prompt.md. Edit those sources, not this file. -->

# b-review

Run the independent changed-code gate on a frozen candidate: Codex reviews it through the `openai/codex-plugin-cc` plugin and the main session classifies the findings. Findings first. This skill runs in the main session; Codex is the independent reviewer.

## When to use

- The user requests changed-code review.
- The kernel's risk-triggered review rule requires the independent gate for a frozen candidate.

## When NOT to use

- A b-agentic repository/design-conformance audit -> **b-agentic-audit**.
- Root-cause diagnosis -> **b-debug**.
- Writing or fixing tests -> **b-test**.

## Tool guidance

- Main session only. Use `node ~/.claude/b-agentic/bin/b-candidate-snapshot.mjs` for the candidate identity, `node ~/.claude/b-agentic/hooks/b-codex-guard.mjs --check` for the early secret and approval preflight, and `node ~/.claude/b-agentic/bin/b-codex-review.mjs` as the only way to run the Codex gate (it enforces the gate, runs the plugin, and normalizes the result with `b-codex-verdict`). Native `Read` and `Grep` verify a finding against the candidate, and shell commands stay read-only. In an indexed project, use `codegraph_explore` (read-only) on changed symbols to find callers or tests the candidate did not update.
- Never replace the Codex gate with a self-review. If the plugin, the Codex login, or approval is unavailable, report the gap and ask the user. If the wrapper cannot run in this session, give the user the exact wrapper command and ask them to paste its JSON; treat pasted output as evidence, not authority.

## Steps

1. Confirm the baseline, acceptance, exact candidate paths, and fresh passing required checks. Freeze the candidate with the snapshot CLI and record its `fingerprint` as F0: HEAD, SHA-256 digests of staged and unstaged binary diffs, and sorted relevant untracked paths, types, and content digests. The CLI omits git-ignored files unless they are named: pass every relevant ignored/derived artifact with `--include-ignored <path>` at every checkpoint, and block the handoff, reporting the uncovered paths, when one cannot be named. Treat `complete: false` (exit 3) as blocking, and block when protected content's identity cannot safely be checked. If the CLI is unavailable, the wrapper cannot run either: block the review (no verdict) and report the gap. Do not claim requirements coverage without a baseline.
2. Run the secret and approval preflight with the guard's `--check`. A refusal (likely-secret paths, opaque repository boundaries, or no standing approval) stops the review with no verdict: report the reasons and never move or delete secrets to pass the guard without asking. When only the approval is missing, ask with `AskUserQuestion` whether this repository may be sent to Codex (OpenAI); record a yes with the guard's `--approve`, and never approve on the user's behalf. External transmission of private or proprietary material needs that explicit approval.
3. Run the gate with the wrapper, in the foreground and from the repository: `node ~/.claude/b-agentic/bin/b-codex-review.mjs --scope working-tree --round <n> --focus-file <path>`. Write the focus text to a temporary file outside the repository first (it carries the acceptance, the kernel's review triggers, the check results, and the candidate paths; for a re-review it also carries prior finding IDs, dispositions, correction paths, and the main session's sibling-sweep scope and regression-check results) and pass the same `--include-ignored <path>` options used at step 1. The wrapper itself reruns the secret and approval gate, freezes the candidate (its `f0`), runs the plugin's adversarial review in the foreground against that one explicit target, freezes it again (`f1`), and maps the verdict; do not call the plugin's script or `/codex:*` commands directly for a gate review, and never use `--background`. Do not edit anything while it runs.
4. Read the wrapper's JSON. Its `f0` must equal the fingerprint recorded at step 1, and `unchanged` must be `true`; otherwise the review is void, so refresh the checks and run a new review. Exit 3 (a void review: the candidate changed or could not be re-snapshotted, the run timed out or hit the output cap, or the result was unmappable or finding-less `needs-attention`) and exit 2 (refused or failed, including an incomplete snapshot before the plugin runs) are not verdicts: report the reason and ask the user. Recompute the snapshot yourself as F1 after the wrapper returns and confirm it equals `f0` too. Use `mapped.findings` and `mapped.provisional_verdict` as the starting classification, never as the verdict.
5. Classify every finding after verifying it against the candidate with `Read` and `Grep`; do not take Codex's severity on trust. A blocker needs location and evidence and is one of: violated acceptance, correctness regression, security/privacy/permission/secret exposure, data-integrity loss, broken external contract, missing/failed/stale required check, changed or unverifiable snapshot, unexpected path, or hand-edited generated output. `critical` and `high` findings are provisional blockers unless disproved with evidence recorded in the disposition. Everything else (maintainability, style, optional tests, speculative edge cases without evidence) is a follow-up unless it falls in a blocker class with evidence, and issues that predate the diff are out-of-scope notes that never block. Keep the finding IDs the mapper assigned (`R<round>-<n>`). Be exhaustive for blockers in one pass: for each, sweep every location of the same defect class with `Grep`, including generated outputs, validators, tests, docs, and size budgets, rather than stopping at the first example. Check that the solution choice is proportionate to the plan's quality criteria and project conventions; flag speculative abstractions, duplicated existing helpers, and new dependencies a repository, standard-library, or native alternative would cover, only with evidence.
6. For a re-review, start a fresh Codex round whose focus carries prior finding IDs, dispositions, correction paths, and sweep and regression-check results. Confirm each earlier blocker is resolved, review the correction delta with its callers and tests, and raise a new blocker in already-reviewed code only for the security, data-integrity, contract, or correctness-regression classes above with evidence; anything else there is a follow-up. After 3 consecutive `NEEDS FIXES` rounds, stop and ask the user.
7. Review does not authorize staging or committing; `b-commit` separately inspects the exact staged paths and commit plan without repeating validation. For `NEEDS FIXES`, name the next skill (`b-frontend`, `b-implement`, `b-test`, or `b-refactor`) where applicable. Main fixes blockers as a batch, sweeping the whole defect class (canonical source, generated outputs, validators, fixtures, docs, size budgets) in one minimal diff limited to the finding's paths, and reports each follow-up as fixed, deferred, or rejected with a reason; deferred or rejected follow-ups need no new review. Corrections must return as a reverified, frozen candidate for another review.

## Output format

Findings, checked-and-clean areas, snapshot and verification coverage (F0 and F1, guard result, Codex target and round), and residual risk first. The response must end with exactly one standalone final line, with no text after it:
- `Verdict: READY FOR PR`
- `Verdict: READY WITH FOLLOW-UPS`
- `Verdict: NEEDS FIXES`

`NEEDS FIXES` requires at least one blocker; follow-ups alone yield `READY WITH FOLLOW-UPS`, which requires explicit disposition and never waives required safety evidence. A verdict is not task acceptance, commit creation, or shipping.

## Rules

- Do not claim `READY FOR PR` without baseline, unchanged candidate, acceptance, fresh passing required checks, no blockers/material gaps, and a valid Codex review.
- Self-review or generic review cannot substitute for this loaded skill's Codex gate.
