# ADR-019: OpenCode as the second runtime, replacing Pi

- Status: Superseded
- Date: 2026-11-15
- Supersedes: ADR-011 (Pi as a second runtime); reverses the OpenCode removal in ADR-008
- Superseded by: [ADR-020](ADR-020-claude-code-only-again.md) (Claude Code only again). The OpenCode tree this record describes was last present at commit `f80281b7`.

## Context

[ADR-011](ADR-011-pi-second-runtime.md) added Pi as an opt-in second runtime after
[ADR-008](ADR-008-claude-code-only.md) removed OpenCode. The user now wants OpenCode
(2.3.0, a rewrite of the version removed in ADR-008) in Pi's place, with the same main
features as Claude Code. OpenCode runs everything natively that Pi needed three
third-party packages for: permissions, subagents, the question tool, todo, skills, MCP,
custom commands, and a plugin API. Claude Code stays the default runtime and its
generated output stays byte-identical to `ba7bc2db`.

The V1 OpenCode design last present at `56282959^` (plugin, permission template,
agent files, installer) does not run on 2.3.0: config keys were renamed, permissions
became an ordered list, and the plugin API changed. It was read for reference only.

## Decision

The user decided each item below on 2026-11-15.

- OpenCode is the opt-in second runtime. Pi is removed entirely: `pi/`, its installer,
  guard extension and tests are deleted, and `install.sh --runtime=pi` is refused with a
  pointer to this ADR. A live `~/.pi/agent` install is left alone; uninstall it from
  commit `ba7bc2db`.
- The ADR-011 render pipeline stays: one set of canonical sources, `<!-- runtime: NAME -->`
  marker lines (now accepting a comma-separated runtime list), an ordered literal glossary,
  `kernel_overrides`, and forbidden Claude tokens, with the `opencode` entry of
  `references/runtimes.yaml` replacing `pi`. Claude output is the identity render.
- OpenCode output is committed under `opencode/`: `skills/`, `commands/` (thin `/b-<name>`
  files that point at the skill), `agents/` (five read-only specialists and `b-worker`),
  the OpenCode kernel, `configs/` (permissions and MCP template), and the hand-written plugin
  the plugin file under that tree.
- Permissions use OpenCode's native ordered `permissions` list, generated from
  `references/mcp_operations.yaml` and the same shell and path rules as the Claude settings
  template (last match wins, so deny rules come last). A parity check compares both rule
  by rule. Read-only specialists deny `edit`, `subagent`, `question` and every non-allowed
  MCP tool; `b-worker` allows `edit` and denies `subagent`, `question` and mutating MCP.
