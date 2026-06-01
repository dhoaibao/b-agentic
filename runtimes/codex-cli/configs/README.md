# Codex CLI Runtime Layout

Adapter-owned layout for Codex CLI. Shared skills and contracts stay runtime-neutral; Codex-specific paths live here and in `runtimes/codex-cli/scripts/`.

## Install layout

- Kernel memory: `~/.codex/AGENTS.md`
- Skills: `~/.codex/skills/<skill-name>/SKILL.md`
- Skill support: `~/.codex/skills/<skill-name>/reference.md`
- Suite metadata/backups/snapshots: `~/.codex/b-agentic/`
- Shared references: `~/.codex/b-agentic/references/contract/*.md`
- MCP template: `~/.codex/b-agentic/templates/mcp.user.template.toml`
- User-scope config: `~/.codex/config.toml`
- Sensitive artifacts: `~/.codex/b-agentic/<skill>/<run-id>/` or `/tmp/codex-cli/b-agentic/<skill>/<run-id>/`
- Temporary logs: `/tmp/codex-cli/b-agentic/<skill>/<slug>.log`

Codex install and smoke checks require Python 3.11+ for `tomllib`.

## Invocation

Codex exposes installed skills through `/skills`, `$skill-name`, and implicit matching. Skills are registered through `[[skills.config]]` entries with `path` and `enabled = true`; the adapter does not install `/b-*` wrapper files.

## Continuation and resume guarantees

This adapter does not provide native phase-to-phase automation. Workflows resume through operator-issued skill invocations plus the previous `[status]` or `[handoff]` block in context.

## Safety, hooks, and MCP

The installer never overwrites `~/.codex/AGENTS.md` without `--replace-memory`. Plain install syncs skills, shared references, and a managed `~/.codex/config.toml` block for `mcp_servers.*`, hooks, and `skills.config`; user config outside the managed block is preserved.

Managed hooks enable `[features].hooks = true`, then add SessionStart/PreToolUse/Stop Serena hooks. Existing user hooks outside the block remain authoritative. Codex may ask users to trust new hooks through `/hooks`; b-agentic does not bypass that step.

MCP uses `[mcp_servers.<name>]` tables from `mcp.user.template.toml`. Serena runs `serena start-mcp-server --context codex --project-from-cwd`. API keys default to shell forwarding unless `--prompt-api-keys` writes user-scope values. Playwright stays `--isolated`; pnpm must be available for `pnpm dlx` entries.

## MCP readiness after install

- `playwright` is immediately available once `pnpm` is on `PATH`; no extra suite-owned setup runs.
- `context7`, `brave-search`, and `firecrawl` entries are installed immediately, but live requests need user-scope API keys in `~/.codex/config.toml` or matching shell environment variables.
- `serena` entry is installed, but full symbol-aware value still depends on the user having Serena installed and completing first-use setup when needed. The installer never runs `serena setup`, `serena init`, or onboarding.

## Optional shell tooling recommendations

Install reports print a default shell-tooling tier for `rg`, `fd`/`fdfind`, and `jq`, plus a separate optional tier for `bat`/`batcat`, `yq`, `git-delta`, `gh`, `tmux`, and `fzf`.
The tier-2 block is aimed at readable file previews, YAML-heavy work, better git diffs, GitHub-heavy workflows, long-running jobs, and non-interactive scoring.
When the installer can detect Homebrew, `apt`, or `dnf`, it prints matching package commands for both tiers; otherwise it falls back to manual-install notes.
The installer never auto-installs these packages.

## Validation

`scripts/validate-skills.sh` runs shared validation plus runtime validators. `scripts/smoke-install.sh` runs the shared smoke harness; Codex coverage lives in `runtimes/codex-cli/tests/smoke.sh`. Use `scripts/validate-skills.sh --release` for delivery-sensitive changes.
