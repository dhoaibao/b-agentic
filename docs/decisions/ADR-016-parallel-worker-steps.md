# ADR-016: Approved worker steps may run at the same time, each in its own worktree

- Status: Accepted
- Date: 2026-11-14
- Supersedes: ADR-015 in part (the "In place, one at a time, the main session
  waiting" part, for steps a plan lists in `parallel_steps`, and the kernel sentence
  "one `b-worker` per approved worker step, never peer writers"); it also revisits
  ADR-014's rejection of a worktree made by the helper, which ADR-014 said to revisit
  for parallel writers

## Context

Stage 5 of the run-first design is parallel writers. It was built without the
measurements [ADR-012](ADR-012-run-first-entry.md),
[ADR-013](ADR-013-concurrent-plan-checks.md), and
[ADR-015](ADR-015-step-writer-worker.md) asked for, by the user's decision, after a
planning round recommended waiting: in four past runs implement was 4 to 59% of the
run time, past plans had a usable width of mostly 1 to 2, and review, fix, and verify
rounds dominated.

Concurrent writers in one working tree were rejected. The step gate keeps one step
base and compares one tree delta, so two workers' edits to one tree cannot be
attributed to steps. Each concurrent worker therefore needs its own tree.

Live evidence gathered 2026-11-14 (also in ADR-015's live checklist): a worker applied
a real step, the gate refused a stray path by name, and then recorded. One probe showed
a `b-worker` started in the repository root writing and editing files by absolute path
in a separate git worktree outside the repository with no permission prompt. A second
probe showed two `b-worker` agents launched in one message running at the same time
(about 30 seconds each with a 20-second sleep), each in its own worktree: both reports
arrived and nothing leaked into the other worktree or the main tree. The `Agent` tool
has no working-directory parameter, so the directory is named in the task.

## Decision

- **`parallel_steps`.** An optional plan field next to `parallel_checks`: at least two
  entries, each once, all in `worker_steps`. Each listed step's paths must be literal
  (no glob characters), canonical (no `.` or `..` component, doubled or trailing
  separator, so an alias cannot name one file twice), and pairwise disjoint (no equal
  path, none inside another). At
  least two listed steps must be able to be ready together (a step without
  `depends_on` waits for the step before it), so lint refuses a list that can never
  form a batch. A quick run refuses it, as it refuses `worker_steps`. At run time a
  batch is the first two listed steps, in plan order, that are open with their
  dependencies recorded (a cap of 2 per batch, by the user's decision). With one step
  ready it is an ordinary in-place worker step as in ADR-015.
- **`worktree add|collect|remove S-n`.** The commands live in the state CLI
  (`claude/bin/b-state.mjs`) because it already owns the secret-safe tree builder, the
  step base, the lock, and the plan summary. They never write the run's state (a write
  between a step base and its record blocks the run) and never touch the main tree or
  its index. `add` refuses an unlisted, recorded, or waiting step, no step base, a
  state revision that moved since the base, a moved `HEAD`, a main tree that is not
  the step base, an existing worktree for the step, a third open worktree, and a
  repository with submodules, any configured clean, smudge, or process filter
  (git LFS installed for the user is one; judged on the configuration alone as git
  reads it from the repository root, because which paths a filter applies to comes from
  attributes files that are not all reachable from the helper; `collect` and the
  `record step` check ask again, also in the worktree, since a worker with a shell can
  add one, and building a tree runs clean filters), and a temporary folder
  inside the repository (resolved through links). It makes a commit object of the step base tree (parent:
  the base `HEAD`) under a fixed identity and date with a marker message naming the run
  and step (no ref moves, signing off), then runs `git worktree add --detach` with
  repository hooks switched off, at
  `<os.tmpdir()>/b-agentic-wt-u<uid>/b-agentic-wt-<8 hex of the repository path>-<run id>-<S-n>`.
  The folder with the uid is made for this user alone (mode 0700, and an existing one
  is trusted only if it is a real directory of this user that no one else can enter),
  because the temporary folder is shared and a checkout takes its modes from the
  umask; the last `worktree remove` takes it away. The location is the user's decision
  (the temporary folder); leftovers are found by name in `git worktree list`, so a
  different `TMPDIR` cannot hide one. The worktree holds
  exactly the step base tree: the user's dirty and untracked files and earlier run
  steps, no ignored files, no likely-secret file.
- **`collect`.** It refuses unless the worktree is registered and its folder exists,
  its `HEAD` is still the marker commit (author, subject, parent, not on a branch), and
  the main tree is exactly the current step base, so a worker that wrote the main tree
  through an absolute path is caught before anything is applied. It builds the worker's
  tree with the file system monitor and repository hooks switched off (a worker can
  reach the configuration those run from), checks the delta with the same scope check as `record step`, and refuses a
  protected path (also a likely-secret name among the files the worktree ignores,
  looked at by name only, since an ignored file never reaches the tree; `record step`
  looks again), a path outside the approved scope, and, stricter than ADR-014 where
  such paths are only counted, any path outside the step's own paths. It prints the
  base tree, the worker tree, and the exact command
  `git diff --binary --full-index --no-renames --no-ext-diff --no-textconv --no-color --src-prefix=a/ --dst-prefix=b/ <base> <tree> | git apply --whitespace=nowarn`,
  which the main session runs from the repository root (`git apply` is atomic; the
  helper never applies). The options are spelled out so the user's diff and apply
  configuration (an external diff or textconv program, color, `diff.noprefix`,
  `apply.whitespace`) cannot run a program or change the patch. On any refusal or conflict the main session applies that step
  itself, records it `--by main`, and removes the worktree.
- **Merge order.** After every report has arrived, the main session compares the
  revision lines of each step packet, then, in plan order, for each step: `collect`,
  apply, run the step's `done_when` check in the main tree,
  `record step S-n --by worker`, `worktree remove S-n`. The main-tree check is the
  binding one; a worker's own check in its worktree is advisory (a fresh checkout has
  no ignored dependencies such as installed packages, and nothing links or installs
  them).
