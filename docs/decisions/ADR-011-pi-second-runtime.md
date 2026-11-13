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
- Safety hooks become one owned fail-closed Pi extension that reuses the
  `claude/hooks` logic; it is built in a later change, not this one.
- The installer is a later change: `--runtime=claude|pi|both` with `claude` as the
  default, disjoint install roots, and no vendor installers run.
- The status line and todo list are not ported in v1. Doctor scripts get no Pi mode yet.

### Gap handling on Pi

| Claude Code feature                          | Pi handling                                                                                |
| -------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Permission rules in the Claude settings file | Generated permission config with the last matching rule winning, so deny rules come last   |
| Path guard hook                              | Guard extension (later change) plus the permission system's `path` rules as a second layer |
| Verify gate (Stop hook)                      | Extension on `agent_before_settle` (later change; spike S3)                                |
| Spec and run context after compaction        | Extension injection (later change; spike S4, S5)                                           |
| Codex review gate                            | Not ported; `b-reviewer` only                                                              |
| Status line, todo                            | Not ported                                                                                 |
| `AskUserQuestion`                            | `ask_user_question` from the pinned package                                                |
| Subagent profile check                       | `subagent` tool and the agent file's `tools` allowlist                                     |

### Spike results

Every item is pending: Pi is not installed on the machine that wrote this record, and
this record stays Proposed until the table is filled in on Pi 1.5.2.

| ID  | Check                                                                          | Result  |
| --- | ------------------------------------------------------------------------------ | ------- |
| S1  | A `tool_call` handler returns `block`; a throwing handler fails open or closed | pending |
| S2  | Exact tool input keys for read, edit, write, grep, find, ls, bash              | pending |
| S3  | `agent_before_settle` returns `continue` and adds one reminder turn            | pending |
| S4  | Context injection after `/compact`                                             | pending |
| S5  | The same injection on startup and resume                                       | pending |
| S6  | The permission system and the guard cover `pi-subagents` children              | pending |
| S7  | Built-in MCP tool names, config shape, `${VAR}` interpolation, Notion OAuth    | pending |
| S8  | `.b-agentic` write denial for file tools while Bash writes still work          | pending |
| S9  | `AGENTS.md` and `CLAUDE.md` loading order and duplication                      | pending |
| S10 | `/skill:` and `/b-` commands, argument passing                                 | pending |
| S11 | Session id environment variable for the run-state lock                         | pending |
| S12 | `rpiv-ask-user-question` tool name and behaviour                               | pending |
| S13 | Permission system rule order, layering, and `path` on Bash                     | pending |
| S14 | `subagent` tool parameters, unknown-agent error, agent precedence, depth       | pending |
| S15 | An extension that throws at import                                             | pending |
| S16 | The Pi settings `packages` pins install and load on Pi 1.5.2                   | pending |

## Consequences

- Two runtimes to maintain. The kernel size limit applies to each rendered kernel.
- The generated Pi permission keys and MCP tool names follow the prior Pi template and
  the package READMEs and are unverified until S7 and S13 run; treat the Pi permission
  config as a draft until then.
- Pi extensions fail open at load time, so the permission system's `path` rules are
  a required backstop for secret paths (S15).
- Child bash on Pi depends on the permission system covering `pi-subagents` children
  (S6). If it does not, child bash is prompt-enforced only, which is an accepted gap.
- Pi and the three pinned packages can change config keys silently; re-run the spike
  after an upgrade.
- `b-flow` on Pi needs the guard extension to set `B_AGENTIC_SESSION_ID` and
  the run-state helper to read it; until that change lands, `b-flow` does not run on Pi.
- Unchanged non-goals: no custom permission engine, no per-project installs, no live
  Pi or Codex session in CI. Reintroducing or removing a runtime needs a new ADR.

Evidence: [`references/runtimes.yaml`](../../references/runtimes.yaml),
[`tooling/generate/registry_sync.py`](../../tooling/generate/registry_sync.py),
[`tooling/validate/runtime_parity.py`](../../tooling/validate/runtime_parity.py),
[`pi/kernel.md`](../../pi/kernel.md), and
[`pi/configs/permission.json`](../../pi/configs/permission.json).
