# ADR-027: The Antigravity runtime is removed again; Claude Code only

- Status: Accepted
- Date: 2026-11-19
- Note: [ADR-030](ADR-030-pi-runtime-rendered-at-install.md) supersedes the no-second-runtime decision below by adding Pi as an opt-in second runtime; the Antigravity removal recorded here still stands.
- Supersedes: ADR-025 (Antigravity CLI as the second runtime); [ADR-020](ADR-020-claude-code-only-again.md) is Accepted again

## Context

[ADR-025](ADR-025-antigravity-second-runtime.md) added Antigravity (`agy`, config under `~/.gemini`) as an
opt-in second runtime: a generated `antigravity/` tree, a hook adapter, an installer, probes, and docs, in the
commits `a3e33ad9` through `caf570fd`. Commit `84b7e40f` reverted that whole range on the same day. Its message
records no reason; the tree it leaves is identical to the one before `a3e33ad9`.

The revert deleted ADR-025 and restored ADR-020 to Accepted, but recorded no decision, so no tracked file
said what ADR-025 was or that it was withdrawn. [`AGENTS.md`](../../AGENTS.md) and
[`REFERENCE.md`](../../REFERENCE.md) still named `f80281b7` as the last second-runtime tree, which is no longer
true: the Antigravity tree was last present at `caf570fd`.

## Decision

- Claude Code is the only runtime again, as [ADR-020](ADR-020-claude-code-only-again.md) decided. ADR-025 is kept
  as a Superseded record of what was tried and why it was specified that way; its removed paths are plain text.
- [`install.sh`](../../install.sh) refuses any `--runtime` other than `claude`, as before ADR-025.
- An Antigravity install an earlier checkout left under `~/.gemini` is not touched by this repository. The
  installer recorded a manifest at `~/.gemini/config/b-agentic/install.json`. Uninstall it from a checkout of
  `caf570fd` with `./install.sh --runtime=antigravity --uninstall`, or remove the b-agentic entries there by hand
  (the `b-agentic` hook group, MCP servers, rule file, skills, agents, and permission rules the manifest lists).
- Adding a second runtime again needs a new ADR that supersedes this one.

## Consequences

- No source, generated, or installer file describes Antigravity; only ADR-025, this record, and the pointer docs
  (`REFERENCE.md`, `AGENTS.md`, `docs/decisions/README.md`) mention it. The runtime parity, installer, and
  generated-tree checks it needed are gone with the tree, and `references/runtimes.yaml` holds only the `claude`
  entry.
- A user who still has the `~/.gemini` install keeps its hooks, and a failing hook blocks every `agy` tool, so
  they follow the uninstall note above or remove the hook group.
- The number 025 stays with the Superseded record and is never reused; ADR-026 was written while it was missing.

Evidence: [`install.sh`](../../install.sh),
[`references/runtimes.yaml`](../../references/runtimes.yaml), and
[`docs/decisions/ADR-020-claude-code-only-again.md`](ADR-020-claude-code-only-again.md).
