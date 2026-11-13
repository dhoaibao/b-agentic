# b-flow: phase contracts, packets, and the step cursor

Status: implemented

## Goal

Every phase of a `/b-flow` run is briefed from the run folder and leaves a record in
it, so the main session can hand a phase to its skill without relying on memory. This
is the first stage of the run-first design; it refines
[ADR-009](../decisions/ADR-009-b-flow-automatic-run.md),
[ADR-010](../decisions/ADR-010-run-artifact-cli.md), and
[ADR-001](../decisions/ADR-001-b-agentic-design-record.md) in place.

## Requirements

- Each skill in `skills/registry.yaml` has a `contract`: its role (`phase`,
  `provider`, `utility`, or `orchestrator`) and, for phase skills and providers, its
  run phases, the evidence it returns, and whether it leaves the worktree unchanged
  (`parallel_safe`). The generator validates the contracts against the run CLIs and
  renders the phase table into the `b-flow` skill for both runtimes.
- `b_run.py handoff <phase>` renders a packet for clarify, implement, verify, review,
  fix, qa, and commit. The review and QA packets are unchanged.
- `b-state.mjs record step S-n` records a plan step as applied; `advance verify` from
  `implement` needs every step recorded; `check` lists the steps still owed.
- A plan step may carry `depends_on`. Without it a step waits for the step before it;
  an empty list means it waits for none.
- No state or artifact schema version change, no new file in the run folder, and no
  kernel change.

## Acceptance criteria

- AC-1: WHEN `advance verify` runs in `implement` with a plan step unrecorded THEN it
  is refused, the missing ids are named, and the state is unchanged. Evidence:
  `bash tests/state/state-probe.sh`.
- AC-2: WHEN `record step S-n` runs outside `implement`, with an unknown id, or with a
  dependency unrecorded THEN it is refused; WHEN it is valid THEN the step is recorded
  with its fingerprint and one history entry. Evidence: `bash tests/state/state-probe.sh`.
- AC-3: WHEN `approve`, `unblock implement`, or `unblock clarify` runs THEN the step
  record is empty; WHEN `unblock fix|verify` runs or `check` voids evidence THEN it is
  kept. Evidence: `bash tests/state/state-probe.sh`.
- AC-4: WHEN `check` runs in `implement` THEN `next` names the packet command, each
  unrecorded step's `record step` command, and `advance verify`. Evidence:
  `bash tests/state/state-probe.sh`.
- AC-5: WHEN `b_run.py handoff <clarify|implement|verify|fix|commit>` runs THEN it
  prints that phase's packet; the review and QA packets are byte-identical to before;
  an unknown phase is invalid; `--out` inside the repository is refused. Evidence:
  `bash tests/artifacts/artifact-probe.sh`, plus a one-off comparison of the review and
  QA packets against the previous CLI.
- AC-6: WHEN `depends_on` names its own, a later, or an unknown step THEN lint refuses;
  WHEN a plan has no `depends_on` THEN it renders byte-identical to before. Evidence:
  `bash tests/artifacts/artifact-probe.sh`.
- AC-7: WHEN an existing run is loaded THEN `show` and `validate` succeed. Evidence:
  `node claude/bin/b-state.mjs show --run <id>` and
  `python3 -I -B claude/bin/b_run.py validate --run <id>` for each run under
  `.b-agentic/runs/`, plus the legacy-state case in `tests/state/state-probe.sh`.
- AC-8: WHEN a contract has an invalid role or phase, or a run phase has no phase skill
  THEN the generator fails; WHEN the registry is current THEN both runtimes' `b-flow`
  skill carries the table. Evidence:
  `python3 tooling/generate/registry_sync.py --self-test --check`.
- AC-9: WHEN all checks run THEN the kernel is unchanged and every suite passes.
  Evidence: `scripts/validate-skills.sh`, `npm run quality`, `git diff --check`.

## Out of scope

- Change requests entering a run automatically, and quick runs (the next stage).
- Writer workers and parallel execution.
- Checking a recorded step against the paths it changed.
- Recording which review gate ran.
