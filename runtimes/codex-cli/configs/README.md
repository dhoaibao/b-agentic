# Codex CLI Runtime Layout

Adapter-owned layout for Codex CLI. Shared skills and contracts stay runtime-neutral; Codex-specific paths live here and in `runtimes/codex-cli/scripts/`.

## Install layout

- Kernel memory: `~/.codex/AGENTS.md`
- Skills: `~/.codex/skills/<skill-name>/SKILL.md`
- Optional subagent profiles: `~/.codex/agents/<agent-name>.toml`
- Command governance rules: `~/.codex/rules/b-agentic.rules`
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

The installer never overwrites `~/.codex/AGENTS.md` without `--replace-memory`. Plain install syncs skills, optional subagent profiles, command governance rules, shared references, and a managed `~/.codex/config.toml` block for `mcp_servers.*`, hooks, and `skills.config`; user config outside the managed block is preserved.

Managed hooks enable `[features].hooks = true` only when the user has no existing `[features]` table, then add SessionStart/PreToolUse/Stop Serena hooks and b-agentic conformance hooks where Codex exposes compatible hook payloads. If existing user config sets `hooks = false`, install reports `hooks: disabled` and preserves that choice; run `/hooks` or set hooks true to activate Serena reminders and b-agentic hooks. Existing user hooks outside the block remain authoritative. Codex may ask users to trust new hooks through `/hooks`; b-agentic does not bypass that step. Runtime conformance hooks warn by default; use installer `--strict` or set `B_AGENTIC_STRICT=1` to request blocking. Surfaces without pre-action payloads are advisory-only.

Optional b-agentic subagent profiles are read-only helpers for exploration, research, review, and verification. User-owned or modified profiles are preserved.

Managed `b-agentic.rules` blocks force-push/reset/clean commands and prompts for dependency installs that request to run outside the sandbox. Existing user rules remain authoritative and modified managed rules are preserved on update or uninstall.

MCP uses `[mcp_servers.<name>]` tables from `mcp.user.template.toml`. Serena runs `serena start-mcp-server --context codex --project-from-cwd`. API keys default to shell forwarding unless `--prompt-api-keys` writes user-scope values. Playwright stays `--isolated`; pnpm must be available for `pnpm dlx` entries.

## MCP readiness after install

- `playwright` is immediately available once `pnpm` is on `PATH`; no extra suite-owned setup runs.
- `context7`, `brave-search`, and `firecrawl` entries are installed immediately, but live requests need user-scope API keys in `~/.codex/config.toml` or matching shell environment variables.
- `serena` entry is installed, but full symbol-aware value still depends on the user having Serena installed and completing first-use setup when needed. The installer never runs `serena setup`, `serena init`, or onboarding.
- Runtime conformance hooks report installed command paths, but they do not prove the external Serena server is installed or authenticated.

## Shell tooling recommendations

Install reports print a core shell-tooling tier for `rg`, `fd`/`fdfind`, and `jq`.
When the installer can detect Homebrew, `apt`, or `dnf`, it prints a matching package command for that core tier; otherwise it falls back to manual-install notes.
The installer never auto-installs these packages.

## Validation

`scripts/validate-skills.sh` runs shared validation plus runtime validators. `scripts/smoke-install.sh` runs the shared smoke harness; Codex coverage lives in `runtimes/codex-cli/tests/smoke.sh`. Use `scripts/validate-skills.sh --release` for delivery-sensitive changes.
