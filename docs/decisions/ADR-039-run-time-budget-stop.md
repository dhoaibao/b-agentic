# ADR-039: A run stops for the user on a time budget

- Status: Accepted
- Date: 2026-11-27
- Supersedes: none; refines [ADR-009](ADR-009-b-flow-automatic-run.md) (the bounds of a run) and [ADR-035](ADR-035-local-run-stats.md) (the stored fields)

## Context

Every bound in [ADR-009](ADR-009-b-flow-automatic-run.md) counts rounds: failed checks,
`NEEDS FIXES`, `QA FAIL`. None counts time, and an unblock starts those counts again, so a
run can go on for more than an hour while each bound still holds. In the 69 runs the
[ADR-035](ADR-035-local-run-stats.md) store held before this decision, the seconds outside
clarify and blocked had a median of 429 and a 90th percentile of 2,795; 7 runs passed
2,700 seconds. The user decides whether a long run is still worth it, and no point of the
run asked.

`unblock` could not serve as the way back: it voids all evidence, resets every attempt
counter, and offers no return to review or QA. Using it for a time stop would cost more
time and give the review loop a fresh count.

## Decision

- **Budget.** `approve` adds `budget: {phase_s, stop_at_s}` to `state.json`. Every later
  state write adds the seconds since the previous write to the phase the run was in on
  disk, for `approved`, `implement`, `verify`, `review`, `fix`, `qa`, and `commit`.
  Clarify and blocked time never count; all other time does, a break the user takes
  included. A later approval keeps what was counted. The first mark is 2,700 seconds,
  and neither it nor the later window can be configured.
- **Stop.** After a successful `check`, `advance`, or `record`, in the same mutex, a run
  whose counted time (the time since the last write included) is at the mark moves to
  `blocked` with the reserved reason `run time budget reached`. The command's own result
  stays recorded; it then returns `ok: false` (exit 3) with `time_stop`: counted seconds
  per phase, the review round count, and the open blocker ids. `check` repeats that report
  in `next`; it applies the stop before it builds those lines, so a failure to build
  them cannot skip it. A refused command writes nothing and never stops the run. Nothing is
  interrupted: the stop acts only when the helper is called.
- **Where it waits**, for the next eligible call:
  - a run with no `budget`, which was approved before this decision: no budget is added
    later, except by a new approval;
  - a call that leaves the run in `clarify`, `blocked`, `commit`, or `done`;
  - while a worktree of the run exists, so a parallel worker's record keeps its phase;
  - `check` in `review` before a verdict, so a running review can still record one;
  - every other command.

  It waits only for a worktree known to exist. When the artifacts or the worktree list
  cannot be read, the run stops all the same, and the report gives no open blockers as
  unknown rather than none: a stop loses nothing, and a skipped one could let the run
  reach `commit` without the user.

- **Continue.** `unblock continue --reason R` leaves only a time stop, back to the phase
  it interrupted. It voids nothing and resets no counter, commit, step, or review field.
  It still needs the approved spec and plan unchanged, valid artifacts, and matching size
  and consent. A step base that was current until the stop stays current, so a plan step
  in progress can be recorded; one already stale stays stale. The next mark is 2,700
  counted seconds later. The candidate is judged as always: if it changed meanwhile, the
  next `check` voids the evidence. `advance blocked` refuses the reserved reason.
- **The reason stays.** A `check` that finds a problem on a time-stopped run (a changed
  branch, spec, artifact, or `HEAD`, or a read that fails once) reports it and keeps the
  time-stop reason, so a passing failure cannot take `continue` away. `continue` repeats
  each blocking test of `check` that applies to a phase it returns to: the repository,
  branch, and `HEAD` (on the run's baseline or a recorded commit) as well as the gates
  above, so it cannot carry evidence to another checkout. It leaves the candidate's
  content to the next `check`. An explicit `advance blocked` still replaces the reason.
- **Other unblocks.** `unblock <phase>` keeps its rules. When the counted time has reached
  the mark, it also opens a new window, so one user decision is never followed at once by
  a second stop. A quick run that met a review trigger is blocked for that trigger, so
  `continue` is refused.
- **State compatibility.** `budget` is optional, so `schema` stays 1, and the stop adds an
  ordinary `advance` history entry with its reason.
- **Run-stats.** A line gains `time_stops`, the number of history entries that blocked the
  run for this reason; `blocked_count` still counts every block. The field is optional:
  the summary counts an older line as missing it, never as zero. A trimmed history makes
  the number a lower bound, as it does `blocked_count`.

## Consequences

- A long run now asks the user at least once per 45 counted minutes of helper activity,
  with the numbers needed to decide.
- The measure is wall-clock time between helper writes, so idle time outside clarify and
  blocked counts, and a stop can come late: after one long command or subagent returns.
- It limits how long a run goes on unasked, not how long its work takes. Slow checks and
  review loops keep their causes.
- Both runtimes use the same helpers; each needs a reinstall to get the stop.
- The compatibility runs one way, as for other run-stats fields: an older helper counts a
  line with `time_stops` as malformed. A user-edited `artifacts.yaml` that an install kept
  has no such field, so lines are written without it, and `stats` and `stats --summary`
  set it aside on the lines the other runtime wrote.
- Rejected: reusing `unblock <phase>` for the way back (voids evidence and resets the
  counters); a special case for `unblock <phase>` to the blocked phase (one word with two
  meanings); stopping before the command (loses a finished check or review verdict);
  deriving the time from `history` (it keeps 200 entries); a separate stop flag beside
  the `blocked` phase (every gate would have to read it); a new history operation (an
  older helper would reject the state); stopping only on `advance` (a stuck phase might
  never advance); a configurable budget (not asked for).

Evidence: [`claude/bin/b-state-commands.mjs`](../../claude/bin/b-state-commands.mjs),
[`claude/bin/b-state-store.mjs`](../../claude/bin/b-state-store.mjs),
[`claude/bin/b_run.py`](../../claude/bin/b_run.py),
[`tests/state/cases/budget.sh`](../../tests/state/cases/budget.sh).
