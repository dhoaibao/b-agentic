# Claude Code configuration ownership

`mcp.base.json` is the canonical checked-in MCP template;
`settings.template.json` is generated from `references/mcp_operations.yaml` and
the hook list in `tooling/generate/registry_sync.py`. Edit sources and run
`python3 tooling/generate/registry_sync.py`, never the generated file.

| Source | Installed path (default `~/.claude`) | Owner |
| --- | --- | --- |
| `settings.template.json` | `settings.json` | Claude Code; only missing `permissions.allow/ask/deny` rules and hook commands are added, each recorded in the manifest; `statusLine` is set only when none is configured (or it is still the recorded one), so your own status line is kept and reported |
| `mcp.base.json` | `~/.claude.json` (`mcpServers`) | Claude Code; nine servers, no stored credentials (`${VAR}` references); `excalidraw`, `drawio`, and `notion` install only when selected (`--with=ID` or the installer checkbox) |
| none for DataGrip | same file | The DataGrip MCP entry is user and IDE managed (Auto-Configure in DataGrip); b-agentic ships only its `mcp__datagrip__*` permission rules; the read-only `allow` rules install only when the optional `datagrip` component is selected, while the `ask` rules always ship |
| `agents/b-*.md` | `agents/b-*.md` | Five generated read-only specialist profiles (tool allowlists, no editing tools), including `b-reviewer`, and the `b-worker` writer profile for approved `b-flow` plan steps |
| `../hooks/*.mjs` | `b-agentic/hooks/` | `b-path-guard`, `b-codex-guard` (a fail-open Bash tripwire and the secret preflight for the Codex gate), `b-alexandria-guard` (a fail-closed `PreToolUse` hook on `firecrawl_scrape` that asks when its `alexandria` argument would run billed provider lookups), `b-verify-gate`, `b-spec-context` (a fail-open `SessionStart` hook on `compact` that points back at approved `docs/specs/*.md`), `b-run-context` (a fail-open `SessionStart` hook that points at the active `b-flow` run id and phase) |
| `../bin/*.mjs`, `../bin/*.py`, `../bin/b-*` wrappers | `b-agentic/bin/` | `b-state`, `b-run`, `b-snapshot`, `b-codex-review`, and `b-codex-guard` (short `sh` wrappers that skills call, installed owner-executable with the absolute Bun path, ADR-028), `b-candidate-snapshot` (the candidate fingerprint used by the review gate), `b-codex-review` (the enforced Codex gate wrapper), `b-codex-verdict` (its verdict mapper), `b-state` (the `b-flow` run-state helper; main session only, fails closed), `b_run.py` (the single writer and validator of the run's markdown artifacts, schemas in `b-agentic/references/artifacts.yaml`), `b-statusline` (the status line: model and effort, repo and branch, context, session cost, cache hit ratio, 5-hour and weekly limits; read-only) |
| `../../skills/*/SKILL.md` | `skills/b-*/SKILL.md` | Generated skills, also the `/b-*` commands |
| `../../references/kernel.template.md` | block in `CLAUDE.md` | Generated kernel between `<!-- b-agentic:start -->` and `<!-- b-agentic:end -->` |

The installer records everything it owns in `b-agentic/install.json`, backs up
each user file it changes under `b-agentic/backups/`, keeps files you modified,
refuses a symlinked managed directory or manifest, writes through (never replaces)
a symlinked config file, and never touches `~/.config/opencode` or `~/.pi` (retired runtime directories; see
[ADR-020](../../docs/decisions/ADR-020-claude-code-only-again.md)). A hook entry or file an
earlier release recorded and this one no longer ships is retired on upgrade:
`settings.json` stops naming a script before the script is deleted, a hook you
edited is kept and reported, and its script is kept until that entry is gone.
State written at run time lives in `b-agentic/`. An older install wrote
`codex-approved-repos.json`, a per-repository approval for sending a repository
to Codex (OpenAI); nothing reads it since
[ADR-021](../../docs/decisions/ADR-021-codex-gate-without-repo-approval.md), and
an upgrade or uninstall leaves that user data alone.

Servers use Claude Code's standard shape (`type` `stdio` or `http`). Credentials
are environment references; expansion of those references in the user-scope MCP
file follows Claude Code's documented behavior and is not exercised by this
repository's checks. Restart Claude Code after changing MCP configuration.
