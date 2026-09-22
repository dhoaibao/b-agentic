# OpenCode Configuration Layout

This page maps b-agentic's native OpenCode installation boundary. For workflow,
MCP, delegated-agent, safety, refresh, and readiness details, see the
[operational reference](../../REFERENCE.md).

## Install Layout

- Global kernel: `~/.config/opencode/AGENTS.md`
- Global skills: `~/.config/opencode/skills/<skill-name>/SKILL.md`
- Managed specialist agents:
  `~/.config/opencode/agents/{b-planner,b-researcher,b-debugger,b-reviewer}.md`
- Generated skill commands: `~/.config/opencode/commands/b-<skill>.md`
- User OpenCode configuration: `~/.config/opencode/opencode.json(c)` (merged,
  never replaced; an existing `.jsonc` file is retained)
- Optional terminal configuration: `~/.config/opencode/cli.json` (never managed
  by b-agentic)
- Managed source snapshots, references, templates, backups, and manifest:
  `~/.config/opencode/b-agentic/`

## Ownership Boundary

The installer manages b-agentic files and caches under the OpenCode
configuration directory while preserving unrelated files, configuration, and
symlinks. It merges b-agentic's native v2 `mcp.servers`, ordered `permissions`,
`plugins`, `compaction`, and `experimental.subagent_depth` recommendations into
`opencode.json`; it never replaces unrelated user settings. Managed `plugins`
entries union ahead of user entries and are removed on uninstall.
Modified or symlinked managed skills
and agents are preserved rather than overwritten or removed.

The four specialist agents are native `mode: subagent` profiles. Their
permissions rules deny edits, user questions, and nested subagents, while
read-only shell commands and the globally allowed read-only MCP tools remain
available for evidence gathering. The
main session remains the only user-facing worktree writer. OpenCode permissions
are tool-name based, so b-agentic intentionally does not claim argument-aware
MCP classification.

The MCP template disables OpenCode v2 Code Mode to preserve direct per-tool
permissions and enables headless isolated Playwright with `--caps=testing`,
which provides locator-generation and state-verification tools. The installer
never starts MCP servers or authenticates them.
