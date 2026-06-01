# Output-Handoff Card

Use this before emitting a non-trivial final reply, `[status]` block, or `[handoff]` block.

- Lead with the next action, decision, or findings.
- Use the shared `[status]` schema for non-trivial phase closes.
- Use the shared `[handoff]` schema for phase transitions or unresolved work passed to another skill.
- Include blockers, skipped checks, and confidence when evidence is incomplete.
- Save a report only when the user asked for it, the output is too large for chat, or a durable handoff/checkpoint needs one.

Modes:
- `lite` usually stays in ordinary chat without a status block.
- `standard` uses `[status]` or `[handoff]` when the run is non-trivial.
- `strict` makes the shared schema mandatory and carries run-id/artifact continuity when required.

The authoritative field schema and verbosity rules live in `../contract/09-output.md`.
