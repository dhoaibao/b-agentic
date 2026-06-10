# Kilo Code Runtime Layout

Adapter-owned layout for Kilo Code. Shared skills and contracts stay runtime-neutral; Kilo Code-specific paths live here and in `runtimes/kilo-code/scripts/`.

## Install layout

- Kernel memory: `~/.config/kilo/AGENTS.md`
- Skills: `~/.config/kilo/skills/<skill-name>/SKILL.md`
- Optional subagent profiles: `~/.config/kilo/agents/<agent-name>.md`
- Skill support: `~/.config/kilo/skills/<skill-name>/reference.md`
- Suite metadata/backups/snapshots: `~/.config/kilo/b-agentic/`
- Shared references: `~/.config/kilo/b-agentic/references/contract/*.md`
- MCP template: `~/.config/kilo/b-agentic/templates/mcp.user.template.json`
- Sensitive artifacts: `~/.config/kilo/b-agentic/<skill>/<run-id>/` or `/tmp/kilo-code/b-agentic/<skill>/<run-id>/`
- Temporary logs: `/tmp/kilo-code/b-agentic/<skill>/<slug>.log`

## Invocation

Kilo Code exposes installed skills through the Agent Skills specification. Skills are discovered from `~/.kilo/skills/` and any paths listed in `kilo.jsonc` under `skills.paths`. The installer adds `~/.config/kilo/skills` to `skills.paths` so b-agentic skills are loaded automatically. No `/b-*` wrapper files are installed.

## Continuation and resume guarantees

This adapter does not provide native phase-to-phase automation. Workflows resume through operator-issued skill invocations plus the previous `[status]` or `[handoff]` block in context.

## Safety and MCP

The installer never overwrites `~/.config/kilo/AGENTS.md` without `--replace-memory`. Plain install syncs skills, optional subagent profiles, shared references, kernel, and MCP config; uninstall removes only managed assets that still match the managed snapshot.

Kilo Code uses `~/.config/kilo/kilo.jsonc` (global) and `./kilo.jsonc` or `.kilo/kilo.jsonc` (project). MCP servers live under the `mcp` key and permissions under the `permission` key. The installer merges `mcp.user.template.json`, preserves user entries, and removes only b-agentic entries on uninstall. The merge normalizes JSONC to plain JSON; user comments inside the managed config file are preserved where possible but may be stripped during merge operations.

Optional b-agentic subagent profiles are read-only or ask-gated helpers for exploration, research, review, and verification. User-owned or modified profiles are preserved.

## MCP readiness after install

- `playwright` is immediately available once `pnpm` is on `PATH`; no extra suite-owned setup runs.
- `context7`, `brave-search`, and `firecrawl` entries are installed immediately, but live requests need user-scope API keys in `~/.config/kilo/kilo.jsonc`.
- `serena` entry is installed, but full symbol-aware value still depends on the user having Serena installed and completing first-use setup when needed. The installer never runs `serena setup`, `serena init`, or onboarding.
- Runtime conformance hooks warn by default where adapter hooks are active. Use installer `--strict` or set `B_AGENTIC_STRICT=1` to request blocking. Current strict claims depend on adapter hooks or payloads; unsupported surfaces are advisory-only and must be reported that way.

## Shell tooling recommendations

Install reports print a core shell-tooling tier for `rg`, `fd`/`fdfind`, and `jq`.
When the installer can detect Homebrew, `apt`, or `dnf`, it prints a matching package command for that core tier; otherwise it falls back to manual-install notes.
The installer never auto-installs these packages.

## Validation

`scripts/validate-skills.sh` runs shared validation plus runtime validators. `scripts/smoke-install.sh` runs the shared smoke harness; Kilo Code coverage lives in `runtimes/kilo-code/tests/smoke.sh`. Use `scripts/validate-skills.sh --release` for delivery-sensitive changes.
