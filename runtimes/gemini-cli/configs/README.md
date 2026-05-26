# Gemini CLI Runtime Layout

This directory contains Gemini CLI runtime templates that are copied or referenced by `install.sh`.

## Supported distribution mode

The Gemini adapter supports a personal-global install:

- Kernel memory: `~/.gemini/GEMINI.md`
- Skills: `~/.gemini/skills/<skill-name>/SKILL.md`
- Skill commands: `/b-*` from `~/.gemini/skills/<skill-name>/SKILL.md`
- Skill-local support files: `~/.gemini/skills/<skill-name>/reference.md`
- Suite metadata, backups, and source snapshots: `~/.gemini/b-agentic/`
- Shared reference snapshot: `~/.gemini/b-agentic/references/*.md`
- Recommended MCP template: `~/.gemini/b-agentic/templates/settings.template.json`
- User-scope config: `~/.gemini/settings.json`
- Sensitive artifacts: `~/.gemini/b-agentic/<skill>/<run-id>/` or `/tmp/gemini-cli/b-agentic/<skill>/<run-id>/`
- Temporary logs: `/tmp/gemini-cli/b-agentic/<skill>/<slug>.log`

> Gemini CLI reads user settings from `~/.gemini/settings.json` and exposes installed skills as slash commands. The adapter installs the runtime kernel as `~/.gemini/GEMINI.md` and also snapshots it under `~/.gemini/b-agentic/GEMINI.md` for uninstall safety.
> Shared skills and shared contract files still stay runtime-neutral in behavior; runtime-specific install paths are resolved by the renderer and installer.

## Invocation policy

Gemini CLI exposes each installed b-agentic skill as a native slash command, so users can invoke `/b-plan`, `/b-implement`, `/b-review`, and the rest of the `/b-*` surface directly from the installed skill tree.

The adapter does not install duplicate TOML wrappers into `~/.gemini/commands/`. During upgrade, it removes prior managed wrappers that still match the managed snapshot and preserves user-edited or user-owned command files. A preserved user command with the same `/b-*` name can still collide with Gemini's native skill command; rename or remove that user command if Gemini reports a conflict.

## Safety policy

The installer never overwrites an existing `~/.gemini/GEMINI.md` without `--replace-memory`. Plain install syncs runtime-local skills, installs the shared reference snapshot under `~/.gemini/b-agentic/references/`, writes the kernel snapshot, and merges b-agentic MCP entries into `~/.gemini/settings.json`. Existing user settings are preserved, and uninstall removes only managed settings and legacy command files that still match the managed snapshot.

## Global MCP Setup

Gemini CLI uses `settings.json` for configuration. MCP servers are configured under the top-level `mcpServers` object. The installer merges `settings.template.json` from this directory into `~/.gemini/settings.json` automatically. Existing user entries are preserved; b-agentic entries are removed on uninstall.

The installer also prompts for optional API keys (Context7, Brave Search, Firecrawl) when run with `--prompt-api-keys`. Key values are written only to the user's `settings.json` and never to the tracked template.

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
- Use environment-variable placeholders such as `$CONTEXT7_API_KEY`, `$BRAVE_API_KEY`, and `$FIRECRAWL_API_KEY` in config; never commit real API keys.
- Keep Playwright configured with `--isolated` unless a user explicitly opts into persistent browser state outside the tracked worktree.
- Treat GitNexus as optional power-user radar.

## MCP readiness after install

- `playwright` is immediately available once Bun is on `PATH`; no extra suite-owned setup runs.
- `context7`, `brave-search`, and `firecrawl` entries are installed immediately, but live requests need user-scope API keys in `~/.gemini/settings.json` or matching shell environment variables.
- `serena` entry is installed, but full symbol-aware value still depends on the user having Serena installed and completing first-use setup when needed. The installer never runs `serena setup`, `serena init`, or onboarding.
- `gitnexus` entry is installed, but graph radar depends on the user having GitNexus installed and running their own indexing/analyze flow. The installer never runs GitNexus setup or indexing.

## Optional shell tooling recommendations

Install reports print a default shell-tooling tier for `rg`, `fd`/`fdfind`, `jq`, `tmux`, and `fzf`, plus a separate optional tier for `bat`/`batcat`, `yq`, `git-delta`, and `gh`.
The tier-2 block is aimed at readable file previews, YAML-heavy work, better git diffs, and GitHub-heavy workflows.
When the installer can detect Homebrew, `apt`, or `dnf`, it prints matching package commands for both tiers; otherwise it falls back to manual-install notes.
The installer never auto-installs these packages.

## Validator scope

`scripts/validate-skills.sh` is the stable wrapper over `tooling/validate/run.sh`, which discovers and runs `runtimes/<name>/scripts/validate.sh` for each registered adapter. Shared checks should fail on runtime-specific wording drift in shared skills and shared contract files, while runtime-owned checks enforce the Gemini install layout documented here.

`scripts/smoke-install.sh` is the stable wrapper over `tests/smoke/install.sh`. The Gemini adapter contributes its install coverage through `runtimes/gemini-cli/tests/smoke.sh`.
