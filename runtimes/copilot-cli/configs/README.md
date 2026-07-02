# GitHub Copilot CLI Runtime Layout

Adapter-owned layout for GitHub Copilot CLI.

## Install Layout

- Kernel memory: `~/.copilot/copilot-instructions.md`
- Skills: `~/.copilot/skills/<skill-name>/SKILL.md`
- Shared references: `~/.copilot/b-agentic/references/contract/*.md`
- MCP template: `~/.copilot/b-agentic/templates/mcp.user.template.json`
- User MCP config: `~/.copilot/mcp-config.json`

## Safety And MCP

The installer never overwrites `~/.copilot/copilot-instructions.md` without `--replace-memory`. Plain install syncs skills, shared references, and MCP config while preserving user-owned config where possible.

MCP entries cover Serena, CodeGraph, Context7, Brave Search, Firecrawl, and Playwright. CodeGraph requires the `codegraph` CLI and a per-project `codegraph init`. API-key-backed tools require user-scope keys. Playwright and other `pnpm dlx` entries require `pnpm` on `PATH`.

GitHub Copilot CLI does not support a persistent config surface for deny/ask safety policy rules. As such, this runtime operates with reduced safety-gate parity. Users should exercise caution and rely on the launch-time flags and manual directory-level approvals.

## Validation

Use `scripts/validate-skills.sh` and `scripts/validate-skills.sh --release` from the repository root.
