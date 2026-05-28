# Codex CLI Runtime Layout

This directory contains Codex CLI runtime templates that are copied or referenced by `install.sh`.

## Supported distribution mode

The Codex adapter supports a personal-global install:

- Kernel memory: `~/.codex/AGENTS.md`
- Skills: `~/.codex/skills/<skill-name>/SKILL.md`
- Skill-local support files: `~/.codex/skills/<skill-name>/reference.md`
- Suite metadata, backups, and source snapshots: `~/.codex/b-agentic/`
- Shared reference snapshot: `~/.codex/b-agentic/references/*.md`
- Recommended MCP template: `~/.codex/b-agentic/templates/mcp.user.template.toml`
- User-scope config: `~/.codex/config.toml`
- Sensitive artifacts: `~/.codex/b-agentic/<skill>/<run-id>/` or `/tmp/codex-cli/b-agentic/<skill>/<run-id>/`
- Temporary logs: `/tmp/codex-cli/b-agentic/<skill>/<slug>.log`

> Codex reads its global kernel from `~/.codex/AGENTS.md`. Shared skills and shared contract files still stay runtime-neutral in behavior; runtime-specific install paths are resolved by the renderer and installer.

## Invocation policy

Codex exposes installed skills through `/skills` and `$skill-name`, and can also choose them implicitly from the skill description. The adapter installs skills under `~/.codex/skills/` and registers them through `[[skills.config]]` entries whose `path` points to the skill folder that contains `SKILL.md` and whose `enabled = true` flag keeps the entry valid under the current Codex config schema.

The adapter does not install custom `/b-*` wrapper files. Codex-native skill discovery is the supported invocation surface unless Codex later documents a first-class wrapper mechanism.

## Safety policy

The installer never overwrites an existing `~/.codex/AGENTS.md` without `--replace-memory`. Plain install syncs runtime-local skills, installs the shared reference snapshot under `~/.codex/b-agentic/references/`, and writes a managed block into `~/.codex/config.toml` for `mcp_servers.*` and `[[skills.config]]` entries, including the required `enabled = true` field for each managed skill. Existing user config outside that managed block is preserved.

Codex runtime install and maintainer validation/smoke checks require Python 3.11+ because TOML parsing uses the standard-library `tomllib` module.

## Global MCP Setup

Codex uses `config.toml` for configuration. MCP servers are configured under `[mcp_servers.<name>]` tables. The installer writes the recommended MCP block from `mcp.user.template.toml` into `~/.codex/config.toml`, alongside the skill-registration block. Existing user config is preserved outside the managed block, and uninstall removes only that block.

The default Serena entry runs `serena start-mcp-server --context ide --project-from-cwd` so Codex uses Serena's IDE context. By default, the managed template forwards the Context7, Brave Search, and Firecrawl API keys from the local shell environment; `--prompt-api-keys` writes literal user-scope values into `~/.codex/config.toml` instead.

| Server | Use |
|---|---|
| `serena` | Semantic code navigation/editing for local source work. |
| `context7` | Library/framework documentation lookup. |
| `brave-search` | Open-web and news discovery. |
| `firecrawl` | Known URL and document extraction. |
| `playwright` | Browser/DOM/visual/e2e evidence with isolated state. |

MCP safety rules:
- Prefer shell-environment forwarding by default, or write literal user-scope values into `~/.codex/config.toml` with `--prompt-api-keys`; never commit real API keys.
- Keep Playwright configured with `--isolated` unless a user explicitly opts into persistent browser state outside the tracked worktree.

## MCP readiness after install

- `playwright` is immediately available once Bun is on `PATH`; no extra suite-owned setup runs.
- `context7`, `brave-search`, and `firecrawl` entries are installed immediately, but live requests need user-scope API keys in `~/.codex/config.toml` or matching shell environment variables.
- `serena` entry is installed, but full symbol-aware value still depends on the user having Serena installed and completing first-use setup when needed. The installer never runs `serena setup`, `serena init`, or onboarding.

## Optional shell tooling recommendations

Install reports print a default shell-tooling tier for `rg`, `fd`/`fdfind`, `jq`, `tmux`, and `fzf`, plus a separate optional tier for `bat`/`batcat`, `yq`, `git-delta`, and `gh`.
The tier-2 block is aimed at readable file previews, YAML-heavy work, better git diffs, and GitHub-heavy workflows.
When the installer can detect Homebrew, `apt`, or `dnf`, it prints matching package commands for both tiers; otherwise it falls back to manual-install notes.
The installer never auto-installs these packages.

## Validator scope

`scripts/validate-skills.sh` is the stable wrapper over `tooling/validate/run.sh`, which discovers and runs `runtimes/<name>/scripts/validate.sh` for each registered adapter. Shared checks should fail on runtime-specific wording drift in shared skills and shared contract files, while runtime-owned checks enforce the Codex install layout documented here.

`scripts/smoke-install.sh` is the stable wrapper over `tests/smoke/install.sh`. The Codex adapter contributes its install coverage through `runtimes/codex-cli/tests/smoke.sh`.

For release-critical delivery changes, prefer `scripts/validate-skills.sh --release`; it keeps the same shared validation path but also runs installer smoke so launcher and install regressions fail the maintained entrypoint.
