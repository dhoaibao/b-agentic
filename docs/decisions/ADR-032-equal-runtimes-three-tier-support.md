# ADR-032: Equal main-flow runtimes and three-tier feature support

- Status: Accepted
- Date: 2026-11-23
- Supersedes: [ADR-030](ADR-030-pi-runtime-rendered-at-install.md) in part (the opt-in secondary-runtime framing and the four-weeks-unused kill criterion) and the "only as an opt-in runtime" wording in [ADR-001](ADR-001-b-agentic-design-record.md)

## Context

[ADR-030](ADR-030-pi-runtime-rendered-at-install.md) and [ADR-031](ADR-031-pi-worker-steps.md) brought Pi to full
main-flow parity with Claude Code (including `b-worker`, `parallel_steps`, `parallel_checks`, and the `b-reviewer` gate)
and were accepted on 2026-11-23 after practical Pi use. However, `ADR-030` still framed Pi as an opt-in secondary
runtime subject to a four-weeks-unused kill criterion, while project docs lacked a formal policy stating which features
must stay equivalent across both runtimes and which harness-specific extras may stay on one runtime alone.

The user decided that Claude Code and Pi are now equal first-class runtimes for every `b-agentic` main flow, while
Claude Code stays the default runtime installed by `./install.sh`, and formalized a three-tier feature support model.

## Decision

- **Equal main-flow runtimes, Claude Code install default:** Claude Code and Pi are equal first-class runtimes for
  every `b-agentic` main flow. `./install.sh` still installs Claude Code by default (under `~/.claude`), and
  `./install.sh --runtime=pi` installs Pi (under `~/.pi/agent`). Canonical sources keep Claude Code wording, and the Pi
  tree stays rendered at install time via `tooling/generate/registry_sync.py --render pi` rather than committed to the
  repository, preserving the maintenance savings of [ADR-030](ADR-030-pi-runtime-rendered-at-install.md).
- **Three-tier feature model:** every `b-agentic` capability and feature is classified into one of three tiers:
  - `shared` (Tier 1): supported completely across both runtimes from the same canonical sources, schemas, and helpers
    (for example, `skills/*/prompt.md`, `references/artifacts.yaml`, `references/mcp_operations.yaml`, `claude/bin/b-state*.mjs`,
    `claude/bin/b_run.py`, `claude/bin/b-candidate-snapshot.mjs`, shared hook logic in `claude/hooks/`, the ten
    templated `mcp.*` servers rendered from `claude/configs/mcp.base.json`, and the shared `mcp_operations.yaml` policy
    covering all eleven `mcp.*` capabilities including IDE-managed `mcp.datagrip`).
  - `adapted` (Tier 2): features requiring runtime-specific mechanics or adapters to serve the same goal and shared
    contracts (for example, `references/runtimes.yaml` vocabulary and glossary, `pi/extensions/b-agentic/guard.mjs`,
    `pi/bin/*` wrappers, `tooling/install/pi_install.py` vs `tooling/install/claude_install.py`, `agent.b-agentic-subagents`
    profile rendering and launch tools, `parallel_checks` background vs same-message `bash` execution, `parallel_steps`
    dispatch, and the `b-review` gate—Codex-first with `b-reviewer` fallback on Claude Code, `b-reviewer` on Pi). Shared
    rendered instruction and safety-boundary contracts are checked across both runtimes by
    `tooling/validate/runtime_parity.py` (while live permission enforcement stays in each runtime's hooks, guards, and
    permission packages), keeping canonical prompt `<!-- runtime: ... -->` markers within `MARKER_BUDGET` (10).
  - `exclusive` (Tier 3): ancillary extras intentionally built for one runtime or impossible to support on the other,
    requiring no cross-runtime parity (Claude-only: `plugin.codex-review` Codex gate, `b-statusline`, `NotebookEdit`,
    piped self-update via `--update`/`--ref`; Pi-only: `pi/themes/dracula.json`, `pi/extensions/b-input-image-preview/index.ts`
    (installed to `~/.pi/agent/extensions/b-input-image-preview/index.ts`, display-only thumbnails and `/b-image [n]`,
    `lstat`-backed native path resolution, `PI_INPUT_IMAGE_PREVIEW=off` opt-out, with TUI rendering/popup/mouse untested automatically), `pi-subagents`
    `subagent_config`, `pi-permission-classifier`, and `/b-*` prompt templates).
