# Zed Runtime Layout

This directory contains Zed runtime templates that are copied or referenced by `install.sh`.

## Supported distribution mode

The Zed adapter supports a personal-global install:

- Kernel memory: `~/.config/zed/AGENTS.md`
- Skills: `~/.agents/skills/<skill-name>/SKILL.md`
- Skill-local support files: `~/.agents/skills/<skill-name>/reference.md`
- Suite metadata, backups, and source snapshots: `~/.agents/b-agentic/`
- Shared contract reference snapshot: `~/.agents/b-agentic/references/contract/*.md`
- Recommended MCP template: `~/.agents/b-agentic/templates/mcp.user.template.json`
- User-scope MCP config: `~/.config/zed/settings.json`
- Sensitive artifacts: `~/.agents/b-agentic/<skill>/<run-id>/` or `/tmp/zed/b-agentic/<skill>/<run-id>/`
- Temporary logs: `/tmp/zed/b-agentic/<skill>/<slug>.log`

> Zed uses `~/.config/zed/AGENTS.md` as its global agent instruction file (v1.4.0+) and merges MCP servers into `~/.config/zed/settings.json` under the `context_servers` key. The `~/.agents/skills/` path is Zed's standard global skill discovery path. The adapter installs the runtime kernel as `~/.config/zed/AGENTS.md` and snapshots it under `~/.agents/b-agentic/AGENTS.md` for uninstall safety.
> Shared skills and shared contract files still stay runtime-neutral in behavior; runtime-specific install paths are resolved by the renderer and installer.

## Invocation policy

Zed exposes installed b-agentic skills as native slash commands, so users can invoke `/b-plan`, `/b-implement`, `/b-review`, and the rest of the `/b-*` surface directly using the native slash command surface.

The adapter does not install wrapper files; Zed discovers skills from `~/.agents/skills/` automatically.

## Safety policy

The installer never overwrites an existing `~/.config/zed/AGENTS.md` without `--replace-memory`. Plain install syncs runtime-local skills, installs the shared reference snapshot under `~/.agents/b-agentic/references/`, writes the kernel snapshot, and merges b-agentic MCP entries into `~/.config/zed/settings.json` under the `context_servers` key. Existing user settings and MCP entries are preserved, and uninstall removes only managed MCP entries.

## Global MCP Setup

Zed MCP servers are configured under the `context_servers` key inside `~/.config/zed/settings.json`. The installer merges `mcp.user.template.json` from this directory into `~/.config/zed/settings.json` automatically. Existing user entries are preserved; b-agentic entries are removed on uninstall.

Remote MCP entries use `url`. The managed Context7 entry therefore uses `url`, while stdio servers continue to use `command` and `args`.

The installer also prompts for optional API keys (Context7, Brave Search, Firecrawl) when run with `--prompt-api-keys`. Key values are written only to the user's `~/.config/zed/settings.json` and never to the tracked template.

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
- `context7`, `brave-search`, and `firecrawl` entries are installed immediately, but live requests need user-scope API keys in `~/.config/zed/settings.json` or matching shell environment variables.
- `serena` entry is installed, but full symbol-aware value still depends on the user having Serena installed and completing first-use setup when needed. The installer never runs `serena setup`, `serena init`, or onboarding.

## Optional shell tooling recommendations

Install reports print a default shell-tooling tier for `rg`, `fd`/`fdfind`, and `jq`, plus a separate optional tier for `bat`/`batcat`, `yq`, `git-delta`, `gh`, `tmux`, and `fzf`.
The installer never auto-installs these packages.

## Validator scope

`scripts/validate-skills.sh` is the stable wrapper over `tooling/validate/run.sh`, which discovers and runs `runtimes/<name>/scripts/validate.sh` for each registered adapter. Shared checks should fail on runtime-specific wording drift in shared skills and shared contract files, while runtime-owned checks enforce the Zed install layout documented here.

`scripts/smoke-install.sh` is the stable wrapper over `tests/smoke/install.sh`. The Zed adapter contributes its install coverage through `runtimes/zed/tests/smoke.sh`.

For release-critical delivery changes, prefer `scripts/validate-skills.sh --release`; it keeps the same shared validation path but also runs installer smoke so launcher and install regressions fail the maintained entrypoint.
