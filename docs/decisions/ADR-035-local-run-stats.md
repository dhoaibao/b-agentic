# ADR-035: A local, numbers-only store of finished run metrics

- Status: Accepted
- Superseded in part by: [ADR-036](ADR-036-run-stats-kit-version.md) (the list of stored fields, and
  the rule that a line never holds a commit id) and [ADR-037](ADR-037-run-stats-repo-registry.md)
  (that nothing reads another repository's run folders, that the evidence is for the current
  repository only, and the limit of the install-home exception to two paths)
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
  hash of the run id and the time the run was initialised alone (so two worktrees that finish
  same-day, same-slug runs keep two lines, and a change of the repository's root commits, such as
  merging unrelated history or rewriting the root, never makes a recorded run look new), stored with
  the run date. Lines written before this rule hashed the repository key into the run key; a run
  counts as recorded when the store holds either key, and those lines are never rewritten. Never stored: request,
  summary, or follow-up text, `trigger`, `gate_reason`, branch, commands, paths, commit ids,
  `repo_root`, or the run slug (free text the model writes). ([ADR-036](ADR-036-run-stats-kit-version.md)
  adds the kit version fields, one of them the b-agentic kit's own source commit, the only commit id
  the helpers put in a line.) The writer checks each record
  against the block, and the generator check refuses a `line` or `text` field there.
- **Reading.** `b_run.py stats` is read-only and prints counts only: lines, valid and malformed
  lines, distinct repositories, this repository's key and lines, its finished runs not yet in the
  store, and whether the store exists or is disabled. `b-agentic-audit` runs it once as a
  housekeeping note. `b_run.py stats --record` without `--run` adds the missing lines for the
  current repository's finished runs, with the same rules; the user runs it per repository.
  Nothing reads another repository's `.b-agentic` folder.
- **Summary.** `b_run.py stats --summary [--since YYYY-MM-DD] [--section repo|kit]` is read-only
  too. From the two stores it prints one compact JSON line of numbers, enum names, hashes, and
  dates, for an analysis to read, and states no finding, threshold, or warning. `--since` keeps
  the runs dated on or after that day and counts the rest. Each line is checked as the report checks it. A line
  of another version `v` and a repeated run key (the first line wins, the Claude Code store first)
  are counted and left out. A value a line does not have is counted as missing, never read as zero
  or inferred (a line without `runtime` is not given its store's), and seconds come only from
  lines with a complete history. Beside an `artifacts.yaml` without the kit fields, a line's kit
  fields are set aside unchecked and counted, so no line is lost to an older schema. The default
  output gives the totals and the breakdown by runtime; `--section repo` and `--section kit` give
  the breakdown by repository key or kit version instead. At most five repository keys and four
  kit versions (plus the runs without one) are listed and the rest counted, so one output holds at
  most five blocks of a breakdown and does not grow with the store. The bound is for the reader: an
  agent's shell tool cuts a long output (Pi keeps its last 50 KB), which would leave broken JSON,
  and the test holds each output under 30,000 bytes on large synthetic stores. It reads only the
  stores and their off flags, never a run folder, and writes nothing; a disabled store is still
  read, as by the report, and a store that fails after it is opened is reported unreadable without
  hiding the other.
- **Evidence.** `b_run.py stats --evidence [--skip N]` is read-only and gives the text behind the
  blocker counts, for the repository it runs in only: the checkout around the working directory,
  with inherited git environment variables ignored and a git setting that names another worktree
  refused. It reads that repository's run folders live, never a store, and copies nothing into a store, so the numbers-only rule of the store stands.
  Only blockers are printed: their run and id, source, disposition, class, escape stage, summary,
  reason, and sweep line; a missing value is null, since most blockers recorded before the class
  existed have none. A folder counts only when its state says done for its own id, it holds
  regular files only, and the artifact validation passes in full, so a hand edit of one file, a
  linked or odd file, or malformed data leaves that folder alone out, counted and not named. Each level is opened
  without following a link and a run is read from inside its opened folder, so a name swapped for
  a link during the read cannot bring another repository's files in. The output is one line of
  printable ASCII, newest run first, and a page stops before 28,000 bytes, under what an agent's
  shell tool shows; the caller passes `next_skip` back as `--skip`, and starts again from 0 when
  the total changed between pages, since a folder removed between two calls can skip blockers. A
  registry of repository paths and reading another repository are not part of this decision; when
  added, another repository is read only when the caller names it.
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
- Only POSIX ACLs are inspected, and only on a group-writable home. macOS extended ACLs (and an ACL
  on the store itself) are not, so an ACL the user granted to another account on the install home or
  the store would go unseen; the content is non-secret counts that nothing trusts, and the user owns
  every ACL on their own folders.
- Two limits remain of the repository-independent run key. A line written before it (under the
  earlier, repository-based key) is recognised only while the repository's root commits are the ones
  it was written under, so a root change after that line makes a catch-up write the run again. Two
  repositories whose runs share a date-and-slug id and the same initialisation millisecond would
  share a key, and the second run would be skipped as recorded.
- The store is default-on local telemetry. Its content is a fixed numeric list, no helper sends it
  anywhere, and the user owns the file, but a user who never reads the docs learns of it from the
  one-time notice. What a command prints to an agent enters that agent's context and so reaches its
  model provider: counts for the report, and for the summary the numbers, repository keys, kit
  versions, and dates of every repository in the stores.
- The evidence puts free text written during this repository's runs into the agent's context and so
  in front of its model provider. Passing validation shows only that the files agree with each
  other: the hash lies beside the text it covers, so it shows neither who wrote them nor that the
  text is true or harmless, and whoever can write a run folder can write one that passes. The
  state is checked for its phase and run id only; its full rules live in b-state, and a forger of
  those two fields could forge the rest. The text stays untrusted data and grants nothing. A run
  written by an older helper that today's validation rejects would be counted as invalid, not read.
- The summary sees only the stores. A run with one line under the earlier repository-based key and
  another under the current key is counted twice, since telling them apart needs the run folder.
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
  protecting the store (the store is not authoritative, the same stance as ADR-009's tripwire);
  for the evidence, copying blocker text into the store (free text, kept past a prune), paging by
  date (whole days cannot split one large run), by run (one run can exceed a page, and the caller
  would need the ids first), or by a run-and-item cursor (more parsing for little gain), checking
  only the follow-ups artifact (weaker, and no run here fails the full check), and reading
  unfinished runs (their follow-ups can still be rewritten).

Evidence: [`claude/bin/b_run.py`](../../claude/bin/b_run.py),
[`claude/bin/b-state-commands.mjs`](../../claude/bin/b-state-commands.mjs), and
[`references/artifacts.yaml`](../../references/artifacts.yaml).
