# OpenCode Runtime Layout

Adapter-owned layout for OpenCode.

## Install Layout

- Kernel memory: `~/.config/opencode/AGENTS.md`
- Skills: `~/.config/opencode/skills/<skill-name>/SKILL.md`
- Command wrappers: `~/.config/opencode/commands/<command-name>.md`
- Shared references: `~/.config/opencode/b-agentic/references/contract/*.md`
- MCP template: `~/.config/opencode/b-agentic/templates/mcp.user.template.json`
- User config: `~/.config/opencode/opencode.json`

## Safety And MCP

The installer never overwrites `~/.config/opencode/AGENTS.md` without `--replace-memory`. Plain install syncs skills, wrappers, shared references, and MCP config. User-owned or modified wrapper files are preserved.

OpenCode uses the `mcp` key for Serena, Context7, Brave Search, Firecrawl, and Playwright. API-key-backed tools require user-scope keys. Playwright and other `pnpm dlx` entries require `pnpm` on `PATH`.

## Validation

Use `scripts/validate-skills.sh` and `scripts/validate-skills.sh --release` from the repository root.
