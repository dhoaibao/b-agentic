# ADR-030: Pi as an opt-in second runtime, rendered at install time

- Status: Proposed
- Date: 2026-11-21
- Supersedes: none yet; on acceptance (run 5) it supersedes [ADR-020](ADR-020-claude-code-only-again.md) and [ADR-027](ADR-027-antigravity-runtime-removed.md) and the no-second-runtime lines of [ADR-001](ADR-001-b-agentic-design-record.md). Until then those three are unchanged; `install.sh --runtime=pi` is an opt-in install of the Pi runtime under `~/.pi/agent` (run 4) and Claude Code stays the default.

## Context

[ADR-020](ADR-020-claude-code-only-again.md) removed OpenCode and said a further runtime needs a new ADR that supersedes it;
[ADR-027](ADR-027-antigravity-runtime-removed.md) removed Antigravity the same way, and [ADR-011](ADR-011-pi-second-runtime.md)
had earlier carried Pi. Each was removed for the same reason: a second generated tree, installer, guard and parity checks
cost more than they returned. The user now wants the Pi coding agent (`@earendil-works/pi-coding-agent`, 1.6.0 dated
2026-11-20) back beside Claude Code, with every workflow, so that b-agentic can run on models from many providers, and
asked for the adapter to stay as thin as possible.

Cost of the earlier attempt, measured at commit `ba7bc2db` (the last Pi tree): 56 Pi-only files and 5,356 lines, of which
3,062 were generated and committed (skills, prompts, agents, a 906-line permission config) and 2,294 hand-written
(extension 298, installer 982, tests 1,014). The OpenCode removal deleted 89 files and 15,002 lines, the Antigravity
removal 59 files and 5,800 lines.

Pi facts used here come from its documentation and source read on 2026-11-21 and from a spike (below). Pi has no
permission system, sandbox, subagents, plan mode or background shell of its own; it has TypeScript extensions with
`tool_call` (can block), `agent_before_settle` (can request one more turn), `session_start`, `before_agent_start`
and `user_bash` hooks, built-in MCP, skills (Agent Skills format), prompt templates, and `-p`, JSON and RPC modes. Its
extension API has no stated stability policy and changed at 1.2.0, 1.5.0 and 1.6.0.

Spike, run on 2026-11-21 against Pi 1.6.0 in an isolated install and agent directory with a scripted offline model and
the old owned guard unchanged (the probe scripts were not committed; run 3 restores them under `tests/pi`):

- Guard and packages: the owned guard, pi-subagents 0.89.2, `@gotgenes/pi-permission-system` 42.2.0 and
  `@juicesharp/rpiv-ask-user-question` 2.15.0 load. Synchronous and background subagent children are gated through
  `registerRequiredChildExtensions` with `requireForAllRunners`; the verify reminder fires once in `-p` and JSON modes;
  gotgenes parses shell commands with its bundled wasm grammar when npm install scripts are skipped, so deny rules
  (`reset --hard`, `sudo`, secret reads, compound commands) hold; nested `codemode` calls pass the same gates.
- Environment: the model's bash tool sees `PI_SESSION_ID`; a throwing auto-discovered extension makes `pi` exit 1 and run
  nothing; MCP tools with direct exposure are named `mcp__<server>__<tool>` with other characters replaced by `_`;
  `/skill:NAME` works in `-p` and RPC once `skill` is allowed, a skill in the agent directory beats the same name under
  `~/.agents`, and a settings entry can add `~/.claude/skills`.
