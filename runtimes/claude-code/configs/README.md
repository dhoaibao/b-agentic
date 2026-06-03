# Claude Code Runtime Layout

Adapter-owned layout for Claude Code. Shared skills and contracts stay runtime-neutral; Claude-specific paths live here and in `runtimes/claude-code/scripts/`.

## Install layout

- Kernel memory: `~/.claude/CLAUDE.md`
- Skills: `~/.claude/skills/<skill-name>/SKILL.md`
- Skill support: `~/.claude/skills/<skill-name>/reference.md`
- Suite metadata/backups/snapshots: `~/.claude/b-agentic/`
- Shared references: `~/.claude/b-agentic/references/contract/*.md`
- Settings template: `~/.claude/b-agentic/templates/settings.template.json`
- MCP template: `~/.claude/b-agentic/templates/mcp.user.template.json`
- User-scope MCP config: `~/.claude.json`
- Sensitive artifacts: `~/.claude/b-agentic/<skill>/<run-id>/` or `/tmp/claude-code/b-agentic/<skill>/<run-id>/`
- Temporary logs: `/tmp/claude-code/b-agentic/<skill>/<slug>.log`

Project-local install, plugin packaging, hooks, and dynamic context injection are non-goals until validator and smoke coverage prove global parity.

## Invocation

Claude Code exposes each skill directory as `/b-*`; descriptions are the primary routing signal.

## Continuation and resume guarantees

This adapter does not provide native phase-to-phase automation. Workflows resume through operator-issued skill invocations plus the previous `[status]` or `[handoff]` block in context. Durable state follows `runtime.md` and `output.md` under the installed shared reference snapshot.

## Safety and merge policy

The installer never overwrites `~/.claude/CLAUDE.md` without `--replace-memory`. Plain install syncs skills, shared references, settings, and MCP entries. Existing settings and MCP config are backed up; unknown keys are preserved, arrays append without duplicates, objects merge recursively, and existing scalar values win conflicts.

## Global MCP Setup

Plain install merges `mcp.user.template.json` into `~/.claude.json` under `mcpServers`. The set is Serena, Context7, Brave Search, Firecrawl, and Playwright. Templates use API-key placeholders; interactive install may write user-scope key values. Brave Search, Firecrawl, and Playwright launch through `pnpm dlx`; Playwright stays `--isolated`. The installer does not run Context7, Serena, or browser setup commands.

## MCP readiness after install

- `playwright` is immediately available once `pnpm` is on `PATH`; no extra suite-owned setup runs.
- `context7`, `brave-search`, and `firecrawl` entries are installed immediately, but live requests need user-scope API keys in `~/.claude.json`.
- `serena` entry is installed, but full symbol-aware value still depends on the user having Serena installed and completing first-use setup when needed. The installer never runs `serena setup`, `serena init`, or onboarding.

## Optional shell tooling recommendations

Install reports print a default shell-tooling tier for `rg`, `fd`/`fdfind`, and `jq`, plus a separate optional tier for `bat`/`batcat`, `yq`, `git-delta`, `gh`, `tmux`, and `fzf`.
The tier-2 block is aimed at readable file previews, YAML-heavy work, better git diffs, GitHub-heavy workflows, long-running jobs, and non-interactive scoring.
When the installer can detect Homebrew, `apt`, or `dnf`, it prints matching package commands for both tiers; otherwise it falls back to manual-install notes.
The installer never auto-installs these packages.

## Validation

`scripts/validate-skills.sh` runs shared validation plus runtime validators. `scripts/smoke-install.sh` runs the shared smoke harness; Claude coverage lives in `runtimes/claude-code/tests/smoke.sh`. Use `scripts/validate-skills.sh --release` for delivery-sensitive changes.
