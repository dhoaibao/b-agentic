# OpenCode Runtime Layout

This directory contains OpenCode runtime templates that are copied or referenced by `install.sh`.

## Supported distribution mode

The OpenCode release supports a personal-global install:

- Kernel memory: `~/.config/opencode/AGENTS.md`
- Skills: `~/.claude/skills/<skill-name>/SKILL.md` (cross-tool compatibility; OpenCode reads Claude Code skill directories natively)
- Command wrappers: `~/.config/opencode/commands/<command-name>.md`
- Skill-local shared references: `~/.claude/skills/<skill-name>/references/b-agentic/*.md`
- Suite metadata, backups, and source snapshots: `~/.config/opencode/b-agentic/`
- Shared reference snapshot: `~/.config/opencode/b-agentic/references/*.md`
- Sensitive artifacts: `~/.config/opencode/b-agentic/<skill>/<run-id>/` or `/tmp/opencode/b-agentic/<skill>/<run-id>/`
- Temporary logs: `/tmp/opencode/b-agentic/<skill>/<slug>.log`

> **Constraint:** Skills remain Claude-Code-shaped because OpenCode reads the Anthropic Agent Skills format natively, including from `~/.claude/skills/`. `${CLAUDE_SKILL_DIR}` references in skills continue to work when Claude Code is installed. Full native skill re-templating for OpenCode is a future iteration.

## Invocation policy

OpenCode exposes each skill directory via its native skill tool. Skills are loaded on-demand when the agent invokes the `skill` tool. Skill descriptions are the primary routing signal.

The adapter also installs thin markdown command wrappers into `~/.config/opencode/commands/` so `/b-*` commands stay available in the TUI. Each wrapper delegates back to the matching skill instead of duplicating the full skill body. If a command file with the same name already exists, the installer preserves it and skips that managed wrapper.

## Safety policy

The installer never overwrites an existing `~/.config/opencode/AGENTS.md` without `--replace-memory`. Plain install syncs skills and references, and writes the kernel. Existing colliding command files are preserved in place, and uninstall removes only wrapper files that still match the managed snapshot.

## Global MCP Setup

OpenCode uses `opencode.json` for configuration. MCP servers are configured under the `mcp` key. The installer merges `mcp.user.template.json` from this directory into `~/.config/opencode/opencode.json` automatically, the same way the Claude Code adapter writes to `~/.claude.json`. Existing user entries are preserved; b-agentic entries are removed on uninstall. The default Serena entry runs `serena start-mcp-server --context ide --project-from-cwd` so OpenCode uses Serena's IDE context.

The installer also prompts for optional API keys (Context7, Brave Search, Firecrawl) when run with `--prompt-api-keys`. Key values are written only to the user's `opencode.json` and never to the tracked template.

The managed Brave Search, Firecrawl, and Playwright entries launch through `bunx`, so Bun must be available on `PATH` when those MCP servers are started.

| Server | Use |
|---|---|
| `serena` | Semantic code navigation/editing for local source work. |
| `context7` | Library/framework documentation lookup. |
| `brave-search` | Open-web and news discovery. |
| `firecrawl` | Known URL and document extraction. |
| `playwright` | Browser/DOM/visual/e2e evidence with isolated state. |
| `gitnexus` | Optional graph radar for architecture and blast-radius work. |

MCP safety rules:
- Use environment-variable placeholders such as `{env:CONTEXT7_API_KEY}`, `{env:BRAVE_API_KEY}`, and `{env:FIRECRAWL_API_KEY}` in config; never commit real API keys.
- Keep Playwright configured with `--isolated` unless a user explicitly opts into persistent browser state outside the tracked worktree.
- Treat GitNexus as optional power-user radar.

## Validator scope

`scripts/validate-skills.sh` discovers and runs `runtimes/<name>/scripts/validate.sh` for each adapter. Shared checks (skill count, frontmatter, required sections) run first, then per-runtime validators check adapter-specific invariants.