- **Attribution.** The `record step` gate is unchanged. Because applies and records are
  serialized, each record's base-to-tree change is that step's. New: for a step
  recorded `--by worker` while its run worktree exists, the main-tree change since the
  step base must equal the worker's change (path, status, mode, blob), otherwise the
  record is refused before any write, as it is when that change includes a path
  outside the step's own paths (the same refusal `collect` makes, so skipping
  `collect` does not skip it) or when a likely-secret path is changed in the main tree
  (no attempt is counted: the main session applies the step itself, and the counted
  refusal of ADR-014 then applies to that record). This catches both changes being applied before the
  first record, which the gate alone would accept since both are in scope. The
  history entry gains `worktree: true` beside `by`, which also gives the measurement
  stage 5 was waiting for.
- **Cleanup and resume.** `worktree remove S-n` runs `git worktree remove --force` on
  the exact registered path; if the folder is already gone it deletes only that
  worktree's own registration under the git common directory (found by resolving its
  link, which git writes relative to its own folder under
  `worktree.useRelativePaths`); never
  `git worktree prune`, `rm -rf`, or `git clean`. `check` lists every remaining
  worktree of the run, and `advance verify` is refused while one remains. After
  `/clear` or a resume mid-batch nothing in the state changed: `check` lists the
  worktrees and the main session asks whether those workers may still be running
  before collecting (a worker still running after collect is caught at record, since
  the worker tree is recomputed there). Orphans of other or replaced runs are not
  listed (future work).
- **The worker.** The step packet gains a `Working directory: <worktree>` line when a
  run worktree exists for the step. The generated `b-worker` body
  (`claude/agents/b-worker.md`) says to work only there with absolute paths and a
  `cd <dir> &&` prefix on shell commands, to use CodeGraph for orientation only (it
  indexes the main tree), to never write the main repository or another worktree, and
  to report rather than install a missing dependency. The prompt and the `b-flow` batch
  procedure are in `skills/b-flow/prompt.md`; `b-plan` proposes `parallel_steps`
  (`skills/b-plan/prompt.md`).
- **The kernel sentence.** The Claude Code kernel now says the main session
  "coordinates read-only children and a `b-worker` per approved worker step, never two
  in a tree" (11,988 bytes, one less than before). The Pi kernel is unchanged at
  11,720 bytes because its override still restores the read-only-children sentence;
  Pi has no worker.
- **Enforcement.** Prevented: the tool list, the path guard (it matches path names, so
  `.b-agentic` and likely-secret names are refused in any folder, a worktree included;
  its firing for a subagent inside a worktree is a live item), and the Bash deny rules
  (they match command text and apply anywhere). Detected: a worker writing the main
  tree or another worker's changes (`collect` and the equality check), a path outside
  scope or step, a moved worktree `HEAD`, a moved main `HEAD`, and run state written
  between base and record. Not preventable and not seen: a worker writing another
  worker's worktree (detected only if it touches another listed step's path or leaves
  its own paths), shared refs moved from a worktree other than `HEAD`, writes outside
  the repository, and installed dependencies. The `Agent` tool cannot confine a worker
  to its directory, so confinement is the prompt plus those detections. The
  `Edit(**/.env)` deny rules are probably relative to the working directory, so they
  may not bind in a worktree outside the repository; only the path guard is certain
  (live item W2).
