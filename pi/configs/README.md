# Pi Configuration Layout

This page is the installed Pi path map and ownership boundary. For installation,
updates, packages, MCP, subagent delegation, safety, preview routes, refresh,
and readiness, see the [operational reference](../../REFERENCE.md).

## Install Layout

- Kernel memory: `~/.pi/agent/AGENTS.md`
- Skills: `~/.pi/agent/skills/<skill-name>/SKILL.md`
- Managed custom agents: `~/.pi/agent/agents/b-agentic/{b-planner,b-researcher,b-debugger,b-reviewer}.md`
- Shared references: `~/.pi/agent/b-agentic/references/kernel.template.md` and
  `mcp_operations.yaml`
- Managed subagent settings template and backup:
  `~/.pi/agent/b-agentic/templates/subagents.user.template.json`
- User Pi settings: `~/.pi/agent/settings.json` (merged, never replaced)
- MCP template: `~/.pi/agent/b-agentic/templates/mcp.user.template.json`
- User MCP config: `~/.pi/agent/mcp.json` (Pi-owned override read by
  `pi-mcp-adapter`)
- First-party extensions: `~/.pi/agent/extensions/`
- Extension snapshots and backups: `~/.pi/agent/b-agentic/extensions/` and
  `backups/`
- Managed custom-agent snapshots and backups: `~/.pi/agent/b-agentic/agents/`
  and `backups/`
- Child-only read-only guard: `~/.pi/agent/b-agentic/subagent-read-only-guard.ts`
- Theme: `~/.pi/agent/themes/dracula.json` (symlink to the b-agentic cache)
- Managed state and cache: `~/.pi/agent/b-agentic/`

## Ownership Boundary

The installer manages b-agentic files and caches under the Pi agent directory
while preserving unrelated files, configuration, and symlinks. User
`~/.pi/agent/AGENTS.md`, `~/.pi/agent/mcp.json`, and `~/.pi/agent/settings.json`
remain owner-controlled. MCP and subagent settings are merged rather than
replaced; only template-managed entries are removed on uninstall. A modified or
symlinked managed custom-agent profile or child-only guard is preserved rather
than overwritten or removed.

The default merged `subagents` settings disable pi-subagents bundled agents and
set the four b-agentic profiles to `model: "inherit"`. Users can subsequently
use `/subagents` to persist a model, thinking, or prompt change at the desired
scope; project settings take precedence over user settings. The main session
remains the only user-facing worktree writer. `b-planner`, `b-researcher`,
`b-debugger`, and `b-reviewer` return bounded read-only results and never
coordinate with peer sessions. Their child-only guard blocks Bash, mutating
native/orchestration tools, direct MCP tools, and unclassified MCP gateway
calls; it permits only classified read-only or safe conditional-read gateway
operations.

The template MCP configuration enables headless, isolated Playwright with the
testing capability (`--caps=testing`), providing locator generation and state
verification tools (`browser_generate_locator`, `browser_verify_*`).
