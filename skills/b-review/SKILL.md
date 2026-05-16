---
name: b-review
description: >
  Pre-PR changed-code review. ALWAYS invoke after implementation is done and
  the user wants a reviewer-style read of a diff, commit range, or explicitly
  requested repository audit. Do NOT invoke for UI/design review, plan review,
  or research synthesis review. Unlike b-test, b-review judges adequacy and
  risk; it does not primarily write tests.
compatibility: opencode
metadata:
  suite: b-skills
---

# b-review

$ARGUMENTS

Review changed code for blockers, regressions, security risk, and missing coverage. Findings first.

Flags: `--skip-tests`, `--baseline=<path|url>`, `--range=<ref>..<ref>`, `--repo-audit`, `--self`, `--external`.

## When to use

- The user wants a pre-PR/pre-commit changed-code review.
- A risky milestone needs reviewer scrutiny before continuing.
- The user explicitly requests a repository or suite-slice audit.
- The goal is to find correctness, regression, security, edge-case, or coverage risks.

## When NOT to use

- Something is broken and needs root-cause tracing -> use **b-debug**.
- The task is writing or fixing tests -> use **b-test**.
- The task is external lookup -> use **b-research**.
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

Default to `git diff HEAD`. Use `--range` when supplied. In `--repo-audit`, lock the requested audit surface instead of diff-first scoping. If there is no diff and no audit target, ask for a branch, commit, or range.

For WIP branches or dirty state, review the cumulative diff from the best available base: supplied range, upstream merge-base, origin default merge-base, then working tree if no base resolves. State scope and mode: self-review or external review.

### Step 2 - Pick fast or standard path

Fast path is allowed only for a single non-sensitive area with no public contract, auth/security/billing/migration touch, or dependency change. Everything else, including `--repo-audit`, uses standard review.

### Step 3 - Establish baseline and inspect risk

Use arguments, `--baseline`, approved plan, checkpoint handoff, or short clarification to identify intended behavior. Without a baseline, run a labeled diff-only or repo-audit risk review and do not claim requirements coverage.

Inspect highest-risk changed symbols and boundaries first. For audits, use a surface-specific checklist: installer/update path, runtime contract, validator, route/tool boundary, dependency/lockfile, generated artifact, or security-sensitive rule. Name the sampled files/symbols, skipped surfaces, and residual risk so a no-findings audit is not mistaken for exhaustive proof.

Run the security checklist on changed entry points and shared boundaries even on fast path. Treat lockfile, generated, snapshot, golden, vendored, and minified changes as derived unless source or approved generation is clear.

### Step 4 - Assess tests and operability

Skip only with `--skip-tests`. Otherwise check requirement coverage when a baseline exists, edge cases, test adequacy, and observability for changed entry points, handlers, jobs, or consumers.

Use diagnostics or narrow commands only when review confidence depends on runtime or typed-language evidence.

### Step 5 - Report verdict

Report findings first, ordered by global severity. Include checked-and-clean areas for standard reviews, capped by global verbosity rules; fast reviews may omit them only when the report says why. If no findings, say so and name residual risk or skipped checks.

Verdicts: **READY FOR PR**, **READY WITH FOLLOW-UPS**, or **NEEDS FIXES**.

If external knowledge is required, resolve one narrow docs lookup inline or hand off to **b-research**.

## Output format

```text
Scope/Mode/Path/Baseline -> Findings -> Checked and clean -> Coverage/Tests/Observability -> Verdict
```

## Rules

- Findings come first; summaries are secondary.
- Do not claim requirements coverage without a baseline.
- Do not run broad checks by default.
- Fast path is risk-gated, not line-count-gated.
- In `--repo-audit`, name the exact inspected surface and checklist.
- For self-review, bias against author blind spots; for external review, separate blockers from style.
- Cite authoritative docs when an API-semantic finding or clean judgment depends on them.

## Reference pointers

- `references/security-checklist.md` - use for auth, untrusted input, sensitive data, uploads, webhooks, or integrations.
- `references/performance-checklist.md` - use for hot paths, query volume, rendering loops, list endpoints, or retry behavior.
