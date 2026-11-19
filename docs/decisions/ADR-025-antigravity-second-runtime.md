# ADR-025: Antigravity CLI as the second runtime

- Status: Superseded
- Date: 2026-11-19
- Supersedes: ADR-020 (Claude Code only again)
- Superseded by: [ADR-027](ADR-027-antigravity-runtime-removed.md) (the Antigravity runtime was removed again). The tree this record describes was last present at commit `caf570fd`; paths it cites that no longer exist are written as plain text.

## Context

[ADR-020](ADR-020-claude-code-only-again.md) made Claude Code the only runtime because the
user worked only there and a second generated tree, installer, plugin, and parity checks cost
more than they returned. The user now wants Google's Antigravity CLI (`agy`, 1.5.12 at the
time of writing) as a real second runtime with the same main workflow: kernel, `b-*` skills as
commands, read-only specialists, `b-worker`, safety hooks including the verify gate, managed
MCP and permissions, `b-flow` run state, and the Codex-first review gate. Claude Code stays the
default, and its generated output stays byte-identical.

`agy` is a closed-source Go binary that replaced Gemini CLI. It reads its configuration from
`~/.gemini`, not from `~/.claude`. An earlier shell-only Antigravity runtime lived in the tree
from commit `6f3c0232` to its removal in `697849f7` (ten days). The last OpenCode tree is
commit `f80281b7`; its render pipeline is the template for this change
([ADR-019](ADR-019-opencode-second-runtime.md)).

The work is split into two runs. Run 1 (this record) delivers the decision, the runtime entry,
the renderers and the committed `antigravity/` tree, the hook adapter, and the small
`claude/bin` changes. Run 2 delivers the installer, `install.sh --runtime`, validator wiring,
and the user-facing docs; it has landed, so `install.sh --runtime=antigravity` installs into `~/.gemini`.

Evidence: [`references/runtimes.yaml`](../../references/runtimes.yaml),
[`tooling/generate/registry_sync.py`](../../tooling/generate/registry_sync.py), and
[`install.sh`](../../install.sh).

## Decision

The user decided each item below on 2026-11-19 after the probes listed further down.

### Runtime and delivery

- `antigravity` is an opt-in second runtime. The `antigravity` entry in
  `references/runtimes.yaml` reuses the generic render mechanism (`<!-- runtime: NAME -->`
  markers, glossary, `kernel_overrides`, forbidden tokens, `primary_gate.runtimes`). Claude
  output is the identity render.
- Generated output is committed under `antigravity/`: `skills/<name>/SKILL.md` as real
  directories, `agents/*.md`, the b-agentic rule file, and `configs/` templates for hooks,
  permissions, and MCP. `tooling/generate/registry_sync.py --check` guards drift and fails on a forbidden Claude
  token in this tree.
- The kernel ships as an owned rule file with `trigger: always_on`, at most 16000 bytes,
  rather than a block merged into a shared `AGENTS.md`. The Claude kernel template is
  unchanged: it is installed raw, so `agy` differences go through `kernel_overrides` and the
  glossary, never through a marker line in that file.
- Later installs copy files directly (no plugin). A plugin namespace could rename `/b-plan` or
  MCP tool names and a failed plugin would silently drop every guard.
- `--runtime=claude|antigravity|both` (default `claude`) is the opt-in switch, added in run 2.
  Any other value stays refused. `both` runs the Claude Code installer and then the Antigravity one,
  stopping at the first failure; a plain `--uninstall` removes only the Claude Code install.
- The verified `agy` version (1.5.12) is recorded in this ADR and in `references/runtimes.yaml`. It is
  reported, never enforced, because `agy` released 1.5.11 and 1.5.12 within one day.

### Agents, skills, and MCP

- Every generated agent sets `subagent: true`, `mainAgent: false`, `model: inherit`, and an
  explicit `tools` list of real tool names. Specialists keep `run_command` because `agy` has
  no list, grep, or find tool; read-only stays prompt-enforced, as on Claude Code.
- An agent `tools` list never names `call_mcp_tool`: that name makes the agent fail to start.
  MCP is implicitly available to every subagent, so the per-agent MCP allowlists of
  [ADR-023](ADR-023-per-agent-mcp-tool-scope.md) cannot be enforced on `agy`. This is accepted
  and recorded as a gap: permissions are global, so a tool the policy allows (`read-only`,
  `conditional-read`, and `trusted-mutation`, which Claude Code keeps for the main session only)
  is callable by every subagent, and every approval-class tool asks. The `agent_note` text in each
  agent file is the only guard for that difference.
