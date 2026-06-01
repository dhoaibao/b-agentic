# Cursor Runtime Layout

Adapter-owned layout for Cursor. Shared skills and contracts stay runtime-neutral; Cursor-specific paths live here and in `runtimes/cursor/scripts/`.

## Install layout

- Kernel memory: `~/.cursor/AGENTS.md`
- Skills: `~/.cursor/skills/<skill-name>/SKILL.md`
- Skill support: `~/.cursor/skills/<skill-name>/reference.md`
- Suite metadata/backups/snapshots: `~/.cursor/b-agentic/`
- Shared references: `~/.cursor/b-agentic/references/contract/*.md`
- MCP template: `~/.cursor/b-agentic/templates/mcp.user.template.json`
- User-scope MCP config: `~/.cursor/mcp.json`
- Sensitive artifacts: `~/.cursor/b-agentic/<skill>/<run-id>/` or `/tmp/cursor/b-agentic/<skill>/<run-id>/`
- Temporary logs: `/tmp/cursor/b-agentic/<skill>/<slug>.log`

`~/.cursor/AGENTS.md` as a global instruction file matches Cursor's config root but is not yet explicitly documented by Cursor. If Cursor does not auto-load it, add the kernel manually through Cursor Settings -> Rules.

## Invocation

Cursor exposes installed b-agentic skills as native slash command entries from `~/.cursor/skills/`. The adapter does not install wrapper files.

## Continuation and resume guarantees

This adapter does not provide native phase-to-phase automation. Workflows resume through operator-issued skill invocations plus the previous `[status]` or `[handoff]` block in context.

## Safety, hooks, and MCP

The installer never overwrites `~/.cursor/AGENTS.md` without `--replace-memory`. Plain install syncs skills, shared references, kernel snapshot, and MCP entries; uninstall removes only managed MCP entries.

Cursor MCP servers live under `mcpServers` in `~/.cursor/mcp.json`. The installer merges `mcp.user.template.json`, preserves user entries, uses `url` for remote entries, and writes API keys only with `--prompt-api-keys`. Playwright stays `--isolated`; pnpm must be available for `pnpm dlx` entries.

Cursor supports `~/.cursor/hooks.json`; b-agentic does not install Cursor hook scripts. Cursor's Claude Code compatibility may still load Claude Code hooks when that layer is active.

## Validation

`scripts/validate-skills.sh` runs shared validation plus runtime validators. `scripts/smoke-install.sh` runs the shared smoke harness; Cursor coverage lives in `runtimes/cursor/tests/smoke.sh`. Use `scripts/validate-skills.sh --release` for delivery-sensitive changes.
