# ADR-004: Replace OpenCode with Codex as the second runtime

- Status: Accepted
- Date: 2026-11-06
- Supersedes: ADR-002 (the OpenCode runtime, its installer, plugin, and gap table; the runtime-adapter design stays)

## Context

[ADR-002](ADR-002-dual-runtime-support.md) added OpenCode beside Claude Code
through runtime adapters. The user now wants Codex CLI as the second runtime
instead. "No third runtime" still holds, so OpenCode and Codex were never in the
tree together: OpenCode was removed first, then Codex was added.

Codex facts were checked against the official docs, the 0.167.0 source at tag
`rust-v0.167.0`, and the locally installed 0.167.0 binary run in an isolated home
(`codex debug prompt-input`, `codex mcp get`, `codex execpolicy check`, and the
app-server `hooks/list` call):

- Agent roles (`~/.codex/agents/<name>.toml`) load with hyphenated names and
  `spawn_agent` exposes an `agent_type` parameter. A role inherits the parent's
  sandbox, approval policy, provider, and MCP servers; `sandbox_mode` and
  `mcp_servers` in the role file are ignored.
- Skills load from `~/.agents/skills` and tolerate extra frontmatter keys. A global
  `~/.codex/AGENTS.md` loads and is outside `project_doc_max_bytes`.
- Hooks load from `~/.codex/hooks.json`, start untrusted, and are trusted by a hash of
  the hook; `PreToolUse` cannot ask and hook errors fail open. Edits arrive as
  `apply_patch` with the patch text in `tool_input.command`.
- An unknown MCP `approval_mode` makes Codex reject the whole config. Rules match an
  exact argument prefix.

## Decision

Phase 1 (done, `3781b7e5`): remove the OpenCode runtime. Its code, assets, installer,
probes, and docs were deleted; `install.sh --runtime=opencode` is refused with a
pointer to this ADR. The adapter machinery (`references/runtimes.yaml` glossary,
`localize`, `validate_runtimes`, `validate_localization`) was kept.

Phase 2 (done): add Codex, `install.sh --runtime=claude|codex|both` (default `claude`).

- Skills render to `codex/skills` and install to `~/.agents/skills`; specialists are
  `~/.codex/agents/b-*.toml` without model keys (they inherit the session model); the
  kernel is a marked block in `~/.codex/AGENTS.md`; MCP servers are `[mcp_servers.*]`
  tables in `~/.codex/config.toml` owned by name and parsed value (no markers, because
  Codex itself rewrites that file: `codex features enable` and `codex mcp add` move
  and reorder tables), edited textually and proven to leave every other table
  unchanged before the first write; rules install to `~/.codex/rules/b-agentic.rules`.
- One hook adapter (`codex/hooks/b-codex-hooks.mjs`) serves `PreToolUse`, `PostToolUse`,
  and `Stop` over the shared verify gate and the snapshot CLI's secret-path rules, with gate state under
  `~/.codex/b-agentic`. It is not named `b-codex-guard`, which ADR-003 retired.
- Read-only specialists are instructed in their role text and, when a hook payload
  names the role in `agent_type`, a `PreToolUse` check denies `apply_patch` and MCP
  tools outside the role's generated allowlist. Shell writes are not blocked.
- Managed MCP servers prompt by default; classified tools get `approve` or `prompt` by
  class, and ClickUp create and update prompt on every call because a hook cannot ask.
- The installer never writes `sandbox_mode` or `approval_policy`. Uninstall restores
  the managed tables and the kernel block while keeping everything else, including
  tables Codex wrote (`[features]`, `[hooks.state]`, `[projects]`); the Codex config and
  `AGENTS.md` return byte for byte unless Codex or you edited around them (surrounding
  blank lines are normalized), and the hook file is re-serialized with two-space
  indentation. A managed server whose table you or Codex changed is kept and reported.

Gap handling on Codex:

| Claude feature                 | Codex handling                                                                                      |
| ------------------------------ | --------------------------------------------------------------------------------------------------- |
| Read-only specialists          | Instructed, plus a best-effort `apply_patch` and MCP allowlist hook; no tool or sandbox restriction |
| Path guard                     | `apply_patch` headers and shell command words; other reads are unguarded                            |
| Shell `deny`/`ask` patterns    | Exact-prefix rules for the adjacent forms; other patterns are an accepted gap                       |
| ClickUp guard (asks on images) | Every ClickUp create or update prompts                                                              |
| Verify gate                    | Ported through `PostToolUse` and `Stop` (exit 2 with stderr)                                        |
| Outside-project writes         | The user's own `sandbox_mode` and `approval_policy`                                                 |
| `AskUserQuestion`              | Plain-text questions                                                                                |

Invariants: manifest-only ownership, refusal before the first write, user keys preserved
on merge, `~/.pi` never written, `~/.claude` untouched during a Codex-only run and the
reverse.

## Consequences

b-agentic maintains two runtimes again. The generator validates the Codex outputs
(parseable TOML, an asking default per managed MCP server, class-faithful approval
modes, read-only role text, a complete rule set, and the kernel size limit), and the
two new probes cover the installer and the hook adapter in sandbox homes without a
Codex binary.

Accepted residual risks: hooks are a guardrail rather than a boundary (they fail open,
cannot ask, skip hosted tools, and need trusting in `/hooks` after every change);
specialists cannot be sandboxed from an agent file, so shell writes by a specialist are
possible; and these facts were not verified against a live Codex turn and need a smoke
test before relying on them: `agent_type` reaching hook payloads inside a subagent,
`Stop` not firing in subagents, the model-facing MCP tool names, the `approve` mode and
the default for servers without a table, and the shell tool's splitting of compound
commands for rules. Codex support is not version-pinned; the facts above were checked
against 0.167.0, so re-verify them after a Codex upgrade.

Unchanged non-goals: no custom permission engine, no third runtime, no Pi revival, no
per-project Codex installs, no live Codex sessions in CI.

Evidence: [`install.sh`](../../install.sh),
[`tooling/install/codex_install.py`](../../tooling/install/codex_install.py),
[`tooling/generate/registry_sync.py`](../../tooling/generate/registry_sync.py),
[`references/runtimes.yaml`](../../references/runtimes.yaml), and
[`codex/hooks/b-codex-hooks.mjs`](../../codex/hooks/b-codex-hooks.mjs).
