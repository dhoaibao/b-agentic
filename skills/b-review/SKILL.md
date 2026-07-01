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

Review changed code or b-agentic itself for blockers, regressions, security risk, and missing coverage. Findings first.

Flags: `--skip-tests`, `--baseline=<path|url>`, `--range=<ref>..<ref>`, `--audit-suite`.

## When to use

- The user wants a pre-PR/pre-commit changed-code review.
- A risky milestone needs reviewer scrutiny.
- The user requests a b-agentic suite audit.

## When NOT to use

- Something is broken and needs root-cause tracing -> use **b-debug**.
- The task is writing or fixing tests -> use **b-test**.
- The task is external lookup -> use **b-research**.
- The user asks only to run lint, format, or build.

## Tools required

- `bash` - inspect status, diff, logs, and narrow verification.
- `codegraph` - changed-flow, call graph, and affected-test evidence when indexed.
- `serena` - inspect changed symbols, references, diagnostics, and boundaries.
- `brave-search` - one narrow public lookup only when API semantics matter.

## Steps

1. Scope the review: working tree, range, baseline, or suite-audit surface.
2. Choose baseline. Without baseline, do a risk review and do not claim requirements coverage.
3. Read relevant repo context when present: `CONTEXT.md`, `CONTEXT-MAP.md`, nearby `docs/adr/`, `docs/agents/`, or `.b-agentic/` notes.
4. Use CodeGraph for changed flows and affected-test discovery when indexed; use Serena/local search for exact references.
5. Inspect highest-risk changed symbols and boundaries first.
6. Check tests, edge cases, security, operability, evidence quality, hidden assumptions, unnecessary diff, and over-abstraction.
7. Verify evidence proves the intended observable outcome, not only command success.
8. Emit findings ordered by severity. If none, say so and name residual risk.

For `--audit-suite` or explicit b-agentic audits, check kernel slimness, real problem statement, source/generated sync, runtime neutrality, runtime parity, installer safety, MCP leverage, validation evidence, prompt-change evidence, domain-specific behavior in core, ceremony creep, and cleanup candidates. Run `scripts/b-agentic-audit.sh` from the b-agentic checkout to execute the automated checklist. Prefer source files over generated assets and lower confidence when runtime behavior is only install-validated.

Use architecture vocabulary only when design friction is material: interface, seam, adapter, locality, leverage, shallow abstraction, and deletion test. Do not turn every review into an architecture report.

## Output format

Findings, checked-and-clean areas, coverage/verification, and verdict: `READY FOR PR`, `READY WITH FOLLOW-UPS`, or `NEEDS FIXES`.

## Rules

- Findings come first.
- Do not edit files during review.
- Do not claim `READY FOR PR` without baseline and passing verification evidence.
- Treat unrelated cleanup, speculative flexibility, and unverified success criteria as review risks.
- Treat prompt or kernel changes without a concrete failure mode or validation story as review risks.
- Treat generated, lockfile, snapshot, vendored, and minified changes as derived unless source generation is clear.
