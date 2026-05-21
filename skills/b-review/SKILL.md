---
name: b-review
description: >
  Pre-PR changed-code review for reviewer-style reads of a diff, commit range,
  or checkpoint after implementation. Do NOT invoke for repo/suite audits,
  UI/design review, plan review, or research synthesis review. Unlike b-audit,
  b-review is diff/range-first and judges changed code adequacy, risk, and
  missing tests.
argument-hint: "[--range=<ref>..<ref>] [--baseline=<path|url>] [--skip-tests]"
---

# b-review

$ARGUMENTS

Review changed code for blockers, regressions, security risk, and missing coverage. Findings first.

Flags: `--skip-tests`, `--baseline=<path|url>`, `--range=<ref>..<ref>`, `--self`, `--external`.

## When to use

- The user wants a pre-PR/pre-commit changed-code review.
- A risky milestone needs reviewer scrutiny before continuing.
- The goal is to find correctness, regression, security, edge-case, or coverage risks.

## When NOT to use

- Something is broken and needs root-cause tracing -> use **b-debug**.
- The task is writing or fixing tests -> use **b-test**.
- The task is external lookup -> use **b-research**.
- The user requests a repository, maintainer, or suite-slice audit -> use **b-audit**.
- The request is plan review, UX critique, or research synthesis review.

## Tools required

- `bash` - inspect diff/status/log and run narrow verification when needed.
- `serena-symbol-toolkit` *(preferred for focused code inspection)*
- `gitnexus-radar` *(optional, for broad route/API/tool/shared-flow risk)*
- `context7-docs` *(optional, for suspicious third-party API usage)*
- `brave-discovery` + `firecrawl-extraction` *(optional, for focused public CVE, advisory, or release-drift lookup)*

If required tools are unavailable, read `${CLAUDE_SKILL_DIR}/references/b-agentic/runtime-contract.md` §4 before applying fallbacks. Graceful degradation: possible with git diff, native tools, and focused reads.

## Steps

### Step 1 - Scope the review

Run `git status --short` before scoping. For current-worktree reviews, include staged, unstaged, and untracked files; review untracked files from their current contents because they are absent from `git diff`. Default tracked changes to `git diff HEAD`. Use `--range` when supplied and state whether current dirty or untracked files are excluded from that range review. If there is no diff and no untracked file in scope, ask for a branch, commit, range, or checkpoint.

For WIP branches or dirty state, review the cumulative diff from the best available base: supplied range, upstream merge-base, origin default merge-base, then working tree if no base resolves. State scope, included untracked files, and mode: self-review or external review.

### Step 2 - Pick fast or standard path

Fast path is allowed only for a single non-sensitive area with no public contract, auth/security/billing/migration touch, or dependency change. Everything else uses standard review.

### Step 3 - Establish baseline and inspect risk

Use arguments, `--baseline`, approved plan, checkpoint handoff, or short clarification to identify intended behavior. Read `${CLAUDE_SKILL_DIR}/references/b-agentic/runtime-contract.md` §5 before applying the baseline source taxonomy. Without a sufficient baseline, run a `baseline-missing` diff-only risk review and do not claim requirements coverage.

Inspect highest-risk changed symbols and boundaries first. Name sampled files/symbols, skipped changed surfaces, and residual risk so a no-findings review is not mistaken for exhaustive proof.

Read `${CLAUDE_SKILL_DIR}/reference.md` before applying the security checklist to changed entry points or shared boundaries. Name the relevant checklist sections when they affect findings or confidence. Treat lockfile, generated, snapshot, golden, vendored, and minified changes as derived unless source or approved generation is clear.

### Step 4 - Assess tests and operability

Skip only with `--skip-tests`. Otherwise check requirement coverage when a baseline exists, edge cases, test adequacy, and observability for changed entry points, handlers, jobs, or consumers.

Use diagnostics or narrow commands only when review confidence depends on runtime or typed-language evidence.

### Step 5 - Report verdict

Read `${CLAUDE_SKILL_DIR}/references/b-agentic/runtime-contract.md` §3 and §9 before reporting severity-ordered findings, checked-and-clean caps, saved reports, or status output. If no findings, say so and name residual risk or skipped checks.

Verdicts: **READY FOR PR**, **READY WITH FOLLOW-UPS**, or **NEEDS FIXES**. Do not use **READY FOR PR** when the review has no baseline, required verification was skipped, or browser/DOM/e2e evidence remains relevant but absent; **b-browser**-verified supplied/CI evidence, existing-tool evidence, or approved live-browser evidence can satisfy that browser evidence requirement.

If external knowledge is required, resolve one narrow docs lookup inline or hand off to **b-research**.

## Output format

```text
Scope/Mode/Path/Baseline -> Findings -> Checked and clean -> Coverage/Tests/Observability -> Verdict
```

Read `${CLAUDE_SKILL_DIR}/references/b-agentic/runtime-contract.md` §9 before closing a non-trivial review with a status block.

## Rules

- Findings come first; summaries are secondary.
- Label no-baseline reviews as `baseline-missing`; do not claim requirements coverage without a baseline.
- Do not run broad checks by default.
- Do not edit files during a review unless the user explicitly asks for fixes.
- Fast path is risk-gated, not line-count-gated.
- For self-review, bias against author blind spots; for external review, separate blockers from style.
- Cite authoritative docs when an API-semantic finding or clean judgment depends on them.

## Reference pointers

- Read `${CLAUDE_SKILL_DIR}/reference.md` before reviewing auth, untrusted input, sensitive data, uploads, webhooks, or integrations.
- Read `${CLAUDE_SKILL_DIR}/references/b-agentic/performance-checklist.md` before reviewing hot paths, query volume, rendering loops, list endpoints, or retry behavior.
