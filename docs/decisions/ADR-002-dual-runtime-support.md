# ADR-002: Dual-runtime support for Claude Code and OpenCode

- Status: Proposed
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
- Plugins: a default export `{ id, server, setup }` whose `server(ctx)` returns
  hooks (the shape the Herdr and Orca plugins on this machine use). A permission
  hook can force `ask`; no documented mechanism blocks a session from stopping.
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

Defaults taken: specialists on OpenCode omit `model` and inherit the session
model; the kernel is a marked block in `~/.config/opencode/AGENTS.md`.

Gap handling on OpenCode:

| Claude feature                 | OpenCode handling                                                                           |
| ------------------------------ | ------------------------------------------------------------------------------------------- |
| Read-only specialists          | `edit`, `subagent`, `question` deny and an MCP allowlist per agent, enforced by the runtime |
| Path guard                     | native `read`/`edit` secret denies plus the plugin refusing file tools                      |
| ClickUp guard (asks on images) | every ClickUp create or update asks                                                         |
| Approval-store tripwire        | shell `ask` rules for the approve command, the approvals file, and the state-dir variable   |
| Verify gate                    | not ported: a session cannot be blocked from stopping                                       |
| Codex gate                     | `shell` with `background: true` through the shared companion and approval logic             |

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
with the Claude settings layer). OpenCode support is pinned to v2.1.4, the
version checked, because the v1 to v2 schema break shows config keys can change
silently.

Accepted residual risks: the verify gate and the ClickUp image prompt are not
ported; whether a plain throw from the plugin's `tool.execute.before` blocks a
tool, how shell patterns match compound commands, and the model-facing shell
tool name were not exercised in a live OpenCode session and need a live check
before relying on them; the plugin and the native rules must both be present for
secret-path protection to be layered.

Unchanged non-goals: no custom permission engine, no third runtime, no Pi
revival, no per-project OpenCode installs, no live OpenCode or Codex sessions in
CI.

Evidence: [`install.sh`](../../install.sh),
[`tooling/install/opencode_install.py`](../../tooling/install/opencode_install.py),
[`tooling/generate/registry_sync.py`](../../tooling/generate/registry_sync.py),
[`references/runtimes.yaml`](../../references/runtimes.yaml), and
[`opencode/plugins/b-agentic.js`](../../opencode/plugins/b-agentic.js).
