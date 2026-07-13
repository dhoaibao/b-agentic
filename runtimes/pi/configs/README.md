# Pi Runtime Layout

Adapter-owned layout for Pi.

## Install Layout

- Kernel memory: `~/.pi/agent/AGENTS.md`
- Skills: `~/.pi/agent/skills/<skill-name>/SKILL.md`
- Shared references: `~/.pi/agent/b-agentic/references/kernel.template.md` and `mcp_operations.yaml`
- MCP template: `~/.pi/agent/b-agentic/templates/mcp.user.template.json`
- User MCP config: `~/.pi/agent/mcp.json` (Pi-owned override read by `pi-mcp-adapter`)
- Permission extension: `~/.pi/agent/extensions/b-agentic-permissions.ts`
- Extension snapshot: `~/.pi/agent/b-agentic/extensions/b-agentic-permissions.ts`

## MCP Adapter Dependency

Pi does not provide native MCP. b-agentic installs MCP server entries into
`~/.pi/agent/mcp.json` and expects the community package
`pi-mcp-adapter` to load them.

Interactive installs prompt before running
`pi install npm:pi-mcp-adapter`. Noninteractive installs run that only
when `B_AGENTIC_INSTALL_PI_MCP_ADAPTER=Y` is set. Uninstall removes
b-agentic-managed MCP config and the permission extension; it does not remove
the adapter package.

Servers default to lazy lifecycle through the adapter's proxy tool so schemas
are not eagerly injected into context. Optional adapter-specific `directTools`
settings can expose selected tools individually when needed.

## Safety

Pi has no native permission model. b-agentic installs a first-party extension
that listens for `tool_call` events and:

- asks before commits, pushes, pulls, reverts, dependency writes, long-lived
  services, and destructive-but-approvable actions
- blocks prohibited git/Docker families and read/write/edit of secret or
  repository-control paths
- inspects compound shell segments (`&&`, `;`, `|`), approval-gates literal
  protected-path tokens (including `rtk`-wrapped path variants), and strips
  `env`/`sudo`/`rtk` wrappers and `git -C` style option prefixes before matching
- requires approval for unbalanced quotes, shell expansions, and
  interpreter/eval-style wrappers (`bash -c`, `sh -c`, `node -e`, `python -c`,
  …) whose bodies are opaque to static matching
- allows built-in discovery tools (`grep`, `find`, `ls`), MCP metadata discovery, fully trusted managed servers (`serena`, `codegraph`, `context7`, `brave-search`), and operation-level Firecrawl/Playwright read tools without prompts
- asks for Firecrawl external-mutation or local-upload tools (agent/crawl/interact/monitor/feedback/parse), Playwright page-mutating tools (click/type/upload/evaluate/…), MCP auth bootstrap, user/unknown MCP servers, and any other non-built-in custom tool
- fails closed when MCP selectors are mixed (e.g. `connect` + `tool`), when an explicit MCP `server` disagrees with the tool-name origin, or when an approval-required action has no UI confirmation

## Validation

Use `scripts/validate-skills.sh` and `scripts/validate-skills.sh --release`
from the repository root. MCP readiness must distinguish missing adapter,
missing config, missing local prerequisites, and ready servers.
