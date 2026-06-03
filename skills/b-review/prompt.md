# b-review

$ARGUMENTS

Review changed code for blockers, regressions, security risk, and missing coverage. Findings first.

Flags: `--skip-tests`, `--baseline=<path|url>`, `--range=<ref>..<ref>`, `--self`, `--external`, `--audit-suite`.

## When to use

- The user wants a pre-PR/pre-commit changed-code review.
- A risky milestone needs reviewer scrutiny before continuing.
- The goal is correctness, regression, security, edge-case, or coverage review.
- The user requests a b-agentic suite self-audit, with or without `--audit-suite`. Other codebase audits stay changed-code reviews unless explicitly scoped.

## When NOT to use

- Something is broken and needs root-cause tracing -> use **b-debug**.
- The task is writing or fixing tests -> use **b-test**.
- The task is external lookup -> use **b-research**.
- The user asks only to run lint, format, or build commands.
- The request is plan review, UX critique, or research synthesis review.

## Tools required

- `bash` - inspect diff/status/log and run narrow verification when needed.
- `serena-symbol-toolkit` *(preferred for focused code inspection)*
- `context7-docs` *(optional, for suspicious third-party API usage)*
- `brave-search` + `firecrawl-extraction` *(optional, for focused public CVE, advisory, or release-drift lookup)*

## Steps

### Step 1 - Scope the review

For `--audit-suite` or explicit b-agentic suite self-audit intent with or without `--audit-suite`, read `{{skill_support_path}}/reference.md` "Audit-suite checklists", name the audited surface, sampled source files, generated/runtime consumers checked, and skipped suite areas.

For changed-code review, run `git status --short`. Include staged, unstaged, and untracked files for current-worktree reviews; use `git diff HEAD` for tracked changes. With `--range`, state whether current dirty/untracked files are excluded. If no diff/untracked scope exists, ask for a branch, commit, range, or checkpoint.

For WIP branches, choose the best base: supplied range, upstream merge-base, origin default merge-base, then working tree.

### Step 2 - Choose path and baseline

Fast path is allowed only for a single non-sensitive area with no public contract, auth/security/billing/migration touch, or dependency change. Everything else uses standard review.

Use arguments, `--baseline`, approved plan, checkpoint handoff, or clarification to identify intended behavior. Without a sufficient baseline, run a `baseline-missing` diff-only risk review and do not claim requirements coverage.

### Step 3 - Inspect risk

Inspect highest-risk changed symbols and boundaries first. Name sampled files/symbols, skipped changed surfaces, and residual risk.

Use Serena for changed symbols, references, diagnostics, and nearby context. Use Context7 only when an API-semantic finding or clean judgment depends on it. Use Brave plus Firecrawl only for focused advisories, release drift, or official-doc confirmation.

Read `{{skill_support_path}}/reference.md` before applying the security checklist to changed entry points or shared boundaries. Treat lockfile, generated, snapshot, golden, vendored, and minified changes as derived unless source or approved generation is clear.

### Step 4 - Assess tests and operability

Skip only with `--skip-tests`. Otherwise check requirement coverage when a baseline exists, edge cases, test adequacy, and observability for changed entry points, handlers, jobs, or consumers. Run diagnostics or narrow commands only when review confidence depends on them.

### Step 5 - Report verdict

Emit findings severity-ordered; cap non-BLOCKER findings at 15 per severity. If no findings, say so and name residual risk or skipped checks.

Verdicts: **READY FOR PR**, **READY WITH FOLLOW-UPS**, or **NEEDS FIXES**. Emit the chosen label in the final `[status]` block's `verdict:` field after reading `{{runtime_reference_root}}/contract/output.md`. Do not use **READY FOR PR** without baseline, required verification, or relevant browser evidence.

If external knowledge is required, resolve one narrow docs lookup inline or hand off to **b-research**.

## Output format

```text
Mode: changed-code | suite-audit
Scope/Path/Baseline -> Findings -> Checked and clean -> Coverage/Tests/Observability -> Verdict
```

## Rules

- Findings come first; summaries are secondary.
- Label no-baseline reviews as `baseline-missing`.
- Do not run broad checks by default.
- Do not edit files during review unless the user asks for fixes.
- Fast path is risk-gated, not line-count-gated.
- Cite authoritative docs when API semantics matter.

## Reference pointers

- `{{skill_support_path}}/reference.md` - auth, untrusted input, sensitive data, uploads, webhooks, integrations, and audit-suite checklists.
- `{{runtime_reference_root}}/performance-checklist.md` - hot paths, query volume, rendering loops, list endpoints, and retry behavior.
