# Kilo Code Runtime Layout

Adapter-owned layout for the current Kilo CLI-backed platform.

## Install Layout

- Kernel memory: `~/.config/kilo/AGENTS.md`
- Skills: `~/.kilo/skills/<skill-name>/SKILL.md`
- Shared references: `~/.kilo/b-agentic/references/contract/*.md`
- MCP template: `~/.kilo/b-agentic/templates/mcp.user.template.json`
- User config: `~/.config/kilo/kilo.jsonc`

## Safety And MCP

The installer never overwrites `~/.config/kilo/AGENTS.md` without `--replace-memory`. Plain install syncs native skills, shared references, and MCP config.

Kilo uses the OpenCode-compatible `mcp` and `permission` schema. The managed template asks by default for bash and edits, allows low-risk inspection commands, denies destructive commands, and allows managed `b-*` skills. Existing JSONC comments and trailing commas are accepted; when b-agentic changes the file it is normalized to strict formatted JSON while preserving its data.

Provider authentication, Kilo account setup, and live MCP startup remain user-owned. Restart Kilo after configuration changes.

## Validation

Use `scripts/validate-skills.sh` and `scripts/validate-skills.sh --release` from the repository root.
