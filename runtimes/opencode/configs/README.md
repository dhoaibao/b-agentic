# OpenCode Runtime Layout

Adapter-owned layout for OpenCode. Shared skills and contracts stay runtime-neutral; OpenCode-specific paths live here and in `runtimes/opencode/scripts/`.

## Install layout

- Kernel memory: `~/.config/opencode/AGENTS.md`
- Skills: `~/.config/opencode/skills/<skill-name>/SKILL.md`
- Optional subagent profiles: `~/.config/opencode/agents/<agent-name>.md`
- Command wrappers: `~/.config/opencode/commands/<command-name>.md`
- Skill support: `~/.config/opencode/skills/<skill-name>/reference.md`
- Suite metadata/backups/snapshots: `~/.config/opencode/b-agentic/`
- Shared references: `~/.config/opencode/b-agentic/references/contract/*.md`
- MCP template: `~/.config/opencode/b-agentic/templates/mcp.user.template.json`
- Sensitive artifacts: `~/.config/opencode/b-agentic/<skill>/<run-id>/` or `/tmp/opencode/b-agentic/<skill>/<run-id>/`
- Temporary logs: `/tmp/opencode/b-agentic/<skill>/<slug>.log`

## Invocation

OpenCode exposes installed skills through its native skill tool. Thin `/b-*` wrappers are installed under `~/.config/opencode/commands/` and delegate to the matching skill; colliding user command files are preserved.

## Continuation and resume guarantees

This adapter does not provide native phase-to-phase automation. Workflows resume through operator-issued skill invocations plus the previous `[status]` or `[handoff]` block in context. Wrappers preserve invocation ergonomics only.

## Safety and MCP

The installer never overwrites `~/.config/opencode/AGENTS.md` without `--replace-memory`. Plain install syncs skills, optional subagent profiles, shared references, kernel, wrappers, and MCP config; uninstall removes only managed wrappers and profiles that still match the managed snapshot.

Optional b-agentic subagent profiles are read-only or ask-gated helpers for exploration, research, review, and verification. User-owned or modified profiles are preserved.

OpenCode uses `~/.config/opencode/opencode.json`; MCP servers live under the `mcp` key. The installer merges `mcp.user.template.json`, preserves user entries, and removes only b-agentic entries on uninstall. The Serena entry uses `--context ide`; API keys stay as `{env:...}` placeholders unless `--prompt-api-keys` writes user-scope values. Playwright stays `--isolated`; pnpm must be available for `pnpm dlx` entries.

## MCP readiness after install

- `playwright` is immediately available once `pnpm` is on `PATH`; no extra suite-owned setup runs.
- `context7`, `brave-search`, and `firecrawl` entries are installed immediately, but live requests need user-scope API keys in `~/.config/opencode/opencode.json`.
- `serena` entry is installed, but full symbol-aware value still depends on the user having Serena installed and completing first-use setup when needed. The installer never runs `serena setup`, `serena init`, or onboarding.
- Runtime conformance hooks warn by default where adapter hooks are active. Set `B_AGENTIC_HOOK_STRICT=1` in the OpenCode environment to make invalid status/handoff output block.

## Shell tooling recommendations

Install reports print a core shell-tooling tier for `rg`, `fd`/`fdfind`, and `jq`.
When the installer can detect Homebrew, `apt`, or `dnf`, it prints a matching package command for that core tier; otherwise it falls back to manual-install notes.
The installer never auto-installs these packages.

## Validation

`scripts/validate-skills.sh` runs shared validation plus runtime validators. `scripts/smoke-install.sh` runs the shared smoke harness; OpenCode coverage lives in `runtimes/opencode/tests/smoke.sh`. Use `scripts/validate-skills.sh --release` for delivery-sensitive changes.
