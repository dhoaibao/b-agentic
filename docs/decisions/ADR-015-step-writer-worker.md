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
  The procedure is in the `b-flow` skill (added 2026-11-14), with one more rule: the
  main session renders the step packet again after the report and stops when its
  state or follow-ups revision differs from the packet it handed over.
- **The kernel sentence.** The Claude Code kernel says the main session "coordinates
  read-only children and one `b-worker` per approved worker step, never peer writers".
  The Pi kernel keeps the old sentence through a runtime override, since Pi has no
  worker. The shell-tool examples in the shell-commands line are dropped (30 bytes) to
  keep the kernel within its limit: 11,989 bytes for Claude Code, 11,720 for Pi.
- **Opt-in by the approved plan.** The profile was inert until 2026-11-14, when the
  plan wiring was added. A plan may list `worker_steps`: `b-plan` proposes them for
  self-contained steps, the approval round confirms or drops each, and a quick run
  refuses the field. The artifact CLI's `handoff implement --step S-n` renders the one-step
  packet. `record step` on a listed step needs `--by worker`, or `--by main` when the
  main session applied it; it is invalid or refused before any write without it, with
  `--by` on an unlisted step, with `--by worker` and no step base for the gate to check
  against, and for a listed step that is already recorded. The history entries of
  listed steps (recorded, refused, or blocked) carry `by`; no other entry does. Before
  a launch the main session runs the artifact CLI's `worker-profile`. The harness
  identifies an agent by the name in its frontmatter, not by its file name, reads
  agent folders recursively, and lets a project profile take precedence over the
  generated one. The check does not parse YAML; it over-approximates instead. In any
  file under an agents folder of the working directory, the folders above it up to the
  repository root, and the user's, a file is a candidate when its name reads as
  `b-worker` (any case, a trailing comment or plain quotes allowed), when its file
  is named after the worker, or when its name cannot be established with certainty: a quoted or
  complex key, a folded, literal, tagged, anchored, or escaped value, a flow or
  indented mapping, a merge key, a repeated name, or a header that is not closed.
  Every candidate is held to a strict reading of its own frontmatter (plain `key:
value` lines, line ends and a byte order mark normalized) and to the worker's
  allowlist: the native tools the generator renders plus the policy's read-only MCP
  tools, no other tool, and no frontmatter key beyond name, description, tools, model,
  effort, and a turn limit. Anything unusual in a candidate is refused rather than
  interpreted. Which of several the harness would load is not decided; each must
  pass, two candidates in one scope are refused as ambiguous, and a symbolic link
  under an agents folder or an unreadable file is refused because it cannot be
  checked. When it is not ok the main session applies the step itself. It checks the
  tools and the frontmatter, not the body (an override could still weaken the
  instructions, which the step gate then sees only through what the worker changes).
  It cannot see a profile supplied on the command line or by managed settings, and
  because the harness's own parser is not available it is a strict over-approximation,
  not a proof; it was hardened in three review rounds and stays best effort against a
  profile written to evade it. Nothing
  starts a worker for a step the plan does not list, and the main session applying a
  step itself stays a complete path to the same recorded state.
- **Enforcement.** Prevented: nested delegation, questions, and mutating MCP calls (the
  tool list); likely-secret and run-folder writes through the file tools (the path
  guard, which does not look at who is calling, and the permission deny rules);
  destination-less and force pushes (the deny rules). Detected: a path outside the
  scope or a likely-secret path (the step gate), a moved `HEAD` (a commit), a run-file
  hash mismatch, a Bash write into the run folder, and run state written between the
  step base and the record. That last check is weaker than it looks: the step base
  keeps the revision of the last write, so a `record step` made during another step
  moves it unseen. The refusal of an already-recorded worker step and the revision
  lines of the step packet, which the main session compares after the report, close
  the likely cases; scope, secret, and `HEAD` safety hold in every case, because each
  record still compares the base with the tree. A worker's other state writes (a
  different step whose dependencies are met, `unblock`) or a follow-up written during
  implement are seen only through those revision lines (the follow-ups file has its
  own). Not seen by the helper at all: a push the user approves, writes outside the
  repository, and installed dependencies.
- **No hook, and no Pi worker.** A hook that refuses git history, run CLIs, and
  installs would prevent rather than detect, but it is a new enforcement point that
  cannot be verified from here and matches commands by text; it can be added after the
  live checks. Pi keeps the main session applying every step: its writer tools are
  excluded for agents, its background children are unverified, and its worktree option
  needs a clean tree.
