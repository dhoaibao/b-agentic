# Codex Runtime Layout

Adapter-owned layout for Codex.

## Install Layout

- Kernel memory: `~/.codex/AGENTS.md`
- Skills: `~/.codex/skills/<skill-name>/SKILL.md`
- Command governance rules: `~/.codex/rules/b-agentic.rules`
- Shared references: `~/.codex/b-agentic/references/contract/*.md`
- MCP template: `~/.codex/b-agentic/templates/mcp.user.template.toml`
- User config: `~/.codex/config.toml`

Codex install and smoke checks require Python 3.11+ for `tomllib`.

## Safety And MCP

The installer never overwrites `~/.codex/AGENTS.md` without `--replace-memory`. Plain install syncs skills, command governance rules, shared references, and a managed config block. User config outside the managed block is preserved.

MCP entries cover Serena, CodeGraph, Context7, Brave Search, Firecrawl, and Playwright. CodeGraph requires the `codegraph` CLI and a per-project `codegraph init`. API-key-backed tools require user-scope keys or matching shell environment variables. Playwright and other `pnpm dlx` entries require `pnpm` on `PATH`.

Codex uses managed command governance rules for baseline gates. The managed rules prompt before commits, pushes, pulls, reverts, dependency writes, and recursive removes; they forbid destructive git history/worktree commands and broad Docker resource deletion.

Capability gap: Codex does not currently expose per-MCP-tool permissions in the managed adapter. Firecrawl external-mutation/local-upload/monitor operations and Playwright page-mutating tools therefore rely on kernel guidance and fresh-session discipline rather than adapter-enforced operation allowlists.

## Validation

Use `scripts/validate-skills.sh` and `scripts/validate-skills.sh --release` from the repository root.
