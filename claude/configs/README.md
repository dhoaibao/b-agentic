# Claude Code configuration ownership

`mcp.base.json` and `mcp.clickup.json` are canonical checked-in templates;
`settings.template.json` is generated from `references/mcp_operations.yaml` and
the hook list in `tooling/generate/registry_sync.py`. Edit sources and run
`python3 tooling/generate/registry_sync.py`, never the generated file.

| Source | Installed path (default `~/.claude`) | Owner |
| --- | --- | --- |
| `settings.template.json` | `settings.json` | Claude Code; only missing `permissions.allow/ask/deny` rules and hook commands are added, each recorded in the manifest |
| `mcp.base.json` | `~/.claude.json` (`mcpServers`) | Claude Code; ten servers, no stored credentials (`${VAR}` references) |
| `mcp.clickup.json` | same file | Optional ClickUp stdio server (`bunx`, pinned), added only after install opt-in |
| `agents/b-*.md` | `agents/b-*.md` | Four generated read-only specialist profiles (tool allowlists, no editing tools) |
| `../hooks/*.mjs` | `b-agentic/hooks/` | `b-path-guard`, `b-codex-guard`, `b-verify-gate` |
| `../bin/*.mjs` | `b-agentic/bin/` | `b-candidate-snapshot`, `b-codex-review` (the enforced gate), `b-codex-verdict` |
| `../../skills/*/SKILL.md` | `skills/b-*/SKILL.md` | Generated skills, also the `/b-*` commands |
| `../../references/kernel.template.md` | block in `CLAUDE.md` | Generated kernel between `<!-- b-agentic:start -->` and `<!-- b-agentic:end -->` |

The installer records everything it owns in `b-agentic/install.json`, backs up
each user file it changes under `b-agentic/backups/`, keeps files you modified,
refuses a symlinked managed directory or manifest, writes through (never replaces)
a symlinked config file, and never writes under `~/.pi`. State written at run time
lives in `b-agentic/`: `codex-approved-repos.json` (the standing per-repository
approval to send code to Codex) is user data and is not removed by a reinstall.

Servers use Claude Code's standard shape (`type` `stdio` or `http`). Credentials
are environment references; expansion of those references in the user-scope MCP
file follows Claude Code's documented behavior and is not exercised by this
repository's checks. Restart Claude Code after changing MCP configuration.
