<!-- b-init-managed:start -->

## Repository Purpose

b-agentic is a slim personal workflow kernel for Claude Code and OpenCode, with
Codex as the independent reviewer. It ships the always-loaded kernel, skills that double as
commands, managed MCP configuration, read-only specialist agents, safety hooks,
and installer/validation tooling. See the [public
overview](README.md) and [operational reference](REFERENCE.md).

## Project Operating Guide

### Architecture and change map

- `skills/` holds registry metadata, canonical prompts, and generated skill files; `references/` holds the shared kernel, capability registry, MCP policy, and per-runtime vocabulary; `claude/` holds generated agents and settings plus the hooks, CLIs, and MCP templates (the hooks and CLIs are shared with OpenCode); `opencode/` holds generated agents, skills, kernel, and permission/MCP templates plus the hand-written safety plugin; `tooling/` holds generation, installation, and validation; `tests/` holds behavior, hook, snapshot, and installer coverage.
- Change shared guidance in `references/`, runtime hooks and CLIs in `claude/`, the OpenCode plugin in `opencode/plugins/`, installer behavior in `install.sh` or `tooling/install/` (`claude_install.py`, `opencode_install.py`), and checks in `tooling/validate/` or `scripts/`. Use the [ADR-001 design record](docs/decisions/ADR-001-b-agentic-design-record.md) when a change crosses these boundaries.

### Documentation

- Create and update project docs by the roles in [docs/README.md](docs/README.md) and the naming and templates in each docs folder's README; search for an existing doc first.

### Canonical sources and change flows

- `skills/registry.yaml` owns skill metadata, routing, phase, execution ownership, and specialist-agent profiles; each `skills/*/prompt.md` owns its canonical skill body. `tooling/generate/registry_sync.py` renders `SKILL.md` files, agents, the settings template, and delivery blocks, so edit sources and regenerate rather than hand-editing output.
- `references/kernel.template.md`, `references/mcp_operations.yaml`, `references/capabilities.yaml`, and `references/runtimes.yaml` own runtime guidance, capability policy, and per-runtime vocabulary (canonical sources use Claude Code wording; the claude runtime renders identically and OpenCode is localized through the glossary, see [ADR-002](docs/decisions/ADR-002-dual-runtime-support.md)). The installers consume generated output; the [operational reference](REFERENCE.md) documents the installed boundary. The earlier Pi runtime was removed from this repository (last commit `ac38e4a`).

### Project constraints and boundaries

- Keep this supplement slim, strong, and usable: retain evidence-backed orientation, ownership, boundaries, and required flows, and link to deeper docs instead of copying setup, release, readiness, or diagnostic catalogs. This is the repository's b-init output quality standard; see [ADR-001 design record](docs/decisions/ADR-001-b-agentic-design-record.md).
- `skills/registry.yaml`, `references/mcp_operations.yaml`, `references/capabilities.yaml`, and `references/runtimes.yaml` use the JSON-compatible YAML subset consumed by generators and validators. Do not treat generated assets as canonical sources.
- Installer and configuration changes cross a user-owned boundary: `tooling/install/` merges user configuration and preserves unrelated content, never writes under `~/.pi`, and each runtime's install leaves the other runtime's directory untouched, and templates do not prove live MCP or Codex readiness. See the [configuration layout](claude/configs/README.md) and the [operational reference](REFERENCE.md).
- No database or migration files, infrastructure/deployment manifests, or external-service client source beyond installer/MCP integration is present. Do not invent conventions for absent surfaces; reassess when evidence appears.

## Verification

- `python3 tooling/generate/registry_sync.py --check` — confirm generated delivery assets match canonical sources.
- `scripts/validate-skills.sh` — run synchronization, behavior, policy, hook, snapshot, and readiness checks (`--release` adds the sandbox installer probe).
- `npm run quality` — run tracked source quality checks when dependencies are installed.
- `rtk git diff --check` — check changed paths for whitespace errors.

<!-- b-init-managed:end -->
