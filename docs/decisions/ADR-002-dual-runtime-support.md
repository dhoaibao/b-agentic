# ADR-002: Dual-runtime support for Claude Code and OpenCode

- Status: Accepted
- Date: 2026-10-23
- Supersedes: ADR-001 (product boundary and the second-runtime non-goal)

## Context

ADR-001 fixes b-agentic to one runtime, Claude Code. The user now wants Claude
Code and OpenCode supported side by side from one checkout. The superseded areas
are the "supports one runtime" statement, the `~/.claude`-only product boundary,
and the "does not maintain a second runtime" non-goal.

Prior art: the repository shipped a native OpenCode v2 runtime until the Pi
migration (`fdae54f8` hard cut, `3197ddfd` config lifecycle; deleted in
`5f709b28`). A machine can still hold that install: a manifest without a
`schema` key and with `suite: b-agentic`, `runtime: opencode` under
`~/.config/opencode/b-agentic/`, using retired skill names (`b-diagram`,
`b-pr-summary`, `b-reviewer`) and a whole-file `AGENTS.md`.

OpenCode facts below were verified against the v2 docs
(`opencode.ai/v2/docs/*`), the locally installed v2.1.4 binary and its debug
commands, and plugins already running on that install; the public
`opencode.ai/docs/*` pages describe v1 and conflict with them.

- Config: `~/.config/opencode/opencode.json(c)`, layers merge. MCP servers sit
  under `mcp.servers.<name>` with `environment` and `disabled`; with
  `codemode: false` tools are named `<server>_<tool>`.
- Rules: global `~/.config/opencode/AGENTS.md` loads. v2 does not read
  `CLAUDE.md`, but it does read `~/.claude/skills` for compatibility; for the same
  skill ID, `~/.config/opencode/skills` outranks it, so one install does not load
  two copies. The compatibility switch (`OPENCODE_DISABLE_CLAUDE_CODE_SKILLS`) is
  an environment variable only and is not relied on.
- Permissions: ordered `permissions: [{action, resource, effect}]`, last match
  wins, no match asks; actions are `read`, `edit`, `shell`, `subagent`, `skill`,
  `question`, `<server>_<tool>`, with `*` wildcards. v1 keys (`bash`, `task`) may
  silently not apply, and a `permission` map is refused by the installer.
- Plugins: V2 reads the default export's `id` and `setup(ctx)` and ignores V1's
  `server()` (`opencode.ai/v2/docs/build/plugins`, `@opencode/plugin` 2.1.4).
  `setup` registers hooks with `await ctx.tool.hook("execute.before", callback)`;
  the callback receives `{ tool, input, ... }` and a throw fails that call alone
  with the thrown message. A permission hook can force `ask`; no documented
  mechanism blocks a session from stopping.
- Matching: rule resources are whole-string wildcards where `*` spans `/`, so
  `**/.env` does not match a project-root `.env`, while `*.env` matches both.
  `external_directory` is allowed by default and asks on reads and writes alike
  once a rule says so. Any `<server>_<tool>` action, including servers the user
  added, inherits the base `* -> allow` unless a rule says otherwise.
- Shell: 2 minute foreground default, `background: true` available. Subagent
  fallback is `general`. Skills are not slash commands.

## Decision

Adopt runtime adapters: one set of canonical sources (`skills/registry.yaml`,
`skills/*/prompt.md`, `references/`) rendered per runtime through
`references/runtimes.yaml` (an ordered glossary and MCP tool-name format applied
to the canonical Claude wording; the claude runtime is the identity), one
installer per runtime sharing the Claude installer's safety helpers, and one
set of guard logic behind the Claude hooks and the OpenCode plugin.
Canonical sources are not tokenised because the installers and validators read
them directly. Claude output is byte-identical across the change.

Decisions taken by the user:

- Safety: staged release. OpenCode ships with documented gaps; the safety
  plugin follows immediately (it is part of the same change).
- Codex review gate on OpenCode: reuse the `codex-plugin-cc` companion from
  `~/.claude/plugins`. This couples the runtimes: OpenCode review needs the
  Claude plugin installed, and the gate otherwise reports unavailable. The
  approval store lives beside the installed hooks, so each runtime keeps its own.
- Skills: OpenCode-rendered skills in `~/.config/opencode/skills`. Duplicate
  loading is avoided by precedence rather than by a switch.
- Installer: `--runtime=claude` stays the default; `opencode` and `both` are
  explicit. Uninstalling one runtime leaves the other byte-identical.

