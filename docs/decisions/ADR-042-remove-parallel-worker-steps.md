# ADR-042: Parallel worker steps are removed

- Status: Accepted
- Date: 2026-11-28
- Supersedes: [ADR-016](ADR-016-parallel-worker-steps.md), and
  [ADR-031](ADR-031-pi-worker-steps.md) in part (parallel worker steps and their
  worktrees on Pi)

## Context

[ADR-016](ADR-016-parallel-worker-steps.md) let approved worker steps run at the same
time, each in its own git worktree, and was built without the measurements earlier
records had asked for. [ADR-031](ADR-031-pi-worker-steps.md) added the same on Pi.

On 2026-11-28 the local run folders of this repository showed three runs that had ever
listed worker or parallel steps, all dated 2026-11-14, the day the feature was built.
The only batch that ran was a throwaway live check. ADR-016's proposed kill criterion
could not settle the question on one run. The user chose to remove the feature
because it had not been used for real work.

## Decision

- Remove the `b-state worktree add|collect|remove` commands, their module, the batch
  and open-worktree `next` lines, the worktree checks of `record step`, the waits of
  `advance verify`, `unblock verify`, and the time stop of
  [ADR-039](ADR-039-run-time-budget-stop.md), the `Working directory` packet line, and
  the batch wording of `b-flow`, `b-plan`, and the `b-worker` body on both runtimes.
  The command is now an unknown command.
- Single `worker_steps` ([ADR-015](ADR-015-step-writer-worker.md)) stay unchanged on
  both runtimes, as do `parallel_checks`
  ([ADR-013](ADR-013-concurrent-plan-checks.md)) and the step gate
  ([ADR-014](ADR-014-checked-plan-steps.md)). Every worker step runs alone in the main
  tree.
- Upgrading in the middle of a parallel batch is not supported, and nothing guards it.
  Finish or discard such a run with the old helpers before reinstalling. A guard was
  tried and dropped during review: it added a `git worktree list` call to every run,
  could match another checkout's worktree, and left other ways into `verify` open.
- Older data stays readable, the way [ADR-021](ADR-021-codex-gate-without-repo-approval.md)
  treated the retired Codex consent:
  - The plan schema keeps `parallel_steps`, so a recorded plan that lists it still
    validates and renders. A new plan that has the key is refused by name.
  - The state history keeps accepting the `worktree` flag.
  - The run-stats schema and writer are unchanged, so stored lines stay valid and new
    lines count 0 ([ADR-035](ADR-035-local-run-stats.md)).
- The kernel sentence "a `b-worker` per approved worker step, never two in a tree"
  stays: it is still true.
- No installer change: an unmodified installed copy of the removed module is retired
  through the install manifest, and a modified copy is kept with a warning and
  imported by nothing.
- Upgrading while the installer keeps a locally edited `b-state` helper is not
  supported. The installer keeps or replaces each file on its own, so a kept old
  helper can still import the removed module or a removed export, and `b-state` then
  fails to start. Move the edited file aside and run the installer again, or pass
  `--force`, which backs up and replaces every modified managed file, not only that
  one. An installer check that refuses such a mixed set is not part of this change.

## Consequences

- Two independent worker steps can no longer run at the same time.
- No helper lists a leftover `b-agentic-wt-*` git worktree any more, so `record step`
  can accept a parallel step whose change is still only in that worktree. If you find
  one with `git worktree list`, look at its changes and bring what you need into the
  main tree before you remove it with `git worktree remove`.
- An unfinished run that listed parallel steps and has no such worktree continues with
  its worker steps one at a time.
- Three items may now be unused and were kept because that was not established: the
  `hardened` option of `worktreeTree`, the `b-run worker-profile` folder walk outside
  the repository, and the Pi `subagent_launch` permission.

Evidence: [`claude/bin/b-state.mjs`](../../claude/bin/b-state.mjs),
[`claude/bin/b-state-record.mjs`](../../claude/bin/b-state-record.mjs),
[`claude/bin/b_run_lib.py`](../../claude/bin/b_run_lib.py),
[`references/artifacts.yaml`](../../references/artifacts.yaml),
[`references/runtimes.yaml`](../../references/runtimes.yaml),
[`skills/b-flow/prompt.md`](../../skills/b-flow/prompt.md),
[`tests/state/cases/pi.sh`](../../tests/state/cases/pi.sh), and
[`tests/artifacts/artifact-probe.sh`](../../tests/artifacts/artifact-probe.sh).
