# ADR-011: Pi as a second runtime

- Status: Proposed
- Date: 2026-11-13
- Supersedes: ADR-008 (Claude Code only); also the second-runtime non-goal in ADR-001

## Context

[ADR-008](ADR-008-claude-code-only.md) made Claude Code the only runtime and said a
second runtime needs a new ADR that supersedes it. The user now wants the Pi coding
agent (`@earendil-works/pi-coding-agent`, 1.5.2 as of 2026-11-13, Node 22.19 or newer)
beside Claude Code, with every current feature, so that b-agentic can run on models
from many providers. Claude Code stays the primary runtime and its generated output
stays byte-identical to the commit before this change (`048308dd`).

Pi facts used here come from the official Pi docs and package READMEs read on
2026-11-13. Pi has built-in MCP (since 1.0.0), skills that follow the Agent Skills
standard, prompt templates, and a TypeScript extension API. It has no built-in
permission system, sandbox, subagents, plan mode, or todo list. Extensions that
throw are logged and the agent continues, so a Pi guard fails open unless it catches
its own errors. Pi was this repository's first runtime (last tree at `ac38e4a0`) and
OpenCode its second ([ADR-002](ADR-002-dual-runtime-support.md)); both were removed.

## Decision

The user decided each item below on 2026-11-13.

- Pi is an opt-in second runtime. Claude Code remains the default runtime.
- One set of canonical sources is rendered per runtime. A prompt line that starts
  with `<!-- runtime: NAME --> ` is emitted only for that runtime, an ordered literal
  glossary in `references/runtimes.yaml` turns Claude Code wording into Pi wording,
  and `kernel_overrides` change the kernel template without markers in it. The
  generator fails on an unknown marker, a stale glossary entry, a drifted override,
  or a leaked Claude token in Pi output. Claude output is the identity render.
- Pi output is committed under `pi/`: `skills/`, `prompts/` (thin `/b-<name>`
  templates that point at the skill), `agents/`, the kernel, and `configs/` (the
  permission config, the MCP base config, and the pinned package list).
- Specialists use the `pi-subagents` package (nicobailon, pinned `0.88.0`). Each agent
  file lists a strict read-only `tools` allowlist including `mcp:<server>/<tool>`
  entries, and excludes `edit`, `write`, `subagent`, and the ask tool. Specialists
  inherit the session model; the registry has no Pi model field.
- Permissions use `@gotgenes/pi-permission-system` (pinned `42.0.0`), generated from
  `references/mcp_operations.yaml` and the same shell and path rules as the Claude
  settings template. A parity check compares the two rule by rule.
- MCP uses Pi's built-in MCP, not `pi-mcp-adapter`.
- The ask tool comes from `@juicesharp/rpiv-ask-user-question` (pinned `2.15.0`).
- The review gate on Pi is the read-only `b-reviewer` subagent only. There is no
  Codex wrapper, guard, or approval on Pi, and `b-flow` records `codex` as `reviewer`.
- Safety hooks are one owned Pi extension (`pi/extensions/b-agentic`) whose plain-Node
  core reuses the `claude/hooks` modules. The file-tool guard fails closed: a missing
  hook module or any error blocks the call. The verify reminder and the context
  injection fail open, as on Claude Code. The extension also registers itself and the
  permission system as required child extensions, so `pi-subagents` children are gated;
  if that registration fails, subagent launches are refused.
- The run-state lock owner on Pi is `PI_SESSION_ID`, which Pi sets for its bash tool.
- The Pi permission config also allows `subagent`, `bg_wait`, and `ask_user_question`,
  keys MCP tools by the names Pi registers (characters outside letters, digits, and `_`
  become `_`), and the MCP config sets each server's `exposure` because the default
  (`codemode`) leaves a server's tools out of the model's direct tool list.
- The installer is a later change: `--runtime=claude|pi|both` with `claude` as the
  default, disjoint install roots, and no vendor installers run.
- The status line and todo list are not ported in v1. Doctor scripts get no Pi mode yet.

### Gap handling on Pi

| Claude Code feature                          | Pi handling                                                                              |
| -------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Permission rules in the Claude settings file | Generated permission config with the last matching rule winning, so deny rules come last |
| Path guard hook                              | Guard extension plus the permission system's `path` rules as a second layer              |
| Verify gate (Stop hook)                      | Extension on `agent_before_settle`, one extra turn per run                               |
| Spec and run context after compaction        | Extension queues the text and returns it from `before_agent_start`                       |
| Codex review gate                            | Not ported; `b-reviewer` only                                                            |
| Status line, todo                            | Not ported                                                                               |
| `AskUserQuestion`                            | `ask_user_question` from the pinned package                                              |
| Subagent profile check                       | `subagent` tool and the agent file's `tools` allowlist                                   |

### Spike results

