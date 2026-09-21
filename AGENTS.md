<!-- b-init-managed:start -->

## Repository Purpose

b-agentic is a slim personal workflow kernel for native OpenCode. It ships the
always-loaded kernel, native skills and commands, managed MCP configuration,
read-only specialist agents, and installer/validation tooling. See the [public
overview](README.md) and [operational reference](REFERENCE.md).

## Project Operating Guide

### Architecture and change map

- `skills/` holds registry metadata, canonical prompts, and generated skill files; `references/` holds the shared kernel, capability registry, and MCP policy; `opencode/` holds native agents, commands, configuration, runtime scripts, and validation; `tooling/` holds generation, installation, and validation; `tests/` holds behavior and installer smoke coverage.
- Change shared guidance in `references/`, native runtime behavior in `opencode/`, installer behavior in `install.sh` or `tooling/install/`, and checks in `tooling/validate/` or `scripts/`. Use the [decision record](docs/decision_design.md) when a change crosses these boundaries.

### Canonical sources and change flows

- `skills/registry.yaml` owns skill metadata, routing, phase, and execution ownership; each `skills/*/prompt.md` owns its canonical skill body. `tooling/generate/registry_sync.py` renders `SKILL.md` files, commands, configuration, and delivery blocks, so edit sources and regenerate rather than hand-editing output.
- `references/kernel.template.md`, `references/mcp_operations.yaml`, and `references/capabilities.yaml` own runtime guidance and capability policy. The OpenCode runtime tree consumes generated output; the [operational reference](REFERENCE.md) documents the installed boundary.

### Project constraints and boundaries

- Keep this supplement slim, strong, and usable: retain evidence-backed orientation, ownership, boundaries, and required flows, and link to deeper docs instead of copying setup, release, readiness, or diagnostic catalogs. This is the repository's b-init output quality standard; see [decision design](docs/decision_design.md).
- `skills/registry.yaml`, `references/mcp_operations.yaml`, and `references/capabilities.yaml` use the JSON-compatible YAML subset consumed by generators and validators. Do not treat generated assets as canonical sources.
- Installer and OpenCode configuration changes cross a user-owned boundary: `tooling/install/` merges user configuration and preserves unrelated content, while templates do not prove live MCP readiness. See the [OpenCode configuration layout](opencode/configs/README.md) and the [operational reference](REFERENCE.md).
- No database or migration files, infrastructure/deployment manifests, or external-service client source beyond installer/MCP integration is present. Do not invent conventions for absent surfaces; reassess when evidence appears.

## Verification

- `python3 tooling/generate/registry_sync.py --check` — confirm generated delivery assets match canonical sources.
- `scripts/validate-skills.sh` — run synchronization, behavior, policy, readiness, and native OpenCode integration checks.
- `npm run quality` — run tracked source quality checks when dependencies are installed.
- `rtk git diff --check` — check changed paths for whitespace errors.

<!-- b-init-managed:end -->

## Project Rules

This section is developer-owned. b-init refreshes must preserve it verbatim and never regenerate, move, or delete it.

- **Scope: changelog maintenance (enforced local convention).** Agents preparing a commit—including b-commit work—must update `CHANGELOG.md` before committing. Include every change made in a calendar day in that day's single `## [vYYYY.MM.DD] - YYYY-MM-DD` section; do not retain a persistent `## [Unreleased]` section, never create a separate ordinal release for another same-day commit, and append a cohesive human-facing entry under the appropriate standard Keep a Changelog category (`Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, or `Security`). Keep dated sections one per date and newest-first. Never copy or mechanically reuse raw commit-subject text as the entry. This is agent-maintained policy, not Git-hook or other commit automation; do not create a release entry merely for an uncommitted change. **Evidence:** `CHANGELOG.md`, `tooling/validate/changelog.py`.