- One local plugin file reuses the `claude/hooks` modules: a path guard on
  `execute.before` that fails closed (a missing hook module or any error throws), a
  Codex shell guard (the Claude Code Bash hook's `judgeCommand`: a direct companion call
  needs the guard's approval, and recording or revoking an approval is refused because a
  plugin hook cannot show Claude Code's native ask), a verify reminder that sends one extra
  turn on `session.execution.succeeded`, and run and spec context injection. A directory `grep` is refused when ripgrep, listed with OpenCode's own flags, would search a likely-secret file or cannot be listed (OpenCode authorizes `grep` on the pattern only). File tools may not write the approval store under any name, and native `read` and `edit`
  denies, native shell asks for the approval commands, and a native `edit` deny for the store stay as a second layer
  because a plugin that fails to load leaves the tools unguarded.
- The review gate reuses the Codex companion through the `b-codex-review` wrapper, as on
  Claude Code ([ADR-007](ADR-007-codex-first-review-gate.md)); `b-reviewer` runs only when
  the wrapper exits 4. This reverses the Pi choice (reviewer only) and couples OpenCode to
  the Codex plugin that the Claude Code install provides.
- `b-worker` is ported. OpenCode subagents always run in the background and notify the
  parent when the child goes idle, so the `b-flow` worker wait is worded for OpenCode as
  "end the turn; the idle notification is the wait". Parallel worker worktrees are not
  ported in this change.
- The run-state lock owner on OpenCode is `OPENCODE_SESSION_ID`, which the shell tool sets
  (see S4 below; it is undocumented, so a probe guards it).
- The installer (the OpenCode installer, `install.sh --runtime=opencode|both`;
  default stays `claude`) writes only under `~/.config/opencode` and records what it owns
  in a manifest there. A schema-1 manifest from the earlier OpenCode release is adopted and
  upgraded: recorded `tablepro` and Codex entries are retired, the Codex approval file is
  left in place (the OpenCode review wrapper still reads it), and user plugins and rules are preserved. It never runs
  `opencode`, npm, or any vendor installer. A pending permission intent records how many
  identical rules the file held before the write, so an interrupted run never makes a rule
  the user already had look like ours, and the count each owned rule is left at is written to the
  manifest before the config, so a retried uninstall or upgrade never removes a rule twice.
- The status line is not ported. Todo is native (`experimental.todo`).

### Gap handling on OpenCode

| Claude Code feature     | OpenCode handling                                                                                                | Source              |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------- | ------------------- |
| Kernel                  | Marked block in `~/.config/opencode/AGENTS.md` (V2 does not read `CLAUDE.md`)                                    | docs `instructions` |
| Skills                  | `~/.config/opencode/skills`, which outranks `~/.claude/skills` for the same id                                   | docs `skills`       |
| `/b-<name>` commands    | `~/.config/opencode/commands/*.md` with `$ARGUMENTS`                                                             | docs `commands`     |
| Read-only specialists   | `agents/*.md` with `mode: subagent` and a deny-first `permissions` list                                          | docs `agents`       |
| `b-worker`              | Subagent allowed `edit`; background, idle notification replaces the blocking wait                                | docs `agents`       |
| Permission rules        | Ordered `permissions` list, last match wins, generated and parity-checked                                        | docs `permissions`  |
| Path guard hook         | Plugin `execute.before` throw; also fires for subagent sessions; plus native denies                              | probe S1, S2        |
| Verify gate (Stop hook) | `session.execution.succeeded` plus `ctx.session.prompt`, once per session                                        | probe S5            |
| Spec and run context    | Plugin context injection through the session `context` hook                                                      | docs `server`       |
| `AskUserQuestion`       | Native `question` tool                                                                                           | docs `tools`        |
| Run-state lock owner    | `OPENCODE_SESSION_ID` in the shell tool environment                                                              | probe S4            |
| MCP and OAuth           | `mcp.servers.<name>`, `{env:VAR}`, `codemode: false` for direct tool names; `opencode mcp auth` left to the user | docs `mcp-servers`  |
| Review gate             | `b-codex-review` through a shell allow rule; `b-reviewer` on exit 4                                              | docs `permissions`  |
| Subagent profile check  | `permissions` list of the agent file, checked by `claude/bin/b_run.py worker-profile`                            | docs `agents`       |
| Todo                    | Native `todowrite` behind `experimental.todo`                                                                    | docs `config`       |
| Status line             | Not ported (TUI plugin API not evaluated)                                                                        | docs `plugins/cli`  |

### Probe results

Run on 2026-11-15 against OpenCode 2.3.0 with `opencode run --standalone`, a scratch HOME,
a mock OpenAI-compatible model, and a probe plugin.

| ID  | Check                                            | Result                                                                                                                                                  |
| --- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| S1  | A throwing `execute.before` hook blocks the tool | Live: the read failed with the thrown message and the tool did not run                                                                                  |
| S2  | Hook event fields and the file-tool input key    | Live: `{tool, sessionID, agent, input}`; `read`, `write` take `path`, `shell` takes `command`                                                           |
| S3  | The hook fires in subagent sessions              | Live: a `general` child's `read` reached the hook with its own `sessionID` and `agent`                                                                  |
| S4  | Session id in the shell tool environment         | Live: `OPENCODE_SESSION_ID` and `OPENCODE=1` are set; `AI_AGENT` is only set when absent, so it is not an identity                                      |
| S5  | One extra turn after a run settles               | Live: `ctx.session.prompt` from `session.execution.succeeded` sent one follow-up; `session.idle` did not fire in run mode                               |
| S6  | Event API shape                                  | Live: `ctx.event.subscribe()` is an async iterable of `{type, data: {sessionID}}`                                                                       |
| S7  | `ctx.shell.hook("create.before")` event          | Live: carries `command, cwd, timeout, shell, env` and no session id                                                                                     |
| S8  | Custom provider for an offline probe             | Live: `package: "@opencode/ai/providers/openai-compatible"` with `models` works                                                                         |
| S9  | MCP tool action names                            | Binary 2.3.0: `<server>_<tool>` with only characters outside letters, digits, `_` and `-` replaced by `_`; hyphens stay (`context7_resolve-library-id`) |

Not verified live: background subagent behavior of `b-worker`, child `session.execution`
payloads, compaction survival of context entries, `execute.before` for nested MCP calls in
Code Mode, a plugin load failure leaving OpenCode running without the guard, and
`opencode.jsonc` merging.

## Consequences

- Two runtimes to maintain; each rendered kernel stays within its size limit.
- Removing Pi drops Node as a runtime for the plugin and hooks (Bun runs them), but Node is still
  needed on both runtimes: the Codex review wrapper starts the Codex plugin's script with it, so both
  installers list `node` as a prerequisite.
- OpenCode config keys have already changed once (V1 to V2); pin the verified version here
  and re-run the probe after an upgrade.
- If the plugin fails to load the guard is absent, so native `deny` rules for secret paths
  and `.b-agentic` writes are a required second layer.
- A shell tool call can reach the run artifact CLI, as on Claude Code; `OPENCODE_SESSION_ID`
  is read from an undocumented variable, so the state probe asserts it.
- Unchanged non-goals: no custom permission engine, no per-project installs, no live
  OpenCode or Codex session in CI. Adding or removing a runtime needs a new ADR.

Evidence: [`references/runtimes.yaml`](../../references/runtimes.yaml),
[`tooling/generate/registry_sync.py`](../../tooling/generate/registry_sync.py),
and [`tooling/validate/runtime_parity.py`](../../tooling/validate/runtime_parity.py), plus the
OpenCode tree at commit `f80281b7` (removed by ADR-020).
