# Pi Configuration Layout

Adapter-owned layout for Pi.

## Install Layout

- Kernel memory: `~/.pi/agent/AGENTS.md`
- Skills: `~/.pi/agent/skills/<skill-name>/SKILL.md`
- Shared references: `~/.pi/agent/b-agentic/references/kernel.template.md` and `mcp_operations.yaml`
- MCP template: `~/.pi/agent/b-agentic/templates/mcp.user.template.json`
- User MCP config: `~/.pi/agent/mcp.json` (Pi-owned override read by `pi-mcp-adapter`)
- Permission extension: `~/.pi/agent/extensions/b-agentic-permissions.ts`
- Extension snapshot: `~/.pi/agent/b-agentic/extensions/b-agentic-permissions.ts`

## Optional Pi Packages

Pi does not provide native MCP. b-agentic installs MCP server entries into
`~/.pi/agent/mcp.json` and expects the community package
`pi-mcp-adapter` to load them. Interactive installs prompt before running
`pi install npm:pi-mcp-adapter`. Noninteractive installs run that only when
`B_AGENTIC_INSTALL_PI_MCP_ADAPTER=Y` is set.

For long-session compaction continuity, b-agentic can install the optional
`pi-observational-memory` package. Interactive installs prompt before running
`pi install npm:pi-observational-memory`; noninteractive installs require
`B_AGENTIC_INSTALL_PI_OBSERVATIONAL_MEMORY=Y`. Use it as the sole automatic
memory/compaction layer rather than combining it with another such extension.

Uninstall removes b-agentic-managed MCP config and the permission extension; it
does not remove any of these packages.

Servers default to lazy lifecycle through the adapter's proxy tool so schemas
are not eagerly injected into context. Optional adapter-specific `directTools`
settings can expose selected tools individually when needed.

## Safety

Pi has no native permission model. b-agentic installs a first-party extension
that listens for `tool_call` events and:

- asks before commits, pushes, pulls, reverts, dependency writes, long-lived
  services, and destructive-but-approvable actions
- blocks prohibited git/Docker families and protected native writes/edits;
  protected native reads require explicit UI approval and fail closed without UI
- inspects compound shell segments (`&&`, `;`, `|`), approval-gates literal
  protected-path tokens (including `rtk`-wrapped path variants), and strips
  `env`/`sudo`/`rtk` wrappers and `git -C` style option prefixes before matching
- requires approval for unbalanced quotes, shell expansions, and
  interpreter/eval-style wrappers (`bash -c`, `sh -c`, `node -e`, `python -c`,
  …) whose bodies are opaque to static matching
- requires RTK for every native command family listed by `rtk --help`; unsupported
  raw utilities must use their required modern replacements, and `rtk proxy` is unwrapped
  for the same safety classification as its effective command; allows MCP metadata
  discovery and only the explicitly classified read-only operations of managed MCP servers without prompts
- asks for MCP connect/server-scoping lifecycle operations, Serena local symbol mutations because the Pi adapter cannot prove a
  target is confined to the current repository; asks for Firecrawl external-mutation or local-upload tools (agent/crawl/interact/monitor/feedback/parse), Playwright page-mutating tools (click/type/upload/evaluate/…), MCP auth bootstrap, unclassified managed operations, user/unknown MCP servers, and any other non-built-in custom tool
- fails closed when MCP selectors are mixed (e.g. `connect` + `tool`), when an explicit MCP `server` disagrees with the tool-name origin, or when an approval-required action has no UI confirmation

## Validation

Use `scripts/validate-skills.sh` and `scripts/validate-skills.sh --release`
from the repository root. MCP readiness must distinguish missing adapter,
missing config, missing local prerequisites, and ready servers. The opt-in
`scripts/mcp-doctor.sh --probe-schemas` lane performs approved live startup/network
checks and reports current tool IDs that are new or absent relative to policy.
