# ADR-003: Read-only subagent as the independent review gate

- Status: Accepted
- Date: 2026-11-04
- Supersedes: ADR-001 (the Codex review-gate passages in Context and under "Workflow and skill design", "Safety and approval design", and "Verification and change discipline") and ADR-002 (the Codex gate on OpenCode)

## Context

ADR-001 moved the independent changed-code gate from a cross-vendor Pi
`b-reviewer` to Codex, run through the `openai/codex-plugin-cc` plugin and a
wrapper, because Claude Code specialists are Anthropic-only. That bought a
different model family, a sandbox-enforced read-only reviewer, and a mechanical
snapshot check, at the cost of a second Codex subscription, a usage limit, a
disclosure to OpenAI that needs per-repository approval, and about 1,200 lines of
guard, wrapper, and verdict-mapper code plus roughly 530 lines of hook tests.

The user reported that the Codex gate needs a separate subscription. In practice
the gate also failed at its usage limit with no verdict (`b-codex-review.mjs`
exit 2, "You've hit your usage limit"), so a required gate was unavailable when
the kernel required it. Two read-only Opus subagent reviews run through the
`b-planner` profile as a stand-in found no blockers on a kernel change and one
real wording ambiguity, which the main session then fixed. They were not compared
against Codex, so no claim is made that the subagent finds more or fewer defects.

Claude Code documents that a named, non-fork subagent starts with a fresh context
and uses its own `model` field, while a fork inherits the full conversation
(`code.claude.com/docs/en/sub-agents`). That is the property that matters most
for independence from the implementer.

## Decision

`b-review` is a delegated skill again, run only by a new read-only `b-reviewer`
specialist (`opus`, effort `high`; OpenCode `claude-agent/opus#high`), generated
from `skills/registry.yaml` like the other four specialists. The main session
freezes the candidate with `b-candidate-snapshot` (F0), calls the reviewer by its
named type with the baseline, target, acceptance, check results, candidate paths,
F0, and relevant ignored paths, and never the implementer's rationale. The
reviewer recomputes the snapshot at start and end, classifies findings against the
unchanged blocker taxonomy, and ends with one `Verdict:` line; the main session
recomputes the fingerprint after it returns and voids the review on any
difference. A missing or failing reviewer is reported and asked about, never
replaced by a self-review. The 3-round `NEEDS FIXES` stop, same-class sweeps, and
follow-up dispositions are unchanged.

The Codex wrapper (`b-codex-review.mjs`) and verdict mapper (`b-codex-verdict.mjs`)
are removed, as is the `plugin.codex-review` capability and the installer's Codex
prerequisite and plugin instructions. The `b-codex-guard` hook and its tests stay
for now as a dormant tripwire for direct `/codex:*` calls and the user-owned
approval store is left in place; removing them needs an installer change that
retires hook entries no longer in the template (`plan_settings` retires permission
rules but not hooks), so it is a separate change. Upgrades delete unmodified
copies of the removed CLIs and keep modified ones with a warning, through the
existing manifest logic.

## Consequences

- No second subscription, login, plugin, or approval for review, and the
  candidate goes to no new recipient. The gate is available whenever a Claude
  subagent is.
- Independence is weaker than cross-vendor: the reviewer shares the main
  session's model family, so some blind spots correlate. For a high-risk change
  (security, permissions, secrets) the user can still run the Codex plugin by hand
  as an extra opinion; it is not part of the gate.
- Read-only is instructed on Claude Code (the tool list omits `Edit`, `Write`,
  `NotebookEdit`, and nested delegation) and enforced by `permissions` on OpenCode.
  Shell access can still mutate state. The fingerprint recomputation catches any
  change to tracked or named files, not a change to an ignored or
  outside-repository file that was never named.
- Whether PreToolUse hooks such as the path guard fire for subagent tool calls was
  not verified live; hook input carries an `agent_id` for subagent calls
  (ADR-001), so the path guard and deny rules are expected to apply.
- Existing installs keep working: the installer retires the removed CLIs and adds
  `agents/b-reviewer.md`. The retired OpenCode install really shipped an agent
  named `b-reviewer`, and the migration fixtures that modeled it now use a
  different retired name, so a real legacy `b-reviewer` migration is untested
  (a recorded follow-up).
- Effort (refined 2026-11-04): the reviewer first shipped at `xhigh` and was
  lowered to `high`, together with `b-planner`, on public benchmark and
  documentation evidence (Anthropic reserves `xhigh` for measured gains; a vendor
  code-review benchmark and Artificial Analysis favor `high` on quality per cost;
  the same benchmark found `xhigh` caught the most hard bugs at lower precision,
  which matters for a gate that exists to catch blockers), without a replay on
  this repository. The OpenCode `#high` variant was not
  verified locally. Revisit with measured wall-clock, tokens, rounds per change,
  and real versus disputed blockers; return to `xhigh` if `high` misses blockers.
- Revisit if review quality proves worse than the Codex gate, or if a cheap
  cross-vendor reviewer becomes available without a second subscription.

Evidence: [`skills/registry.yaml`](../../skills/registry.yaml),
[`skills/b-review/prompt.md`](../../skills/b-review/prompt.md),
[`tooling/generate/registry_sync.py`](../../tooling/generate/registry_sync.py),
[`tooling/validate/behavior.py`](../../tooling/validate/behavior.py),
[`claude/bin/b-candidate-snapshot.mjs`](../../claude/bin/b-candidate-snapshot.mjs),
[`claude/hooks/b-codex-guard.mjs`](../../claude/hooks/b-codex-guard.mjs),
[`tests/install/claude-install-probe.sh`](../../tests/install/claude-install-probe.sh), and
[`REFERENCE.md`](../../REFERENCE.md).
