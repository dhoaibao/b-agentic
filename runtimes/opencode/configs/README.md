# OpenCode Runtime Layout

This directory contains OpenCode runtime templates that are copied or referenced by `install.sh`.

## Supported distribution mode

The OpenCode release supports a personal-global install:

- Kernel memory: `~/.config/opencode/AGENTS.md`
- Skills: `~/.config/opencode/skills/<skill-name>/SKILL.md`
- Command wrappers: `~/.config/opencode/commands/<command-name>.md`
- Skill-local support files: `~/.config/opencode/skills/<skill-name>/reference.md`
- Suite metadata, backups, and source snapshots: `~/.config/opencode/b-agentic/`
- Shared contract reference snapshot: `~/.config/opencode/b-agentic/references/contract/*.md`
- Shared decision cards: `~/.config/opencode/b-agentic/references/cards/*.md`
- Sensitive artifacts: `~/.config/opencode/b-agentic/<skill>/<run-id>/` or `/tmp/opencode/b-agentic/<skill>/<run-id>/`
- Temporary logs: `/tmp/opencode/b-agentic/<skill>/<slug>.log`

> OpenCode installs and reads its own runtime-local skill tree under `~/.config/opencode/skills/`. Shared skills and shared contract files still stay runtime-neutral in behavior; runtime-specific install paths are resolved by the renderer and installer.

## Invocation policy

OpenCode exposes each skill directory via its native skill tool. Skills are loaded on-demand when the agent invokes the `skill` tool. Skill descriptions are the primary routing signal.

The adapter also installs thin markdown command wrappers into `~/.config/opencode/commands/` so `/b-*` commands stay available in the TUI. Each wrapper delegates back to the matching skill instead of duplicating the full skill body. If a command file with the same name already exists, the installer preserves it and skips that managed wrapper.

## Continuation and resume guarantees

This adapter does not provide native phase-to-phase automation. b-agentic workflows resume through operator-issued skill invocations plus the previous `[status]` or `[handoff]` block in context. OpenCode command wrappers preserve invocation ergonomics only; they do not automatically advance a workflow phase. Durable resume state, when a skill writes it, follows the shared run-id and artifact rules under `~/.config/opencode/b-agentic/references/contract/08-artifacts.md` and `~/.config/opencode/b-agentic/references/contract/11-session.md`.

## Safety policy

The installer never overwrites an existing `~/.config/opencode/AGENTS.md` without `--replace-memory`. Plain install syncs runtime-local skills, installs the shared reference snapshot under `~/.config/opencode/b-agentic/references/`, and writes the kernel. Existing colliding command files are preserved in place, and uninstall removes only wrapper files that still match the managed snapshot.

## Global MCP Setup

OpenCode uses `opencode.json` for configuration. MCP servers are configured under the `mcp` key. The installer merges `mcp.user.template.json` from this directory into `~/.config/opencode/opencode.json` automatically, the same way the Claude Code adapter writes to `~/.claude.json`. Existing user entries are preserved; b-agentic entries are removed on uninstall. The default Serena entry runs `serena start-mcp-server --context ide --project-from-cwd` so OpenCode uses Serena's IDE context.

The installer also prompts for optional API keys (Context7, Brave Search, Firecrawl) when run with `--prompt-api-keys`. Key values are written only to the user's `opencode.json` and never to the tracked template.

The managed Brave Search, Firecrawl, and Playwright entries launch through `pnpm dlx`, so pnpm must be available on `PATH` when those MCP servers are started.

| Server | Use |
|---|---|
| `serena` | Semantic code navigation/editing for local source work. |
| `context7` | Library/framework documentation lookup. |
| `brave-search` | Open-web and news discovery. |
| `firecrawl` | Known URL and document extraction. |
| `playwright` | Browser/DOM/visual/e2e evidence with isolated state. |

MCP safety rules:
- Use environment-variable placeholders such as `{env:CONTEXT7_API_KEY}`, `{env:BRAVE_API_KEY}`, and `{env:FIRECRAWL_API_KEY}` in config; never commit real API keys.
- Keep Playwright configured with `--isolated` unless a user explicitly opts into persistent browser state outside the tracked worktree.

## MCP readiness after install

- `playwright` is immediately available once `pnpm` is on `PATH`; no extra suite-owned setup runs.
- `context7`, `brave-search`, and `firecrawl` entries are installed immediately, but live requests need user-scope API keys in `~/.config/opencode/opencode.json`.
- `serena` entry is installed, but full symbol-aware value still depends on the user having Serena installed and completing first-use setup when needed. The installer never runs `serena setup`, `serena init`, or onboarding.

## Optional shell tooling recommendations

Install reports print a default shell-tooling tier for `rg`, `fd`/`fdfind`, and `jq`, plus a separate optional tier for `bat`/`batcat`, `yq`, `git-delta`, `gh`, `tmux`, and `fzf`.
The tier-2 block is aimed at readable file previews, YAML-heavy work, better git diffs, GitHub-heavy workflows, long-running jobs, and non-interactive scoring.
When the installer can detect Homebrew, `apt`, or `dnf`, it prints matching package commands for both tiers; otherwise it falls back to manual-install notes.
The installer never auto-installs these packages.

## Validator scope

`scripts/validate-skills.sh` is the stable wrapper over `tooling/validate/run.sh`, which discovers and runs `runtimes/<name>/scripts/validate.sh` for each registered adapter. Shared checks should fail on runtime-specific wording drift in shared skills and shared contract files, while runtime-owned checks enforce the OpenCode install layout documented here.

`scripts/smoke-install.sh` is the stable wrapper over `tests/smoke/install.sh`. The OpenCode adapter contributes its install coverage through `runtimes/opencode/tests/smoke.sh`.

For release-critical delivery changes, prefer `scripts/validate-skills.sh --release`; it keeps the same shared validation path but also runs installer smoke so launcher and install regressions fail the maintained entrypoint.
