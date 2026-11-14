# ADR-014: A plan step is checked when it is recorded

- Status: Accepted
- Date: 2026-11-14
- Supersedes: none (refines the step cursor of
  [ADR-009](ADR-009-b-flow-automatic-run.md) and the scope check of
  [ADR-010](ADR-010-run-artifact-cli.md))

## Context

Stage 4 of the run-first design asked for a writer worker: a subagent that applies a
plan step while the main session orchestrates. Planning it showed three things.

- **A step was recorded on trust.** `record step` stored a fingerprint and checked
  nothing about what the step changed. The scope was first compared on the way to
  review, QA, a commit, or the end, so an edit outside the approved scope was found
  only after every step was applied.
- **A worker is not yet decided, and its design rests on unverified behaviour.** A
  sequential worker saves main-session context, not time, and costs the instructions
  each child reloads. The harness worktree does not carry a run's uncommitted changes,
  so the worker would edit in place and be checked afterwards; whether a writer
  subagent can run in the foreground and whether the path guard fires on its edits
  must be probed first.
- **"Checked rather than trusted" does not need a worker.** A check at each recorded
  step serves every run, whoever applies the step, and is what a worker would be
  checked by.

Parallel writers (stage 5) are also to be decided on measurements, and a run recorded
nothing per step beyond its fingerprint.

## Decision

- **Step base.** Entering `implement` (from the approval, or by `unblock implement`)
  and every recorded step store where the next step starts: the working tree as a tree
  id, its fingerprint, `HEAD`, and the state revision of that write. The snapshot is
  taken first; while a likely-secret path is changed it is incomplete and no tree is
  built. The tree is built from the changed paths listed by name, never by adding the
  whole working tree: a likely-secret name in the list refuses it, exactly the listed
  index entries are updated, the tracked ones before the untracked ones so that a file
  a step turned into a directory, or a directory into a file, gives the same tree as
  adding everything would (a path that became a directory meanwhile is not descended
  into, a symbolic link is stored as a link), and every entry that differs from `HEAD`
  is checked by name once more, which covers a path that was already staged. A file
  created or swapped in after the snapshot is therefore not hashed into the object
  store. The snapshot is taken again after the tree, and a different fingerprint
  records nothing, so the tree and the fingerprint describe the same content. The same
  listing now builds every tree the helper computes, including the one a commit must
  match and the ignored artifacts a candidate names. In a repository without a commit
  the base records an empty `HEAD`.
- **Step gate.** `record step` builds the tree after the step and compares it with the
  base through `scope-check --base --tree --step`. A path outside the approved scope,
  or a likely-secret path, refuses the step: nothing is recorded, the base stays, the
  reason goes to the history (path names for the scope, a count only for
  likely-secret paths, the rejected tree id only for the scope), and the refusal is
  counted. The third refusal in a row blocks the run; a recorded step resets the
  count.
- **The approved scope, not the step's own paths.** A changed path inside the scope
  but outside the step's `paths` is counted, not refused: plans often miss a test or
  a document, and the approval is the scope.
- **Not a plan step.** A step runs between two writes of the state helper. When the
  state revision or `HEAD` differs from the base, something else wrote the run state
  or committed, and the run is blocked for the user.
- **Undoing a refused step.** The helper never changes the tree. The main session
  puts the named paths back from the base tree and records again; a step that needs
  such a path is a stop.
- **Measurements.** A recorded step's history entry carries its tree id, the number
  of paths it changed, and how many of them are outside its own paths. With the
  timestamps the history already has, that gives the time per step and whether two
  steps touched the same paths. No duration field is added.
- **Without a base.** A run recorded before this change, or one that entered
  `implement` while a likely-secret path was changed, has no base: its steps are
  recorded unchecked, as before, until it enters `implement` again.
- **Unchanged.** State and artifact schema versions stay 1; packets and `next` lines
  keep their bytes; the scope checks on the way to review, QA, a commit, and the end
  stay; the kernels, the registry, and the agent profiles are not touched.

## Consequences

- An edit outside the approved scope is refused at the step that made it, not after
  the last one.
- Each recorded step costs one snapshot, one tree built in a throwaway index, and one
  `git diff-tree`; the cost on a very large repository is not measured.
- A state written by this version carries history facts an older installed helper
  refuses, so an older copy fails closed on a newer run.
- The tree ids are unreachable git objects: `git gc` removes them after its grace
  period. A base removed that way makes `record step` refuse; `advance blocked` and
  `unblock implement` start the steps again from the current tree.
- Ignored artifacts are not in the trees, so the gate does not see them; the later
  scope checks still do.
- What remains of the window is inside git itself, between its own check of a listed
  path and its read of that path; the helper cannot close it.
- The check that the state revision is unchanged matters most once a worker exists;
  until then it only catches a second writer of the run state.
- The writer worker is a later decision, after probes of the harness, with its own
  ADR: it would supersede the "no writer worker" point of ADR-009 and change one
  kernel sentence.
- Rejected: the harness's worktree isolation and a `WorktreeCreate` hook for a
  worker (neither carries uncommitted changes, and the hook would replace worktree
  creation for every session); a worktree made by the helper from a snapshot commit
  (the subagent's working directory stays the main tree, dependencies are missing,
  leftovers on a crash; to be revisited for parallel writers); refusing every path
  outside a step's own paths (more stops than the approval asks for); stopping at the
  first refusal; a refusal that writes nothing (no bound, no trace); storing path
  lists per step (path names in the state); the helper restoring files itself.

Evidence: [`claude/bin/b-state.mjs`](../../claude/bin/b-state.mjs),
[`claude/bin/b_run.py`](../../claude/bin/b_run.py),
[`skills/b-flow/prompt.md`](../../skills/b-flow/prompt.md),
[`tests/state/state-probe.sh`](../../tests/state/state-probe.sh),
[`tests/artifacts/artifact-probe.sh`](../../tests/artifacts/artifact-probe.sh).
