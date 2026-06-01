# Review-Verdict Card

Use this before closing `b-review` or any workflow that depends on a review verdict.

- Findings come first and are severity ordered.
- `READY FOR PR` requires a real baseline, required verification, and no unresolved browser-evidence gap.
- `READY WITH FOLLOW-UPS` is for accepted gaps or non-blocking follow-ups that are named explicitly.
- `NEEDS FIXES` is for blocking findings, missing required evidence, or missing baseline/verification.
- `b-orchestrate` may use `BLOCKED` or `IN PROGRESS` as workflow verdicts; `b-review` does not.

Modes:
- `standard` is the normal review path.
- `strict` is mandatory for public contracts, security-sensitive work, dependency changes, CI/release changes, and multi-phase workflow closes.

The authoritative rules live in `../contract/03-definitions.md`, `../contract/09-output.md`, and `../contract/10-decisions.md`.
