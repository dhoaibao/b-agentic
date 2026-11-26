# ADR-037: A registry of checkout paths, so a named repository's evidence can be read

- Status: Accepted
- Date: 2026-11-26
- Supersedes: [ADR-035](ADR-035-local-run-stats.md) in part: its rule that nothing reads another repository's `.b-agentic` folder, evidence being for the current repository only, and the limit of the install-home exception to the store and its off file

## Context

The summary of [ADR-035](ADR-035-local-run-stats.md) shows numbers for every repository in the
stores, but its evidence reads only the repository it runs in. An agent analysing the numbers to
improve b-agentic could not read why another repository's blockers happened, and the stores hold
only a hash that names no folder.

## Decision

- **A second file, with paths.** `stats --record`, the live call at `advance done` included, also
  appends `{"v":1,"repo":KEY,"path":PATH}` to `run-stats-repos.jsonl` in the runtime's install
  home, once for each key and path. It is written by the store's own writer (the same home rules,
  off file, 0600 exclusive create without following a link, lock, torn-tail repair, and single
  write), and is only appended to, up to 1 MiB with lines of at most 4,096 bytes and absolute,
  normalized, printable paths of at most 1,024 bytes. The path is the checkout around the working
  directory; a redirected worktree, and a clone without a key, are not registered. The store stays
  numbers-only.
- **The registry cannot harm recording.** It runs after the store lines are settled, catches every
  failure, and reports only in the new `registry` field. The first creation adds to the notice. The
  caller of the live record stops after 10 seconds and then reports the whole record as failed, so
  registering runs no git and waits for its lock only when the record is less than 2 seconds old.
  The writer and the readers share one line check, so a line the readers reject never counts as
  already listed.
- **Registered paths leave through one command.** `stats --repos` prints keys with paths, bounded
  under 28,000 bytes, and its help says printed paths reach the model provider. No other output,
  refusal, or error gets a path added from the registry or from git. Blocker text is not
  filtered: it is printed as written and can hold paths. The registry is read under the checks it
  is written under.
- **Another repository only by name.** `stats --evidence --repo KEY` takes the key, never a path,
  so only a registered checkout can be read, and nothing is read without `--repo`.
- **A registry line is a hint, checked on what is held.** A path may be stale. Each of the first 4
  paths of a key is opened once without following a link, and then, from inside that held folder,
  it must belong to the user, be the top level git names (holding `.git`), be no partial clone,
  and still have the key. Its runs are read relative to the held folder, with the per-run checks
  of the current repository's evidence. Folders left out are counted by reason, never named.
- **Every checkout of a key is merged**, newest run id first, because the summary counts the runs
  of every clone under one key. Each folder is read once, and each run once: as in the summary, a
  run is its id and start time, so two clones that gave two runs one id keep both. A fork or a
  template copy that shares the root commits shares the key and is read with the rest; the user
  chose to keep this and say so in the help and the docs, with `--repos` to check a key first.
- **git inside another repository.** Every key lookup and the evidence checkout lookup run a git
  found in an absolute `PATH` entry, and drop relative and empty `PATH` and library-path entries
  and the preload variables, since git is started from inside the folder. They also drop every
  inherited `GIT_` variable, set `GIT_NO_LAZY_FETCH` and turn optional locks off, turn the
  filesystem monitor off, close stdin, and stop after 8 seconds; the two runs of one key lookup
  share that limit, to stay under the 10 seconds of the live record. Only `rev-parse`, a `config`
  query, and `rev-list` run. A partial clone is refused for `--repo`, since an older git ignores
  the lazy-fetch variable. As a side effect, an inherited `GIT_DIR` no longer steers any key
  lookup. Finding the current repository, the first git call of every `b-run` command, is
  unchanged by this decision.
- **Removal and off.** A user forgets a checkout by deleting its line or the file; there is no
  command. The off file stops new entries; reading continues and reports the registry as disabled,
  as the summary does for a disabled store. Install, sync, and uninstall leave the file alone. The
  helper writing it in the install home extends ADR-035's standing exception.

## Consequences

- The user's checkout paths, which can name clients or projects, are now kept on disk by default,
  in a file only the user can read, and reach a model provider when `--repos` is run through an
  agent. The one-time notice names the file when it is created.
- `--evidence --repo` puts free text from another repository's runs into the context of an agent
  working in a different one. It is as untrusted as that repository's files, and its checks find
  damage and stray edits, not a forger. It can name paths or projects, `--repos` run or not.
  Redacting was rejected: it cannot catch names or every path, and it would change the evidence.
- Checking a checkout runs git with that repository's own configuration. The commands used run no
  hook, pager, diff driver, or transport; that is a reading of what they do, not a test of each
  setting git has. The folder checked and read must belong to the user. An absolute `PATH` entry
  that itself points into a checkout is still searched, as the user put it there.
- Asking for one project's evidence can print the blocker text of another one that shares its root
  commits, such as a fork or a project made from the same template.
- The checkout's git metadata can still change between the key check and the read; the folder
  that is read stays the one that was opened.
- The two limits of the current evidence now apply to other repositories too: a forged scope
  pattern can stall validation, and so that key's pages, and a run folder removed between two
  pages can skip blockers.
- A repository with very large history may exceed the 8-second lookup and get no key, so its runs
  are not recorded. A repository recorded before this decision is registered the next time
  `stats --record` runs in it.
- A moved checkout leaves a stale line that is counted as gone until the user removes it.
- Rejected: a path in the numbers-only store (breaks its rule); one JSON object rewritten under a
  lock file (needs a temporary file, a rename, and a second lock file, only to prune); taking a
  path in `--repo` (would read any folder the caller names); reading only the first checkout that
  passes (misses the runs of other clones); making the caller choose one checkout when a key has
  several (adds an option and a step to every read of a repository with two clones); telling runs
  apart by folder name alone (drops one of two runs); making the off file block reading (unlike
  the store); a command that edits the registry.

Evidence: [`claude/bin/b_run.py`](../../claude/bin/b_run.py),
[`tests/state/cases/stats.sh`](../../tests/state/cases/stats.sh), and
[`tests/artifacts/artifact-probe.sh`](../../tests/artifacts/artifact-probe.sh).
