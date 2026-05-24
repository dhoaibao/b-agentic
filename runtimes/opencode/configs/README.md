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

> **Constraint:** OpenCode intentionally consumes the shared Claude-shaped skill tree from `~/.claude/skills/`. Shared skills and shared contract files still must stay runtime-neutral in behavior; `${CLAUDE_SKILL_DIR}` support-path usage is the current shared delivery bridge marker and temporary delivery mechanic in this iteration. Full native skill re-templating for OpenCode is a future iteration.

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

## MCP readiness after install

- `playwright` is immediately available once Bun is on `PATH`; no extra suite-owned setup runs.
- `context7`, `brave-search`, and `firecrawl` entries are installed immediately, but live requests need user-scope API keys in `~/.config/opencode/opencode.json`.
- `serena` entry is installed, but full symbol-aware value still depends on the user having Serena installed and completing first-use setup when needed. The installer never runs `serena setup`, `serena init`, or onboarding.
- `gitnexus` entry is installed, but graph radar depends on the user having GitNexus installed and running their own indexing/analyze flow. The installer never runs GitNexus setup or indexing.

## Validator scope

`scripts/validate-skills.sh` is the stable wrapper over `tooling/validate/run.sh`, which discovers and runs `runtimes/<name>/scripts/validate.sh` for each registered adapter. Shared checks should fail on runtime-specific wording drift in shared skills and shared contract files, while allowing the documented `${CLAUDE_SKILL_DIR}` bridge marker and the adapter-owned OpenCode delivery constraints described here.

`scripts/smoke-install.sh` is the stable wrapper over `tests/smoke/install.sh`. The OpenCode adapter contributes its install coverage through `runtimes/opencode/tests/smoke.sh`.