- **Live checklist.** The user confirms after installing; these were not run when this
  ADR was written. Each item has an expected result and a fallback.
  - W1: the path guard fires for a subagent's tool calls in a worktree. Expect the
    guard message naming the run artifact CLI. If false, run files in a worktree are
    only detected; list no parallel steps.
  - W2: the deny rules bind outside the working directory. A `.env` write there should
    come back as a permission denial, not the guard's message. If only the guard fires,
    the deny rules are unverified and count as failed; the guard alone is then the
    protection, so list no parallel steps if that is not enough.
  - W3: no permission prompt for edits in a worktree at the temporary location. If
    prompts appear, accept them or list no parallel steps.
  - W4: two simultaneous completion notifications both arrive. If one is lost, the
    user nudges with any message; if a report never arrives, the main session applies
    that step itself.
  - W5: `/clear` or compaction mid-batch. The resume rule applies (`check` lists the
    worktrees and the main session asks before collecting); if the workers are lost,
    remove the worktrees and apply the steps itself.
  - W6: workers stay in their directory. This is prompt only; `collect` and `record`
    detect a breach. If workers stray, list no parallel steps.
  - First live use of the wiring: a throwaway full run in this repository (commit
    consent no) whose plan lists two new documentation files as steps S-1 and S-2,
    both with `depends_on: []`, both in `worker_steps` and `parallel_steps`. Expect
    both workers to start in one message and both reports to arrive,
    the state CLI's `show --history` to show two records with `by: worker` and
    `worktree: true`, `git worktree list` to show only the main tree, and the main
    tree to hold only the two steps' paths. Then AC-12: a worker attempting a `.env`
    write and a `.b-agentic` write in a worktree, recording which message came back.
- **Kill criterion (the user's measure, proposed).** If batches form in fewer than
  about one in three runs that list them, or the batch wall time does not beat the sum
  of the step times, drop `parallel_steps` from `b-plan` guidance.

## Consequences

- Each worker reloads its instructions, so tokens roughly double while two run, and a
  batch adds worktree setup and a serialized merge and inspection. A small step is a
  net loss. Usable width in past plans is mostly 1 to 2.
- A worktree has no ignored dependencies, so a step whose check needs installed
  packages (for example `npm run quality`) must not be parallel. A configured
  git filter (so git LFS users get in-place worker steps only), submodules, and a temporary folder inside the repository are refused by
  `add`; sparse checkout and `autocrlf` are untested stop conditions. Pi keeps the main
  session applying every step.
- The `worktree` history key is the only new state field and the schema version stays
  1. An older helper rejects the key, so it fails closed.
- Rejected: concurrent workers in one tree (edits on another step's paths are
  invisible, and it reverses ADR-014's counted-not-refused rule); harness
  `isolation: worktree` and a `WorktreeCreate` hook (no uncommitted changes, no way
  back); a Python copy in the artifact CLI (it duplicates the secret-safe tree
  builder); a new standalone helper (new installed surface that would import state
  internals); `--no-checkout` plus `read-tree` (leaves the worker's status full of
  base changes); symlinked or copied ignored directories such as `node_modules`
  (writes go through the link into the main tree; copies are slow and stale); installs
  in a worktree; `git apply --3way` (stages into the user's index and leaves conflict
  markers); `git restore --source` (overwrites with no preimage check); merging in
  completion order (not reproducible); the helper applying the change (breaks "never
  changes the main tree"); groups as a list of lists, "no dependency between any
  listed pair", and glob paths in `parallel_steps` (readiness already gives waves;
  waves are legitimate; disjointness of globs is not cheap to decide); no cap on batch
  width (the user chose a cap of 2).

Evidence: [`claude/bin/b-state.mjs`](../../claude/bin/b-state.mjs),
[`claude/bin/b_run.py`](../../claude/bin/b_run.py),
[`references/artifacts.yaml`](../../references/artifacts.yaml),
[`claude/agents/b-worker.md`](../../claude/agents/b-worker.md),
[`references/kernel.template.md`](../../references/kernel.template.md),
[`skills/b-flow/prompt.md`](../../skills/b-flow/prompt.md),
[`skills/b-plan/prompt.md`](../../skills/b-plan/prompt.md),
[`tests/state/state-probe.sh`](../../tests/state/state-probe.sh),
[`tests/artifacts/artifact-probe.sh`](../../tests/artifacts/artifact-probe.sh),
[`tests/hooks/hooks-probe.sh`](../../tests/hooks/hooks-probe.sh).
