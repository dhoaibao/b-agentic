# Claude Code Runtime Layout

This directory contains Claude Code runtime templates that are copied or referenced by `install.sh`.

## Supported distribution mode

The first Claude-native release supports a personal-global install only:

- Kernel memory: `~/.claude/CLAUDE.md`
- Skills: `~/.claude/skills/<skill-name>/SKILL.md`
- Skill-local shared references: `~/.claude/skills/<skill-name>/references/b-agentic/*.md`
- Suite metadata, backups, and source snapshots: `~/.claude/b-agentic/`
- Shared reference snapshot: `~/.claude/b-agentic/references/*.md`
- Recommended settings template: `~/.claude/b-agentic/templates/settings.recommended.json`
- Global MCP template: `~/.claude/b-agentic/templates/mcp.user.template.json`
- User-scope MCP config: `~/.claude.json`
- Sensitive artifacts: `~/.claude/b-agentic/<skill>/<run-id>/` or `/tmp/claude-code/b-agentic/<skill>/<run-id>/`
- Temporary logs: `/tmp/claude-code/b-agentic/<skill>/<slug>.log`

Project-local `.claude/` install, plugin packaging, hooks, and dynamic context injection are non-goals for the first migrated release. Add them only after validator and smoke coverage prove global parity.

## Invocation policy

Claude Code exposes each skill directory as `/b-*`. Mutating or coordinating skills are manual-only through `disable-model-invocation: true`. Read-only discovery and review skills may remain model-invocable when their descriptions are tight and do not grant tools.

## Safety policy

The installer never overwrites an existing `~/.claude/CLAUDE.md` without `--replace-memory`. Plain install syncs skills and references, merges recommended settings into `~/.claude/settings.json`, and merges user-scope MCP servers into `~/.claude.json`. Existing settings and MCP config are backed up before merge.

Settings merge is conservative: unknown keys are preserved, arrays are appended without duplicates, objects are merged recursively, and existing scalar values win conflicts.

## Global MCP Setup

Plain install merges `mcp.user.template.json` into `~/.claude.json` under top-level `mcpServers`, matching Claude Code's user scope. The global set contains Serena, Context7, Brave Search, Firecrawl, Playwright, and GitNexus.

| Server | Use |
|---|---|---|
| `serena` | Semantic code navigation/editing for local source work. |
| `context7` | Library/framework documentation lookup. |
| `brave-search` | Open-web and news discovery. |
| `firecrawl` | Known URL and document extraction. |
| `playwright` | Browser/DOM/visual/e2e evidence with isolated state. |
| `gitnexus` | Optional graph radar for architecture and blast-radius work. |

MCP safety rules:
- Use environment-variable placeholders such as `${CONTEXT7_API_KEY}`, `${BRAVE_API_KEY}`, and `${FIRECRAWL_API_KEY}`; never commit real API keys.
- Keep Playwright configured with `--isolated` unless a user explicitly opts into persistent browser state outside the tracked worktree.
- Do not include Claude hooks, generated root guidance, indexes, memories, or setup commands in MCP templates.
- Treat GitNexus as optional power-user radar. Users must run `gitnexus analyze` or `gitnexus setup` themselves if they want indexing, generated skills, hooks, or global MCP config.
- Context7 may also offer CLI + Skills setup through `npx ctx7 setup`; b-agentic uses the MCP HTTP endpoint with the `${CONTEXT7_API_KEY}` header placeholder and does not run Context7 setup commands during install.
