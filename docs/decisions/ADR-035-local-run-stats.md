# ADR-035: A local, numbers-only store of finished run metrics

- Status: Accepted
- Date: 2026-11-25
- Supersedes: none; refines [ADR-010](ADR-010-run-artifact-cli.md) (what a run records) and [ADR-024](ADR-024-prune-old-runs.md) (a pruned run keeps no summary)

## Context

A `b-flow` run leaves its numbers (steps, review rounds, blockers, phase durations) only in its run
folder, and [ADR-024](ADR-024-prune-old-runs.md) deletes a pruned folder fully. Audits read the
current repository only, so evidence about how runs behave in other repositories, or about runs
older than the prune window, is gone. The hook of the verify gate already keeps an on-by-default,
append-only local log under the install home ([ADR-001](ADR-001-b-agentic-design-record.md),
[`claude/hooks/b-verify-gate.mjs`](../../claude/hooks/b-verify-gate.mjs)), and it stores more than this
decision does.

## Decision

- **One line per finished run.** When a run reaches `done`, `b-state` calls
  `b_run.py stats --record --run ID` after the `done` state is saved and ignores any
  failure. The helper appends one JSON line to `run-stats.jsonl` in the runtime's install home:
  `~/.claude/b-agentic` or, under the Pi wrapper folder override, `~/.pi/agent/b-agentic`. Each
  runtime has its own file. A run is written once per store: the writer scans the file for the run's key
  under the file lock. Every path (live, by name with `--run`, and catch-up) writes only the runs of its own runtime, so a run never enters both stores. A crash between the save and the append loses one line, which
  `b_run.py stats --record` without `--run` adds back.
- **On by default, off by a flag file.** The store is created on first use. Any entry named
  `run-stats.off` in the same folder (a file, a folder, a symlink, even a dangling one) means
  nothing is created or appended and the result is `skipped:disabled`. No environment variable
  and no command turns it back on, so the model cannot undo the user's choice. Deleting
  `run-stats.jsonl` deletes the data; turning the store off keeps it.
- **Safe creation.** The helper never creates a folder: the install home must already exist as a
  real folder owned by the user that others cannot write and that a group can write only when it
  is the user's own private group (its only member, by its member list and by the accounts that use
  it as their primary group, and with no POSIX ACL on the folder, since an ACL's group bits are only
  its mask; the installers create the home 775 under umask 002, so a stricter rule would switch the
  store off for most Linux users), or the write is skipped
  with a reason. All later steps go through that folder's file descriptor. The store is created with
  `O_EXCL` and `O_NOFOLLOW` at mode 0600, and an existing store must be a regular file owned by
  the user with one hard link and no group or other access, or it is skipped (a loose mode is never
  changed). Opens are non-blocking and the type is checked afterward, so a FIFO at the store path is
  skipped, never waited on. A line is at most 2 KiB and the file at most about 8 MiB. One writer
  holds `flock`, scans for the run's key, ends an unterminated tail left by an interrupted writer
  with a newline, rechecks the off file as its last step, and writes the line with one `write`; a
  short or failed write is cut back to the size before it. A short race remains: an off file that
  appears between the first check and the creation can leave an empty store, and one that appears
  after the last check and before that single `write` can still let that one line through.
- **Numbers only.** The fields live in a `run_stats` block of
  [`references/artifacts.yaml`](../../references/artifacts.yaml): the run's size, how it ended,
  counts of steps, criteria, and scope paths, seconds per phase, review rounds and gate,
  QA verdict, fix rounds, blocked count, failed checks, commit count, `AC-n` results, and
  blocker counts by the `blocker_class` and `escape_stage` enums. The repository key is a
  hash of the repository's root commits, so it survives a move and holds no name (a shallow clone has no key, since its boundary commits would change it when deepened, so its runs are not recorded); the run key is a
  hash of the repository key, the run id and the time the run was initialised (so two worktrees
  that finish same-day, same-slug runs keep two lines), stored with the run date. Never stored: request,
  summary, or follow-up text, `trigger`, `gate_reason`, branch, commands, paths, commit ids,
  `repo_root`, or the run slug (free text the model writes). The writer checks each record
  against the block, and the generator check refuses a `line` or `text` field there.
- **Reading.** `b_run.py stats` is read-only and prints counts only: lines, valid and malformed
  lines, distinct repositories, this repository's key and lines, its finished runs not yet in the
  store, and whether the store exists or is disabled. `b-agentic-audit` runs it once as a
  housekeeping note. `b_run.py stats --record` without `--run` adds the missing lines for the
  current repository's finished runs, with the same rules; the user runs it per repository.
  Nothing reads another repository's `.b-agentic` folder.
- **Disclosure.** `advance done` reports the outcome as `run_stats` (`written`, `already`,
  `skipped:<reason>` such as `skipped:disabled`, or `failed`). The first creation adds a one-time
  `notice` naming the file and the off switch, which the `b-flow` done step relays.
- **What does not change.** The kernel line that a status snapshot persists no telemetry covers the
  status line, not this store, and stays as it is. [ADR-024](ADR-024-prune-old-runs.md) still deletes
  a pruned run folder fully; the numbers that must outlive it now live outside the folder. The
  helper writing this one file in the install home is a standing exception the user approved on
  2026-11-25, limited to these two paths. Install, sync, and uninstall leave both the store and the
  off file alone, and uninstall keeps a non-empty install home.

## Consequences

- Run numbers outlive `prune`, and an audit can count blockers, review rounds, and durations across
  repositories without reading any run's prose.
- A user whose primary group is shared with other accounts, or whose home is writable by such a group, gets no store until the folder is tightened (`chmod 755`); the skip is reported as `skipped:home-not-private`, never silent.
- The store is default-on local telemetry. Its content is a fixed numeric list, nothing leaves the
  machine, and the user owns the file, but a user who never reads the docs learns of it from the
  one-time notice.
- Nothing rotates or deletes the file; the user removes it by hand, as with the verify-gate log.
- A run that ends blocked, is replaced, or never finishes is not recorded.
- Rejected: opt-in by creating the file or by an enable command (the user chose on by default);
  an environment variable or a disable command as the off switch (per session, or model-settable);
  the repository folder name or a path hash as the repository key (leaks names, or changes when
  the repository moves); the full run id (its slug is free text); writing from the JavaScript
  helper (catch-up and the reader would duplicate the logic); recording at `record commit` (misses
  runs without a commit) or in a separate finalize command (the model can skip it); a `stats_written`
  flag in `state.json` (changes the run schema); one file shared by both runtimes (a Pi-only machine
  has no `~/.claude`); a new reference file or an installer prompt (both installers keep fixed
  lists); a `mkdir` of the install home (a runtime tree outside the installer's manifest);
  automatic rotation or deletion ([ADR-024](ADR-024-prune-old-runs.md) rejected it); guard rules
  protecting the store (the store is not authoritative, the same stance as ADR-009's tripwire).

Evidence: [`claude/bin/b_run.py`](../../claude/bin/b_run.py),
[`claude/bin/b-state-commands.mjs`](../../claude/bin/b-state-commands.mjs), and
[`references/artifacts.yaml`](../../references/artifacts.yaml).
