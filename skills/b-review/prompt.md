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
- The user requests a b-agentic suite self-audit (not a diff review) -> use **b-audit**. For any other codebase audit, stay in **b-review**. See `{{skill_support_path}}/references/b-agentic/contract/10-decisions.md` for the tiebreaker.
- The request is plan review, UX critique, or research synthesis review.

## Tools required

- `bash` - inspect diff/status/log and run narrow verification when needed.
- `serena-symbol-toolkit` *(preferred for focused code inspection)*
- `gitnexus-radar` *(optional, for broad route/API/tool/shared-flow risk)*
- `context7-docs` *(optional, for suspicious third-party API usage)*
- `brave-search` + `firecrawl-extraction` *(optional, for focused public CVE, advisory, or release-drift lookup)*


## Steps

### Step 1 - Scope the review

Run `git status --short` before scoping. For current-worktree reviews, include staged, unstaged, and untracked files; review untracked files from their current contents because they are absent from `git diff`. Default tracked changes to `git diff HEAD`. Use `--range` when supplied and state whether current dirty or untracked files are excluded from that range review. If there is no diff and no untracked file in scope, ask for a branch, commit, range, or checkpoint.

For WIP branches or dirty state, review the cumulative diff from the best available base: supplied range, upstream merge-base, origin default merge-base, then working tree if no base resolves. State scope, included untracked files, and mode: self-review or external review. Read `{{skill_support_path}}/references/b-agentic/contract/10-decisions.md` before applying the self/external review distinction.

### Step 2 - Pick fast or standard path

Fast path is allowed only for a single non-sensitive area with no public contract, auth/security/billing/migration touch, or dependency change. Everything else uses standard review.

### Step 3 - Establish baseline and inspect risk

Use arguments, `--baseline`, approved plan, checkpoint handoff, or short clarification to identify intended behavior. Read `{{skill_support_path}}/references/b-agentic/contract/05-evidence.md` before applying the baseline source taxonomy. Without a sufficient baseline, run a `baseline-missing` diff-only risk review and do not claim requirements coverage.

Inspect highest-risk changed symbols and boundaries first. Name sampled files/symbols, skipped changed surfaces, and residual risk so a no-findings review is not mistaken for exhaustive proof.

- Use Serena first for exact changed symbols, local references, typed diagnostics, and nearby implementation context.
- Use GitNexus only when route/API/tool consumers, exported boundaries, or shared execution flows are part of the risk story; keep it to targeted radar passes, not general code reading.
- Use Context7 only when a finding or clean judgment depends on third-party API semantics that the repo cannot establish.
- Use Brave Search plus Firecrawl only for focused public advisories, release drift, or official-doc confirmation when local evidence is insufficient.
- If the diff is small and local with no shared/public boundary trigger, keep the review native or Serena-first instead of escalating into a graph or web-assisted review.

Read `{{skill_support_path}}/reference.md` before applying the security checklist to changed entry points or shared boundaries. Name the relevant checklist sections when they affect findings or confidence. Treat lockfile, generated, snapshot, golden, vendored, and minified changes as derived unless source or approved generation is clear.

### Step 4 - Assess tests and operability

Skip only with `--skip-tests`. Otherwise check requirement coverage when a baseline exists, edge cases, test adequacy, and observability for changed entry points, handlers, jobs, or consumers.

Use diagnostics or narrow commands only when review confidence depends on runtime or typed-language evidence.

### Step 5 - Report verdict

Read `{{skill_support_path}}/references/b-agentic/contract/03-definitions.md` and `{{skill_support_path}}/references/b-agentic/contract/09-output.md` before reporting severity-ordered findings, checked-and-clean caps, saved reports, or status output. If no findings, say so and name residual risk or skipped checks.

Verdicts: **READY FOR PR**, **READY WITH FOLLOW-UPS**, or **NEEDS FIXES**. Do not use **READY FOR PR** when the review has no baseline, required verification was skipped, or browser/DOM/e2e evidence remains relevant but absent; **b-browser**-verified supplied/CI evidence, existing-tool evidence, or approved live-browser evidence can satisfy that browser evidence requirement.

If external knowledge is required, resolve one narrow docs lookup inline or hand off to **b-research**.

## Output format

```text
Scope/Mode/Path/Baseline -> Findings -> Checked and clean -> Coverage/Tests/Observability -> Verdict
```


## Rules

- Findings come first; summaries are secondary.
- Label no-baseline reviews as `baseline-missing`; do not claim requirements coverage without a baseline.
- Do not run broad checks by default.
- Do not edit files during a review unless the user explicitly asks for fixes.
- Fast path is risk-gated, not line-count-gated.
- For self-review, bias against author blind spots; for external review, separate blockers from style.
- Cite authoritative docs when an API-semantic finding or clean judgment depends on them.

## Reference pointers

- Read `{{skill_support_path}}/reference.md` before reviewing auth, untrusted input, sensitive data, uploads, webhooks, or integrations.
- Read `{{skill_support_path}}/references/b-agentic/performance-checklist.md` before reviewing hot paths, query volume, rendering loops, list endpoints, or retry behavior.
