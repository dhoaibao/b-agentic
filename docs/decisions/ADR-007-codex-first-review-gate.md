# ADR-007: Codex-first review gate on Claude Code, with the subagent as fallback

- Status: Accepted
- Date: 2026-11-10
- Supersedes: ADR-003 (the removal of the Codex gate on Claude Code; ADR-003's subagent reviewer stays as the fallback and as OpenCode's gate)

## Context

[ADR-003](ADR-003-subagent-review-gate.md) replaced the Codex gate with the
read-only `b-reviewer` subagent because Codex needed a second subscription, its
usage limit once left a required gate with no verdict, and the wrapper, verdict
mapper, and guard cost about 1,200 lines plus roughly 530 lines of tests. It also
recorded that the subagent may share the main session's model family, so some
blind spots can correlate, and said to revisit if review quality proved worse than
the Codex gate or a cross-vendor reviewer became cheap.

The user wants the cross-vendor Codex review back on Claude Code and wants the
subagent kept for the case that failed before: Codex being unavailable.

## Decision

On Claude Code, `b-review` runs Codex first, through the `openai/codex-plugin-cc`
plugin, and uses `b-reviewer` only as a fallback. The implementation restores the
pre-ADR-003 code rather than rewriting it: `claude/bin/b-codex-review.mjs`,
`claude/bin/b-codex-verdict.mjs`, `claude/hooks/b-codex-guard.mjs`, the guard-only
parts of `claude/bin/b-candidate-snapshot.mjs`, the `plugin.codex-review`
capability, the installer's Codex prerequisite and plugin instructions, and their
tests. The gate keeps its earlier properties: a secret and approval preflight, a
per-repository approval recorded only through `b-codex-guard --approve`, a
mechanical F0/F1 identity check, a foreground run bounded by a timeout and output
cap, and a fail-closed verdict mapper.

What is new:

- **A fallback signal.** The wrapper exits 4 with `status: "unavailable"` when the
  plugin script is missing or the plugin exits non-zero (signed out, usage limit,
  crash). A cheap `--available` probe runs first and reports the missing plugin
  before any approval question, so a user without the plugin is never asked to
  approve a disclosure that cannot happen; a broken override variable makes the probe
  exit 2, a refusal. Exit 4 is the only automatic fallback: main says so in one line and runs
  `b-reviewer` with the same baseline, round, and F0. A refusal (exit 2: likely
  secret, missing approval, untracked symlink) or a void run (exit 3) never falls
  back on its own, because that would route around the protection that stopped it;
  main reports it and the user chooses to rerun or to use `b-reviewer`. When only
  the approval is missing, the question offers `b-reviewer` as the alternative to
  sending the repository to OpenAI. A self-review never substitutes for either gate.
- **One skill, two paths.** `b-review` stays a `subagent`-mode skill with
  `b-reviewer` as its agent, plus a registry `primary_gate` field naming the
  runtime, label, and kernel note. The generator renders a Claude Code variant of
  the skill (Codex steps, a boundary that makes the subagent the fallback, a kernel
  line) and an unchanged OpenCode variant. Runtime-specific prose lives in
  `<!-- runtime:NAME -->` blocks in `skills/b-review/prompt.md`, and a capability may
  carry `runtimes` so OpenCode does not advertise the Codex plugin.
- **A fail-open Bash tripwire.** The `b-codex-guard` hook runs on every Bash call
  and, unlike the file-tool guard, sets no `onFailure: "block"`: a broken copy that
  blocked Bash would block its own repair. The wrapper, not the hook, is the
  boundary, so `tooling/validate/mcp_policy.py` now requires the file-tool guard to
  fail closed and the Bash tripwire to fail open.

OpenCode is unchanged: its gate is `b-reviewer`, its installer does not ship the
Codex scripts, and its capability list omits the Codex plugin.

## Consequences

- Claude Code reviews are cross-vendor again, but they need the `codex` CLI, the
  plugin, a Codex login, and a per-repository disclosure to OpenAI. The installer
  prints the plugin commands and never runs them. Without them, or at a usage
  limit, the review falls back to `b-reviewer` instead of having no verdict.
- The fallback review is the weaker independence ADR-003 described (same model
  family possible). The report names which gate ran and why, so a `b-reviewer`
  verdict is not mistaken for a Codex one.
- Roughly 1,200 lines of guard, wrapper, and mapper code and their hook,
  snapshot, and install tests return to the maintenance surface, plus a second
  review path to keep in sync. The behavior fixtures cover the exit-4 fallback and
  the no-fallback-on-refusal rule.
- The per-repository approval store (a JSON file in the install directory) is read again; an upgrade from the
  subagent-only release leaves it untouched, and uninstall never removes it. The
  upgrade adds the Codex scripts and the Bash hook once, beside any hook the user
  already has on Bash.
- Accepted residual risks are those of the earlier Codex gate: Codex's sandbox can
  read every workspace file and has no ignore mechanism, the guard scans path names
  rather than content, and plugin command syntax and result shape are not exercised
  live by this repository's checks. No claim is made that Codex finds more or fewer
  defects than the subagent; the choice rests on model-family independence.
- Revisit if the usage limit or subscription cost makes Codex unavailable often
  enough that the fallback is the normal path, or if the wrapper's maintenance cost
  outweighs the independence it buys.

Evidence: [`skills/registry.yaml`](../../skills/registry.yaml),
[`skills/b-review/prompt.md`](../../skills/b-review/prompt.md),
[`tooling/generate/registry_sync.py`](../../tooling/generate/registry_sync.py),
[`claude/bin/b-codex-review.mjs`](../../claude/bin/b-codex-review.mjs),
[`claude/bin/b-codex-verdict.mjs`](../../claude/bin/b-codex-verdict.mjs),
[`claude/hooks/b-codex-guard.mjs`](../../claude/hooks/b-codex-guard.mjs),
[`claude/bin/b-candidate-snapshot.mjs`](../../claude/bin/b-candidate-snapshot.mjs),
[`tooling/install/claude_install.py`](../../tooling/install/claude_install.py),
[`tooling/validate/mcp_policy.py`](../../tooling/validate/mcp_policy.py),
[`tests/hooks/hooks-probe.sh`](../../tests/hooks/hooks-probe.sh),
[`tests/install/claude-install-probe.sh`](../../tests/install/claude-install-probe.sh), and
[`REFERENCE.md`](../../REFERENCE.md).