- MCP permissions render as `mcp(server/tool)` strings from `references/mcp_operations.yaml`.
  The hook adapter maps `call_mcp_tool` (`ServerName`, `ToolName`) to the `mcp__server__tool`
  names the Claude policy uses.
- `$ARGUMENTS` is not substituted by `agy`, so rendered skills say "the text after the command
  name". Skills are real directories because `agy` does not load symlinks.

### Hooks and gates

- One Bun adapter reuses the pure exports of the Claude hooks and does not change them. It
  never prints `allow`, so `agy` permission `ask` rules still apply; a no-objection result
  prints nothing.
- A shell command is checked word by word for protected paths, because a shell `cat` bypasses
  a `read_file` permission deny. Guard events deny on an internal error. `agy` already fails
  closed on a hook crash, a timeout, or invalid JSON.
- The verify gate keys state by `conversationId`. `Stop` asks for one extra turn only when
  `fullyIdle` is true and `continuationActive` is false. `Stop` also fires for every subagent
  conversation and carries no parent marker, so a subagent's edits dirty only its own
  conversation. This differs from Claude Code, where a subagent's edits mark the parent.
- Run and spec context arrive through a `SessionStart` `injectSteps` system message, which
  persists across a resumed conversation.
- The review gate is Codex first through `b-codex-review`, then `b-reviewer` on exit 4, as
  on Claude Code ([ADR-007](ADR-007-codex-first-review-gate.md)). `primary_gate.runtimes`
  lists both runtimes. The wrapper strips every `ANTIGRAVITY_*` variable from the Codex
  companion environment because it holds a secret CSRF token.
- The run-state lock owner falls back to `ANTIGRAVITY_CONVERSATION_ID` after
  `CLAUDE_CODE_SESSION_ID`. The main session's value equals the hook `conversationId`.
  Workers never call the run CLI, so their different id does not matter.
- `worker-profile` checks `.agents/agents` and `~/.gemini/config/agents` under `agy`.

### Gap handling on agy

| Claude Code feature   | agy handling                                                          | Source |
| --------------------- | --------------------------------------------------------------------- | ------ |
| Kernel                | Owned `always_on` rule file, at most 16000 bytes                      | P6     |
| Skills                | Real directories in the `agy` skills path                             | E4     |
| `/b-<name>` commands  | A skill is its own `/<name>` command; no `$ARGUMENTS`                 | E1     |
| Read-only specialists | `tools` allowlist with `run_command`; prompt-enforced read-only       | P1, E5 |
| `b-worker`            | Subagent with `write_file`, `edit_file`; async, parent gets a message | E8     |
| Permission rules      | `deny > ask > allow`, not ordered; `mcp(server/tool)` patterns        | P3, E6 |
| Path guard hook       | `PreToolUse` in parent and subagents; plus shell word check           | E2, E7 |
| Verify gate           | `Stop` continue once, only when fully idle                            | E7     |
| Spec and run context  | `SessionStart` `injectSteps` system message                           | P6     |
| `AskUserQuestion`     | `ask_question`                                                        | docs   |
| Run-state lock owner  | `ANTIGRAVITY_CONVERSATION_ID`                                         | P9     |
| MCP and OAuth         | the agy MCP config, lazy tools, Streamable HTTP only                  | P3     |
| Per-agent MCP scope   | Not enforceable (gap)                                                 | P4     |
| Review gate           | `b-codex-review` background task; `b-reviewer` on exit 4              | P5     |
| Todo                  | None                                                                  | docs   |
| Status line           | Not ported                                                            | docs   |
| Parallel worker steps | Not ported                                                            | none   |

### Probe results

Run on 2026-11-19 against `agy` 1.5.12, in a scratch workspace with headless `-p`, an
interactive child terminal, a mock stdio MCP server, and probe hooks.

