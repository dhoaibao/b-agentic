# b-flow: continue a run without memory of it

Status: implemented

## Goal

A session that has only the repository and the run folder can continue a `/b-flow`
run: it can tell the phase, what the phase still owes, and what earlier rounds found
or decided, from the helper's output alone. Refines
[ADR-009](../decisions/ADR-009-b-flow-automatic-run.md).

## Requirements

- `b-state.mjs check` prints `next`: the steps the current phase still owes, derived
  from the state and the validated artifacts. It only reads and grants no approval.
- Review, the low-risk exception, and QA need every approved plan check recorded at
  exit 0 for the current candidate, not just one. `check` returns a run that is
  already past `verify` without them to `verify`, so `next` never names a step its
  guard would refuse.
- `record review` refuses `NEEDS FIXES` without a blocker of that round in
  `followups.md`, and `READY WITH FOLLOW-UPS` without a finding of that round.
- `state.json` keeps a bounded `history`: one entry per write, in the same atomic write
  as the change, holding only the kinds of facts the state already holds. Every block
  reason, including one that replaces another, and the unblock reason are kept there.
- `skills/b-flow/prompt.md` points at `next` and at the history instead of restating
  what the helper derives.

## Acceptance criteria

- AC-1: WHEN `advance review`, `record review`, or `advance qa` runs with a plan check
  missing or not at exit 0 for the candidate THEN it is refused, the check is named,
  and the state is unchanged. Evidence: `bash tests/state/state-probe.sh`.
- AC-2: WHEN `record review --verdict "NEEDS FIXES"` runs without an `R<round>-`
  blocker in `followups.md`, or `READY WITH FOLLOW-UPS` without an `R<round>-` item,
  THEN it is refused. Evidence: `bash tests/state/state-probe.sh`.
- AC-3: WHEN a `b-state` command writes the state THEN `history` gains one entry with
  only the allowed detail fields, capped at 200 with `history_dropped`, and an unblock
  keeps its reason. Evidence: `bash tests/state/state-probe.sh`.
- AC-4: WHEN `check` runs in any phase, including `check --takeover` by a new session,
  THEN its output carries `next` naming the missing evidence and the command.
  Evidence: `bash tests/state/state-probe.sh`.
- AC-5: WHEN a `state.json` without `history` is loaded THEN `show` and `check` work.
  Evidence: `bash tests/state/state-probe.sh`.
- AC-6: WHEN the generator runs THEN the rendered `b-flow` skill matches its source
  for both runtimes, the kernel is unchanged, and every suite passes. Evidence:
  `python3 tooling/generate/registry_sync.py --check`, `scripts/validate-skills.sh`.

## Out of scope

- Persisted state for skills run outside `/b-flow`.
- A recorded step cursor for `implement` and the review gate's identity.
- Continuing after compaction without an explicit `/b-flow resume`.
- Stored review or QA reports, command output, or a separate event log file.
