# ADR-015: One writer subagent may apply an approved plan step

- Status: Accepted
- Date: 2026-11-14
- Supersedes: ADR-009 in part (the sentence "The main session implements; read-only
  specialists stay read-only and no writer worker is added" and the note that an
  optional writer worker would need its own ADR) and ADR-001 in part (the sentence
  "Worktree mutation, user interaction, verification, and reporting stay in the main
  session", for the worktree mutation of an approved plan step, and the set of
  generated agents: five read-only specialists plus one writer)

## Context

Stage 4 of the run-first design asked for a writer worker: a subagent that applies a
plan step while the main session orchestrates. [ADR-014](ADR-014-checked-plan-steps.md)
made the step gate the thing that checks a step, whoever applied it, so a worker can
now be checked rather than trusted. What the worker offers is a smaller main-session
context (its reading and editing happen in the child) and a result that is checked; it
does not make a run faster, and each worker step reloads the child's instructions (the
kernel, the project guide, the profile, the phase skill, and the packet).

Subagents started from the main conversation run in the background by default: an
`Agent` call returns at once and the result arrives later as a completion notification.
The kernel already says a child that gates action is waited for, so a worker is
exactly that wait, not background work the main session continues beside.

The harness behaviour this design leans on was researched but not verified here: the
decision was to build first and let the user confirm it in a live session after
installing. The harness worktree isolation was rejected for a worker because it does
not carry a run's uncommitted changes (a later step needs the earlier ones), and the
built-in docs give no way to bring its result back.

## Decision

- **A separate registry map.** `skills/registry.yaml` gains a `workers` map with one
  entry, `b-worker` (`sonnet`, effort `high`). It is not in `agents`, so every
  read-only assertion about specialists stays unconditional and unchanged. The
  generator validates it (exactly that name; a model, effort, or turn limit and
  nothing else), renders `claude/agents/b-worker.md` for Claude Code only, and a
  self-test fails a registry that lists a tool list, permission mode, isolation, hooks,
  skills, or background field, a second worker, or a worker named like a specialist.
  No skill binds to a worker.
- **The profile.** Tools: `Read`, `Grep`, `Glob`, `Edit`, `Write`, `Bash`, and the
  read-only MCP tools the specialists receive. Never `NotebookEdit`, `Agent`, `Task`,
  `Skill`, `AskUserQuestion`, or another MCP class. The frontmatter carries only name,
  description, tools, model, and effort (and a turn limit when the registry sets
  one): no permission mode (it applies only when the parent is in the default or
  dont-ask mode), no isolation, no hooks. The body gives the worker one approved step
  and its packet: it reads the step's phase skill and follows its editing guidance
  except the parts that need a user, a review, a commit, or a spec; edits in place
  inside the approved scope; never touches the run folder, likely-secret files, or git
  history; installs nothing; runs neither run CLI; answers `NEEDS INPUT` rather than
  asking; and reports the step id, changed paths, its check and exit code, deviations,
  and open questions. The report is evidence, not authority.
- **In place, one at a time, the main session waiting.** While a worker runs the main
  session ends its turn: it edits nothing, runs no run CLI (a state write between the
  step base and the record would be refused as run state written outside the step),
  runs no check, generator, or formatter, starts no other child, and commits nothing.
  Afterwards it inspects the diff, reruns the step's check, and records the step; the
  step gate then checks the changed paths against the approved scope and the base.
  This procedure is added to `b-flow` with the plan wiring, not in this change.
- **The kernel sentence.** The Claude Code kernel says the main session "coordinates
  read-only children and one `b-worker` per approved worker step, never peer writers".
  The Pi kernel keeps the old sentence through a runtime override, since Pi has no
  worker. The shell-tool examples in the shell-commands line are dropped (30 bytes) to
  keep the kernel within its limit: 11,989 bytes for Claude Code, 11,720 for Pi.
- **Inert here, optional later.** Nothing in this change lets a run use the worker: it
  needs a plan field naming worker steps, a step-scoped packet, and the step's applier
  recorded in the history, which come as the second run of this unit after the live
  checklist below. Until a plan lists a worker step, nothing starts a worker, and the
  main session applying a step itself stays a complete path to the same recorded
  state.
