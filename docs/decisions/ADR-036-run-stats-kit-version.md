# ADR-036: Each run-stats line records the kit version the run started on

- Status: Accepted
- Date: 2026-11-26
- Supersedes: [ADR-035](ADR-035-local-run-stats.md) in part: its list of stored fields, and its rule that a line never holds a commit id (one id is now allowed: the b-agentic kit's own source commit)

## Context

A [ADR-035](ADR-035-local-run-stats.md) line says how a run went but not which skills, hooks, and
helpers ran it, so lines from before and after a change to the kit cannot be told apart. The
source commit alone is not enough: most commits change documents, tests, or the other runtime, and
change nothing this runtime runs.

## Decision

- **Computed at install time, from git, per runtime.** Each installer counts the commits of the
  source's `HEAD` that touch what really runs for its runtime. There is no `VERSION` file, content
  digest, or git hook: nothing has to be bumped, and a commit that changes nothing the runtime
  runs does not move its version.
- **Four manifest fields.** The install manifest (b-agentic/install.json in the runtime's folder)
  holds all four or none:
  - `kit_seq`: `git rev-list --count --full-history HEAD -- <paths>`;
  - `kit_commit`: the newest such commit, `git rev-list -1 HEAD -- <paths>` (40 hex characters);
  - `kit_date`: that commit's committer date in UTC, `YYYY-MM-DD`;
  - `kit_dirty`: `git status` reports a change or an untracked file under the paths, or the install
    kept a user-owned or modified managed file or kernel block, left a link where a retired
    file was, or found the user's settings still running a hook script the source no longer
    ships (whoever owns it), so what is installed may differ from the commit.
- **Path lists.** `KIT_PATHS` in
  [`tooling/install/claude_install.py`](../../tooling/install/claude_install.py) holds one list per
  runtime; every list excludes `README.md` files.
  - Both: `install.sh`, `skills/registry.yaml`, `claude/configs/mcp.base.json`,
    `references/{kernel.template.md,capabilities.yaml,mcp_operations.yaml,artifacts.yaml}`, and
    `tooling/install/{claude_install.py,claude_install_ui.py,optional_components.py,vendor_tools.py,all_install.py}`.
  - Claude Code: `skills/*/SKILL.md`, `claude/agents/*.md`, `claude/bin`, `claude/hooks`, and
    `claude/configs/settings.template.json`.
  - Pi: `skills/*/prompt.md`, the `b-state*.mjs`, `b-candidate-snapshot.mjs`, `b-protected.mjs`,
    and `b_run.py` files of `claude/bin`, the five hooks Pi installs, `references/runtimes.yaml`,
    `pi/bin`, `pi/extensions`, `pi/themes`, `tooling/generate/registry_sync.py`, and
    `tooling/install/pi_install.py`.
  - [`tooling/validate/kit_paths.py`](../../tooling/validate/kit_paths.py), part of the default
    validation, traces dry-run installs of each runtime and of both, with every optional component,
    plus the Pi render. It fails when an install reads a source file its list does not match, or a
    list matches a file that runtime's install does not read (`install.sh` and `all_install.py` are
    exempt from the second direction).
- **Never remove an entry.** A path a runtime stops reading moves to that runtime's `retired`
  list, which keeps counting. Removing an entry would lower `kit_seq` for newer commits.
- **No version rather than a guess.** The four fields are left out when the source is not the root
  of its own git worktree (no git, or a folder inside another repository), is shallow or a partial
  clone, uses SHA-256 ids, has no matching commit, or git fails, times out, or refuses it (such as
  dubious ownership). They are also left out when the source changes while an install runs: each
  installer reads the version before its first source file and again when it writes the manifest,
  and records it only when both are the same, so a newer commit is never given to files read from
  an older one (a change made and undone within one install is not seen). Git runs with every
  `GIT_*` variable cleared, no replace objects, no lazy fetch, no optional locks, `core.fsmonitor`
  off, and a timeout, and never fails an install. A `--dry-run` computes nothing, a
  `--statusline-only` manifest carries no version, the intent manifest of an install carries none
  (so an interrupted run claims neither version), and an uninstall drops the fields before its
  first removal.
- **Two snapshots in the run.** `b-state` reads the install manifest beside the running helpers when it
  creates a run (`state.kit.init`) and at `advance done` (`state.kit.done`). It takes all four
  valid fields or none, only when the manifest's `target` is the run's runtime. A missing,
  unreadable, malformed, partial, linked, oversized, or non-regular file gives no version and
  never fails or stalls the command (the file is opened without blocking and without following a
  link). Helpers run from a source checkout have no install manifest beside them. The state schema
  stays 1: earlier helpers ignore the new key.
- **Five store fields.** The line copies `kit_seq`, `kit_date`, `kit_commit`, and `kit_dirty`
  from the **init** snapshot only, and adds `kit_changed` only when both snapshots are complete:
  `true` when `kit_commit` or `kit_dirty` differs; `false` when the commit is the same and both
  are clean; left out when the commit is the same and both are dirty, since two dirty trees may or
  may not differ. A run with no init snapshot gets no kit field. A catch-up (`stats --record`)
  reads only `state.json`, never the installed manifest, so an old run is never given today's
  version. The writer checks the new fields like every other one, and also refuses a line whose
  four fields are incomplete, whose `kit_seq` is not positive, or that has `kit_changed` without
  them. When the `artifacts.yaml` beside the helpers has no kit fields (an install keeps a copy
  the user edited), the line is written without them rather than dropped.
- **The one commit id.** `kit_commit` is a commit of the b-agentic source the kit was installed
  from; the helpers put no other commit id, and no path, branch, or text from a repository a run
  worked in, into a line. The writer checks the format, not the origin: like every number in a
  line, the value comes from the run's `state.json`, which is not authenticated
  ([ADR-009](ADR-009-b-flow-automatic-run.md)), so a hand-edited state could put any 40-character
  hex value there. Signing snapshots with a key in the install home was rejected: the store is
  local, is not authoritative, and every other field has the same source.

## Consequences

- Lines can be grouped by the kit that ran them, and a run that finished on a different kit than it
  started on is marked.
- **Limits of `kit_seq`.** It never drops from a commit to its descendant while no list entry is
  removed. It does not order two diverged branches (they can share a number), a rebase, squash, or
  other history rewrite can lower it, the two runtimes' numbers are unrelated, and a change that
  adds a path raises the number by that path's whole history, so a jump is not that many new
  changes. `kit_commit` is the newest counted commit, not a digest of the installed files.
- **Limits of the snapshot.** It describes the source at the last install, not the installed files
  byte for byte: an edit made after the install is not seen until the next one. `kit_dirty` rests
  on `git status`, so an ignored file, or one git is told to assume unchanged or skip, is not
  seen. It covers managed files and the kernel block: settings, permission, MCP, and subagent
  entries merged into user files, including ones the install kept as the user's, are not
  reflected. A reinstall and a return between `init` and `done` leaves `kit_changed` false.
  The installers take no lock: two installs or uninstalls running into the same folder at once
  can leave files and a manifest, version included, that do not match each other.
- **Older installs.** A `b-run` from before this decision counts a line with kit fields as
  malformed, and so also reports that run as missing; its catch-up does not write the run again.
  Reinstalling that runtime updates its reader.
- Runs started before the helpers and the manifest both had this support have no kit field.
- Rejected: a `VERSION` file (it needs a bump on each commit that changes behaviour, and drifts
  when forgotten); a git hook that writes one (not installed in every clone); a digest of the
  installed files (it names a state but gives no order); the plain `HEAD` commit (it moves on
  commits that change nothing that runs); reading the manifest at catch-up (it would give old runs
  today's version); storing both snapshots in the line (the change flag is what a later analysis
  needs).

Evidence: [`tooling/install/claude_install.py`](../../tooling/install/claude_install.py),
[`claude/bin/b-state-store.mjs`](../../claude/bin/b-state-store.mjs),
[`claude/bin/b_run.py`](../../claude/bin/b_run.py), and
[`references/artifacts.yaml`](../../references/artifacts.yaml).
