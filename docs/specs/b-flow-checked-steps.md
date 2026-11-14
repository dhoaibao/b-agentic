# b-flow: a plan step is checked when it is recorded

Status: implemented

## Goal

What a plan step changed is checked against the approved scope when the step is
recorded, not after the last step, and each step leaves measurements in the history.
This is the first unit of the writer-worker stage and serves every run, whoever applies
the step. Decided in [ADR-014](../decisions/ADR-014-checked-plan-steps.md).

## Requirements

- Entering `implement` and every recorded step store a step base: the working tree as
  a tree id, its fingerprint, `HEAD`, and the state revision of that write.
- `record step` refuses a step whose changes since the base include a path outside the
  spec scope or a likely-secret path. Nothing is recorded, the base stays, the reason
  and (for a scope path) the rejected tree id go to the history, and the refusal is
  counted; the third in a row blocks the run and a recorded step resets the count.
- A changed path inside the scope but outside the step's own paths is counted, not
  refused.
- `record step` blocks the run when the run state was written or `HEAD` moved since
  the step base.
- A recorded step's history entry carries its tree id, its changed-path count, and how
  many of those paths are outside its own paths. No duration field.
- `scope-check` accepts `--base`, `--tree`, and `--step` together and classifies the
  paths that differ between two tree ids; without them its output is unchanged.
- No likely-secret file is added to a tree and no such path name enters the state. The
  helper never restores files.
- No state or artifact schema version change; packets and `next` lines keep their
  bytes; no kernel, registry, or agent profile change.

## Acceptance criteria

- AC-1: WHEN `record step S-n` runs and every path changed since the step base is
  inside the spec scope THEN the step is recorded and its history entry carries the
  tree, the changed-path count, and the count outside its own paths. Evidence:
  `bash tests/state/state-probe.sh`.
- AC-2: WHEN the paths changed since the step base include one outside the spec
  scope, or a likely-secret path leaves the snapshot incomplete THEN `record step`
  exits 3 with `recorded: false`, the history holds the reason (the rejected tree id
  only for a scope path, a count only for likely-secret paths), and the refusal count
  grows by one. Evidence: `bash tests/state/state-probe.sh`.
- AC-3: WHEN the gate refuses `record step` a third time in a row THEN the run is
  blocked, and a recorded step before that resets the count. Evidence:
  `bash tests/state/state-probe.sh`.
- AC-4: WHEN the run state was written or `HEAD` moved after the step base THEN
  `record step` blocks the run. Evidence: `bash tests/state/state-probe.sh`.
- AC-5: WHEN a state written before this change is loaded THEN it validates under
  schema 1 and `record step` behaves as before until `implement` is entered again.
  Evidence: `bash tests/state/state-probe.sh`.
- AC-6: WHEN `scope-check` runs with `--base`, `--tree`, and `--step` THEN it reports
  the outside-scope and likely-secret paths of the delta and the changed and
  outside-step counts, and without those flags its output is unchanged. Evidence:
  `bash tests/artifacts/artifact-probe.sh`.
- AC-7: WHEN the change is compared with the existing probes THEN no existing
  next-line, packet, or scope-check assertion is changed or removed. Evidence:
  inspection of the diff of both probe files.
- AC-8: WHEN the generated outputs are checked THEN the `b-flow` skill renders for
  Claude Code and Pi with no stale output. Evidence:
  `python3 tooling/generate/registry_sync.py --self-test --check`.
- AC-9: WHEN the release validation runs THEN it passes. Evidence:
  `scripts/validate-skills.sh --release`.

## Out of scope

- The `b-worker` profile, its packet, its prompt wiring, and the kernel sentence it
  needs (a later unit, after probes of the harness).
- A plan field naming worker steps.
- Refusing a path outside a step's own paths that stays inside the scope.
- Duration fields.
