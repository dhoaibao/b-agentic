<!-- b-init-managed:start -->

## Repository Purpose

b-agentic is a slim personal workflow kernel for Claude Code, with
Codex or a read-only subagent as the independent reviewer, and an opt-in second
runtime for the Pi coding agent ([ADR-011](docs/decisions/ADR-011-pi-second-runtime.md)). It ships the always-loaded kernel, skills that double as
commands, managed MCP configuration, read-only specialist agents, safety hooks,
and installer/validation tooling. See the [public
overview](README.md) and [operational reference](REFERENCE.md).

## Project Operating Guide

### Architecture and change map

- `skills/` holds registry metadata, canonical prompts, and generated skill files; `references/` holds the shared kernel, capability registry, MCP policy, and Claude Code vocabulary; `claude/` holds generated agents and settings plus the hooks, CLIs, and MCP templates; `pi/` holds the generated Pi skills, prompts, agents, kernel, and configs plus the owned guard extension `pi/extensions/b-agentic/`; `tooling/` holds generation, installation, and validation; `tests/` holds behavior, hook, snapshot, and installer coverage.
- Change shared guidance in `references/`, runtime hooks and CLIs in `claude/`, installer behavior in `install.sh` or `tooling/install/` (`claude_install.py`, `pi_install.py`), and checks in `tooling/validate/` or `scripts/`. Use the [ADR-001 design record](docs/decisions/ADR-001-b-agentic-design-record.md) when a change crosses these boundaries.

### Documentation

- Create and update project docs by the roles in [docs/README.md](docs/README.md) and the naming and templates in each docs folder's README; search for an existing doc first.

### Canonical sources and change flows

- `skills/registry.yaml` owns skill metadata, routing, phase, execution ownership, and specialist-agent profiles; each `skills/*/prompt.md` owns its canonical skill body. `tooling/generate/registry_sync.py` renders `SKILL.md` files, agents, the settings template, and delivery blocks, so edit sources and regenerate rather than hand-editing output.
- `references/kernel.template.md`, `references/mcp_operations.yaml`, `references/capabilities.yaml`, and `references/runtimes.yaml` own runtime guidance, capability policy, and per-runtime vocabulary (canonical sources use Claude Code wording; the `pi` entry of `references/runtimes.yaml`, `<!-- runtime: NAME -->` prompt lines, and the Pi `kernel_overrides` render the Pi variants, see [ADR-011](docs/decisions/ADR-011-pi-second-runtime.md)). Claude Code output is the identity render. The installers consume generated output; the [operational reference](REFERENCE.md) documents the installed boundary. OpenCode was removed in [ADR-008](docs/decisions/ADR-008-claude-code-only.md), and the earlier Pi runtime (last in commit `ac38e4a`) was replaced by the ADR-011 one.

### Project constraints and boundaries

- Keep this supplement slim, strong, and usable: retain evidence-backed orientation, ownership, boundaries, and required flows, and link to deeper docs instead of copying setup, release, readiness, or diagnostic catalogs. This is the repository's b-init output quality standard; see [ADR-001 design record](docs/decisions/ADR-001-b-agentic-design-record.md).
- `skills/registry.yaml`, `references/mcp_operations.yaml`, `references/capabilities.yaml`, and `references/runtimes.yaml` use the JSON-compatible YAML subset consumed by generators and validators. Do not treat generated assets as canonical sources.
- Installer and configuration changes cross a user-owned boundary: `tooling/install/` merges user configuration and preserves unrelated content, and templates do not prove live MCP or model readiness. A Claude Code run touches only `~/.claude` and `~/.claude.json`; a Pi run (`install.sh --runtime=pi|both`, default `claude`) touches only `~/.pi/agent` and writes the generated permission config only when none exists or it is b-agentic's own. See the [Claude Code](claude/configs/README.md) and [Pi](pi/configs/README.md) configuration layouts and the [operational reference](REFERENCE.md).
- No database or migration files, infrastructure/deployment manifests, or external-service client source beyond installer/MCP integration is present. Do not invent conventions for absent surfaces; reassess when evidence appears.

## Verification

- `python3 tooling/generate/registry_sync.py --check` — confirm generated delivery assets match canonical sources.
- `scripts/validate-skills.sh` — run synchronization, behavior, policy, hook, snapshot, Pi guard, and readiness checks (`--release` adds the sandbox installer probes for both runtimes).
- `npm run quality` — run tracked source quality checks when dependencies are installed.
- `rtk git diff --check` — check changed paths for whitespace errors.

<!-- b-init-managed:end -->
