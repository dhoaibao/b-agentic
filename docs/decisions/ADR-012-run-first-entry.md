# ADR-012: Run-first entry, change requests enter a `b-flow` run

- Status: Accepted
- Date: 2026-11-13
- Supersedes: ADR-009 in part (the explicit-only entry of `b-flow`, the clean tree at
  every approval, and "outside `/b-flow`" in the commit consent exception); ADR-001 in
  part (the "explicit `/b-flow` run" wording of the bounded-orchestration exception)

## Context

[ADR-009](ADR-009-b-flow-automatic-run.md) made `b-flow` a run with file-backed state,
but only on an explicit `/b-flow` request. Most change work therefore still ran as a
single phase skill sequenced from the session's memory, with no recorded acceptance,
checks, or result. The run can now be continued from its folder alone (the `next`
steps, the history, the step record, and a packet for every phase), so entering a run
is cheap enough to be the default for change work. Two things stood in the way: every
run needed a clarification and approval round, which is too much for a small edit, and
every approval needed a clean tree, which a session that edits without committing
never has. The kernel is also at its size limit, so the routing table cannot grow.

## Decision

- **Entry.** A change that would route to an implement-phase skill (`b-implement`,
  `b-frontend`, `b-refactor`, `b-test`) enters a `b-flow` run. The registry marks
  `b-flow` as the routing entry (`routing.entry`), and the generator checks that its
  kernel line names exactly the phase skills of `implement`. The kernel routing table
  stays: validators and the installer's optional components read its lines, and
  utilities and evidence providers must be routable before any skill is loaded.
- **What does not enter a run.** A skill the user names (`/b-<name>`) runs standalone
  and writes no run state. Questions, lookups, plans, reviews, commits, PRs, and
  utility skills route as before. Only the main session records state; no other skill
  reads or writes it (ADR-009's rejection of that stands).
- **Two sizes.** A spec may carry `size: quick`; without it a run is full, which is
  ADR-009's run with its clarification and single approval round.
- **Quick run.** For a quick run the user's change request is the approval, and no
  question is asked. The state helper, not the prompt, decides whether a run may be
  quick: at most 3 plan steps, 3 criteria with automated or inspection evidence, 5
  literal scope paths, no clarifying answers, no checks listed to run together
  ([ADR-013](ADR-013-concurrent-plan-checks.md)), and the fixed consent `commit: no`,
  `branch_target: current`, `codex: reviewer`. A quick run therefore has the authority
  a direct `b-implement` request always had (it never commits or pushes) and gains the
  run's guards and record. A review trigger blocks it: `advance review` records the
  trigger as the run's review obligation and stops the run, which then continues only
  through `unblock clarify` and the approval of a full spec. A review trigger a run
  has met stays its obligation for good, whatever the run's size and however often it
  returns to clarify: no later approval drops it, the run cannot be approved as quick
  again, and it cannot record a low-risk exception. (This tightens ADR-009, under
  which a return to clarify cleared the trigger of a full run.) The size is
  the approved spec's: like the consent, the state's copy is compared with it at every
  step, so an edited state cannot turn a quick run into a full one. A quick run keeps
  `b-qa`, so every run reaches its end through one evidence gate.
- **Ending without a commit.** A run without commit consent ends at QA: `advance done`
  from `qa` needs the same evidence as the commit gate (a current QA PASS, review
  coverage, every criterion passed or waived). A run with commit consent still ends
  only through its commits.
- **Changes already in the tree.** `init` records the changed paths of the tree by a
  digest of content and executable bit (never a likely-secret path, a directory, a very
  large file, or a path below a symbolic link, so no read leaves the tree). While a
  recorded path keeps that identity it is the user's: the scope check ignores it and
  the packets list it apart. Once it differs, the run changed it and it is checked like
  any other path; that includes a recorded path the run deleted or reverted, which git
  no longer reports. A run that may commit still needs a clean tree at approval, so a
  commit holds the run's work and nothing else; a run on a changed tree records
  `commit: no`.
- **One unfinished run per worktree.** `init` refuses while the active run is not
  finished, and `--replace` leaves that run only on the user's answer. `init` holds a
  worktree mutex, so two sessions cannot both pass that check.
- **Unchanged.** One approval round for a full run, commit consent bound to the
  approved spec, no push or PR, the bounded rounds, no Stop-hook continuation, and an
  explicit `/b-flow resume` to continue a run in a new session. The same sources render
  for Pi, and both runtimes run the same two CLIs.

## Consequences

- A small change costs more helper calls than a direct edit did: the price of a
  recorded spec, checks, and result.
- Whether a live session actually selects `b-flow` from the kernel line cannot be
  checked by the static routing corpus, which stays at the level of phase skills; it
  needs observation in a real session on each runtime.
- The kernel has 10 bytes of headroom (11,990 of 12,000), so later routing changes
  must pay for themselves.
- A changed tree no longer blocks work, but it does block commit consent; the user
  commits with `b-commit` or starts from a clean tree.
- The record of pre-existing changes and the review trigger live only in the run's
  state file, with no copy in the approved spec to compare against. A state edited by hand can
  alter them: the residual risk [ADR-010](ADR-010-run-artifact-cli.md) already accepts
  for that file (a tripwire, not a boundary).
- Whether a change needs review is still decided by the session (the kernel's risk
  triggers), for quick and full runs alike; the helper enforces what follows from that
  decision, not the decision.
- Rejected: replacing the kernel routing table with routing owned by `b-flow` (breaks
  the validators, the optional components, and skill selection before load); raising
  the kernel limit; entering a run from a hook; leaving the quick-or-full choice to
  the prompt alone; a quick run that commits (commit policy would change with every
  edit); a quick run without a spec and plan (it would fork the guards); a quick run
  that skips QA (a second path to the end); a list of review-trigger paths inside the
  helper (not generic, so the helper blocks review in a quick run instead).

Evidence: [`skills/registry.yaml`](../../skills/registry.yaml),
[`skills/b-flow/prompt.md`](../../skills/b-flow/prompt.md),
[`references/kernel.template.md`](../../references/kernel.template.md),
[`claude/bin/b-state.mjs`](../../claude/bin/b-state.mjs),
[`claude/bin/b_run.py`](../../claude/bin/b_run.py),
[`tests/state/state-probe.sh`](../../tests/state/state-probe.sh).
