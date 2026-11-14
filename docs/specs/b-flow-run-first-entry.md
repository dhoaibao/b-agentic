# b-flow: change requests enter a quick or full run

Status: implemented

## Goal

Change work runs inside a `b-flow` run by default, so its acceptance, checks, and
result are recorded, without making a small edit pay for a clarification and approval
round. Decided in [ADR-012](../decisions/ADR-012-run-first-entry.md).

## Requirements

- The kernel routes a change that would go to `b-implement`, `b-frontend`,
  `b-refactor`, or `b-test` to `b-flow`; a `/b-<name>` the user types runs standalone;
  questions, lookups, and utilities start no run.
- A spec may carry `size: quick`. The state helper decides whether a run may be quick:
  at most 3 plan steps, 3 criteria with automated or inspection evidence, 5 literal
  scope paths, no answers, and consent `commit: no`, `current`, `reviewer`.
- A quick run takes the request as its approval, never commits, keeps `b-qa`, and is
  blocked by a review trigger until the user approves a full run.
- A run without commit consent ends with `advance done` from `qa`, on the same
  evidence as the commit gate.
- A run may start on a tree that already has changes when it does not commit: `init`
  records those paths by content digest and the scope check ignores them while their
  content is the same. A run that may commit still needs a clean tree at approval.
- `init` refuses while another run is unfinished; `--replace` leaves it on the user's
  answer.
- No state or artifact schema version change, no new file in the run folder, and both
  kernels within their size limit.

## Acceptance criteria

- AC-1: WHEN `approve --size quick` breaks a quick limit, or the size differs from the
  spec THEN it is refused with the condition named. Evidence:
  `bash tests/state/state-probe.sh`.
- AC-2: WHEN a quick run runs `advance review --trigger T` THEN the run is blocked with
  `needs: full-run approval`. Evidence: `bash tests/state/state-probe.sh`.
- AC-3: WHEN a run without commit consent has a current QA PASS and every criterion
  passed or waived THEN `advance done` succeeds; otherwise it is refused, and a run
  with commit consent is refused too. Evidence: `bash tests/state/state-probe.sh`.
- AC-4: WHEN `init` runs while an unfinished run is active THEN it is refused with that
  run named; `--replace` proceeds. Evidence: `bash tests/state/state-probe.sh`.
- AC-5: WHEN a run starts on a tree with changes THEN unchanged pre-existing paths pass
  the scope check and are listed apart in the packets, a pre-existing path the run
  changes is checked against the scope, and commit consent `yes` is refused. Evidence:
  `bash tests/state/state-probe.sh`.
- AC-6: WHEN the generator runs THEN the `b-flow` kernel line is the entry line naming
  exactly the implement-phase skills, `b-commit` and `b-pr` keep "only on explicit user
  request", and both kernels are within their limits. Evidence:
  `python3 tooling/generate/registry_sync.py --self-test --check`,
  `python3 tooling/validate/behavior.py`.
- AC-7: WHEN the static routing corpus runs THEN change prompts classify to their phase
  skill and `b-flow` wins only when named. Evidence:
  `python3 tooling/validate/behavior.py`.
- AC-8: WHEN an optional component is excluded at install THEN exactly its routing line
  is removed. Evidence: `scripts/validate-skills.sh --release`.
- AC-9: WHEN Pi output renders THEN no forbidden token appears. Evidence:
  `python3 tooling/generate/registry_sync.py --check`.
- AC-10: WHEN a spec without `size` is written THEN its bytes are as before, and the
  existing runs load and validate. Evidence: `bash tests/artifacts/artifact-probe.sh`,
  and `b-state.mjs show` with `b_run.py validate` for each run under `.b-agentic/runs/`.
- AC-11: WHEN a live session gets a change request or a typed `/b-<name>` THEN it
  enters a run or runs that skill standalone. Evidence: user-confirmed in a real
  session on each runtime; no automated harness exists.

## Out of scope

- Read-only parallelism, writer workers, and parallel writers (later stages).
- Continuing after compaction without an explicit `/b-flow resume`.
- Recording which review gate ran.
