# Claude Code Runtime Layout

This directory contains Claude Code runtime templates that are copied or referenced by `install.sh`.

## Supported distribution mode

The first Claude-native release supports a personal-global install only:

- Kernel memory: `~/.claude/CLAUDE.md`
- Skills: `~/.claude/skills/<skill-name>/SKILL.md`
- Skill-local support files: `~/.claude/skills/<skill-name>/reference.md`
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

The installer never overwrites an existing `~/.claude/CLAUDE.md` without `--replace-memory`. Plain install syncs skills, installs the shared reference snapshot under `~/.claude/b-agentic/references/`, merges recommended settings into `~/.claude/settings.json`, and merges user-scope MCP servers into `~/.claude.json`. Existing settings and MCP config are backed up before merge.

Settings merge is conservative: unknown keys are preserved, arrays are appended without duplicates, objects are merged recursively, and existing scalar values win conflicts.

## Global MCP Setup

Plain install merges `mcp.user.template.json` into `~/.claude.json` under top-level `mcpServers`, matching Claude Code's user scope. The global set contains Serena, Context7, Brave Search, Firecrawl, and Playwright.

| Server | Use |
|---|---|---|
| `serena` | Semantic code navigation/editing for local source work. |
| `context7` | Library/framework documentation lookup. |
| `brave-search` | Open-web and news discovery. |
| `firecrawl` | Known URL and document extraction. |
| `playwright` | Browser/DOM/visual/e2e evidence with isolated state. |

MCP safety rules:
- Use environment-variable placeholders such as `${CONTEXT7_API_KEY:-}`, `${BRAVE_API_KEY}`, and `${FIRECRAWL_API_KEY}` in templates; never commit real API keys.
- The managed Brave Search, Firecrawl, and Playwright entries launch through `pnpm dlx`, so pnpm must be available on `PATH` when those MCP servers are started.
- During an interactive install, prompt for Context7, Brave Search, and Firecrawl API keys and write provided values directly to user-scope `~/.claude.json`. Leave a prompt blank to keep the placeholder. Non-interactive installs skip prompts.
- Keep Playwright configured with `--isolated` unless a user explicitly opts into persistent browser state outside the tracked worktree.
- Do not include Claude hooks, generated root guidance, indexes, memories, or setup commands in MCP templates.
- Context7 may also offer CLI + Skills setup through `npx ctx7 setup`; b-agentic uses the MCP HTTP endpoint with the `${CONTEXT7_API_KEY:-}` optional header placeholder unless the installer prompt writes a concrete key, and does not run Context7 setup commands during install.

## MCP readiness after install

- `playwright` is immediately available once `pnpm` is on `PATH`; no extra suite-owned setup runs.
- `context7`, `brave-search`, and `firecrawl` entries are installed immediately, but live requests need user-scope API keys in `~/.claude.json`.
- `serena` entry is installed, but full symbol-aware value still depends on the user having Serena installed and completing first-use setup when needed. The installer never runs `serena setup`, `serena init`, or onboarding.

## Optional shell tooling recommendations

Install reports print a default shell-tooling tier for `rg`, `fd`/`fdfind`, and `jq`, plus a separate optional tier for `bat`/`batcat`, `yq`, `git-delta`, `gh`, `tmux`, and `fzf`.
The tier-2 block is aimed at readable file previews, YAML-heavy work, better git diffs, GitHub-heavy workflows, long-running jobs, and non-interactive scoring.
When the installer can detect Homebrew, `apt`, or `dnf`, it prints matching package commands for both tiers; otherwise it falls back to manual-install notes.
The installer never auto-installs these packages.

## Validator scope

`scripts/validate-skills.sh` is the stable wrapper over `tooling/validate/run.sh`, which runs shared regression checks for runtime-neutral skills and shared contract files plus each registered runtime validator. Claude-specific paths, memory filenames, install-layout details, and runtime caveats stay adapter-owned here and in `runtimes/claude-code/scripts/validate.sh`.

`scripts/smoke-install.sh` is the stable wrapper over `tests/smoke/install.sh`. The Claude adapter contributes its install coverage through `runtimes/claude-code/tests/smoke.sh`.

For release-critical delivery changes, prefer `scripts/validate-skills.sh --release`; it keeps the same shared validation path but also runs installer smoke so launcher and install regressions fail the maintained entrypoint.

Shared skills and shared contract files stay runtime-neutral; Claude-specific install paths remain adapter-owned here and in `runtimes/claude-code/scripts/validate.sh`.