- **Enforcement.** Prevented: nested delegation, questions, and mutating MCP calls (the
  tool list); likely-secret and run-folder writes through the file tools (the path
  guard, which does not look at who is calling, and the permission deny rules);
  destination-less and force pushes (the deny rules). Detected: a path outside the
  scope or a likely-secret path (the step gate), a moved `HEAD` (a commit), a changed
  state revision or run-file hash, and a Bash write into the run folder. Not seen by the
  helper: a push the user approves, writes outside the repository, installed
  dependencies, and a run artifact written during implement; the last has no check
  until the packet and prompt wiring exists.
- **No hook, and no Pi worker.** A hook that refuses git history, run CLIs, and
  installs would prevent rather than detect, but it is a new enforcement point that
  cannot be verified from here and matches commands by text; it can be added after the
  live checks. Pi keeps the main session applying every step: its writer tools are
  excluded for agents, its background children are unverified, and its worktree option
  needs a clean tree.
- **Live checklist (the user confirms after installing).** Each item runs in a scratch
  repository with a direct `Agent` call to `b-worker`. The profile itself forbids the
  paths A1 and A2 use, so a worker that declines in its own words proves nothing: the
  evidence is an attempted `Edit` or `Write` call and the refusal text the harness
  returned for it. A refusal without an attempted call is inconclusive, and an
  inconclusive item counts as failed (its fallback applies) until a retry, with the
  task saying the user authorised the probe and asking the worker to attempt the call
  and quote the tool's error, shows the refusal.
  - A1: the path guard fires for the worker. Ask it to write a file under the run
    folder. Expect the guard's own message, which names the run artifact CLI, and no
    file. If false, run files are only detected, not prevented; keep the worker but
    add the hook, or list no worker steps.
  - A2: the deny rules bind the worker. Ask it to edit a `.env` file. Expect a refusal
    that is the permission denial, not the path guard's message, and no file: the guard
    also blocks that path, so only the message tells the two apart. If the message is
    the guard's, the deny rules are unverified and count as failed. If false, secrets
    are only detected; list no worker steps until fixed.
  - A3: edits land in the main tree. Its working directory is the repository root and a
    file it writes shows in the main session's status. If false, the step gate sees
    nothing; the main session applies steps.
  - A4: which session id the worker's shell sees. Only the enforcement notes change.
  - A5: the call returns at once, the main session ends its turn, and the completion
    notification returns it to work with the worker's report. If false, the user
    nudges with any message.
  - A6: an in-repository edit raises no permission prompt in the default mode. If
    false, accept the prompts or list no worker steps.
  - A7: the registry model is honoured (the agent listing shows it); the effort is not
    observable and stays unverified.

## Consequences

- An install carries six Claude Code profiles; Pi carries none for the worker.
- The worker's cost is per step: its reloaded instructions, plus a main-session
  inspection of every report. It pays off for a self-contained step whose own reading
  and editing exceed that; for a small step the main session is cheaper.
- The history will carry who applied each step, once the plan wiring exists. With the
  tree, path counts, refusals, and timestamps the step gate already records, that is
  the measurement stage 5 (parallel writers) is to be decided on.
- A worker can still do what the profile asks it not to do and the helper cannot see
  (see Enforcement); the approval of the steps handed to it is the safeguard, and the
  user's review of the diff.
- Until the live checklist is run, A1 to A7 are assumptions, each with a fallback that
  leaves the main session applying the step.
- Rejected: harness worktree isolation, a `WorktreeCreate` hook, and a worktree made
  by the helper (none carries uncommitted changes; the last leaves the child's working
  directory in the main tree); a writer flag inside the `agents` map (every read-only
  assertion would need an exception); a hand-written profile (breaks the canonical
  source rule and the generator would not see it); a permission mode in the profile; a
  Pi worker; a capability-registry entry (the agent capability names exactly the five
  specialists); recording "worker started" in the state (a state write between the
  step base and the record would stop the run); the worker recording its own step.

Evidence: [`skills/registry.yaml`](../../skills/registry.yaml),
[`tooling/generate/registry_sync.py`](../../tooling/generate/registry_sync.py),
[`claude/agents/b-worker.md`](../../claude/agents/b-worker.md),
[`references/kernel.template.md`](../../references/kernel.template.md),
[`tests/hooks/hooks-probe.sh`](../../tests/hooks/hooks-probe.sh),
[`tests/install/claude-install-probe.sh`](../../tests/install/claude-install-probe.sh).
