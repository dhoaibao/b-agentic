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
- `serena-symbol-toolkit` - inspect changed symbols, references, diagnostics, and boundaries.
- `brave-search` - one narrow public lookup only when API semantics matter.

## Steps

1. Scope the review: working tree, range, baseline, or suite-audit surface.
2. Choose baseline. Without baseline, do a risk review and do not claim requirements coverage.
3. Inspect highest-risk changed symbols and boundaries first.
4. Check tests, edge cases, security, operability, evidence quality, hidden assumptions, unnecessary diff, and over-abstraction.
5. Emit findings ordered by severity. If none, say so and name residual risk.

For `--audit-suite` or explicit b-agentic audits, check kernel slimness, source/generated sync, runtime parity, installer safety, MCP leverage, validation evidence, and cleanup candidates. Prefer source files over generated assets and lower confidence when runtime behavior is only install-validated.

## Output format

Findings, checked-and-clean areas, coverage/verification, and verdict: `READY FOR PR`, `READY WITH FOLLOW-UPS`, or `NEEDS FIXES`.

## Rules

- Findings come first.
- Do not edit files during review.
- Do not claim `READY FOR PR` without baseline and passing verification evidence.
- Treat unrelated cleanup, speculative flexibility, and unverified success criteria as review risks.
- Treat generated, lockfile, snapshot, vendored, and minified changes as derived unless source generation is clear.
