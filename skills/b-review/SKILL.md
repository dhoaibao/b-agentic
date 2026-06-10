---
name: b-review
description: >
  Pre-PR changed-code review for reviewer-style reads of a diff, commit
  range, or checkpoint after implementation, plus b-agentic suite
  self-audits when explicitly requested or invoked with `--audit-suite`.
  Do NOT invoke for general repo audits, UI/design review, plan review, or
  research synthesis review.
argument-hint: "[--range=<ref>..<ref>] [--baseline=<path|url>] [--skip-tests] [--audit-suite]"
---

<!-- Generated from skills/registry.yaml and skills/b-review/prompt.md. Edit those sources, not this file. -->

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
- `serena-symbol-toolkit` - inspect changed symbols, references, diagnostics, and boundaries.
- Optional runtime subagent: `b-review` may inspect bounded diff slices. The active **b-review** skill owns finding severity, final verdict, status, and handoff.

## Steps

### Step 1 - Scope the review

For `--audit-suite` or explicit b-agentic suite self-audit intent with or without `--audit-suite`, read `./reference.md` "Audit-suite checklists", name the audited surface, sampled source files, generated/runtime consumers checked, and skipped suite areas.

For changed-code review, run `git status --short`. Include staged, unstaged, and untracked files for current-worktree reviews; use `git diff HEAD` for tracked changes. With `--range`, state whether current dirty/untracked files are excluded. If no diff/untracked scope exists, ask for a branch, commit, range, or checkpoint.

When reviewing state-governance changes, inspect `.b-agentic/state.json` handling, action classification, validator fail-open/fail-closed behavior, and runtime capability claims. A strictness claim is a finding if the changed runtime cannot block pre-action payloads for the claimed surface.

For WIP branches, choose the best base: supplied range, upstream merge-base, origin default merge-base, then working tree.

### Step 2 - Choose path and baseline

Fast path is allowed only for a single non-sensitive area with no public contract, auth/security/billing/migration touch, or dependency change. Everything else uses standard review.

Use arguments, `--baseline`, approved plan, checkpoint handoff, or clarification to identify intended behavior. Without a sufficient baseline, run a `baseline-missing` diff-only risk review, do not claim requirements coverage, and do not use **READY FOR PR**.

### Step 3 - Inspect risk

Inspect highest-risk changed symbols and boundaries first. Name sampled files/symbols, skipped changed surfaces, and residual risk.

**Serena review workflow:**
1. `get_symbols_overview` on each changed file to identify modified symbols.
2. `find_symbol` with `include_body=True` on changed functions, methods, or classes.
3. `find_referencing_symbols` on boundary symbols to understand consumer impact.
4. `get_diagnostics_for_file` on changed files to catch type errors and warnings.

Read `./reference.md` before applying the security checklist to changed entry points or shared boundaries. Treat lockfile, generated, snapshot, golden, vendored, and minified changes as derived unless source or approved generation is clear.

### Step 4 - Assess tests and operability

Skip only with `--skip-tests`. Otherwise check requirement coverage when a baseline exists, edge cases, test adequacy, and observability for changed entry points, handlers, jobs, or consumers. Run diagnostics or narrow commands only when review confidence depends on them.

### Step 5 - Report verdict

Emit findings severity-ordered; cap non-BLOCKER findings at 15 per severity. If no findings, say so and name residual risk or skipped checks.

Verdicts: **READY FOR PR**, **READY WITH FOLLOW-UPS**, or **NEEDS FIXES**. Emit the chosen label in the final `[status]` block's `verdict:` field after reading `../../b-agentic/references/contract/output.md`. Use **READY FOR PR** only with `state: complete`, `blockers: none`, no BLOCKER or MAJOR findings, sufficient baseline evidence, required verification, and relevant browser evidence. Use **READY WITH FOLLOW-UPS** only when every accepted gap or skipped check is named.

If external knowledge is required, resolve one narrow docs lookup inline or hand off to **b-research**.

## Output format

```text
Mode: changed-code | suite-audit
Scope/Path/Baseline -> Findings -> Checked and clean -> Coverage/Tests/Observability -> Verdict
```

## Rules

- Findings come first; summaries are secondary.
- Subagents are optional accelerators; never let them emit final verdicts, status blocks, or unverified findings without active-skill review.
- Label no-baseline reviews as `baseline-missing`.
- Do not run broad checks by default.
- Do not edit files during review unless the user asks for fixes.
- Fast path is risk-gated, not line-count-gated.
- Treat strict/advisory capability overclaims as correctness findings.
- Cite authoritative docs when API semantics matter.
- Use Serena for every symbol inspection; do not review code without reading symbol definitions and references.

## Reference pointers

- `./reference.md` - auth, untrusted input, sensitive data, uploads, webhooks, integrations, and audit-suite checklists.
- `../../b-agentic/references/performance-checklist.md` - hot paths, query volume, rendering loops, list endpoints, and retry behavior.