- **Live checklist.** Run on 2026-11-14, after installing, in this repository rather
  than a scratch one, because a worker's working directory is the session's: A1, A2,
  A3, and A5 are confirmed, A6 is probable, A4, A7, and A8 were not checked, and the
  first live use passed. Each item runs with a direct `Agent` call to `b-worker`. The profile itself forbids the
  paths A1 and A2 use, so a worker that declines in its own words proves nothing: the
  evidence is an attempted `Edit` or `Write` call and the refusal text the harness
  returned for it. A refusal without an attempted call is inconclusive, and an
  inconclusive item counts as failed (its fallback applies) until a retry, with the
  task saying the user authorised the probe and asking the worker to attempt the call
  and quote the tool's error, shows the refusal.
  - A1: the path guard fires for the worker. Ask it to write a file under the run
    folder. Expect the guard's own message, which names the run artifact CLI, and no
    file. If false, run files are only detected, not prevented; keep the worker but
    add the hook, or list no worker steps. Confirmed: a `Write` under the run folder
    came back with the guard's message and no file existed.
  - A2: the deny rules bind the worker. Ask it to edit a `.env` file. Expect a refusal
    that is the permission denial, not the path guard's message, and no file: the guard
    also blocks that path, so only the message tells the two apart. If the message is
    the guard's, the deny rules are unverified and count as failed. If false, secrets
    are only detected; list no worker steps until fixed. Confirmed: a `Write` to a
    `.env` file came back as the permission denial ("File is in a directory that is
    denied by your permission settings"), not the guard's message, and no file existed.
  - A3: edits land in the main tree. Its working directory is the repository root and a
    file it writes shows in the main session's status. If false, the step gate sees
    nothing; the main session applies steps. Confirmed: the worker's `pwd` was the
    repository root and its file showed in the main session's status.
  - A4: which session id the worker's shell sees. Only the enforcement notes change.
    Not checked.
  - A5: the call returns at once, the main session ends its turn, and the completion
    notification returns it to work with the worker's report. If false, the user
    nudges with any message. Confirmed, in the probe and in the first live use below.
  - A6: an in-repository edit raises no permission prompt in the default mode. If
    false, accept the prompts or list no worker steps. Probable: the worker reported
    no prompt and the user saw none, but a subagent cannot reliably see one.
  - A7: the registry model is honoured (the agent listing shows it); the effort is not
    observable and stays unverified. Not checked.
  - A8: a background worker survives `/clear`, compaction, or a resume. If not, the
    resume rule (ask whether an earlier session's worker may still be running before
    starting one) already covers it. Not checked.
  - First live use of the wiring: in a scratch repository, a `/b-flow` run whose plan
    lists one worker step records it `--by worker`; a file outside the scope created
    while the worker runs is refused naming the path, removed, and the step recorded on
    retry. Passed in a throwaway full run in this repository: the worker applied the
    step, the report left the state and follow-ups revisions unchanged, and the
    record carried `by: worker` with one path and none outside. A stray file made by
    the main session after the report was refused naming its path, and the step
    recorded once it was removed. A file created while the worker runs was not
    tried, so the concurrent case is still untested.

## Consequences

- An install carries six Claude Code profiles; Pi carries none for the worker.
- The worker's cost is per step: its reloaded instructions, plus a main-session
  inspection of every report. It pays off for a self-contained step whose own reading
  and editing exceed that; for a small step the main session is cheaper.
- The history carries who applied each listed step (`by`). With the tree, path counts,
  refusals, and timestamps the step gate already records, that is the measurement
  stage 5 (parallel writers) is to be decided on; durations include the main session's
  inspection time, and a worker's own cost is not recorded. A helper from before this
  wiring refuses `--by` as an unknown argument, so it fails closed on such a run.
- A worker can still do what the profile asks it not to do and the helper cannot see
  (see Enforcement); the approval of the steps handed to it is the safeguard, and the
  user's review of the diff.
- A4, A6, A7, and A8 stay assumptions until checked, each with a fallback that leaves
  the main session applying the step. The worker's own cost is not recorded.
- Rejected: harness worktree isolation, a `WorktreeCreate` hook, and a worktree made
  by the helper (none carries uncommitted changes; the last leaves the child's working
  directory in the main tree); a writer flag inside the `agents` map (every read-only
  assertion would need an exception); a hand-written profile (breaks the canonical
  source rule and the generator would not see it); a permission mode in the profile; a
  Pi worker; a capability-registry entry (the agent capability names exactly the five
  specialists); recording "worker started" in the state (a state write between the
  step base and the record would stop the run); a required revision pin on the record
  (a retry after a gate refusal would need the new revision, and a stale one blocks
  the run; to be revisited if the revision lines prove insufficient); the main session
  choosing worker steps at run time (delegation with no approval); `--by` optional or
  required on every step (silent misattribution, or changed commands for unlisted
  steps); a new ADR for the wiring (the decision is unchanged).

Evidence: [`skills/registry.yaml`](../../skills/registry.yaml),
[`tooling/generate/registry_sync.py`](../../tooling/generate/registry_sync.py),
[`claude/agents/b-worker.md`](../../claude/agents/b-worker.md),
[`references/kernel.template.md`](../../references/kernel.template.md),
[`tests/hooks/hooks-probe.sh`](../../tests/hooks/hooks-probe.sh),
[`tests/install/claude-install-probe.sh`](../../tests/install/claude-install-probe.sh).
