<!-- b-init-managed:start -->

## Repository Purpose

b-agentic is a slim personal workflow kernel for Claude Code, with
Codex or a read-only subagent as the independent reviewer, and an opt-in Pi
runtime ([ADR-030](docs/decisions/ADR-030-pi-runtime-rendered-at-install.md),
Proposed). It ships the always-loaded kernel, skills that double as commands,
managed MCP configuration, read-only specialist agents plus `b-worker`, safety
hooks, and installer/validation tooling. See the [public overview](README.md)
and [operational reference](REFERENCE.md).

## Project Operating Guide

### Architecture and change map

- `skills/` holds registry metadata, canonical prompts, and generated skill files; `references/` holds the shared kernel, capability registry, MCP policy, runtime vocabulary (`runtimes.yaml`), and `b-flow` artifact schemas (`artifacts.yaml`); `claude/` holds generated agents and settings plus the hooks, CLIs, and MCP templates; `pi/` holds the hand-written parts of the opt-in Pi runtime (helper wrappers, the guard extension, and the vendored Dracula theme in `pi/themes/`; its rendered tree is generated at install time, never committed); `tooling/` holds generation, installation, and validation; `tests/` holds behavior, hook, snapshot, and installer coverage.
- Change shared guidance and schemas in `references/`, runtime hooks and CLIs in `claude/`, installer behavior and shared terminal UI in `install.sh` or `tooling/install/` (`claude_install.py`, `claude_install_ui.py`, `pi_install.py`, `optional_components.py`), the Pi guard, wrappers, and theme in `pi/`, and checks in `tooling/validate/` or `scripts/`. Use the [ADR-001 design record](docs/decisions/ADR-001-b-agentic-design-record.md) when a change crosses these boundaries.

### Documentation

- Create and update project docs by the roles in [docs/README.md](docs/README.md) and the naming and templates in each docs folder's README; search for an existing doc first.

### Canonical sources and change flows

- `skills/registry.yaml` owns skill metadata, routing, phase, execution ownership, optional components, specialist-agent profiles, and `workers` (`b-worker`); each `skills/*/prompt.md` owns its canonical skill body. `tooling/generate/registry_sync.py` renders `SKILL.md` files, agents, the settings template, the `README.md` skills table, and kernel delivery blocks (and renders the Pi tree at install time via `--render pi`), so edit sources and regenerate rather than hand-editing output.
- `references/kernel.template.md`, `references/mcp_operations.yaml`, `references/capabilities.yaml`, `references/runtimes.yaml`, and `references/artifacts.yaml` own runtime guidance, capability policy, per-runtime vocabulary, and `b-flow` run artifact schemas (canonical sources use Claude Code wording; `references/runtimes.yaml` holds the `claude` entry, which is the identity render, and the opt-in `pi` entry with the `<!-- runtime: NAME[,NAME] -->` marker, glossary, and `kernel_overrides` mechanism). The installer consumes generated output; the [operational reference](REFERENCE.md) documents the installed boundary. Earlier second runtimes were removed by [ADR-008](docs/decisions/ADR-008-claude-code-only.md), by [ADR-020](docs/decisions/ADR-020-claude-code-only-again.md) (last OpenCode tree in commit `f80281b7`; the earlier Pi tree was last in `ba7bc2db`), and by [ADR-027](docs/decisions/ADR-027-antigravity-runtime-removed.md) (last Antigravity tree in commit `caf570fd`); Pi returns as an opt-in runtime under [ADR-030](docs/decisions/ADR-030-pi-runtime-rendered-at-install.md) and [ADR-031](docs/decisions/ADR-031-pi-worker-steps.md) (both Proposed), whose generated tree is never committed.

### Project constraints and boundaries

- Keep this supplement slim, strong, and usable: retain evidence-backed orientation, ownership, boundaries, and required flows, and link to deeper docs instead of copying setup, release, readiness, or diagnostic catalogs. This is the repository's b-init output quality standard; see [ADR-001 design record](docs/decisions/ADR-001-b-agentic-design-record.md).
- `skills/registry.yaml`, `references/mcp_operations.yaml`, `references/capabilities.yaml`, `references/runtimes.yaml`, and `references/artifacts.yaml` use the JSON-compatible YAML subset consumed by generators and validators. Do not hand-edit generated assets (`skills/*/SKILL.md`, `claude/agents/*`, `claude/configs/settings.template.json`).
- Installer and configuration changes cross a user-owned boundary: `tooling/install/` merges user configuration and preserves unrelated content, writes through symlinked config files while refusing symlinked managed directories or manifests, and templates do not prove live MCP or model readiness. A Claude Code run touches only `~/.claude` and `~/.claude.json`; `install.sh --runtime=pi` writes under `~/.pi/agent`, never installs Pi or a package, and pins nothing; any other `--runtime` is refused. See the [Claude Code configuration layout](claude/configs/README.md), the [Pi runtime](pi/README.md), and the [operational reference](REFERENCE.md).
- No database or migration files, infrastructure/deployment manifests, or external-service client source beyond installer/MCP integration is present. Do not invent conventions for absent surfaces; reassess when evidence appears.

## Verification

- `python3 tooling/generate/registry_sync.py --check` — confirm generated delivery assets match canonical sources (add `--self-test` for generator and in-memory Pi render checks).
- `scripts/validate-skills.sh` — run synchronization, behavior, policy, hook, snapshot, status line, Pi guard, and readiness checks (`--release` adds the sandbox installer probes for both runtimes).
- `scripts/b-agentic-audit.sh` — run ADR traceability and structural suite slimness/token checks (`--skip-preflight` skips live preflight).
- `bun run quality` — run Prettier, Ruff, ShellCheck, and Markdownlint checks on tracked files when dependencies are installed.
- `rtk git diff --check` — check changed paths for whitespace errors.

<!-- b-init-managed:end -->
