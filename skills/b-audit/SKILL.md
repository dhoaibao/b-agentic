---
name: b-audit
description: >
  Repository and suite-slice audits for reviewer-style audits of named
  repository areas, runtime contracts, installers, validators, tool boundaries,
  or skill-suite surfaces. Unlike b-review, b-audit is not diff/range-first and
  reports sampled coverage plus residual risk.
argument-hint: "[--surface=<area>] [--baseline=<path|url>] [--skip-checks]"
---

# b-audit

$ARGUMENTS

Audit a named repository surface for production-readiness risk. Findings first; sampled coverage must be explicit.

Flags: `--baseline=<path|url>`, `--surface=<area>`, `--skip-checks`, `--self`, `--external`.

## When to use

- The user explicitly requests a repository, maintainer, or suite-slice audit.
- The target is a named surface such as installer/update path, runtime contract, validator, tool boundary, dependency/lockfile, generated artifact, or security-sensitive rule.
- The goal is to find systemic correctness, safety, operability, documentation drift, or coverage risk outside a specific diff/range review.
- A b-agentic suite audit needs routing boundaries, Claude skill layout alignment, runtime-contract consistency, docs sync, validator coverage, artifact paths, or safety-gate drift checked.

## When NOT to use

- The user wants a pre-PR/pre-commit changed-code review -> use **b-review**.
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

If required tools are unavailable, read `${CLAUDE_SKILL_DIR}/references/b-agentic/runtime-contract.md` §4 before applying fallbacks. Graceful degradation: possible with native tools, focused reads, and targeted commands; graph-shaped impact confidence may be lower without optional radar.

## Steps

### Step 1 - Scope the audit

Lock the requested surface from arguments or `--surface`. If the surface is absent or too broad, ask for the smallest clarification that names the target area. Do not default to a whole-repository audit.

State mode: self-audit or external audit. Use arguments, `--baseline`, approved plan, checkpoint handoff, or short clarification to identify intended behavior. Read `${CLAUDE_SKILL_DIR}/references/b-agentic/runtime-contract.md` §5 before applying the baseline source taxonomy. Without a sufficient baseline, label the run `baseline-missing` and do not claim requirements coverage.

### Step 2 - Pick the checklist

Read `${CLAUDE_SKILL_DIR}/reference.md` before choosing the smallest surface-specific checklist: installer/update path, runtime contract, validator, route/tool boundary, dependency/lockfile, generated artifact, or security-sensitive rule.

For b-agentic suite audits, check routing boundaries, Claude skill layout alignment, runtime-contract consistency, README/REFERENCE sync, validator coverage, artifact paths, and safety-gate drift.

### Step 3 - Inspect risk evidence

Inspect the highest-risk files, symbols, contracts, or generated consumers first. Use exact text search for prose/config/runtime references and symbol tools for code paths when they materially improve confidence.

Name sampled files/symbols, skipped surfaces, and residual risk so a no-findings audit is not mistaken for exhaustive proof. Treat lockfile, generated, snapshot, golden, vendored, and minified evidence as derived unless source or approved generation is clear.

### Step 4 - Check verification and operability

Skip commands only with `--skip-checks`. Otherwise run the narrowest command that materially supports the audit, such as a validator, typecheck, targeted test, smoke check, or diff hygiene command.

Assess observability, cleanup, installation/update behavior, and rollback expectations when those concerns belong to the audited surface.

### Step 5 - Report verdict

Read `${CLAUDE_SKILL_DIR}/references/b-agentic/runtime-contract.md` §3 and §9 before reporting severity-ordered findings, checked-and-clean caps, saved reports, or status output. If no findings, say so and name residual risk or skipped checks.

Verdicts: **AUDIT PASS**, **AUDIT PASS WITH FOLLOW-UPS**, or **NEEDS FIXES**. Do not use **AUDIT PASS** when the audit has no baseline, required verification was skipped, or sampled coverage leaves material unreviewed risk; use **AUDIT PASS WITH FOLLOW-UPS** or **NEEDS FIXES** instead.

If external knowledge is required, resolve one narrow docs lookup inline or hand off to **b-research**.

## Output format

```text
Scope/Mode/Baseline -> Findings -> Checked and clean -> Coverage/Verification/Operability -> Verdict
```

Read `${CLAUDE_SKILL_DIR}/references/b-agentic/runtime-contract.md` §9 before closing a non-trivial audit with a status block.

## Rules

- Findings come first; summaries are secondary.
- Name the exact audited surface and checklist.
- Label no-baseline audits as `baseline-missing`; do not claim requirements coverage without a baseline.
- Do not run broad checks by default.
- Do not edit files during an audit unless the user explicitly asks for fixes.
- For self-audit, bias against author blind spots; for external audit, separate blockers from style.
- Cite authoritative docs when an API-semantic finding or clean judgment depends on them.

## Reference pointers

- Read `${CLAUDE_SKILL_DIR}/reference.md` before applying concrete audit criteria for installer/update paths, runtime contracts, validators, route/tool boundaries, dependencies, generated artifacts, security-sensitive rules, or b-agentic suite audits.
