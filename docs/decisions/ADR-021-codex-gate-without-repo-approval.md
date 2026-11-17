# ADR-021: Codex review gate without a per-repository approval

- Status: Accepted
- Date: 2026-11-17
- Supersedes: ADR-007 in part (the per-repository Codex approval and the approval question); ADR-001 in part (the Codex approval passages under "Safety and approval design"); ADR-009 in part (the Codex consent in the approval round); ADR-012 in part (the quick-run consent `codex: reviewer`)

## Context

[ADR-007](ADR-007-codex-first-review-gate.md) made Codex the first review gate and kept
a standing per-repository approval (a JSON store in the install directory, recorded with
the guard's `--approve` behind a native prompt) before any repository went to OpenAI.
[ADR-009](ADR-009-b-flow-automatic-run.md) and
[ADR-012](ADR-012-run-first-entry.md) added a `standing|reviewer` Codex consent to the
`b-flow` approval round, defaulting to `reviewer`.

In use, most sessions reviewed with the `b-reviewer` subagent instead of Codex. A
`b-flow` run never probed the approval, so its consent fell to `reviewer`: three of the
four runs recorded on 2026-11-17 chose `reviewer` although the repository was already
approved, and quick runs were fixed to `reviewer`. The user's position is that Claude
already sends the same code outside the machine, so a second consent for Codex adds
friction without adding protection.

## Decision

- There is no per-repository approval for Codex. A repository that passes the secret
  checks goes to Codex (OpenAI) with no question. The guard ([`claude/hooks/b-codex-guard.mjs`](../../claude/hooks/b-codex-guard.mjs)) loses `--approve`,
  `--revoke`, the approval store helpers, the `B_AGENTIC_STATE_DIR` override, the
  approval reason, and the Bash-hook `ask` tripwire for the approval. `--approve` and
  `--revoke` are now unknown arguments (exit 2).
- Every protection that is not consent stays: the likely-secret scan, opaque
  repository boundaries, untracked symlinks, the `--base` range scan, the supported-form
  rules for a direct plugin call, F0/F1, and the wrapper and guard exit codes. A refusal
  (exit 2 or `--check` exit 3) or a void run (exit 3) still stops and asks the user and
  never falls back on its own; exit 4 (Codex unavailable) stays the only automatic
  fallback to `b-reviewer`.
- Kernel rule 5 keeps its likely-secret clause and gains one exception: external
  transmission needs explicit approval, "except a `b-review` Codex gate run that passes
  its secret guard".
- `b-flow` has no Codex consent. The approval round covers the spec, `AC-n`, commit
  consent, and branch target, and the review phase runs `b-review` as the kernel
  specifies. `consent.codex` is a legacy, read-only field: older specs and states keep it
  (so they validate and re-render byte for byte), it is ignored, and new spec data that
  carries it is refused.
- `record review --verdict` requires `--gate codex|reviewer`, and `--gate-reason` when the
  gate is `reviewer` (why Codex was not used). The gate and reason are stored in the run
  state, in the history entry, and in the QA packet (`Review gate:`, `not recorded` for
  older runs); voiding the evidence clears them. A low-risk exception names no gate.
- The approval store file an older install wrote is left in place, unread. The installer
  neither deletes it nor prints a note, and no longer lists "approve each repository" as a
  next step.

## Consequences

- Codex is the default review gate in `b-review` and in `b-flow` runs; the subagent runs
  only on exit 4 or by the user's choice after a refusal.
- A repository the user once declined to send to Codex is now sent, because a decline was
  never stored and cannot be honored.
- The residual risks of [ADR-001](ADR-001-b-agentic-design-record.md) for secrets remain:
  the scan reads path names only, ignored files are not scanned, and Codex's read-only
  sandbox can read the workspace.
- `record review` calls that omit `--gate` are refused (exit 2); the prompts and the
  `next` hints name the flag. Runs recorded before this ADR load with an empty gate.
- Running `install.sh` is required before the installed kernel, guard, and state CLI change.

Evidence: [`claude/hooks/b-codex-guard.mjs`](../../claude/hooks/b-codex-guard.mjs),
[`claude/bin/b-codex-review.mjs`](../../claude/bin/b-codex-review.mjs),
[`claude/bin/b-state-record.mjs`](../../claude/bin/b-state-record.mjs),
[`skills/b-review/prompt.md`](../../skills/b-review/prompt.md),
[`skills/b-flow/prompt.md`](../../skills/b-flow/prompt.md), and
[`tests/hooks/hooks-probe.sh`](../../tests/hooks/hooks-probe.sh).
