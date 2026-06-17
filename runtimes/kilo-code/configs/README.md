# Kilo Code Runtime Layout

Adapter-owned layout for Kilo Code.

## Install Layout

- Kernel memory: `~/.config/kilo/AGENTS.md`
- Skills: `~/.kilo/skills/<skill-name>/SKILL.md`
- Shared references: `~/.kilo/b-agentic/references/contract/*.md`
- MCP template: `~/.kilo/b-agentic/templates/mcp.user.template.json`
- User config: `~/.config/kilo/kilo.jsonc`

Kilo currently documents global instructions and config under `~/.config/kilo/`, but global skills under `~/.kilo/skills/`. The adapter keeps that split: the active kernel and JSON config live in `~/.config/kilo/`, while managed skills and b-agentic metadata live in `~/.kilo/` so generated skills can still resolve `../../b-agentic/references` correctly.

## Safety And MCP

The installer never overwrites `~/.config/kilo/AGENTS.md` without `--replace-memory`. Plain install syncs skills, shared references, and MCP config. User-owned config outside the managed JSON merge is preserved.

Kilo uses the `mcp` key for Serena, CodeGraph, Context7, Brave Search, Firecrawl, and Playwright. CodeGraph requires the `codegraph` CLI and a per-project `codegraph init`. API-key-backed tools require user-scope keys. Playwright and other `pnpm dlx` entries require `pnpm` on `PATH`.

Kilo uses the same `allow` / `ask` / `deny` permission model as its OpenCode-derived CLI. The managed template asks by default for bash and edits, allows low-risk inspection commands, denies destructive git and broad remove commands, and allows only managed `b-*` skills without prompting.

## Validation

Use `scripts/validate-skills.sh` and `scripts/validate-skills.sh --release` from the repository root.
