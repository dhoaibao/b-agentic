# ADR-005: Restore OpenCode and remove Codex as the second runtime

- Status: Accepted
- Date: 2026-11-07
- Supersedes: ADR-004 (Codex as the second runtime)

## Context

[ADR-004](ADR-004-codex-runtime.md) replaced OpenCode with Codex CLI. The user now
wants OpenCode back as the second runtime and Codex gone. "No third runtime" still
holds: Codex and OpenCode are never in the tree together.

## Decision

Restore the OpenCode runtime as [ADR-002](ADR-002-dual-runtime-support.md) designed
it, and remove Codex entirely.

- `install.sh --runtime=claude|opencode|both` (default `claude`); `--runtime=codex`
  is no longer accepted.
- The OpenCode assets, installer (`tooling/install/opencode_install.py`), plugin,
  probes, and glossary entry in `references/runtimes.yaml` come back from the tree
  before `3781b7e5`. The `codex/` tree, its installer, hook adapter, probes, and
  glossary entry are deleted.
- Later runtime-neutral changes are kept: the status line, the
  `delegation_unavailable` runtime field, the "require user approval even without a
  native prompt" wording for unclassified MCP tools, and the instruction parity
  check (`tooling/validate/runtime_parity.py`), now comparing Claude Code and
  OpenCode.
- ADR-004 stays as history and is marked superseded.

## Consequences

- OpenCode keeps the gaps recorded in ADR-002 (no verify gate, no ClickUp
  image-reference prompt; the ClickUp gap is moot since
  [ADR-006](ADR-006-retire-clickup-integration.md)). Its behavior was last verified against OpenCode v2.1.4 and
  no live session is run by this repository's checks.
- `install.sh --runtime=codex` is refused with a pointer to this ADR. A machine that
  installed the Codex runtime keeps its managed files, which this repository no
  longer touches. Uninstall them with the installer from commit `aa9ff2cf`
  (`git checkout aa9ff2cf && install.sh --runtime=codex --uninstall`), or remove
  only the paths listed in `~/.codex/b-agentic/install.json`. Do not delete `~/.codex`
  itself: it also holds Codex's own login, sessions, and config.
- Codex specialist model pins (`codex_model`, `codex_effort`) are gone from the
  registry; `opencode_model` pins return.

Evidence: [`install.sh`](../../install.sh),
[`tooling/install/opencode_install.py`](../../tooling/install/opencode_install.py),
[`tooling/generate/registry_sync.py`](../../tooling/generate/registry_sync.py), and
[`references/runtimes.yaml`](../../references/runtimes.yaml).
