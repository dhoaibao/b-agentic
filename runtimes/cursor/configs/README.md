# Cursor Runtime Layout

This directory contains Cursor runtime templates that are copied or referenced by `install.sh`.

## Supported distribution mode

The Cursor adapter supports a personal-global install:

- Kernel memory: `~/.cursor/AGENTS.md`
- Skills: `~/.cursor/skills/<skill-name>/SKILL.md`
- Skill-local support files: `~/.cursor/skills/<skill-name>/reference.md`
- Suite metadata, backups, and source snapshots: `~/.cursor/b-agentic/`
- Shared contract reference snapshot: `~/.cursor/b-agentic/references/contract/*.md`
- Shared decision cards: `~/.cursor/b-agentic/references/cards/*.md`
- Recommended MCP template: `~/.cursor/b-agentic/templates/mcp.user.template.json`
- User-scope MCP config: `~/.cursor/mcp.json`
- Sensitive artifacts: `~/.cursor/b-agentic/<skill>/<run-id>/` or `/tmp/cursor/b-agentic/<skill>/<run-id>/`
- Temporary logs: `/tmp/cursor/b-agentic/<skill>/<slug>.log`

> Cursor uses `~/.cursor/AGENTS.md` as a global agent instruction file and configures MCP servers in `~/.cursor/mcp.json` under the `mcpServers` key. The `~/.cursor/skills/` path is the standard global skill discovery path. The adapter installs the runtime kernel as `~/.cursor/AGENTS.md` and snapshots it under `~/.cursor/b-agentic/AGENTS.md` for uninstall safety.
>
> **Note:** `~/.cursor/AGENTS.md` as a global agent instruction file is consistent with `~/.cursor/` being Cursor's established global config root (where `~/.cursor/mcp.json` and `~/.cursor/skills/` already live), but is not yet explicitly documented by Cursor. If Cursor does not auto-load this file, add the kernel content manually via Cursor Settings → Rules.
>
> Shared skills and shared contract files remain runtime-neutral in behavior; runtime-specific install paths are resolved by the renderer and installer.

## Invocation policy

Cursor exposes installed b-agentic skills as native slash commands, so users can invoke `/b-plan`, `/b-implement`, `/b-review`, and the rest of the `/b-*` surface directly using the native slash command surface.

The adapter does not install wrapper files; Cursor discovers skills from `~/.cursor/skills/` automatically.

## Continuation and resume guarantees

This adapter does not provide native phase-to-phase automation. b-agentic workflows resume through operator-issued skill invocations plus the previous `[status]` or `[handoff]` block in context. Durable resume state, when a skill writes it, follows the shared run-id and artifact rules under `~/.cursor/b-agentic/references/contract/08-artifacts.md` and `~/.cursor/b-agentic/references/contract/11-session.md`.

## Safety policy

The installer never overwrites an existing `~/.cursor/AGENTS.md` without `--replace-memory`. Plain install syncs runtime-local skills, installs the shared reference snapshot under `~/.cursor/b-agentic/references/`, writes the kernel snapshot, and merges b-agentic MCP entries into `~/.cursor/mcp.json` under the `mcpServers` key. Existing user settings and MCP entries are preserved, and uninstall removes only managed MCP entries.

## Global MCP Setup

Cursor MCP servers are configured under the `mcpServers` key inside `~/.cursor/mcp.json`. The installer merges `mcp.user.template.json` from this directory into `~/.cursor/mcp.json` automatically. Existing user entries are preserved; b-agentic entries are removed on uninstall.

Remote MCP entries use `url`. The managed Context7 entry therefore uses `url`, while stdio servers continue to use `command` and `args`.

The installer also prompts for optional API keys (Context7, Brave Search, Firecrawl) when run with `--prompt-api-keys`. Key values are written only to the user's `~/.cursor/mcp.json` and never to the tracked template.

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
- `context7`, `brave-search`, and `firecrawl` entries are installed immediately, but live requests need user-scope API keys in `~/.cursor/mcp.json` or matching shell environment variables.
- `serena` entry is installed, but full symbol-aware value still depends on the user having Serena installed and completing first-use setup when needed. The installer never runs `serena setup`, `serena init`, or onboarding.

## Hooks

Cursor supports a `~/.cursor/hooks.json` file for custom hook scripts. The b-agentic installer does **not** merge hook scripts for the Cursor runtime — b-agentic does not currently install hook scripts for any non-Claude-Code runtime. Cursor also loads Claude Code hooks via built-in third-party compatibility. If you use hook-based behaviors from a Claude Code install, those hooks continue to apply when Cursor's Claude Code compatibility layer is active.

## Optional shell tooling recommendations

Install reports print a default shell-tooling tier for `rg`, `fd`/`fdfind`, and `jq`, plus a separate optional tier for `bat`/`batcat`, `yq`, `git-delta`, `gh`, `tmux`, and `fzf`.
The installer never auto-installs these packages.

## Validator scope

`scripts/validate-skills.sh` is the stable wrapper over `tooling/validate/run.sh`, which discovers and runs `runtimes/<name>/scripts/validate.sh` for each registered adapter. Shared checks should fail on runtime-specific wording drift in shared skills and shared contract files, while runtime-owned checks enforce the Cursor install layout documented here.

`scripts/smoke-install.sh` is the stable wrapper over `tests/smoke/install.sh`. The Cursor adapter contributes its install coverage through `runtimes/cursor/tests/smoke.sh`.

For release-critical delivery changes, prefer `scripts/validate-skills.sh --release`; it keeps the same shared validation path but also runs installer smoke so launcher and install regressions fail the maintained entrypoint.
