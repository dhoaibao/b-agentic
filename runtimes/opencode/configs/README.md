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

OpenCode uses the `mcp` key for Serena, CodeGraph, Context7, Brave Search, Firecrawl, and Playwright. CodeGraph requires the `codegraph` CLI and a per-project `codegraph init`. API-key-backed tools require user-scope keys. Playwright and other `pnpm dlx` entries require `pnpm` on `PATH`.

OpenCode uses `permission` config for baseline gates. The managed template asks by default for bash and edits, allows low-risk inspection commands, denies destructive git and broad remove commands, and allows only managed `b-*` skills.

Support tier: `guidance-shell-only` (production claim: `shell-gated-only`). Managed templates encode Firecrawl/Playwright policy through OpenCode `permission` keys named `sanitize(server)_sanitize(tool)`: classified read-only tools are `allow`, gated tools are `ask`. That encoding is validated statically only; do not claim operation-level runtime enforcement until versioned official-runtime evidence and live fresh-session tests prove read tools run without prompts, gated tools prompt, and unclassified tools cannot bypass the policy. Fully trusted managed servers use server wildcards with documented rationale from `references/contract/mcp_operations.yaml`.

## Validation

Use `scripts/validate-skills.sh` and `scripts/validate-skills.sh --release` from the repository root.
