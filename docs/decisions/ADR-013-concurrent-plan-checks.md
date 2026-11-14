# ADR-013: Plan checks that may run together

- Status: Accepted
- Date: 2026-11-14
- Supersedes: none (refines the `record check` coupling of
  [ADR-010](ADR-010-run-artifact-cli.md), the verify bound of
  [ADR-009](ADR-009-b-flow-automatic-run.md), and the quick limits of
  [ADR-012](ADR-012-run-first-entry.md))

## Context

Stage 3 of the run-first design asked for read-only parallelism inside a `b-flow` run,
in two parts: plan checks that run at the same time, and QA evidence gathered while the
review runs. Both were measured before either was built.

- **Checks.** The verify phase runs the plan checks one after another, so it costs
  their sum, and every fix round repeats it. In this repository the four required
  checks took about 262 s in sequence, 248 s of that in the release validation alone,
  so running them together saves about 14 s (5%) per round. A repository whose lint,
  type check, tests, and build take similar times would save more; that was not
  measured.
- **Binding.** `record check` bound a result to the candidate fingerprint at the moment
  of recording, not at the moment the check started. With one check at a time the two
  are the same; with several running they are not.
- **QA during review.** QA already reuses the checks recorded in verify: a QA row's
  command must be the spec command or a plan check. Only the reading for `inspection`
  criteria could move earlier, it is thrown away on every `NEEDS FIXES`, and a command
  that moves the fingerprint while the review runs voids that review.

## Decision

- **Opt-in list.** A plan may carry `parallel_checks`: at least two of its checks, each
  once. Those may run at the same time; every check not listed runs alone, which stays
  the default. The list is part of the approved plan, so the user accepts it in the
  approval round.
- **What "may run together" means.** A listed check writes nothing inside the
  repository except ignored caches no other listed check reads; shares no port, fixed
  temporary path, lock, database, server, browser profile, or ignored output directory
  with another listed check; does not depend on another check's result or on order;
  and needs no prompt. The helper cannot observe processes, so it enforces only what
  follows.
- **Bound to the candidate it started on.** `record check` takes `--from`, the
  fingerprint the check started on, which `next` prints with the listed checks. It is
  required for a listed check and optional for the others. A result is recorded only
  when the candidate still has that fingerprint. `--from` with an `--include-ignored`
  set other than the recorded one is refused, because a different set is a different
  candidate.
- **A candidate that moved.** A check whose `--from` is no longer the candidate records
  no result, counts as one failed verify attempt (the run still blocks at 3), and
  leaves its reason in the history. The retries are therefore bounded and traceable.
- **Quick runs.** A quick run with `parallel_checks` is refused: it has no approval
  round, so nobody would have accepted the list.
- **Runtimes.** On Claude Code the listed checks start as separate background commands
  and are recorded one at a time after every one has finished. Pi has no background
  commands ([ADR-011](ADR-011-pi-second-runtime.md)), so it runs the same checks one at
  a time with the same `--from` and reaches the same state.
- **Unchanged.** The helper still never runs a check (ADR-010). The kernels are
  byte-unchanged: checks are commands, not child sessions, and they run in verify,
  before the review freeze. The registry's `parallel_safe` flag describes skills and
  stays unused. State and artifact schema versions stay 1, and a plan without the field
  keeps its bytes, its packets, and its `next` lines.
- **QA evidence is not gathered during review.** QA stays strictly after the review
  verdict, for the reasons in the context.

## Consequences

- The gain is bounded by the longest check: about 5% of a verify round here, more
  where checks are of similar length.
- Interference through ignored paths, ports, or temporary files does not move the
  fingerprint, so the helper cannot detect it. The approval of the list is the only
  safeguard, which is why the list is opt-in and refused in a quick run.
- Each lost check of one batch counts as a failed attempt, so three can block a run in
  one round, as three failing checks already do (ADR-009). The `b-flow` prompt
  therefore stops recording a batch at the first lost check and starts again from
  `check`.
- Ignored artifacts the candidate includes are named on a check that runs alone,
  before the listed ones. A plan whose checks are all listed cannot include one.
- The history timestamps already give the time of each verify round; no duration field
  was added. Runs recorded before the history existed give no baseline, so the first
  comparison needs runs made from now on. Parallel writers (stage 5) are to be decided
  on such measurements.
- Rejected: the helper running the checks itself (ADR-010 already rejected a hidden
  executor); all checks together by default with a list of exceptions (an unsafe
  default); a lease or "in flight" field in the state (self-reported, since the helper
  cannot see processes); turning each check into an object with group labels (changes
  the type of `checks`, and named groups are not needed yet); recording acceptance
  results during review (needs the QA matrix before the verdict, or new state kinds);
  reading for QA during review with no helper support (prompt-only, tiny saving);
  consuming `parallel_safe`; a new kernel line; blocking the run at the first moved
  candidate (one stray temporary file would stop it); a plain refusal that writes
  nothing (unbounded retries with no trace).

Evidence: [`references/artifacts.yaml`](../../references/artifacts.yaml),
[`claude/bin/b_run.py`](../../claude/bin/b_run.py),
[`claude/bin/b-state.mjs`](../../claude/bin/b-state.mjs),
[`skills/b-flow/prompt.md`](../../skills/b-flow/prompt.md),
[`tests/state/state-probe.sh`](../../tests/state/state-probe.sh),
[`tests/artifacts/artifact-probe.sh`](../../tests/artifacts/artifact-probe.sh).
