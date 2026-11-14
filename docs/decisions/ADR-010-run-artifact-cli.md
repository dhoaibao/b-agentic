# ADR-010: A single writer for `b-flow` run artifacts

- Status: Accepted
- Date: 2026-11-12
- Supersedes: none (refines the "Run files" and "State helper" bullets of
  [ADR-009](ADR-009-b-flow-automatic-run.md))

## Context

[ADR-009](ADR-009-b-flow-automatic-run.md) made `state.json` machine-checked, but
`spec.md`, `plan.md`, `qa.md`, and `followups.md` are still written by the model with
native `Write`, following prose. Their structure therefore drifts: acceptance ids are
found by a regex, check commands are unconstrained, the QA matrix and the recorded
`AC-n` results are separate self-reports, and the scope stop-condition has no scope list
to compare against.

## Decision

- **One writer.** `claude/bin/b_run.py` (Python 3.11+, standard library only, run as
  `python3 -I -B`) is the only writer of the four artifacts. It reads JSON on stdin,
  validates it against [`references/artifacts.yaml`](../../references/artifacts.yaml),
  checks the artifact's phase and its cross-artifact rules, renders canonical markdown
  from the validated data, and writes it atomically. `artifacts.json` records each
  artifact's sha256 and validated data, so `validate` re-renders and compares bytes
  instead of parsing free-form markdown.
- **Schemas are data.** `references/artifacts.yaml` (JSON-compatible YAML) owns the
  field grammar, enums, limits, allowed run files, and an example per kind. The CLI, the
  generator check, and the artifact probe all read it; `b_run.py schema <kind>` prints
  the exact shape for the model. Rendering and the few cross-field rules stay in code.
- **Enforcement in three layers.** The path guard refuses native `Edit`, `Write`, and
  `NotebookEdit` on any `.b-agentic` path (`Read` stays allowed). `b-state` requires
  `b_run.py validate` to pass, and the spec and plan hashes it recorded at approval to
  match, before `approve` and every `advance`. A Bash write is not prevented but is
  detected as a hash mismatch or an unknown file in the run folder, which blocks the
  run. Hand-editing `state.json` or `artifacts.json` through Bash stays an accepted
  residual risk, the same tripwire-not-boundary stance as ADR-009.
- **State couples to the artifacts.** `record check` refuses a command that is not in
  the validated plan's `checks` (a check the plan lists to run with others is recorded
  with the fingerprint it started on,
  [ADR-013](ADR-013-concurrent-plan-checks.md); refined 2026-11-14); `advance` to `review` or `qa` runs `b_run.py
scope-check` against the spec's scope globs; `record qa` and `record ac` must match
  the validated `qa.md`; the handoff packet of every run phase a skill is briefed for
  (clarify, implement, verify, review, fix, QA, commit; refined 2026-11-13) comes from
  `b_run.py handoff`, not from hand-written focus text, and its sections are defined in
  that CLI. A plan step may carry `depends_on` (earlier steps only); a step without it
  waits for the step before it. The commit consent is a `consent` block
  in `spec.md`: `approve` refuses flags that differ from it, `advance commit` needs
  it to say yes, and `check` blocks a `state.json` whose consent differs. `approve`
  also refuses a working tree with changes, so pre-existing edits cannot join the
  candidate. `advance review` requires `--trigger` and records it, which also bars a
  later `--low-risk` exception once a review was triggered or held. Blockers found by
  review or QA are recorded in `followups.md` with `kind: blocker` and, once fixed, a
  `sweep` line; the re-review handoff lists them under "Prior review".
- **Language split.** `b-state.mjs` stays Node because it shares candidate-fingerprint
  code with the snapshot CLI and the Codex guards; each file under `.b-agentic` still
  has exactly one writer. A Python port is not part of this decision.
- **Vocabulary.** One set of values everywhere: evidence `automated | browser | ci |
inspection | user-confirmed`; criterion result `pass | fail | gap | waived`
  (`waived` only by the user); disposition `open | fixed | deferred | rejected`.

## Consequences

- Artifact structure is stable across sessions and models, and tamper is detected.
- The installer ships `b_run.py` next to the `.mjs` files and `artifacts.yaml` next to
  the other references; the generator checks the schema file and that the Python
  protected-path mirror matches the Node rules.
- A skill prompt asks the model for JSON that `b_run.py schema` describes instead of
  prose structure. The kernel is unchanged (it has no byte headroom).
- Skill `references/` bundles are a separate, later change.
- Rejected: schemas embedded in the CLI (no shared readable source for the generator);
  parsing model-written markdown (fragile); the CLI running check commands (a hidden
  executor that bypasses permissions); signed artifacts (the key would sit where the
  model can read it); third-party validation libraries (the only install prerequisite
  is `python3`); a Bash ask-tripwire (best effort, more prompts); a Python port of
  `b-state` now (about 1,250 lines of fail-closed logic to re-review).

Evidence: [`claude/bin/b_run.py`](../../claude/bin/b_run.py),
[`references/artifacts.yaml`](../../references/artifacts.yaml),
[`claude/bin/b-state.mjs`](../../claude/bin/b-state.mjs),
[`claude/hooks/b-path-guard.mjs`](../../claude/hooks/b-path-guard.mjs).
