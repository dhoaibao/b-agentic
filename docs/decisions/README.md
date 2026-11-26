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
[ADR-009](ADR-009-b-flow-automatic-run.md) for the bounded `b-flow` automatic run, and
[ADR-010](ADR-010-run-artifact-cli.md) for the single writer of its run artifacts, and
[ADR-011](ADR-011-pi-second-runtime.md) for Pi as an opt-in second runtime, and
[ADR-012](ADR-012-run-first-entry.md) for change requests entering a quick or full run, and
[ADR-013](ADR-013-concurrent-plan-checks.md) for plan checks that may run together, and
[ADR-014](ADR-014-checked-plan-steps.md) for plan steps checked when they are recorded, and
[ADR-015](ADR-015-step-writer-worker.md) for one writer subagent applying an approved plan step, and
[ADR-016](ADR-016-parallel-worker-steps.md) for approved worker steps running at the same time, each in its own worktree, and
[ADR-017](ADR-017-bun-hook-runtime.md) for the managed hooks and status line running under Bun with Node as the fallback, and
[ADR-018](ADR-018-bun-only-runtime.md) for Bun as the only runtime for Claude Code, superseding ADR-017, and
[ADR-019](ADR-019-opencode-second-runtime.md) for OpenCode as the second runtime in place of Pi, superseding ADR-011, and
[ADR-020](ADR-020-claude-code-only-again.md) for Claude Code only again, superseding ADR-019, and
[ADR-021](ADR-021-codex-gate-without-repo-approval.md) for the Codex review gate without a per-repository approval, superseding parts of ADR-007, and
[ADR-022](ADR-022-discussion-first-entry.md) for the discussion-first entry gate and the split of oversized requests, refining ADR-012, and
[ADR-023](ADR-023-per-agent-mcp-tool-scope.md) for per-agent MCP tool allowlists, refining ADR-001 and ADR-015, and
[ADR-024](ADR-024-prune-old-runs.md) for cleaning up old run folders on request, refining ADR-010 and ADR-012, and
[ADR-025](ADR-025-antigravity-second-runtime.md) for the superseded Antigravity second runtime, and
[ADR-026](ADR-026-grounded-claims-rule.md) for the grounded-claims kernel rule, refining ADR-022, and
[ADR-027](ADR-027-antigravity-runtime-removed.md) for removing the Antigravity runtime again, superseding ADR-025, and
[ADR-028](ADR-028-short-helper-wrappers.md) for short helper wrappers in place of the long runtime commands, refining ADR-018, and
[ADR-029](ADR-029-self-describing-helper-clis.md) for self-describing helper CLIs, refining ADR-010 and ADR-028, and
[ADR-030](ADR-030-pi-runtime-rendered-at-install.md) for the Pi second runtime rendered at install time, superseding the no-second-runtime decisions of ADR-020 and ADR-027, and
[ADR-031](ADR-031-pi-worker-steps.md) for `b-worker` and parallel worktree steps on Pi, superseding ADR-030 in part, and
[ADR-032](ADR-032-equal-runtimes-three-tier-support.md) for equal main-flow runtimes (Claude Code and Pi) and three-tier feature support, superseding ADR-030 in part, and
[ADR-033](ADR-033-opt-in-vendor-tool-installs.md) for opt-in interactive `[y/N]` vendor tool installs after sync, superseding ADR-001 and ADR-030 in part, and
[ADR-034](ADR-034-all-runtimes-install.md) for the `--runtime=all` installer across Claude Code and Pi, extending ADR-030, ADR-032, and ADR-033, and
[ADR-035](ADR-035-local-run-stats.md) for a local, numbers-only store of finished run metrics, refining ADR-010 and ADR-024, and
[ADR-036](ADR-036-run-stats-kit-version.md) for recording in each run-stats line the kit version the run started on, superseding ADR-035 in part.

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
