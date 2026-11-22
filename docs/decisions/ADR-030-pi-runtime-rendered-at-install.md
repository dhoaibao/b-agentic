# ADR-030: Pi as an opt-in second runtime, rendered at install time

- Status: Proposed
- Date: 2026-11-21
- Supersedes: none yet; on acceptance (see Pending acceptance) it supersedes [ADR-020](ADR-020-claude-code-only-again.md) and [ADR-027](ADR-027-antigravity-runtime-removed.md) and the no-second-runtime lines of [ADR-001](ADR-001-b-agentic-design-record.md). Until then those three are unchanged; `install.sh --runtime=pi` is an opt-in install of the Pi runtime under `~/.pi/agent` and Claude Code stays the default.

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
the old owned guard unchanged (the probe scripts were not committed then; the guard probe and the manual spike now live
under `tests/pi`):

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
  Pi or a package (it prints the Pi version and warns below the floor). A new release can break a guard silently, so
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
- `--render pi` renders the kernel, skills, prompts, agents and the Pi permission, MCP and settings configuration. The owned
  extension (path guard with `user_bash`, verify gate, context injection, child gating, fail-closed capability checks) and the
  installer are hand-written; the shapes of the Pi data in the runtime vocabulary file are validated by the generator
  check, `runtime_parity.py` and `mcp_policy.py`.
- The helpers became runtime-neutral: `PI_SESSION_ID` is the lock owner when no Claude Code variable is set, and
  `B_AGENTIC_HELPER_DIR` (a `~/` or absolute path, mirrored in three copies and checked by a parity probe) changes the
  folder their printed commands name and is the one signal that the helpers run on Pi (no worker steps, no worktrees, gate
  `reviewer` only). An explicit empty `--owner` is refused by both `b-state` and `b-run`.
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
- Known limits, found in review and deferred or accepted by design:
  - Installer: there is no lock, so two installs started at the same time are not serialized. A config file that is a
    symlink (the kernel file, the Pi settings and MCP files, the permission config) is written through to its target, even
    outside `~/.pi/agent`; a link into the agent directory, Pi's own state files, `~/.claude`, `~/.claude.json` or
    `~/.config/opencode`, and a symlinked managed directory, are refused. A symlinked `~/.pi/agent` root is followed, so
    the whole install lands at its target, although the installer's own help says only `~/.pi/agent` is written. The
    Claude installer's guard protects `~/.pi` and where it resolves but not a relocated `~/.pi/agent` root, so a Claude
    config symlink that resolves there would be written (found in review; it predates this ADR and is not fixed here). Uninstall drops a permission section it leaves empty, and an emptied
    `permission` object; no rule is lost.
  - Permission rules: only a literal user catch-all `*` that differs from the shipped one for its section sets the floor
    for managed rules. A catch-all equal to the shipped one sets none, so an existing MCP `*` of `ask` still gains the
    managed allows for the managed servers, by design. A pattern that is equivalent
    but spelled differently (`**`, `* *`) can override a managed deny. The order of rules (last match wins) is assumed
    from the permission package's README and modelled by the validators, not proven against a live Pi. The validator
    models only `*` in a pattern and does not reject a `?`, none is rendered; the renderer maps only dashes in MCP tool
    ids and the validator fails closed on any other character or an id over 64 characters. The install probe's verdict
    helper matches with `fnmatch`, not Pi's matcher, and does not assert a bare `git push` verdict itself (the
    `mcp_policy.py` evaluator does).
  - Guard: it fails closed for `subagent` tool launches only, and the spike proves no more than that and the installed
    layout: nothing automated shows that the permission package's shell handler is active. If it is missing, the main session's own
    tools run without its rules, and a project-level MCP override cannot be seen at install time. A slash or RPC launch
    bypasses the tool hook when child registration fails: Pi 1.6.0 runs extension commands before the `input` event
    (taken from Pi's documentation as recorded in the run spec, not re-checked), so there is no input-event gate. The
    `user_bash` check is narrow, and a hidden `.b-agentic.x` spelling passes. The background specialist runner is not
    probed, because the scripted model cannot drive a detached run (a separate `pi` process).
  - Helpers: a worktree moved with `git worktree move` to another folder name is not found by the open-worktree guard,
    which looks up folder-name prefixes; the Claude path reads a newline-delimited worktree list, so a temporary
    directory with a newline in its name is missed there (Pi reads the NUL-delimited list). Pi's verify refusal lists
    worktree ids with a plain sort (`S-10` before `S-2`), the step packet of a non-worker step still forbids `b-state`
    commands although Pi's `next` lines never send a main-session step through it, and four Claude helper strings
    changed for Pi have no exact test assertion (a reviewer diffed each against `HEAD`; the Claude output is unchanged).
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

### Pending acceptance

This ADR stays Proposed until two checks that nothing automated can do have been run by a person on a real machine, and
their results are written here:

1. A real install: Pi 1.6.0 or newer and the four packages installed by the user, `./install.sh --runtime=pi`, then a
   `/b-flow` run end to end on Pi (clarify, approval, implement, verify, the `b-reviewer` gate, QA, commit), and the
   model's `bash` tool asked to run `sudo true`, which must return a tool result that reports the permission denial and not
   a shell error (no automated check shows this; a `!` or RPC shell command does not exercise the permission package).
2. The classifier with a real model and API key:
   `PI_PROBE_NPM_DIR=DIR PI_SPIKE_CLASSIFIER=1 PI_SPIKE_MODEL=PROVIDER/MODEL tests/pi/spike.sh`. The script prints the
   verdicts and asserts none; a person reads them and confirms the routine command was judged and allowed and the
   suspicious one refused.

Optional: settle the billing and terms of a Claude Pro or Max login in Pi through `b-research` (the unverified item above).

On acceptance, one change makes these edits and nothing else:

- This ADR: Status becomes Accepted, the Supersedes line states what it supersedes, and this section records the results.
- ADR-020 and ADR-027: add a note that ADR-030 supersedes their no-second-runtime decision, keeping their history.
- ADR-001: note the same on its no-second-runtime lines.
- `docs/decisions/README.md`: the ADR-030 index line drops "proposed" and "once accepted".
- `AGENTS.md`, `README.md`, `REFERENCE.md` and `pi/README.md`: drop the "Proposed" status wording and the earlier-removal
  sentences that no longer hold.
