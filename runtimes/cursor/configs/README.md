# Cursor Runtime Layout

Adapter-owned layout for Cursor.

## Install Layout

- Kernel memory: `~/.cursor/AGENTS.md` (Note: Cursor Agent loads `AGENTS.md` from the project root; this file serves as the local reference copy)
- Skills: `~/.cursor/skills/<skill-name>/SKILL.md`
- Shared references: `~/.cursor/b-agentic/references/contract/*.md`
- MCP template: `~/.cursor/b-agentic/templates/mcp.user.template.json`
- User MCP config: `~/.cursor/mcp.json`
- Settings template: `~/.cursor/b-agentic/templates/settings.template.json`
- User Settings config: `~/.cursor/cli-config.json`

## Safety And MCP

The installer never overwrites `~/.cursor/AGENTS.md` without `--replace-memory`. Plain install syncs skills, shared references, settings, and MCP config while preserving user-owned config where possible.

MCP entries cover Serena, CodeGraph, Context7, Brave Search, Firecrawl, and Playwright. CodeGraph requires the `codegraph` CLI and a per-project `codegraph init`. API-key-backed tools require user-scope keys. Playwright and other `pnpm dlx` entries require `pnpm` on `PATH`.

Cursor CLI uses `cli-config.json` permission rules for baseline gates. The managed template denies destructive git history/worktree commands and auto-allows only Firecrawl/Playwright read-only operations from `references/contract/safety-tools.md`. Under `approvalMode: allowlist`, unlisted MCP tools (including Firecrawl external-mutation/local-upload/monitor tools and Playwright page-mutating tools) require approval rather than being allowlisted.

## Validation

Use `scripts/validate-skills.sh` and `scripts/validate-skills.sh --release` from the repository root.
