# Claude Code Runtime Layout

This directory contains Claude Code runtime templates that are copied or referenced by `install.sh`.

## Supported distribution mode

The first Claude-native release supports a personal-global install only:

- Kernel memory: `~/.claude/CLAUDE.md`
- Skills: `~/.claude/skills/<skill-name>/SKILL.md`
- Skill-local shared references: `~/.claude/skills/<skill-name>/references/b-agentic/*.md`
- Suite metadata, backups, and source snapshots: `~/.claude/b-agentic/`
- Shared reference snapshot: `~/.claude/b-agentic/references/*.md`
- Recommended settings template: `~/.claude/b-agentic/templates/settings.template.json`
- Global MCP template: `~/.claude/b-agentic/templates/mcp.user.template.json`
- User-scope MCP config: `~/.claude.json`
- Sensitive artifacts: `~/.claude/b-agentic/<skill>/<run-id>/` or `/tmp/claude-code/b-agentic/<skill>/<run-id>/`
- Temporary logs: `/tmp/claude-code/b-agentic/<skill>/<slug>.log`

Project-local `.claude/` install, plugin packaging, hooks, and dynamic context injection are non-goals for the first migrated release. Add them only after validator and smoke coverage prove global parity.

## Invocation policy

Claude Code exposes each skill directory as `/b-*`. All skills are model-invocable when their descriptions match the request. Skill descriptions are the primary routing signal.

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
- Use environment-variable placeholders such as `${CONTEXT7_API_KEY:-}`, `${BRAVE_API_KEY}`, and `${FIRECRAWL_API_KEY}` in templates; never commit real API keys.
- The managed Brave Search, Firecrawl, and Playwright entries launch through `bunx`, so Bun must be available on `PATH` when those MCP servers are started.
- During an interactive install, prompt for Context7, Brave Search, and Firecrawl API keys and write provided values directly to user-scope `~/.claude.json`. Leave a prompt blank to keep the placeholder. Non-interactive installs skip prompts.
- Keep Playwright configured with `--isolated` unless a user explicitly opts into persistent browser state outside the tracked worktree.
- Do not include Claude hooks, generated root guidance, indexes, memories, or setup commands in MCP templates.
- Treat GitNexus as optional power-user radar. The b-agentic MCP template uses `gitnexus mcp`, so GitNexus must be installed on `PATH`; users must run `gitnexus analyze` or `gitnexus setup` themselves if they want indexing, generated skills, hooks, or GitNexus-owned global MCP config.
- Context7 may also offer CLI + Skills setup through `npx ctx7 setup`; b-agentic uses the MCP HTTP endpoint with the `${CONTEXT7_API_KEY:-}` optional header placeholder unless the installer prompt writes a concrete key, and does not run Context7 setup commands during install.

## MCP readiness after install

- `playwright` is immediately available once Bun is on `PATH`; no extra suite-owned setup runs.
- `context7`, `brave-search`, and `firecrawl` entries are installed immediately, but live requests need user-scope API keys in `~/.claude.json`.
- `serena` entry is installed, but full symbol-aware value still depends on the user having Serena installed and completing first-use setup when needed. The installer never runs `serena setup`, `serena init`, or onboarding.
- `gitnexus` entry is installed, but graph radar depends on the user having GitNexus installed and running their own indexing/analyze flow. The installer never runs GitNexus setup or indexing.

## Validator scope

`scripts/validate-skills.sh` is the stable wrapper over `tooling/validate/run.sh`, which runs shared regression checks for runtime-neutral skills and shared contract files plus each registered runtime validator. Claude-specific paths, memory filenames, install-layout details, and runtime caveats stay adapter-owned here and in `runtimes/claude-code/scripts/validate.sh`.

`scripts/smoke-install.sh` is the stable wrapper over `tests/smoke/install.sh`. The Claude adapter contributes its install coverage through `runtimes/claude-code/tests/smoke.sh`.

The only shared bridge marker intentionally permitted outside the Claude adapter is `${CLAUDE_SKILL_DIR}` support-path usage in shared skills.
