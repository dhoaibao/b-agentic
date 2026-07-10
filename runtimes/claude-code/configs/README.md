# Claude Code Runtime Layout

Adapter-owned layout for Claude Code.

## Install Layout

- Kernel memory: `~/.claude/CLAUDE.md`
- Skills: `~/.claude/skills/<skill-name>/SKILL.md`
- Shared references: `~/.claude/b-agentic/references/contract/*.md`
- MCP template: `~/.claude/b-agentic/templates/mcp.user.template.json`
- Settings template: `~/.claude/b-agentic/templates/settings.template.json`
- User MCP config: `~/.claude.json`

## Safety And MCP

The installer never overwrites `~/.claude/CLAUDE.md` without `--replace-memory`. Plain install syncs skills, shared references, settings, and MCP config while preserving user-owned config where possible.

MCP entries cover Serena, CodeGraph, Context7, Brave Search, Firecrawl, and Playwright. CodeGraph requires the `codegraph` CLI and a per-project `codegraph init`. API-key-backed tools require user-scope keys. Playwright and other `pnpm dlx` entries require `pnpm` on `PATH`.

Claude Code uses `settings.json` permission rules for baseline gates. The managed template asks before commits, pushes, pulls, reverts, and dependency installs; denies destructive git history/worktree commands; auto-allows only Firecrawl/Playwright read-only operations from `references/contract/safety-tools.md`; and asks before Firecrawl external-mutation, local-upload, monitor-lifecycle, and Playwright page-mutating tools.

## Validation

Use `scripts/validate-skills.sh` and `scripts/validate-skills.sh --release` from the repository root.
