# Antigravity CLI Runtime Layout

Adapter-owned layout for Antigravity CLI. Shared skills and contracts stay runtime-neutral; Antigravity-specific paths live here and in `runtimes/antigravity-cli/scripts/`.

## Install layout

- Kernel memory: `~/.gemini/GEMINI.md`
- Skills: `~/.gemini/antigravity-cli/skills/<skill-name>/SKILL.md`
- Skill support: `~/.gemini/antigravity-cli/skills/<skill-name>/reference.md`
- Suite metadata/backups/snapshots: `~/.gemini/antigravity-cli/b-agentic/`
- Shared references: `~/.gemini/antigravity-cli/b-agentic/references/contract/*.md`
- MCP template: `~/.gemini/antigravity-cli/b-agentic/templates/mcp_config.template.json`
- User-scope settings: `~/.gemini/antigravity-cli/settings.json`
- User-scope MCP config: `~/.gemini/antigravity-cli/mcp_config.json`
- Sensitive artifacts: `~/.gemini/antigravity-cli/b-agentic/<skill>/<run-id>/` or `/tmp/antigravity-cli/b-agentic/<skill>/<run-id>/`
- Temporary logs: `/tmp/antigravity-cli/b-agentic/<skill>/<slug>.log`

## Invocation

Antigravity CLI exposes installed b-agentic skills as native slash command entries from `~/.gemini/antigravity-cli/skills/`. The adapter does not install duplicate TOML wrappers into `~/.gemini/commands/`.

## Continuation and resume guarantees

This adapter does not provide native phase-to-phase automation. Workflows resume through operator-issued skill invocations plus the previous `[status]` or `[handoff]` block in context.

## Safety and MCP

The installer never overwrites `~/.gemini/GEMINI.md` without `--replace-memory`. Plain install syncs skills, shared references, kernel snapshot, settings, and MCP entries; uninstall removes only managed settings or managed MCP entries.

Antigravity uses `~/.gemini/antigravity-cli/mcp_config.json` under `mcpServers`. The installer merges `mcp_config.template.json`, preserves user entries, uses `serverUrl` for remote entries, and writes API keys only with `--prompt-api-keys`. Playwright stays `--isolated`; pnpm must be available for `pnpm dlx` entries.

## MCP readiness after install

- `playwright` is immediately available once `pnpm` is on `PATH`; no extra suite-owned setup runs.
- `context7`, `brave-search`, and `firecrawl` entries are installed immediately, but live requests need user-scope API keys in `~/.gemini/antigravity-cli/mcp_config.json` or matching shell environment variables.
- `serena` entry is installed, but full symbol-aware value still depends on the user having Serena installed and completing first-use setup when needed. The installer never runs `serena setup`, `serena init`, or onboarding.

## Optional shell tooling recommendations

Install reports print a default shell-tooling tier for `rg`, `fd`/`fdfind`, and `jq`, plus a separate optional tier for `bat`/`batcat`, `yq`, `git-delta`, `gh`, `tmux`, and `fzf`.
The tier-2 block is aimed at readable file previews, YAML-heavy work, better git diffs, GitHub-heavy workflows, long-running jobs, and non-interactive scoring.
When the installer can detect Homebrew, `apt`, or `dnf`, it prints matching package commands for both tiers; otherwise it falls back to manual-install notes.
The installer never auto-installs these packages.

## Validation

`scripts/validate-skills.sh` runs shared validation plus runtime validators. `scripts/smoke-install.sh` runs the shared smoke harness; Antigravity coverage lives in `runtimes/antigravity-cli/tests/smoke.sh`. Use `scripts/validate-skills.sh --release` for delivery-sensitive changes.