The kernel is a marked block in `~/.config/opencode/AGENTS.md`. Model selection
was refined on 2026-10-24: the registry's optional `opencode_model` field pins
OpenCode specialists independently of Claude Code's `model` alias. OpenCode
initially defaulted to `openai/gpt-6.1-sol#xhigh` for planner, debugger, and
auditor, and `openai/gpt-6-luna#high` for researcher. On 2026-10-31, after a
benchmark review (Artificial Analysis, vendor pages), the defaults became
`anthropic/claude-opus-5-5#xhigh` for planner,
`anthropic/claude-sonnet-5-5#xhigh` for debugger,
`anthropic/claude-sonnet-5-5#medium` for researcher, and
`openai/gpt-6.1-sol#xhigh` for auditor, which keeps the audit on a different model
family than the Claude main session. Later that day the three Claude specialists
moved from the `anthropic` provider, which needs a separate API key and failed
with `invalid x-api-key`, to OpenCode's `claude-agent` provider using the
`opus` and `sonnet` aliases with the same variants. The same day the registry gained an optional
`effort` field for Claude Code subagent frontmatter. Omitting `opencode_model`
retains session model inheritance. The variant suffixes select variants documented
in the [OpenCode V2 agent guide](https://opencode.ai/v2/docs/agents#model).

Gap handling on OpenCode:

| Claude feature                 | OpenCode handling                                                                                                                                                                                                 |
| ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Read-only specialists          | `edit`, `subagent`, `question` deny, `*_*` deny for every other `<server>_<tool>` (user-added servers included), `execute` and `browser` deny, then an MCP allowlist per agent; external directories stay allowed |
| Path guard                     | native `read`/`edit` secret denies (`*.env`, `*.pem`, `*credentials.*`, ...) plus the plugin refusing file tools                                                                                                  |
| Outside-project writes         | the main session asks on `external_directory` (reads included, as OpenCode cannot tell them apart), except `~/.config/opencode`, `~/.claude`, `~/.local/share/opencode`, `/tmp/opencode`                          |
| Unclassified MCP tools         | `*_*` asks in the main session; managed servers then ask by default and follow their class                                                                                                                        |
| ClickUp guard (asks on images) | every ClickUp create or update asks                                                                                                                                                                               |
| Approval-store tripwire        | shell `ask` rules for the approve command, the approvals file, and the state-dir variable                                                                                                                         |
| Verify gate                    | not ported: a session cannot be blocked from stopping                                                                                                                                                             |
| Codex gate                     | `shell` with `background: true` through the shared companion and approval logic                                                                                                                                   |

Invariants: manifest-only ownership, refusal before the first write, user keys
preserved on merge, managed permission rules always the final block,
`opencode.jsonc` refused until a comment-preserving merge exists, `~/.pi` never
written, `~/.claude` untouched during an OpenCode-only run and the reverse. A
manifest from the retired OpenCode install is refused unless `--migrate-legacy`
is passed, which backs up and removes only the paths that manifest names.

## Consequences

b-agentic maintains two runtimes. The kernel size limit applies to each
runtime's rendered kernel, and the generator validates the OpenCode outputs
(read-only specialists, an asking default per managed MCP server, rule parity
with the Claude settings layer). OpenCode support is not version-pinned and
the installer does not check the OpenCode version; the facts above were checked
against v2.1.4, and the v1 to v2 schema break shows config keys can change
silently, so re-verify them after an OpenCode upgrade.

Accepted residual risks: the verify gate and the ClickUp image prompt are not
ported; the plugin's `execute.before` throw, how shell patterns match compound
commands, and the model-facing tool names were verified against the published
2.1.4 packages and a recording context rather than a live OpenCode session, and
need a live check before relying on them; the plugin and the native rules must
both be present for secret-path protection to be layered. Because `*_*` also
matches `opencode_*` actions, only `opencode_models`,
`opencode_list_mcp_resources`, `opencode_worktree_list`, and
`opencode_session_rename` are re-allowed; other `opencode_*` actions ask when
OpenCode raises them. Whether Code Mode's `opencode` namespace (session move,
worktree create) and the desktop `browser` namespace raise any permission action
is unverified on 2.2.5, so the main session may run them without asking.
Specialists therefore also deny `execute` and `browser` outright.

Unchanged non-goals: no custom permission engine, no third runtime, no Pi
revival, no per-project OpenCode installs, no live OpenCode or Codex sessions in
CI.

Evidence: [`install.sh`](../../install.sh),
[`tooling/install/opencode_install.py`](../../tooling/install/opencode_install.py),
[`tooling/generate/registry_sync.py`](../../tooling/generate/registry_sync.py),
[`references/runtimes.yaml`](../../references/runtimes.yaml), and
[`opencode/plugins/b-agentic.js`](../../opencode/plugins/b-agentic.js).