| ID  | Check                           | Result                                                                                                                        |
| --- | ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| E1  | Slash skill arguments           | `$ARGUMENTS` stays literal; the text after `/<skill>` reaches the model                                                       |
| E2  | `PreToolUse` in a subagent      | Fires with the child's own `conversationId`; `deny` blocks, even `invoke_subagent`                                            |
| E3  | Session id in the shell tool    | `ANTIGRAVITY_CONVERSATION_ID` and `ANTIGRAVITY_TRAJECTORY_ID`; a subagent has its own                                         |
| E4  | Claude skill folder             | Loads when it is a real directory; a symlink does not load                                                                    |
| E5  | Subagent tool isolation         | A `read_file`-only agent has no shell or write tool                                                                           |
| E6  | Deny rules                      | `command(...)` deny held against chains and `$()`; `read_file(dir/)` deny held, but shell `cat` bypassed it                   |
| E7  | `Stop` hook                     | `continue` forced one extra turn; it also fires for subagents with `fullyIdle` false while a parent waits                     |
| E8  | `b-worker` and parallel workers | Edit and shell tools work in `accept-edits`; two parallel workers both reported                                               |
| P1  | Tool inventory                  | `read_file`, `write_file`, `edit_file`, `run_command` only; listing and search go through `run_command`                       |
| P2  | `PostToolUse`                   | Fires in parent and subagents, not for a denied call; `error` is not set for a non-zero exit code                             |
| P3  | MCP call shape                  | Lazy: the schema file is read, then `call_mcp_tool` with `ServerName`, `ToolName`, `Arguments`; `mcp(server/tool)` rules work |
| P4  | Per-agent MCP scope             | Any subagent can call MCP; `call_mcp_tool` in `tools` or an unknown `mcpServers` name breaks the agent                        |
| P5  | Long command                    | Becomes a background task after about 10 s; the agent waits and gets the exit code and stdout                                 |
| P6  | Context injection               | `SessionStart` and `PreInvocation` `injectSteps` reach the model; `SessionStart` persists across resume                       |
| P7  | Hook failure modes              | Exit 1, exit 2, a timeout, and invalid JSON each block the tool                                                               |
| P8  | Config normalization            | the agy settings file is reformatted with content kept; the agy hooks file and MCP config stay byte-identical                 |
| P9  | Owner id                        | The shell id equals the hook `conversationId` and the JSON `conversation_id`, stable across resume                            |

### Installed smoke test

Run on 2026-11-19 against `agy` 1.5.12 with the installed `b-agentic` assets in the real `~/.gemini`
(the run-2 installer, absolute hook commands), headless `-p`, in a scratch workspace with a synthetic `.env`:

| ID  | Check             | Result                                                                                                                                 |
| --- | ----------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| S1  | Secret path read  | `read_file` of `./.env` was denied by the `b-agentic` path guard hook, so the installed hook command ran and agy loaded the hooks file |
| S2  | Plain read        | `read_file` of an ordinary file returned its content                                                                                   |
| S3  | Kernel and skills | The `b-agentic` kernel rule was loaded and the `b-*` skills were visible                                                               |
| S4  | `git push`        | A `command` permission was needed; headless mode cannot prompt and auto-denied it, so the push did not run                             |

A session-only `--settings` allow of `command(*)` was probed the same day: `ls` ran, `git push --dry-run`
still asked, `git push --force` was denied by a deny rule, and `cat .env` was denied by the path-guard hook.
`grep -r FAKE .` in a directory holding a synthetic `.env` printed the file's line with no prompt: the guard
matches a secret path named in the command, not a recursive read of a directory that holds one. Before
`command(*)` that command asked.

An interactive approval dialog for `git push` was not exercised, and these runs prove nothing about the
Gemini-class models following the long skills.

### Not verified

- Whether the hook `command` field expands `$HOME`: the installer writes absolute paths, which S1 shows
  work, so the form with `$HOME` is not used.
- The permission syntax for file paths (only `mcp(server/tool)` and `command(...)` were
  exercised).
- Whether a hook `allow` overrides a permission `ask`; the adapter never prints `allow`.
- A Codex wait of several minutes beyond about 4.5 minutes in print mode.
- Compaction survival of injected context, and parallel workers in separate git worktrees.
- Whether Gemini-class models follow the long Claude-written skills; no CI can show this.
- The location of the user skills folder beyond `~/.gemini/config/skills` (assumed).
- Whether a `command(...)` rule accepts an inner `*`. Only prefix rules are rendered, so the
  Claude patterns with an inner wildcard (option placement of `git push`, pushes to `main`,
  `gh api` methods) have no `agy` rule. A Claude pattern without a `*` matches one exact
  command (`git push`, `git push origin`, bare `bash`), and as a prefix it would widen to every
  push or every shell, so it is not rendered either: a plain `git push` asks, while the
  force, delete, mirror, all, and prune spellings are denied by prefix. The kernel text is the
  only guard for the rest. The generated template renders no broad shell allow; the installer adds `command(*)`
  by default (run 3), so a command outside those prefixes (`git -C repo push`, `npm publish`, `curl -X POST`)
  runs without a prompt.
- The argument key of an `edit_file` call: probes captured `Path` for `read_file` and
  `write_file` only, so the adapter also checks `TargetFile` and `AbsolutePath`.
