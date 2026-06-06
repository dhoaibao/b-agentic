# Kimi Code CLI Runtime Layout

Adapter-owned layout for Kimi Code CLI. Shared skills and contracts stay runtime-neutral; Kimi-specific paths live here and in `runtimes/kimi-code-cli/scripts/`.

## Install layout

- Kernel memory: `~/.kimi-code/AGENTS.md`
- Skills: `~/.kimi-code/skills/<skill-name>/SKILL.md`
- Skill support: `~/.kimi-code/skills/<skill-name>/reference.md`
- Suite metadata/backups/snapshots: `~/.kimi-code/b-agentic/`
- Shared references: `~/.kimi-code/b-agentic/references/contract/*.md`
- MCP template: `~/.kimi-code/b-agentic/templates/mcp.user.template.json`
- User-scope MCP config: `~/.kimi-code/mcp.json`
- User-scope runtime config: `~/.kimi-code/config.toml`
- Sensitive artifacts: `~/.kimi-code/b-agentic/<skill>/<run-id>/` or `/tmp/kimi-code-cli/b-agentic/<skill>/<run-id>/`
- Temporary logs: `/tmp/kimi-code-cli/b-agentic/<skill>/<slug>.log`

Kimi install and smoke checks require Python 3.11+ for `tomllib`.

## Invocation

Kimi Code CLI discovers Agent Skills from `~/.kimi-code/skills/` and supports manual skill invocation with `/skill:<name>`. The adapter does not install `/b-*` command wrapper files for Kimi Code CLI.

## Continuation and resume guarantees

This adapter does not provide native phase-to-phase automation. Workflows resume through operator-issued skill invocations plus the previous `[status]` or `[handoff]` block in context.

## Safety, hooks, and MCP

The installer never overwrites `~/.kimi-code/AGENTS.md` without `--replace-memory`. Plain install syncs skills, shared references, an MCP template, `~/.kimi-code/mcp.json`, and a managed `~/.kimi-code/config.toml` block for b-agentic conformance hooks; user config outside the managed block is preserved.

Kimi hooks use `[[hooks]]` entries in `config.toml`. b-agentic installs a `Stop` hook that runs the conformance checker, but Kimi hooks are fail-open: hook errors, timeouts, and non-blocking events must not be treated as strict security enforcement. Kimi supports blocking for selected hook events and has permission/manual approval modes for high-risk operations; b-agentic reports pre-action enforcement as advisory-only for this adapter.

MCP uses `mcpServers` entries from `mcp.user.template.json`. Serena runs `serena start-mcp-server --context kimi-code-cli --project-from-cwd`. API keys can be written with `--prompt-api-keys` or maintained directly in `~/.kimi-code/mcp.json`. Playwright stays `--isolated`; pnpm must be available for `pnpm dlx` entries.

## MCP readiness after install

- `playwright` is available once `pnpm` is on `PATH`; no extra suite-owned setup runs.
- `context7`, `brave-search`, and `firecrawl` entries are installed immediately, but live requests need user-scope API keys in `~/.kimi-code/mcp.json` or another Kimi-supported auth path.
- `serena` entry is installed, but full symbol-aware value still depends on the user having Serena installed and completing first-use setup when needed. The installer never runs `serena setup`, `serena init`, or onboarding.
- Runtime conformance hooks report installed command paths, but they do not prove the external Serena server is installed or authenticated.
- Strict state can still be initialized for workflow bookkeeping, but Kimi pre-action enforcement remains advisory-only because hook failure defaults to allow.

## Shell tooling recommendations

Install reports print a core shell-tooling tier for `rg`, `fd`/`fdfind`, and `jq`.
When the installer can detect Homebrew, `apt`, or `dnf`, it prints a matching package command for that core tier; otherwise it falls back to manual-install notes.
The installer never auto-installs these packages.

## Validation

`scripts/validate-skills.sh` runs shared validation plus runtime validators. `scripts/smoke-install.sh` runs the shared smoke harness; Kimi coverage lives in `runtimes/kimi-code-cli/tests/smoke.sh`. Use `scripts/validate-skills.sh --release` for delivery-sensitive changes.
