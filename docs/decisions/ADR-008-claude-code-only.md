# ADR-008: Claude Code only; remove OpenCode and TablePro

- Status: Accepted
- Date: 2026-11-12
- Supersedes: ADR-002 (dual-runtime support) and ADR-005 (OpenCode restored)
- Note: [ADR-011](ADR-011-pi-second-runtime.md) supersedes the Claude-Code-only runtime statement and adds Pi as an opt-in second runtime; the OpenCode and TablePro removals stand.

## Context

[ADR-002](ADR-002-dual-runtime-support.md) added OpenCode beside Claude Code, and
[ADR-005](ADR-005-opencode-restored.md) restored it after the Codex detour. The user
now works only in Claude Code, and keeping a second generated tree, installer,
plugin, and parity checks costs more than it returns. The optional TablePro
component (the `b-tablepro` skill and its `tablepro` MCP server) is also unused.

## Decision

- Claude Code is the only runtime. The `opencode/` tree, its installer
  (opencode_install.py), the OpenCode plugin probe and installer probe, and the `opencode` entry and
  glossary in `references/runtimes.yaml` are deleted. `opencode_model` leaves the
  agent registry.
- `install.sh` installs Claude Code only. `--runtime=claude` is still accepted as a
  no-op; any other `--runtime` value is refused with a pointer to this ADR, and
  `--migrate-legacy` is removed.
- Runtime-conditional prompt blocks (`<!-- runtime:NAME -->`), the localization
  glossary, and the OpenCode permission, template, and parity validators are removed
  from `tooling/generate/registry_sync.py` and `tooling/validate/`.
- The `b-tablepro` skill, the `tablepro` optional component, its MCP template entry,
  its permission and capability entries, and its routing fixtures are removed.
  `b-datagrip` is the only database skill.
- Install state an earlier release left under `~/.config/opencode` is not touched or
  cleaned up; remove it by hand if wanted.

## Consequences

- One generated delivery tree (`skills/`, `claude/`) and one installer to maintain.
- OpenCode users stay on an earlier commit (the last one before this ADR).
- A reinstall over an install that recorded `tablepro` retires it like any other
  removed asset: unmodified copies of the skill, the `tablepro` MCP entry, and its
  permission rules are removed. An edited skill is kept with a warning; an edited MCP
  entry is kept silently.
- The MCP and skill doctor scripts no longer take `--runtime`.
- Reintroducing a second runtime needs a new ADR that supersedes this one.

Evidence: [`install.sh`](../../install.sh),
[`tooling/generate/registry_sync.py`](../../tooling/generate/registry_sync.py),
[`references/runtimes.yaml`](../../references/runtimes.yaml), and
[`skills/registry.yaml`](../../skills/registry.yaml).
