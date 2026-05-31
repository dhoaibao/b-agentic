# Antigravity CLI Runtime Layout

This directory contains Antigravity CLI runtime templates that are copied or referenced by `install.sh`.

## Supported distribution mode

The Antigravity adapter supports a personal-global install:

- Kernel memory: `~/.gemini/GEMINI.md`
- Skills: `~/.gemini/antigravity-cli/skills/<skill-name>/SKILL.md`
- Skill commands: `/b-*` from `~/.gemini/antigravity-cli/skills/<skill-name>/SKILL.md`
- Skill-local support files: `~/.gemini/antigravity-cli/skills/<skill-name>/reference.md`
- Suite metadata, backups, and source snapshots: `~/.gemini/antigravity-cli/b-agentic/`
- Shared contract reference snapshot: `~/.gemini/antigravity-cli/b-agentic/references/contract/*.md`
- Recommended MCP template: `~/.gemini/antigravity-cli/b-agentic/templates/mcp_config.template.json`
- User-scope settings: `~/.gemini/antigravity-cli/settings.json`
- User-scope MCP config: `~/.gemini/antigravity-cli/mcp_config.json`
- Sensitive artifacts: `~/.gemini/antigravity-cli/b-agentic/<skill>/<run-id>/` or `/tmp/antigravity-cli/b-agentic/<skill>/<run-id>/`
- Temporary logs: `/tmp/antigravity-cli/b-agentic/<skill>/<slug>.log`

> Antigravity CLI uses `~/.gemini/GEMINI.md` as global context and keeps Antigravity-owned settings, skills, plugins, MCP config, and b-agentic metadata under `~/.gemini/antigravity-cli/`. The adapter installs the runtime kernel as `~/.gemini/GEMINI.md` and snapshots it under `~/.gemini/antigravity-cli/b-agentic/GEMINI.md` for uninstall safety.
> Shared skills and shared contract files still stay runtime-neutral in behavior; runtime-specific install paths are resolved by the renderer and installer.

## Invocation policy

Antigravity CLI exposes each installed b-agentic skill as a native slash command, so users can invoke `/b-plan`, `/b-implement`, `/b-review`, and the rest of the `/b-*` surface directly from the installed skill tree.

The adapter does not install duplicate TOML wrappers into `~/.gemini/commands/`.

## Safety policy

The installer never overwrites an existing `~/.gemini/GEMINI.md` without `--replace-memory`. Plain install syncs runtime-local skills, installs the shared reference snapshot under `~/.gemini/antigravity-cli/b-agentic/references/`, writes the kernel snapshot, writes or merges Antigravity settings, and merges b-agentic MCP entries into `~/.gemini/antigravity-cli/mcp_config.json`. Existing user settings and MCP entries are preserved, and uninstall removes only managed settings or managed MCP entries.

## Global MCP Setup

Antigravity CLI uses a separate `mcp_config.json` file for MCP servers. MCP servers are configured under the top-level `mcpServers` object. The installer merges `mcp_config.template.json` from this directory into `~/.gemini/antigravity-cli/mcp_config.json` automatically. Existing user entries are preserved; b-agentic entries are removed on uninstall.

Remote MCP entries use `serverUrl`. The managed Context7 entry therefore uses `serverUrl`, while stdio servers continue to use `command` and `args`.

The installer also prompts for optional API keys (Context7, Brave Search, Firecrawl) when run with `--prompt-api-keys`. Key values are written only to the user's `mcp_config.json` and never to the tracked template.

The managed Brave Search, Firecrawl, and Playwright entries launch through `pnpm dlx`, so pnpm must be available on `PATH` when those MCP servers are started.

| Server | Use |
|---|---|
| `serena` | Semantic code navigation/editing for local source work. |
| `context7` | Library/framework documentation lookup. |
| `brave-search` | Open-web and news discovery. |
| `firecrawl` | Known URL and document extraction. |
| `playwright` | Browser/DOM/visual/e2e evidence with isolated state. |

MCP safety rules:
- Use environment-variable placeholders such as `$CONTEXT7_API_KEY`, `$BRAVE_API_KEY`, and `$FIRECRAWL_API_KEY` in config; never commit real API keys.
- Keep Playwright configured with `--isolated` unless a user explicitly opts into persistent browser state outside the tracked worktree.

## MCP readiness after install

- `playwright` is immediately available once `pnpm` is on `PATH`; no extra suite-owned setup runs.
- `context7`, `brave-search`, and `firecrawl` entries are installed immediately, but live requests need user-scope API keys in `~/.gemini/antigravity-cli/mcp_config.json` or matching shell environment variables.
- `serena` entry is installed, but full symbol-aware value still depends on the user having Serena installed and completing first-use setup when needed. The installer never runs `serena setup`, `serena init`, or onboarding.

## Optional shell tooling recommendations

Install reports print a default shell-tooling tier for `rg`, `fd`/`fdfind`, and `jq`, plus a separate optional tier for `bat`/`batcat`, `yq`, `git-delta`, `gh`, `tmux`, and `fzf`.
The tier-2 block is aimed at readable file previews, YAML-heavy work, better git diffs, GitHub-heavy workflows, long-running jobs, and non-interactive scoring.
When the installer can detect Homebrew, `apt`, or `dnf`, it prints matching package commands for both tiers; otherwise it falls back to manual-install notes.
The installer never auto-installs these packages.

## Validator scope

`scripts/validate-skills.sh` is the stable wrapper over `tooling/validate/run.sh`, which discovers and runs `runtimes/<name>/scripts/validate.sh` for each registered adapter. Shared checks should fail on runtime-specific wording drift in shared skills and shared contract files, while runtime-owned checks enforce the Antigravity install layout documented here.

`scripts/smoke-install.sh` is the stable wrapper over `tests/smoke/install.sh`. The Antigravity adapter contributes its install coverage through `runtimes/antigravity-cli/tests/smoke.sh`.

For release-critical delivery changes, prefer `scripts/validate-skills.sh --release`; it keeps the same shared validation path but also runs installer smoke so launcher and install regressions fail the maintained entrypoint.