- **Main-flow boundary:** all main-flow features—routing, `b-flow` lifecycle, `b-plan`, `b-research`, `b-debug`,
  `b-audit`, `b-agentic-audit`, `b-review`, `b-qa`, `b-commit`, `b-pr`, `b-worker` and `parallel_steps`/`parallel_checks`,
  state/artifact/snapshot integrity, and safety boundaries—must be `shared` or `adapted`, never `exclusive`.
- **Capability tier schema and validation:** every entry in `references/capabilities.yaml` carries a required `tier`
  field (`"shared"`, `"adapted"`, or `"exclusive"`), validated by `tooling/generate/registry_sync.py`:
  - `agent.b-agentic-subagents` is `adapted`; `plugin.codex-review` is `exclusive` with `runtimes: ["claude"]`; every
    `mcp.*` capability is `shared`.
  - `exclusive` capabilities require a `runtimes` list that is a non-empty proper subset of known runtimes; `shared`
    and `adapted` entries must not carry `runtimes`; `kind: "agent"` capabilities may never be `exclusive`.
- **Maintenance gate (replacing the kill criterion):** the four-weeks-unused removal trigger in
  [ADR-030](ADR-030-pi-runtime-rendered-at-install.md) is dropped. Because Pi and its four npm packages stay unpinned,
  `tests/pi/spike.sh` stays a mandatory manual check after each Pi or package upgrade: any breakage blocks claiming Pi
  main-flow parity until fixed. Demoting or removing Pi requires a new ADR.

## Consequences

- Adding a new main-flow feature requires either keeping it `shared` or providing a Tier 2 `adapted` path that passes
  `tooling/validate/runtime_parity.py`. Adding a new capability to `references/capabilities.yaml` fails `--check` until
  its `tier` (and `runtimes` if `exclusive`) is classified.
- **Known accepted Pi safety divergences (Tier 2 adapter gaps):** three pre-existing Pi limits documented in
  [ADR-030](ADR-030-pi-runtime-rendered-at-install.md) remain accepted as part of the Pi adapter until addressed in
  dedicated follow-ups:
  1. `pi-permission-classifier` final allow: Pi treats a classifier `allow` as final for `ask` rules on non-`path` /
     non-`external_directory` surfaces, so the model may approve asks that Claude Code's native rules or user prompts
     gate (pushing to a named branch, creating a PR, or asked MCP/tool calls; note that outside-project writes rely on
     kernel approval and built-in checks rather than managed `Edit`/`Write` path prompts on Claude Code as well).
     Follow-up: add a per-surface opt-out or deny-list refinement if stricter prompts are desired.
  2. Narrow `user_bash` guard: `pi/extensions/b-agentic/guard.mjs` checks `!` commands at the token level and can miss
     obfuscated `.b-agentic.x` or shell-variable spellings. Follow-up: expand `guard.mjs` test cases and path matching.
  3. Slash and RPC specialist launches: when child extension registration fails, slash/RPC launches run before Pi's
     `input` event and bypass the `subagent` tool gate. Follow-up: add an input or command gate if Pi exposes one.

Evidence: [`references/capabilities.yaml`](../../references/capabilities.yaml),
[`tooling/generate/registry_sync.py`](../../tooling/generate/registry_sync.py),
[`tooling/validate/runtime_parity.py`](../../tooling/validate/runtime_parity.py),
[`pi/extensions/b-agentic/guard.mjs`](../../pi/extensions/b-agentic/guard.mjs),
[`pi/extensions/b-input-image-preview/index.ts`](../../pi/extensions/b-input-image-preview/index.ts), and
[`tests/pi/spike.sh`](../../tests/pi/spike.sh).

## Rejected

- Marking `plugin.codex-review` as `adapted` (with or without `runtimes: ["claude"]`): mixes `adapted` and `exclusive`
  semantics when Pi has no Codex plugin.
- Dropping `plugin.codex-review` from the `tier` field requirement: leaves an unclassified capability in
  `references/capabilities.yaml`.
- Marking `mcp.*` capabilities as `adapted`: the ten bundled MCP servers render identically from
  `claude/configs/mcp.base.json` with shared tool names and `mcp_operations.yaml` policy (while `mcp.datagrip` is
  IDE-managed and user-configured on both runtimes under the same shared policy); only installer delivery differs.
- Rewriting `--runtime=pi` install-flag descriptions to avoid the word "opt-in" everywhere: `--runtime=pi` remains an
  explicit flag beside the default `./install.sh`, so describing the install flag as opt-in remains accurate.
