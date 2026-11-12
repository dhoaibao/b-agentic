<!-- b-init-managed:start -->

# Decisions

ADRs: why a choice was made over its alternatives. See
[ADR-001](ADR-001-b-agentic-design-record.md) for the design baseline and
[ADR-002](ADR-002-dual-runtime-support.md) for dual-runtime support,
[ADR-003](ADR-003-subagent-review-gate.md) for the subagent review gate,
[ADR-004](ADR-004-codex-runtime.md) for the superseded Codex runtime, and
[ADR-005](ADR-005-opencode-restored.md) for restoring OpenCode and removing Codex,
[ADR-006](ADR-006-retire-clickup-integration.md) for retiring ClickUp support, and
[ADR-007](ADR-007-codex-first-review-gate.md) for the Codex-first review gate with the subagent fallback, and
[ADR-008](ADR-008-claude-code-only.md) for removing OpenCode and TablePro, and
[ADR-009](ADR-009-b-flow-automatic-run.md) for the bounded `b-flow` automatic run.

## Naming

`ADR-NNN-<kebab-title>.md`. Use three digits and never reuse a number.

## Template

Status/Date/Supersedes, Context, Decision, Consequences.

## Rules

- Refinements update an ADR in place.
- A reversed decision gets a new ADR with `Supersedes: ADR-NNN`, and the old ADR
  notes the superseded area.
- This `README.md` is not an ADR.

<!-- b-init-managed:end -->
