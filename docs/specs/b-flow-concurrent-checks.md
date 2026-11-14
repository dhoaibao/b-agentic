# b-flow: plan checks that may run together

Status: implemented

## Goal

Cut the wall-clock time of a run's verify phase without weakening a guard: checks the
approved plan lists may run at the same time, and each result still belongs to exactly
one candidate. Decided in [ADR-013](../decisions/ADR-013-concurrent-plan-checks.md),
which also records why QA evidence is not gathered while the review runs.

## Requirements

- A plan may carry `parallel_checks`: at least two of its checks, each once. Every
  check not listed runs alone. A plan without the field keeps its bytes, its packets,
  and its `next` lines.
- `check` in verify names the listed checks still owed in one `next` line, with the
  current candidate fingerprint as `--from`.
- `record check` needs `--from` for a listed check and records the result only when
  the candidate still has that fingerprint. Otherwise it records no result, counts one
  failed verify attempt (the run blocks at 3), and leaves the reason in the history.
- `--from` with an `--include-ignored` set other than the recorded one is refused.
- A quick run with `parallel_checks` is refused.
- Claude Code starts the listed checks as background commands; Pi runs them one at a
  time with the same `--from`. Neither kernel changes.
- No state or artifact schema version change, and the state helper never runs a check.

## Acceptance criteria

- AC-1: WHEN a plan lists `parallel_checks` with a command not in `checks`, a
  duplicate, or fewer than two entries THEN lint and write refuse it; a plan without
  the field renders byte-identical to before. Evidence:
  `bash tests/artifacts/artifact-probe.sh`.
- AC-2: WHEN `handoff verify` runs for a plan with `parallel_checks` THEN the packet
  marks the listed checks; packets of plans without the field are byte-identical.
  Evidence: `bash tests/artifacts/artifact-probe.sh`.
- AC-3: WHEN `check` runs in verify with listed checks owed THEN `next` names them in
  one line with the current fingerprint as `--from`, and other owed checks keep their
  line. Evidence: `bash tests/state/state-probe.sh`.
- AC-4: WHEN `record check` runs for a listed check with `--from` equal to, different
  from, or without a fingerprint THEN it records, counts a failed attempt without a
  result (blocking at the third), or is refused with the state unchanged. Evidence:
  `bash tests/state/state-probe.sh`.
- AC-5: WHEN `record check` combines `--from` with an `--include-ignored` set that
  differs from the recorded one, or `approve --size quick` meets `parallel_checks`
  THEN it is refused with the reason named. Evidence:
  `bash tests/state/state-probe.sh`.
- AC-6: WHEN the generator renders `b-flow` THEN the Claude Code skill names background
  commands for listed checks, the Pi skill runs them one at a time with no forbidden
  token, and the kernels are unchanged. Evidence:
  `python3 tooling/generate/registry_sync.py --self-test --check`.
- AC-7: WHEN the decision record validator runs THEN ADR-013 passes and is listed.
  Evidence: `python3 tooling/validate/decision_design.py`.
- AC-8: WHEN existing runs under `.b-agentic/runs/` are loaded THEN `show` and
  `validate` succeed for each. Evidence: inspection, both commands for each run folder.
- AC-9: WHEN every required check runs THEN all pass. Evidence:
  `scripts/validate-skills.sh --release`.
- AC-10: WHEN a live Claude Code full run has `parallel_checks` THEN the listed checks
  start as background commands and the run reaches the same recorded state as a
  sequential run. Evidence: user-confirmed in a real session after `install.sh`; no
  automated harness exists.

## Out of scope

- QA evidence gathered while the review runs.
- Consuming the registry's `parallel_safe` flag.
- Running the suites of `tooling/validate/run.sh` in parallel.
- Writer workers and parallel writers (later stages).
- Per-check duration fields in the state.
