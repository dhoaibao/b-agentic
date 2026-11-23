# ADR-031: Worker steps and parallel worktrees on Pi

- Status: Accepted
- Date: 2026-11-22
- Supersedes: [ADR-030](ADR-030-pi-runtime-rendered-at-install.md) in part (the no-`b-worker` and no-worktree constraints on Pi)

## Context

[ADR-030](ADR-030-pi-runtime-rendered-at-install.md) initially disabled `b-worker` ([ADR-015](ADR-015-step-writer-worker.md))
and `parallel_steps` ([ADR-016](ADR-016-parallel-worker-steps.md)) on Pi, forcing every approved worker step onto the
main session with `--by main`. Meanwhile `pi-subagents` 0.89.2 natively supports per-child `cwd` directories,
`workflow: "parallel"` fanout, and `registerRequiredChildExtensions` child gating so every spawned child inherits
`guard.mjs` and `@gotgenes/pi-permission-system`. The user requested parity with Claude Code for both sequential
`worker_steps` and parallel `parallel_steps` on Pi.

## Decision

- Render `agents/b-worker.md` on Pi from `skills/registry.yaml` (`workers`) and `references/runtimes.yaml`
  (`runtimes.pi.workers`, `worker_tools`, `worker_excluded_tools`), granting `read`, `grep`, `find`, `ls`, `bash`,
  `edit`, `write`, and `b-planner`'s read-only `mcp:` tools while keeping `excludeTools: subagent, ask_user_question`
  and `allowNestedSubagents: false`.
- Keep the shared worker body in `tooling/generate/registry_sync.py` and share the `b-plan` / `b-flow` worker text
  across runtimes via two Pi glossary entries in `references/runtimes.yaml` (reducing canonical runtime marker lines
  from 8 to 3), using `subagent` (`agent: "b-worker"`) for single steps and `subagent({ workflow: "parallel", args: { tasks: [{ agent: "b-worker", task, cwd }, ...] } })`
  for `parallel_steps`.
- Allow `subagent_launch` in `runtimes.pi.allowed_tools` so each `workflow: "parallel"` child starts without a
  headless permission denial.
- Remove the `onPi()` worker/worktree narrowing from `claude/bin/b-state*.mjs` and `claude/bin/b_run.py` while keeping
  Pi's `reviewer`-only review gate, `PI_SESSION_ID` lock owner, and `B_AGENTIC_HELPER_DIR` command prefix; make
  `runWorktrees` and `_worktree_dir` use NUL-delimited `git worktree list --porcelain -z` and fail closed on listing
  errors across both runtimes, require worktree cleanup on `unblock verify`, and extend `b-run worker-profile` (with
  `--step S-n` for worktree `cwd`s) to inspect Pi `.pi/agents`, `.agents`, `~/.pi/agent/agents`, and `~/.agents`
  profiles, Pi `---` frontmatter delimiters, and Pi `subagents.*` discovery/extension/override settings.
- Enable `parallel_checks` concurrency on Pi via the Pi glossary in `references/runtimes.yaml`: `skills/b-flow/SKILL.md`
  instructs the model to issue one `bash` tool call per listed check in a single assistant message with no other tool
  call (relying on Pi's default parallel tool execution, falling back cleanly if any sibling tool or setting forces
  sequential mode), edit nothing while they run, and record each result with `--from`.

## Consequences

- Pi and Claude Code share the same `b-flow` `worker_steps` and `parallel_steps` lifecycle (`WORKTREE_CAP = 2`,
  `b-state worktree add|collect|remove`, and `b-state record step S-n --by worker`), with fail-closed NUL-delimited
  worktree enumeration on both runtimes.
- Acceptance result (2026-11-23, user-confirmed practical Pi use without issues): accepted on the user's confirmation
  that the Pi runtime has been used in practice with no issues. Standalone live runs of a `worker_steps` step, a
  two-step `parallel_steps` batch (`subagent_launch`, child `guard.mjs` + `pi-permission-system` enforcement,
  `b-state worktree collect`), and a `parallel_checks` batch with real provider models were not recorded or itemized
  separately from general practical use.

Evidence: [`references/runtimes.yaml`](../../references/runtimes.yaml),
[`tooling/generate/registry_sync.py`](../../tooling/generate/registry_sync.py),
[`skills/b-flow/prompt.md`](../../skills/b-flow/prompt.md),
[`skills/b-plan/prompt.md`](../../skills/b-plan/prompt.md),
[`claude/bin/b-state-next.mjs`](../../claude/bin/b-state-next.mjs),
[`claude/bin/b-state-worktree.mjs`](../../claude/bin/b-state-worktree.mjs),
[`claude/bin/b_run.py`](../../claude/bin/b_run.py), and
[`pi/extensions/b-agentic/guard.mjs`](../../pi/extensions/b-agentic/guard.mjs).
