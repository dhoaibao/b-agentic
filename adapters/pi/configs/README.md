# Pi Configuration Layout

This page is the installed Pi path map and ownership boundary. For installation,
updates, packages, MCP, safety, preview routes, refresh, and readiness,
see the [operational reference](../../REFERENCE.md).

## Install Layout

- Kernel memory: `~/.pi/agent/AGENTS.md`
- Skills: `~/.pi/agent/skills/<skill-name>/SKILL.md`
- Shared references: `~/.pi/agent/b-agentic/references/kernel.template.md` and
  `mcp_operations.yaml`
- MCP template: `~/.pi/agent/b-agentic/templates/mcp.user.template.json`
- User MCP config: `~/.pi/agent/mcp.json` (Pi-owned override read by
  `pi-mcp-adapter`)
- First-party extensions: `~/.pi/agent/extensions/`
- Extension snapshots and backups: `~/.pi/agent/b-agentic/extensions/` and
  `backups/`
- Theme: `~/.pi/agent/themes/dracula.json` (symlink to the b-agentic cache)
- Managed state and cache: `~/.pi/agent/b-agentic/`

## Ownership Boundary

The installer manages the b-agentic files and caches under the Pi agent
directory while preserving unrelated files, configuration, and symlinks. User
`~/.pi/agent/AGENTS.md`, `~/.pi/agent/mcp.json`, and Pi settings remain
owner-controlled; MCP configuration is merged rather than replaced. The template
MCP configuration enables headless, isolated Playwright with the testing
capability (`--caps=testing`), providing locator generation and state
verification tools (`browser_generate_locator`, `browser_verify_*`).

Skill coordination is prompt-governed and solo: the workflow kernel routes each
request to one active skill, and the extensions preserve normal Pi tools and
shared approval policy. See [REFERENCE.md](../../REFERENCE.md) for the review
and commit gates.
