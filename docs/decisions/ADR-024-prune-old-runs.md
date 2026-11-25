# ADR-024: Cleaning up old run folders with `b_run.py prune`

- Status: Accepted
- Date: 2026-11-18
- Supersedes: none; refines [ADR-010](ADR-010-run-artifact-cli.md) (the run folder's one writer) and [ADR-012](ADR-012-run-first-entry.md) (every change request enters a run)

## Context

Every `b-flow` run leaves a folder under `.b-agentic/runs/` (about 50 KB each). Nothing removed
them, so a long-lived working tree kept every run it had ever made. The folders are untracked
(`.b-agentic/.gitignore` is `*`), so they cost no review noise, only disk and listing length.

A cleanup deletes data and has to be safe next to a run that may be resumed: a run in any phase
but `done` is state a later session may continue.

## Decision

- `b_run.py runs [--days N]` is a read-only report; `b_run.py prune [--days N]` lists, and with
  `--apply` removes, the runs that are finished. **Finished means `phase == "done"`.** There is no
  "abandoned" phase: a run left behind by `init --replace` keeps its phase and is kept.
- A run is eligible only when it is done, its `updated_at` is older than N days (default 30), it is
  not the run `active` names, its `state.json` is valid with a matching `run_id`, and its folder
  holds only plain files. Everything else is kept and counted by reason.
- Removal is file by file through directory file descriptors opened one below the other without
  following links, never recursively and never through the shell, so the `rm -rf` deny is neither
  used nor bypassed. A run's files are removed through the descriptor of the folder that was
  inspected, and its name only while it is still that folder, so a folder swapped in after the
  inspection is kept.
  `--apply` is refused while `.b-agentic/mutex` exists or when `.b-agentic` or `.b-agentic/runs`
  is a link. The default is a dry run, and the user confirms before `--apply`.
- The check runs in two places only, and neither deletes: `b-state.mjs init` adds a one-line `hint`
  when more than 40 run folders exist (a count of names), and `b-audit` and `b-agentic-audit` run
  `runs` and report a housekeeping note that is not a finding and does not change the verdict.
- A pruned run is deleted fully: no summary or index is kept inside the run folder. Commits stay in
  git. ([ADR-035](ADR-035-local-run-stats.md) keeps a numbers-only line per finished run in a
  separate local store; the folder is still deleted fully.)

## Consequences

- A run's verdicts and `AC-n` results are lost once it is pruned; a user who wants them keeps
  `spec.md` through `docs/specs/` (the `b-flow` done step offers it).
- The hint costs one directory listing per `init`; size is measured only by `runs` and `prune`.
- Rejected: automatic or background deletion, a statusline or `SessionStart` check, `shutil.rmtree`
  or shell `rm`, keeping a summary inside the folder (`validate` would fail on it and the folder
  would still count), a settings rule for `prune --apply`, and letting an audit run `prune`.

Evidence: [`claude/bin/b_run.py`](../../claude/bin/b_run.py) and
[`claude/bin/b-state.mjs`](../../claude/bin/b-state.mjs).