Run on 2026-11-13 against Pi 1.5.2 with an offline scripted model in an isolated
agent directory, plus the three pinned packages. "Docs" means the bundled Pi docs and
`dist` source; "live" means a run on Pi.

| ID  | Check                                                                          | Result                                                                                                                                                          |
| --- | ------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| S1  | A `tool_call` handler returns `block`; a throwing handler fails open or closed | Live: block and throw both return an error result and the tool does not run (fails closed per call)                                                             |
| S2  | Exact tool input keys for read, edit, write, grep, find, ls, bash              | Live: read, edit, write, ls take `path`; grep takes `pattern`, `path`, `glob`; find takes `pattern`, `path`; bash takes `command`                               |
| S3  | `agent_before_settle` returns `continue` and adds one reminder turn            | Live: one extra turn with the reminder, then the run settles; `outcome` is completed, aborted, or error                                                         |
| S4  | Context injection after `/compact`                                             | Live (RPC mode; compaction is cancelled in single-shot mode): a `before_agent_start` message queued from `session_compact` reaches the next run                 |
| S5  | The same injection on startup and resume                                       | Live for startup; resume and new session follow the same event                                                                                                  |
| S6  | The permission system and the guard cover `pi-subagents` children              | Live, foreground: children are ungated unless extensions are registered; `registerRequiredChildExtensions` gates them. Background children are not verified     |
| S7  | Built-in MCP tool names, config shape, `${VAR}` interpolation, Notion OAuth    | Live: names are `mcp__<server>__<tool>` with `_` for other characters; default `codemode` exposure is not directly callable. Docs: `${VAR}`, `/mcp login` OAuth |
| S8  | `.b-agentic` write denial for file tools while Bash writes still work          | Live: the guard refuses file-tool writes and allows reads; a Bash write through the run artifact CLI is not path-checked by design and was not run on Pi        |
| S9  | `AGENTS.md` and `CLAUDE.md` loading order and duplication                      | Live: only the first of the override, `AGENTS.md`, and `CLAUDE.md` spellings in that order loads per directory, so the shim is not duplicated                   |
| S10 | `/skill:` and `/b-` commands, argument passing                                 | Live: `/b-x alpha "beta gamma"` expands `$ARGUMENTS` and `$1`; `/skill:name args` expands the skill block                                                       |
| S11 | Session id environment variable for the run-state lock                         | Live: Pi sets `PI_SESSION_ID` and `AI_AGENT=pi` for bash                                                                                                        |
| S12 | `rpiv-ask-user-question` tool name and behaviour                               | Live: the tool is registered as `ask_user_question`; its prompt behaviour is not exercised                                                                      |
| S13 | Permission system rule order, layering, and `path` on Bash                     | Live: deny, ask (denied when headless), and `path` rules work, including `cat .env`; unknown tools such as `subagent` ask                                       |
| S14 | `subagent` tool parameters, unknown-agent error, agent precedence, depth       | Live: parameters `agent`, `task`, `async`; `mcp:<server>/<tool>` uses original tool names and needs configured servers. Precedence and depth are not tested     |
| S15 | An extension that throws at import                                             | Live: with `-e` Pi refuses to start; an auto-discovered extension is not tested                                                                                 |
| S16 | The Pi settings `packages` pins install and load on Pi 1.5.2                   | Live: all three pins install and load; npm reports the `tree-sitter-bash` install script as not yet approved                                                    |

## Consequences

- Two runtimes to maintain. The kernel size limit applies to each rendered kernel.
- The generated permission config was exercised on the main session and a foreground
  child (S6, S13). Background children, deferred MCP exposure for specialists, and
  the `tree-sitter-bash` install script on a clean machine are not verified.
- An extension that fails to load can leave Pi without the guard (S15 covers only
  `-e`), so the permission system's `path` rules stay a required second layer for
  secret paths.
- Child gating depends on `registerRequiredChildExtensions` from `pi-subagents`; the
  guard refuses subagent launches when that registration fails.
- Pi and the three pinned packages can change config keys silently; re-run the spike
  after an upgrade.
- `b-flow` on Pi needs the installer (a later change) to place the run-state helper, the run artifact CLI,
  and the hook modules under the Pi agent directory; the run-state helper already reads
  `PI_SESSION_ID`.
- Unchanged non-goals: no custom permission engine, no per-project installs, no live
  Pi or Codex session in CI. Reintroducing or removing a runtime needs a new ADR.

Evidence: [`references/runtimes.yaml`](../../references/runtimes.yaml),
[`tooling/generate/registry_sync.py`](../../tooling/generate/registry_sync.py),
[`tooling/validate/runtime_parity.py`](../../tooling/validate/runtime_parity.py),
[`pi/kernel.md`](../../pi/kernel.md), and
[`pi/configs/permission.json`](../../pi/configs/permission.json).
