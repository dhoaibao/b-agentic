# ADR-020: Claude Code only again; remove OpenCode

- Status: Accepted
- Date: 2026-11-17
- Supersedes: ADR-019 (OpenCode as the second runtime)

## Context

[ADR-019](ADR-019-opencode-second-runtime.md) added OpenCode as an opt-in second runtime
beside Claude Code. The user works only in Claude Code, and keeping a second generated tree,
installer, plugin, guard, and parity checks costs more than it returns. This repeats the
decision of [ADR-008](ADR-008-claude-code-only.md), which removed the earlier OpenCode
release.

## Decision

- Claude Code is the only runtime. The `opencode/` tree, its installer, plugin, guard, and
  tests and probes are deleted, along with the `opencode` entry in
  `references/runtimes.yaml`, the OpenCode renderers and validators in
  `tooling/generate/registry_sync.py` and `tooling/validate/`, and the `OPENCODE_SESSION_ID`
  fallback for the run-state owner.
- `install.sh` installs Claude Code only. `--runtime=claude` is still accepted as a no-op;
  any other `--runtime` value (`opencode`, `both`, `pi`, `codex`) is refused with a pointer
  to this ADR and nothing is written.
- The generic render mechanism stays with only the `claude` entry: `references/runtimes.yaml`,
  `<!-- runtime: NAME -->` marker lines, the glossary, `kernel_overrides`, forbidden tokens,
  and `primary_gate.runtimes`. A future runtime needs a new ADR that supersedes this one.
- The Claude Code installer and `install.sh` keep refusing `~/.config/opencode` (and `~/.pi`)
  as a configuration or source directory, so a misconfigured path never lands in a
  user-owned tree.
- Install state an earlier release left under `~/.config/opencode` is not touched. To
  uninstall it, check out commit `f80281b7` and run its
  installer with `--runtime=opencode --uninstall`, or remove the b-agentic entries under
  `~/.config/opencode` by hand (the manifest is `~/.config/opencode/b-agentic/install.json`).

## Consequences

- One generated delivery tree (`skills/`, `claude/`) and one installer to maintain; Claude
  Code generated output is byte-identical to the commit before this ADR.
- OpenCode users stay on `f80281b7` or earlier.
- The run-state lock owner comes from `--owner` or `CLAUDE_CODE_SESSION_ID` only.
- Reintroducing a second runtime needs a new ADR that supersedes this one.

Evidence: [`install.sh`](../../install.sh),
[`tooling/generate/registry_sync.py`](../../tooling/generate/registry_sync.py),
[`references/runtimes.yaml`](../../references/runtimes.yaml), and
[`skills/registry.yaml`](../../skills/registry.yaml).
