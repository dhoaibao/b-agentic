# Before-Ready Card

Use this before claiming completion, `READY FOR PR`, or a similar readiness outcome.

- Confirm the requested scope is done.
- Run the narrowest verification that directly supports the claim, then widen only when risk justifies it.
- Name skipped checks or accepted follow-ups instead of implying coverage.
- Do not use `complete`, `READY FOR PR`, or high confidence when baseline, verification, or evidence is missing.
- For UI/browser-relevant work, require `b-browser`-verified evidence or downgrade to a follow-up outcome.

Modes:
- `lite` keeps the claim local and narrow.
- `standard` requires verification and explicit skipped-check reporting when needed.
- `strict` requires explicit evidence, readiness language discipline, and any needed status or handoff artifact.

The authoritative rules live in `../contract/03-definitions.md`, `../contract/07-execution.md`, `../contract/09-output.md`, and `../contract/10-decisions.md`.
