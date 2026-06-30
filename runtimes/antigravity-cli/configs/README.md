# Antigravity CLI Runtime Layout

Adapter-owned layout for Antigravity CLI.

## Install Layout

- Kernel memory: `~/.gemini/GEMINI.md`
- Skills: `~/.gemini/antigravity-cli/skills/<skill-name>/SKILL.md`
- Shared references: `~/.gemini/antigravity-cli/b-agentic/references/contract/*.md`
- MCP template: `~/.gemini/antigravity-cli/b-agentic/templates/mcp.user.template.json`
- Settings template: `~/.gemini/antigravity-cli/b-agentic/templates/settings.template.json`
- User MCP config: `~/.gemini/antigravity-cli/mcp_config.json`
- User settings: `~/.gemini/antigravity-cli/settings.json`

## Safety And MCP

The installer never overwrites `~/.gemini/GEMINI.md` without `--replace-memory`. Plain install syncs skills, shared references, MCP config, and settings while preserving user-owned config where possible.

MCP entries cover Serena, CodeGraph, Context7, Brave Search, Firecrawl, and Playwright. Antigravity remote servers use `serverUrl` instead of `url` or `httpUrl`. CodeGraph requires the `codegraph` CLI and a per-project `codegraph init`. API-key-backed tools require user-scope keys. Playwright and other `pnpm dlx` entries require `pnpm` on `PATH`.

Antigravity CLI uses `settings.json` permission rules for baseline gates. The managed template asks before commits, pushes, pulls, reverts, and dependency installs; denies destructive git history/worktree commands; and does not allow Firecrawl monitor mutation tools. Permission precedence is deny, then ask, then allow.

## Validation

Use `scripts/validate-skills.sh` and `scripts/validate-skills.sh --release` from the repository root.
