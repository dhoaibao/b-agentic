# ADR-038: A new blocker names its class and the stage it escaped

- Status: Accepted
- Date: 2026-11-26
- Supersedes: [ADR-010](ADR-010-run-artifact-cli.md) in part: its rejection of a required `blocker_class`, and its rule that a rewrite never changes a recorded `escaped_from`

## Context

[ADR-010](ADR-010-run-artifact-cli.md) made `blocker_class` and `escaped_from` optional, because a
required class could block a run mid-review. The `b-flow` prompt asks for both, but nothing checks
them. In the 66 runs that the [ADR-035](ADR-035-local-run-stats.md) store held before this
decision, its 132 blockers were all counted `unclassified` for both fields, so the numbers could not
say what review finds or which earlier stage misses it. Most were recorded before the fields
existed, so this does not show how often a prompt alone fills them.

The risk ADR-010 named is small: `b-run write` refuses invalid input before it writes any file and
never writes state, so the same findings can be written again with the missing field added. Every
`b-review` blocker already belongs to one of the classes.

## Decision

- **Required on new blockers.** `b-run write` and `lint` refuse a `kind: blocker` item whose id the
  recorded follow-ups lack unless it has both `blocker_class` and `escaped_from`, for a review or QA
  source and every disposition. Other items keep both fields optional.
- **`unknown`.** `escape_stage` gains `unknown`, for a stage that is not known, on any review or QA
  item. The earlier-than-source rule for named stages is unchanged.
- **One refinement.** A rewrite may replace a recorded `escaped_from: unknown` with a stage earlier
  than the source, since the cause is often found only at the fix. A named stage never changes, and
  no recorded value is dropped.
- **Input only.** The requirement is checked on new input, never on recorded data. A blocker
  recorded without the fields stays as it is through later rewrites, which may still add either
  once, and older runs still validate and render byte for byte. A run started before this rule
  needs the fields only on blockers it records afterwards.
- **Only what the schema can record.** Both installers keep a user-edited `artifacts.yaml`, so a
  newer helper can run beside an older schema. It then requires `blocker_class` only when that
  schema has the field, and `escaped_from` only when it also offers `unknown`, so a writer is never
  made to invent a stage.
- **`lint` reads the record.** `lint` now loads the run's recorded follow-ups as `write` does; it
  did not before, so it also missed a dropped id or a changed value. With no run to read, it treats
  every blocker as new.

## Consequences

- New blockers can be counted by class and stage. `unknown` is its own run-stats key, apart from
  `unclassified`, which still means the field is absent.
- The fields are model-reported: the helper checks that a value is in the list, not that it is
  right, and a careless writer can answer `unknown` every time.
- The compatibility runs one way. An older helper, or an older user-edited `artifacts.yaml`, rejects
  run data that says `unknown` and counts a run-stats line with that key as malformed. Reinstalling
  that runtime updates its reader, unless its `artifacts.yaml` was edited: that copy is kept, and
  the requirement stays reduced until the user takes the new schema.
- Rejected: a warning only (the data could stay missing); applying the rule to recorded data (older
  runs would stop validating); requiring only `blocker_class` (the user chose both); keeping a
  recorded `unknown` final (it would lose the cause found at the fix); an `unknown` blocker class (a
  blocker is defined by its class).

Evidence: [`claude/bin/b_run.py`](../../claude/bin/b_run.py),
[`references/artifacts.yaml`](../../references/artifacts.yaml),
[`tests/artifacts/artifact-probe.sh`](../../tests/artifacts/artifact-probe.sh).
