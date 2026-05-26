# Kimi Code CLI Runtime Layout

This directory contains Kimi Code CLI runtime templates that are copied or referenced by `install.sh`.

## Supported distribution mode

The Kimi adapter supports a personal-global install:

- Kernel memory: `~/.kimi/AGENTS.md`
- Skills: `~/.kimi/skills/<skill-name>/SKILL.md`
- Skill commands: `/b-*` via native skill loader from installed skills
- Skill-local support files: `~/.kimi/skills/<skill-name>/reference.md`
- Suite metadata, backups, and source snapshots: `~/.kimi/b-agentic/`
- Shared reference snapshot: `~/.kimi/b-agentic/references/*.md`
- Recommended MCP template: `~/.kimi/b-agentic/templates/mcp_config.template.json`
- User-scope MCP config: `~/.kimi/mcp.json`
- Sensitive artifacts: `~/.kimi/b-agentic/<skill>/<run-id>/` or `/tmp/kimi-cli/b-agentic/<skill>/<run-id>/`
- Temporary logs: `/tmp/kimi-cli/b-agentic/<skill>/<slug>.log`

> Kimi Code CLI uses `~/.kimi/AGENTS.md` as user-level project guidance (following the cross-tool [AGENTS.md](https://agents.md) convention) and keeps skills and b-agentic metadata under `~/.kimi/`. The adapter installs the runtime kernel as `~/.kimi/AGENTS.md` and snapshots it under `~/.kimi/b-agentic/AGENTS.md` for uninstall safety.
> Shared skills and shared contract files still stay runtime-neutral in behavior; runtime-specific install paths are resolved by the renderer and installer.

## Invocation policy

Kimi Code CLI uses a native skill loader: each installed `~/.kimi/skills/<name>/SKILL.md` is discovered automatically, exposing `/b-plan`, `/b-implement`, `/b-review`, and the rest of the `/b-*` surface directly.

The adapter does not install command wrappers of any kind. `command_wrappers.supported = false`.

## Skills visibility note

Kimi Code CLI uses a brand-group directory model (mutually exclusive skill trees). If a user has both `~/.claude/skills/` and `~/.kimi/skills/` present, Kimi loads only `~/.kimi/skills/` by default. Users with existing Claude skills who want both trees visible should set `merge_all_available_skills = true` in `~/.kimi/config.toml`.

## Safety policy

The installer never overwrites an existing `~/.kimi/AGENTS.md` without `--replace-memory`. Plain install syncs runtime-local skills, installs the shared reference snapshot under `~/.kimi/b-agentic/references/`, writes the kernel snapshot, and merges b-agentic MCP entries into `~/.kimi/mcp.json`. The `~/.kimi/config.toml` is user-owned and is preserved — the installer does not touch it so user OAuth and provider settings from `/login` survive. Existing MCP entries are preserved; uninstall removes only managed MCP entries.

## Global MCP Setup

Kimi Code CLI uses a separate `~/.kimi/mcp.json` file for MCP servers. MCP servers are configured under the top-level `mcpServers` object (a format compatible with other MCP clients). The installer merges `mcp_config.template.json` from this directory into `~/.kimi/mcp.json` automatically. Existing user entries are preserved; b-agentic entries are removed on uninstall.

Remote MCP entries use `serverUrl`. The managed Context7 entry therefore uses `serverUrl`, while stdio servers continue to use `command` and `args`.

The installer also prompts for optional API keys (Context7, Brave Search, Firecrawl) when run with `--prompt-api-keys`. Key values are written only to the user's `~/.kimi/mcp.json` and never to the tracked template.

The managed Brave Search, Firecrawl, and Playwright entries launch through `pnpm dlx`, so pnpm must be available on `PATH` when those MCP servers are started.

| Server | Use |
|---|---|
| `serena` | Semantic code navigation/editing for local source work. |
| `context7` | Library/framework documentation lookup. |
| `brave-search` | Open-web and news discovery. |
| `firecrawl` | Known URL and document extraction. |
| `playwright` | Browser/DOM/visual/e2e evidence with isolated state. |
| `gitnexus` | Optional graph radar for architecture and blast-radius work. |

MCP safety rules:
- Use environment-variable placeholders such as `$CONTEXT7_API_KEY`, `$BRAVE_API_KEY`, and `$FIRECRAWL_API_KEY` in config; never commit real API keys.
- Keep Playwright configured with `--isolated` unless a user explicitly opts into persistent browser state outside the tracked worktree.
- Treat GitNexus as optional power-user radar.

## MCP readiness after install

- `playwright` is immediately available once Bun is on `PATH`; no extra suite-owned setup runs.
- `context7`, `brave-search`, and `firecrawl` entries are installed immediately, but live requests need user-scope API keys in `~/.kimi/mcp.json` or matching shell environment variables.
- `serena` entry is installed, but full symbol-aware value still depends on the user having Serena installed and completing first-use setup when needed. The installer never runs `serena setup`, `serena init`, or onboarding.
- `gitnexus` entry is installed, but graph radar depends on the user having GitNexus installed and running their own indexing/analyze flow. The installer never runs GitNexus setup or indexing.

## Optional shell tooling recommendations

Install reports print a default shell-tooling tier for `rg`, `fd`/`fdfind`, `jq`, `tmux`, and `fzf`, plus a separate optional tier for `bat`/`batcat`, `yq`, `git-delta`, and `gh`.
The installer never auto-installs these packages.

## Validator scope

`scripts/validate-skills.sh` is the stable wrapper over `tooling/validate/run.sh`, which discovers and runs `runtimes/<name>/scripts/validate.sh` for each registered adapter. Runtime-owned checks enforce the Kimi install layout documented here.

`scripts/smoke-install.sh` is the stable wrapper over `tests/smoke/install.sh`. The Kimi adapter contributes its install coverage through `runtimes/kimi-cli/tests/smoke.sh`.
