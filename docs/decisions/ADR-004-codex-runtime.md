# ADR-004: Replace OpenCode with Codex as the second runtime

- Status: Proposed (the OpenCode removal is implemented; the Codex runtime is not yet)
- Date: 2026-11-06
- Supersedes: ADR-002 (the OpenCode runtime, its installer, plugin, and gap table; the runtime-adapter design stays)

## Context

[ADR-002](ADR-002-dual-runtime-support.md) added OpenCode beside Claude Code
through runtime adapters. The user now wants Codex CLI as the second runtime
instead. "No third runtime" still holds, so OpenCode and Codex are never in the
tree together: OpenCode is removed first, then Codex is added.

## Decision

Phase 1 (done): remove the OpenCode runtime.

- Deleted `opencode/`, `tooling/install/opencode_install.py`, and the OpenCode
  installer and plugin probes. Removed the OpenCode generator, validators,
  `opencode_model` registry field, `runtimes.opencode`, and
  `runtime_enforcement.opencode`.
- `install.sh --runtime=opencode` is refused with a pointer to this ADR; an old
  OpenCode install is removed with the installer from a commit before the removal.
- The adapter machinery (`references/runtimes.yaml` glossary, `localize`,
  `validate_runtimes`, `validate_localization`, the `runtime` parameter of the
  skill renderer) is kept for the next runtime. Claude output is unchanged except
  for neutral rewording in `skills/b-browser/SKILL.md` and the installed
  `mcp_operations.yaml` reference (no OpenCode mention).

Phase 2 (planned): add Codex, `--runtime=claude|codex|both`.

- Skills in `~/.agents/skills`; specialists as `~/.codex/agents/<name>.toml`;
  kernel as a marked block in `~/.codex/AGENTS.md`; MCP servers as a marked block
  of `[mcp_servers.*]` tables in `~/.codex/config.toml`, validated before the first
  write; hooks through a thin adapter over the shared path guard and verify gate.
- Specialists inherit the parent sandbox (an agent file cannot restrict it), so
  read-only is prompt-enforced plus a best-effort `PreToolUse` hook keyed on
  `agent_type`; hooks cannot `ask`, so ClickUp create and update ask on every call.
- Specialist models are inherited from the session unless pinned later.

## Consequences

Phase 2 is gated on a live spike against the installed Codex CLI for the facts
not verifiable from documentation: whether `agent_type` reaches tool hooks in
subagents, model-facing MCP tool names, the default MCP `approval_mode`, and hooks
under a `--profile` layer. This ADR becomes Accepted when Phase 2 lands.

Evidence: [`install.sh`](../../install.sh),
[`references/runtimes.yaml`](../../references/runtimes.yaml), and
[`tooling/generate/registry_sync.py`](../../tooling/generate/registry_sync.py).