- Gaps: `user_bash` (a user's `!` command, also the RPC `bash` command) is gated by neither the owned guard nor gotgenes;
  the permission config must allow `skill` and name `codemode`; `pi -p` waits for EOF on an open non-terminal stdin, so
  a driver passes `</dev/null`; Pi has no background bash; `@gotgenes/pi-permission-model-judge` is not an auto mode (it only
  denies mistyped paths) while `pi-permission-classifier` 0.6.1 is a chain link that judges the asks of the permission
  system, fails safe and must load before it, though its allow and deny verdicts were not exercised without a real model.

## Decision

- Pi is an opt-in second runtime. Claude Code stays the default, and every generated Claude file stays byte-identical:
  the Claude render is the identity render and never applies the glossary or kernel overrides.
- Nothing is pinned. The floor is Pi 1.6.0, the version the spike ran on; the Pi package entries name npm packages without
  versions (`pi-permission-classifier` before `@gotgenes/pi-permission-system`, `pi-subagents`,
  `@juicesharp/rpiv-ask-user-question`), a pin in that list fails the generator check, and the installer never installs
  Pi or a package (it will print the Pi version and warn below the floor). A new release can break a guard silently, so
  the owned extension fails closed when the API it relies on is missing, and a manual spike script is run after each
  Pi upgrade.
- The Pi tree is generated at install time and not committed. `tooling/generate/registry_sync.py --render pi --out DIR`
  writes the kernel, 20 skills, 20 prompt templates and 5 agents into a new or empty directory outside the checkout, and
  refuses a Claude render, a directory inside the checkout or a non-empty one. `--check` and `--self-test` render Pi in
  memory and fail on a forbidden Claude token, an unresolved marker, a glossary entry that matches nothing, an over-budget
  kernel or an agent with an editing tool, so the Pi output is verified without ever living in the repository.
- One set of canonical prompts serves both runtimes. A bare marker line and a closing line fence a block that only the
  named runtime keeps (the marker lines may be indented, so a block inside a Markdown list item keeps the list intact),
  beside the existing per-line markers and the glossary, with at most 10 marker lines in all (8 today: the review Codex
  steps and tool line, the worker bullets with their Pi replacement, the worker-step paragraph of the planner). On Pi the review gate is the read-only
  `b-reviewer` subagent only and b-flow records `--gate reviewer`; there is no `b-worker`, worker step or parallel step
  (the main session applies every step and records it bare; only a step an older plan lists as a worker step takes `--by main`); checks that Claude Code runs together run one at a time;
  `AskUserQuestion` becomes `ask_user_question`; no status line, todo, plan mode or sandbox is ported.
- Run 2 renders only the kernel, skills, prompts and agents. The Pi permission, MCP and package configuration, the owned
  extension (path guard with `user_bash`, verify gate, context injection, child gating, fail-closed capability checks) and the
  installer follow in runs 3 and 4; the shapes of the Pi data in the runtime vocabulary file are validated now.
- The helpers became runtime-neutral in run 1: `PI_SESSION_ID` is the lock owner when no Claude Code variable is set, and
  `B_AGENTIC_HELPER_DIR` changes the folder their printed commands name. Two follow-ups from that review are scheduled:
  align the empty-string owner handling of `b-state` and `b-run` (run 3), and tighten the folder variable to a `~/` or
  absolute path in the three mirrored copies and the parity probe (run 4, with the wrappers).
- Kill criterion: remove the Pi runtime, by a new ADR, when it goes unused for four weeks or when two Pi or package
  upgrades break the spike.
- Acceptance: this ADR becomes Accepted only after the live install check on a real machine and a classifier check with
  a real model; the status of the three superseded decisions is not touched before then.

## Consequences

- Maintenance is the real cost. Run 2 added about 450 hand-written lines (generator, runtime data, prompt markers); runs 3 and 4
  are estimated at a few hundred lines of extension and several hundred for the installer, plus tests, so the hand-written
  total is expected to land near the earlier 2,294 lines, not far below. What this attempt avoids is the 3,062 committed
  generated lines, the double regeneration on every prompt edit and the rule-by-rule permission parity.
- Every glossary entry quotes Claude wording, so a later edit of that wording makes `--check` fail until the entry is
  updated; that failure is the intended signal, not a defect.
- Unverified on Pi 1.6.0: the agent frontmatter keys (`excludeTools`, `systemPromptMode`, inheritance flags) and the
  `mcp:<server>/<tool>` tool ids carried over from the earlier tree; `argument-hint` and `$ARGUMENTS` in prompt templates;
  the 1024-character description limit; whether Pi reads a `CLAUDE.md` in a subdirectory on demand (it loads the working
  directory and its parents); the exit codes of `--mode json` on a failed response; Pi's own package install with scripts;
  billing and terms of a Claude Pro or Max login in Pi (Pi bills it as extra usage).
- Helper text for the model still names Codex or `b-worker` in a few `next` lines and refusals; that wording is a run 3 or
  run 4 follow-up.
- Rejected: restoring the earlier tree wholesale (it predates the worker, the verify-gate modes and several ADRs and
  carries about 3,000 committed generated lines); pinning Pi or the packages (the user's decision); committing a generated Pi tree
  (double churn and a tree easy to commit by accident); a separate Pi prompt per skill or a placeholder include (they
  duplicate text or add a second mechanism); per-line markers only (about 19 marker lines); Pi only as a delegated worker
  or a `pi -p` call from Claude Code (cheap, but runs no workflow on Pi); `pi-code` (wide scope, unverified hook contract);
  a standalone auto-mode package beside the permission package (unverified handler order, two deny lists).

Evidence: [`tooling/generate/registry_sync.py`](../../tooling/generate/registry_sync.py),
[`references/runtimes.yaml`](../../references/runtimes.yaml),
[`skills/b-review/prompt.md`](../../skills/b-review/prompt.md),
[`skills/b-flow/prompt.md`](../../skills/b-flow/prompt.md),
[`skills/b-plan/prompt.md`](../../skills/b-plan/prompt.md),
[`claude/bin/b-state-core.mjs`](../../claude/bin/b-state-core.mjs),
[`claude/bin/b_run.py`](../../claude/bin/b_run.py), and
[`tests/state/cases/owner.sh`](../../tests/state/cases/owner.sh).