- Whether a hook `ask` is answered from an earlier "Always Allow" grant. The adapter prints
  `force_ask` for a scrape with an `alexandria` argument, which the embedded docs say ignores
  cached permissions.
- Whether `${VAR}` in MCP `env` and `headers` is interpolated; the template copies the
  Claude values unchanged, and a remote server uses `serverUrl` (seen by `agy mcp add` in a
  temporary home, not by a live call).
- Whether the interactive prompt, not only headless mode, still asks for a command with an `ask` rule while
  `command(*)` is allowed, and whether `command(*)` from the saved settings file (not only `--settings`) behaves the same.
- Whether a hook `matcher` accepts `a|b` alternation; the hook template uses `*` and the
  adapter ignores tools it does not guard.

## Consequences

- Two runtimes to maintain. The kernel for `agy` has its own size limit, and
  `tooling/generate/registry_sync.py --check` plus a rendered-token check stop Claude wording leaking into it.
- `agy` is a closed binary that updates almost daily and has already drifted from its own
  docs (`write_to_file` versus `write_file`). Tool names come from probes, not docs; re-run
  the probes after an upgrade.
- Per-agent MCP scope, parallel worker worktrees, a todo tool, and the status line are
  accepted gaps. A subagent's edits do not dirty the parent's verify gate.
- `~/.gemini/config` is shared with other tools. Hook groups owned by other tools (herdr,
  orca) must survive an install; tests/install/antigravity-install-probe.sh proves it in a sandbox HOME.
- Uninstall notes: tooling/install/antigravity_install.py records a manifest at
  `~/.gemini/config/b-agentic/install.json`. Files and the kernel rule are owned by sha256, the
  `b-agentic` hook group and MCP servers by exact value, and permission rules by exact entry, with
  `pending` intent for an interrupted run. `--runtime=antigravity --uninstall` removes only recorded,
  unmodified entries, keeps backups, and leaves other tools' groups, servers, and settings. A `b-agentic`
  hook group the user edited stays too, and because a failing hook blocks every tool, uninstall then keeps
  `b-agentic/` and a reduced manifest until that group is removed and uninstall runs again. An older
  b-agentic install under `~/.gemini` (2026-09-14) was removed by hand on 2026-11-19 with a backup.
- Installer decisions (run 2): a separate module reusing the Claude installer's helpers; hook commands
  use the absolute Bun and home paths, unquoted, because `$HOME` expansion and quoting are unverified, and
  the install is refused when a path would need quoting; a same-named user MCP server or an unrecorded
  `b-agentic` hook group is kept with a warning (`--force` replaces files only); a symlinked `~/.gemini`,
  `config`, `antigravity-cli`, or managed directory is refused; optional components work as on Claude Code.
  The real-`agy` smoke test is manual (see the install runbook), not an automated check.
- Adding or removing a runtime needs a new ADR.

Evidence: [`claude/hooks/b-path-guard.mjs`](../../claude/hooks/b-path-guard.mjs),
[`claude/hooks/b-verify-gate.mjs`](../../claude/hooks/b-verify-gate.mjs),
[`claude/bin/b-state-store.mjs`](../../claude/bin/b-state-store.mjs),
[`claude/bin/b-codex-review.mjs`](../../claude/bin/b-codex-review.mjs), and
[`references/mcp_operations.yaml`](../../references/mcp_operations.yaml).

- Installer decisions (run 3): `agy` Auto mode needs a terminal sandbox that some hosts lack (Ubuntu with
  restricted user namespaces), where every shell command asks and defeats the automation b-agentic is for.
  tooling/install/antigravity_install.py therefore adds one allow rule, `command(*)`, by default for
  `--runtime=antigravity` and `both`; `--no-shell-auto` leaves it out and `--shell-auto` adds it back. The
  choice is a boolean `shell_auto` in the manifest (flag, then the recorded value, then on; an install made
  before this option gets the default at its next run). The rule is a constant in the installer, not in the
  generated template, and is owned by exact entry: an identical `command(*)` the user already had is never
  recorded, so `--no-shell-auto` and uninstall keep it. `install.sh` refuses the flags with
  `--runtime=claude`, with `--uninstall`, and together, and never passes them to the Claude installer. The
  `ask` and `deny` rules still win over the allow. Accepted risk: a command with no `ask` or `deny` prefix
  runs without a prompt, and the path guard does not catch a recursive read such as `grep -r` into a
  directory holding a secret file, so only the kernel text guards those.
