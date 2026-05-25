---
name: b-audit
description: >
  b-agentic suite self-audit only. Reviewer-style audits of the b-agentic
  runtime contract, skill layout, installer, validator, tool boundaries,
  or safety-gate drift. Unlike b-review, b-audit is not diff/range-first
  and reports sampled coverage plus residual risk. For any other codebase,
  use b-review.
argument-hint: "[--surface=<area>] [--baseline=<path|url>] [--skip-checks]"
---

<!-- Generated from skills/registry.yaml and skills/b-audit/prompt.md. Edit those sources, not this file. -->

# b-audit

$ARGUMENTS

Audit the b-agentic suite for systemic correctness, consistency, and operability risk. Findings first; sampled coverage must be explicit. For any codebase other than b-agentic, use **b-review** instead — see `../../b-agentic/references/contract/10-decisions.md` for the tiebreaker.

Flags: `--baseline=<path|url>`, `--surface=<area>`, `--skip-checks`, `--self`, `--external`.

## When to use

- Auditing the b-agentic suite itself: routing boundaries, skill layout alignment, runtime contract consistency, docs sync, validator coverage, artifact paths, installer behavior, or safety-gate drift.
- A named suite surface needs systemic correctness, operability, or coverage checked outside a specific diff/range review.

## When NOT to use

- The target is not the b-agentic suite -> use **b-review** for all other codebase review tasks.
- The user wants a pre-PR/pre-commit changed-code review of this suite -> use **b-review**.
- Something is broken and needs root-cause tracing -> use **b-debug**.
- The task is writing or fixing tests -> use **b-test**.
- The task is external lookup -> use **b-research**.
- The request is plan review, UX critique, or research synthesis review.

## Tools required

- `bash` - inspect status, run targeted commands, and collect audit evidence.
- `serena-symbol-toolkit` *(preferred for focused code inspection)*
- `gitnexus-radar` *(optional, for broad route/API/tool/shared-flow risk)*
- `context7-docs` *(optional, for suspicious third-party API usage)*
- `brave-search` + `firecrawl-extraction` *(optional, for focused public CVE, advisory, or release-drift lookup)*


## Steps

### Step 1 - Scope the audit

Lock the requested surface from arguments or `--surface`. If the surface is absent or too broad, ask for the smallest clarification that names the target area. Do not default to a whole-repository audit.

State mode: self-audit or external audit. Use `--self` or `--external` when explicitly passed; otherwise infer from context, `--baseline`, approved plan, checkpoint handoff, or short clarification. Read `../../b-agentic/references/contract/10-decisions.md` before applying the self/external audit distinction. Read `../../b-agentic/references/contract/05-evidence.md` before applying the baseline source taxonomy. Without a sufficient baseline, label the run `baseline-missing` and do not claim requirements coverage.

### Step 2 - Pick the checklist

Read `./reference.md` before choosing the smallest surface-specific checklist: installer/update path, runtime contract, validator, route/tool boundary, dependency/lockfile, generated artifact, or security-sensitive rule.

For b-agentic suite audits, check routing boundaries, skill source/generated alignment, contract consistency, runtime-facing docs sync, validator coverage, artifact paths, and safety-gate drift.

### Step 3 - Inspect risk evidence

Inspect the highest-risk files, symbols, contracts, or generated consumers first. Use exact text search for prose/config/runtime references and symbol tools for code paths when they materially improve confidence.

Name sampled files/symbols, skipped surfaces, and residual risk so a no-findings audit is not mistaken for exhaustive proof. Treat lockfile, generated, snapshot, golden, vendored, and minified evidence as derived unless source or approved generation is clear.

### Step 4 - Check verification and operability

Skip commands only with `--skip-checks`. Otherwise run the narrowest command that materially supports the audit, such as a validator, typecheck, targeted test, smoke check, or diff hygiene command.

Assess observability, cleanup, installation/update behavior, and rollback expectations when those concerns belong to the audited surface.

### Step 5 - Report verdict

Read `../../b-agentic/references/contract/03-definitions.md` and `../../b-agentic/references/contract/09-output.md` before reporting severity-ordered findings, checked-and-clean caps, saved reports, or status output. If no findings, say so and name residual risk or skipped checks.

Verdicts: **AUDIT PASS**, **AUDIT PASS WITH FOLLOW-UPS**, or **NEEDS FIXES**. Emit the chosen label in the final `[status]` block's `verdict:` field. Do not use **AUDIT PASS** when the audit has no baseline, required verification was skipped, or sampled coverage leaves material unreviewed risk; use **AUDIT PASS WITH FOLLOW-UPS** or **NEEDS FIXES** instead.

If external knowledge is required, resolve one narrow docs lookup inline or hand off to **b-research**.

## Output format

```text
Scope/Mode/Baseline -> Findings -> Checked and clean -> Coverage/Verification/Operability -> Verdict
```


## Rules

- Findings come first; summaries are secondary.
- Name the exact audited surface and checklist.
- Label no-baseline audits as `baseline-missing`; do not claim requirements coverage without a baseline.
- Do not run broad checks by default.
- Do not edit files during an audit unless the user explicitly asks for fixes.
- For self-audit, bias against author blind spots; for external audit, separate blockers from style.
- Cite authoritative docs when an API-semantic finding or clean judgment depends on them.

## Reference pointers

- Read `./reference.md` before applying concrete audit criteria for installer/update paths, runtime contracts, validators, route/tool boundaries, dependencies, generated artifacts, security-sensitive rules, or b-agentic suite audits.
