---
name: b-review
description: >
  Pre-PR changed-code review. ALWAYS invoke after implementation is done and
  the user wants a reviewer-style read of a diff, commit range, or checkpoint.
  Do NOT invoke for repo/suite audits, UI/design review, plan review, or
  research synthesis review. Unlike b-audit, b-review is diff/range-first and
  judges changed code adequacy, risk, and missing tests.
compatibility: opencode
metadata:
  suite: b-skills
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
- `brave-discovery` + `firecrawl-extraction` *(optional, for focused public CVE/risky-pattern lookup)*

Fallbacks: `AGENTS.md` section 4. Graceful degradation: possible with git diff, native tools, and focused reads.

## Steps

### Step 1 - Scope the review

Default to `git diff HEAD`. Use `--range` when supplied. If there is no diff, ask for a branch, commit, range, or checkpoint.

For WIP branches or dirty state, review the cumulative diff from the best available base: supplied range, upstream merge-base, origin default merge-base, then working tree if no base resolves. State scope and mode: self-review or external review.

### Step 2 - Pick fast or standard path

Fast path is allowed only for a single non-sensitive area with no public contract, auth/security/billing/migration touch, or dependency change. Everything else uses standard review.

### Step 3 - Establish baseline and inspect risk

Use arguments, `--baseline`, approved plan, checkpoint handoff, or short clarification to identify intended behavior. Without a baseline, run a `baseline-missing` diff-only risk review and do not claim requirements coverage.

Inspect highest-risk changed symbols and boundaries first. Name sampled files/symbols, skipped changed surfaces, and residual risk so a no-findings review is not mistaken for exhaustive proof.

Run the security checklist on changed entry points and shared boundaries even on fast path, and name the relevant checklist sections when they affect findings or confidence. Treat lockfile, generated, snapshot, golden, vendored, and minified changes as derived unless source or approved generation is clear.

### Step 4 - Assess tests and operability

Skip only with `--skip-tests`. Otherwise check requirement coverage when a baseline exists, edge cases, test adequacy, and observability for changed entry points, handlers, jobs, or consumers.

Use diagnostics or narrow commands only when review confidence depends on runtime or typed-language evidence.

### Step 5 - Report verdict

Report findings first, ordered by global severity. Include checked-and-clean areas for standard reviews, capped by global verbosity rules; fast reviews may omit them only when the report says why. If no findings, say so and name residual risk or skipped checks.

Verdicts: **READY FOR PR**, **READY WITH FOLLOW-UPS**, or **NEEDS FIXES**. Do not use **READY FOR PR** when the review has no baseline or required verification was skipped; use **READY WITH FOLLOW-UPS** or **NEEDS FIXES** instead.

If external knowledge is required, resolve one narrow docs lookup inline or hand off to **b-research**.

## Output format

```text
Scope/Mode/Path/Baseline -> Findings -> Checked and clean -> Coverage/Tests/Observability -> Verdict
```

## Rules

- Findings come first; summaries are secondary.
- Label no-baseline reviews as `baseline-missing`; do not claim requirements coverage without a baseline.
- Do not run broad checks by default.
- Fast path is risk-gated, not line-count-gated.
- For self-review, bias against author blind spots; for external review, separate blockers from style.
- Cite authoritative docs when an API-semantic finding or clean judgment depends on them.

## Reference pointers

- `reference.md` - use for auth, untrusted input, sensitive data, uploads, webhooks, or integrations.
- `references/b-skills/performance-checklist.md` - use for hot paths, query volume, rendering loops, list endpoints, or retry behavior.
