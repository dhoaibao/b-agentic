# Zed Runtime Layout

Adapter-owned layout for Zed. Shared skills and contracts stay runtime-neutral; Zed-specific paths live here and in `runtimes/zed/scripts/`.

## Install layout

- Kernel memory: `~/.config/zed/AGENTS.md`
- Skills: `~/.agents/skills/<skill-name>/SKILL.md`
- Skill support: `~/.agents/skills/<skill-name>/reference.md`
- Suite metadata/backups/snapshots: `~/.agents/b-agentic/`
- Shared references: `~/.agents/b-agentic/references/contract/*.md`
- MCP template: `~/.agents/b-agentic/templates/mcp.user.template.json`
- User-scope MCP config: `~/.config/zed/settings.json`
- Sensitive artifacts: `~/.agents/b-agentic/<skill>/<run-id>/` or `/tmp/zed/b-agentic/<skill>/<run-id>/`
- Temporary logs: `/tmp/zed/b-agentic/<skill>/<slug>.log`

## Invocation

Zed exposes installed b-agentic skills as native slash command entries from `~/.agents/skills/`. The adapter does not install wrapper files.

## Continuation and resume guarantees

This adapter does not provide native phase-to-phase automation. Workflows resume through operator-issued skill invocations plus the previous `[status]` or `[handoff]` block in context.

## Safety and MCP

The installer never overwrites `~/.config/zed/AGENTS.md` without `--replace-memory`. Plain install syncs skills, shared references, kernel snapshot, and MCP entries; uninstall removes only managed MCP entries.

Zed MCP servers live under `context_servers` in `~/.config/zed/settings.json`. The installer merges `mcp.user.template.json`, preserves user entries, uses `url` for remote entries, and writes API keys only with `--prompt-api-keys`. Playwright stays `--isolated`; pnpm must be available for `pnpm dlx` entries.

## Validation

`scripts/validate-skills.sh` runs shared validation plus runtime validators. `scripts/smoke-install.sh` runs the shared smoke harness; Zed coverage lives in `runtimes/zed/tests/smoke.sh`. Use `scripts/validate-skills.sh --release` for delivery-sensitive changes.
