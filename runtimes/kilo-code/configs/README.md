# Kilo Code Runtime Layout

Adapter-owned layout for Kilo Code.

## Install Layout

- Kernel memory: `~/.config/kilo/AGENTS.md`
- Skills: `~/.config/kilo/skills/<skill-name>/SKILL.md`
- Shared references: `~/.config/kilo/b-agentic/references/contract/*.md`
- MCP template: `~/.config/kilo/b-agentic/templates/mcp.user.template.json`
- User config: `~/.config/kilo/kilo.jsonc`

## Safety And MCP

The installer never overwrites `~/.config/kilo/AGENTS.md` without `--replace-memory`. Plain install syncs skills, shared references, and MCP config while preserving user config where possible.

MCP entries cover Serena, Context7, Brave Search, Firecrawl, and Playwright. API-key-backed tools require user-scope keys. Playwright and other `pnpm dlx` entries require `pnpm` on `PATH`.

## Validation

Use `scripts/validate-skills.sh` and `scripts/validate-skills.sh --release` from the repository root.
