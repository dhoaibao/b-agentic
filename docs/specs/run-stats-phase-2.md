# Run-stats phase 2 and follow-ups

Status: draft

This is a backlog, not an approved plan. Nothing here authorizes work: a part
that is picked up needs its own clarify and approval round. It was written on
2026-11-27 from notes and files that existed on one machine only.

## Goal

Keep what is left of the run-stats extension
([ADR-035](../decisions/ADR-035-local-run-stats.md) to
[ADR-038](../decisions/ADR-038-required-blocker-analytics.md)) in the
repository: the unbuilt parts, how to judge the sweep rule, and the open
follow-ups.

## Requirements

### Where phase 2 stands

- **Shipped:** a new blocker must carry `blocker_class` and `escaped_from`, and
  `escaped_from` may be `unknown`
  ([ADR-038](../decisions/ADR-038-required-blocker-analytics.md), commit
  `6ee4f7cd`).
- **Not shipped:** parts A, B, and C below.
- An earlier run for part A, `20261126-run-stats-blocker-mechanism`, was approved
  with a wider scope and never merged. Its run folder and a stashed ADR draft are
  local to one machine; this file carries what is worth keeping from them. Its
  baseline is old and part of its scope shipped in a narrower form, so start a new
  run instead of resuming it. ADR number 038 is taken. The run CLI code has since
  moved from `claude/bin/b_run.py` to `claude/bin/b_run_lib.py`
  ([ADR-040](../decisions/ADR-040-precompiled-run-cli.md)).

### Part A: failure mechanism and fix-caused blockers

Advice on 2026-11-27, not a user decision: wait on `mechanism`; take `caused_by`
first if fix-caused blockers must be measured.

The design the user approved for the earlier run on 2026-11-26:

- Follow-up items gain `mechanism`, on blockers only, one of `check-bypass`,
  `unhandled-case`, `lifetime`, `state-race`, `wrong-logic`, `docs-mismatch`,
  `test-gap`, `other`. It is separate from `blocker_class`, and `other` has no
  free-text note.
- Follow-up items gain an optional `caused_by`, on blockers only: the `R` or `Q`
  id of another blocker the run had already recorded, whose fix caused this one.
  It is set only on the blocker's first write, and is never added, changed, or
  dropped later.
- A new blocker must carry `mechanism`. Recorded blockers are exempt, may gain it
  once, and are never backfilled. An older kept `artifacts.yaml` without the field
  keeps the old rules.
- `followups.md` shows both lines only when present, so older runs render byte for
  byte.
- A stats line gains `blockers.by_mechanism` and `blockers.caused_by_fix` when the
  loaded `run_stats` block declares them; the line version stays 1.
  `stats --summary` gains matching counts and missing keys, and
  `stats --evidence` gains both keys per blocker.
- Prompt changes are limited to what a fix or review must record.

What review found in that run's unmerged code, to test in a new one:

- Validate recorded follow-ups before using them as the earlier version.
- Do not check `caused_by` only when the schema also has `mechanism`.
- Prompts and `next` hints must follow the loaded schema, which can be older.
- Two more `null` keys can push a near-limit blocker over the per-blocker byte cap
  of `stats --evidence`, so a printable old blocker stops printing.
- Recording and summary must both use the count keys the loaded schema declares.

When it is picked up, also add the ways checked to the sweep rule text in
`references/artifacts.yaml`, which still describes the older sweep line.

### Part B: run grouping with planned items

Decided by the user on 2026-11-26: keep a list of planned items per group, and
`init` a run only when its item starts. Do not create child runs up front: one
unfinished run per worktree, a stale baseline, inflated clarify time, and a stale
kit version.

Proposed, not decided: list the remaining items at `done` and in the session
reminder (a reminder only, never an automatic run); a dropped item needs a reason
and the user's approval; stats count real runs only. Storage and the effect of
`prune` are not designed. It does not help find recurring defects.

### Part C: agent time and waiting time

Added to phase 2 by the user. The design is proposed, not decided:

- Four classes per phase: agent working, waiting on background work, waiting on
  the human, unknown. Agent or background activity wins over human wait.
- Capture from runtime hooks or events into a separate timing file, not
  `state.json`; wall-clock time with no double counting, plus a coverage figure.
- Research first whether Claude Code and Pi expose the needed events, permission
  waits included. This has not been checked.

Today a phase duration includes waiting, and blocked time appears only in the run
total. The 45-minute time stop
([ADR-039](../decisions/ADR-039-run-time-budget-stop.md)) is not this feature.
Pick this up if a run takes long and the cause is unclear.

### Judging the sweep rule

Commit `efc5a3aa` added the rule: for every fixed blocker, name the violated
invariant, check the ways it can be broken, and have a re-review look for a
missing way. Its effect is unproven.

Baseline from a manual reading on 2026-11-27 of 75 blockers in finished runs of
five repositories, 45 read on 2026-11-26 and 30 newer:

- Of the 30 newer blockers, 29 came from this repository, and 17 appeared in
  review round 2 or later.
- Of 11 runs with blockers in two or more rounds, in 10 a later blocker broke the
  same invariant by another route although the earlier fix recorded a sweep. This
  is one reader's judgement, and the runs came from two repositories.
- Grouping of the 30 newer blockers, also by judgement: `unhandled-case` 11,
  `check-bypass` 9, `wrong-logic` 4, `state-race` 2, `docs-mismatch` 2,
  `test-gap` 1, `other` 1, `lifetime` 0. The line between the first two is
  unclear, so recorded labels may not be consistent.
- Of the 27 blockers that carried an escape stage: plan 11, implement 10, spec 5,
  verify 1. These labels are model-reported.

Limits: a re-review concentrates on the fix, so some recurrence is expected, and
most cases were guard, permission, or process code.

To judge it, read runs on a kit at or after `efc5a3aa`
(`b-run stats --summary --section kit`). Proposed, not decided: wait for at least
5 runs with blockers in two or more rounds, then compare the share of blockers in
round 2 or later and, by reading them, the recurrence. That sample shows a
direction at most. `stats --evidence` sends blocker text to the agent's model
provider; ask the user before reading another repository's (`--repo`).

Related ideas, not approved: have `b-plan` list failure states for guard-like
code, after the sweep rule has been judged so the two effects stay apart. A
300-character `sweep` line may be too tight for paths, scope, ways, and the
regression check; raise the limit only if real runs do not fit.

### Using run-stats in `b-agentic-audit`

Not now. The finding above came from reading blocker text, not from the counts,
and an audit would read other repositories' text each time. Proposed test before
adding it: the data shows an actionable improvement that single runs hide, in at
least two repositories. The first re-analysis met that only narrowly, since both
cases were guard-like code. If added, report it as a signal, never as a finding or
a verdict input.

### Moving to another machine

The stores, the repository registry, and run folders stay where they were
written, so a new machine starts with no data. The store alone keeps counts.
Reading old blocker text again also needs each repository's `.b-agentic/runs`.
This file keeps the baseline above, not the data behind it. Do not commit stores,
run folders, or other repositories' text.

### Open follow-ups

Copied from notes made when each run ended. They were not re-verified unless the
item says so, so confirm each one in the code before fixing it. Deferred there as
limits or rare cases; none was approved as work.

Kit version ([ADR-036](../decisions/ADR-036-run-stats-kit-version.md)):

- The installers take no lock.
- The first version sample is taken after module import and the registry read;
  the docs overstate how early it is.
- The version is also sampled on uninstall, where git filters can run.
- `tooling/validate/kit_paths.py` must exempt matches that only a retired path
  uses before the first path is retired. A keyword search on 2026-11-27 found no
  such exemption.

Store and run key ([ADR-035](../decisions/ADR-035-local-run-stats.md)):

- A line stored under the older repository-based key, followed by a change of root
  commits, can be written again.
- Runs with the same id and the same init millisecond, or with no history, share a
  key, also across repositories. The same-id case is untested.
- After a helper downgrade rows can repeat, and a root change followed by `prune`
  can lower this repository's line count.

Summary and evidence:

- The repository-key git lookup allows lazy fetch and has no timeout.
- The shared store reader keeps the first store's lines while it parses the
  second.
- Offset paging of `--evidence` can skip blockers if a run folder is removed
  between pages.
- A forged scope pattern may stall validation, and with it every evidence page.
  Read from code, not reproduced.

Repository registry ([ADR-037](../decisions/ADR-037-run-stats-repo-registry.md)):

- `repo_root` still runs git without the hardening.
- Under `--repo`, same-named runs with missing or malformed start data merge. This
  needs hand-damaged state, and the reference text on damaged start times says
  more than the code does.
- A stall in the git search or in spawning git is not bounded.
- `claude/configs/README.md` does not mention `--repo`. A search on 2026-11-27
  found only `--repos` there.

## Acceptance criteria

Draft criteria for part A only. Parts B and C have none until they are clarified.

- AC-1: WHEN a new blocker lacks `mechanism`, or a non-blocker carries it, or its
  value is not in the list THEN `write` and `lint` refuse it and write nothing.
- AC-2: WHEN a run recorded before the change is validated, rendered, or rewritten
  as recorded THEN it passes and renders byte for byte.
- AC-3: WHEN `caused_by` names anything but another blocker the run had already
  recorded, or is added, changed, or dropped later THEN it is refused.
- AC-4: WHEN stats lines are recorded, summarized, or printed as evidence, with
  the new schema or an older one THEN no line is skipped for the new fields, and
  each output stays within its size limit.

## Out of scope

- Backfilling recorded runs or store lines.
- Token or cost telemetry and an aggregator script.
- Keeping abandoned runs. The store holds finished runs only, so its numbers carry
  survivorship bias; changing that needs its own ADR.
- Deferred work outside run-stats.
