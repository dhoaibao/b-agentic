# ADR-023: Per-agent MCP tool scope for the specialists and the writer child

- Status: Accepted
- Date: 2026-11-18
- Supersedes: none; refines [ADR-001](ADR-001-b-agentic-design-record.md) (which MCP tools a
  specialist receives) and [ADR-015](ADR-015-step-writer-worker.md) (the writer child's MCP set)

## Context

Every specialist profile and the writer child received every MCP tool classed `read-only`:
31 tools across CodeGraph, Context7, Brave, Firecrawl, Playwright, draw.io, Excalidraw and
shadcn. [ADR-001](ADR-001-b-agentic-design-record.md) justified one shared set by keeping
private Notion reads out of the `read-only` class, and assumed Claude Code's tool search
defers large tool sets.

A read-only audit of the agent profiles found that this costs context on every spawn:

- A planner child observed the full schemas of all 31 allowlisted tools in its first
  context, not deferred. The size was estimated by eye at about 10,000 tokens and has not
  been measured.
- No delegated skill prompt names a shadcn, Playwright, draw.io or Excalidraw tool. Only
  `b-frontend`, which runs in the main session, names shadcn.
- Each `b-flow` review round after the five-minute subagent cache expires, and each worker
  of a parallel pair, pays this again ([ADR-016](ADR-016-parallel-worker-steps.md)).

## Decision

- **A per-agent allowlist.** Each entry of `agents` in `skills/registry.yaml` carries a
  required `mcp_tools` list. The generator renders an agent's `tools:` line as
  `Read`, `Grep`, `Glob`, `Bash`, its `mcp_tools` in policy order, and its
  `conditional_tools`. The registry check requires every entry to be unique, classed
  `read-only` in `references/mcp_operations.yaml`, and to include
  `mcp__codegraph__codegraph_explore`.
- **The allowlists.** `b-planner`, `b-reviewer`, and `b-auditor` get CodeGraph and the two
  Context7 tools. `b-debugger` adds `firecrawl_developer_search`. `b-researcher` gets
  CodeGraph, Context7, the eight Brave tools, `firecrawl_find_tools`,
  `firecrawl_developer_search`, and the four `firecrawl_research_*` tools, plus its three
  `conditional-read` Firecrawl tools. The Firecrawl job and usage tools
  (`agent_status`, `check_crawl_status`, `credit_usage`) are dropped: no skill names them,
  and a read-only child cannot start the jobs they poll.
- **The writer child** still has no registry field for tools. Its MCP set is exactly
  `b-planner`'s, so the invariant that the worker reads what a specialist reads
  survives, and the self-test and `tooling/validate/mcp_policy.py` check it.
- **Unchanged.** Model and effort, the Notion and DataGrip exclusion, and the main session's
  MCP permissions. A new `read-only` tool no longer reaches a child automatically: it must
  be added to an agent's `mcp_tools`.

## Consequences

- Each of the four three-tool profiles drops about 28 tools from its spawn. The estimate is
  roughly 9,000 tokens per spawn for them and about 3,000 for `b-researcher`, and it is
  not measured. A measurement is a follow-up: spawn `b-planner` with a trivial task before
  and after `./install.sh` and compare the first-turn input tokens.
- MCP server instructions still reach a child for connected servers whose tools are not in
  its allowlist, so this change does not remove that text.
- A skill that later needs another MCP tool in a child must add it to that agent's list. A
  missing tool is reported by the child as a missing tool, not a silent failure.
- Rejected: named tool groups (a schema layer for six consumers); dropping only the unused
  Playwright, draw.io, Excalidraw and shadcn tools (about 15% of the saving, and Brave and
  Firecrawl stay in every child); doing nothing until measured (the eager load was already
  observed); a registry `mcp_tools` field for the worker (it breaks
  [ADR-015](ADR-015-step-writer-worker.md)'s rule that the generator owns the worker's
  tools); reclassifying the unused tools away from `read-only` (it would change the main
  session's auto-allow permissions, a separate concern).

Evidence: [`skills/registry.yaml`](../../skills/registry.yaml),
[`tooling/generate/registry_sync.py`](../../tooling/generate/registry_sync.py),
[`tooling/validate/mcp_policy.py`](../../tooling/validate/mcp_policy.py),
[`references/mcp_operations.yaml`](../../references/mcp_operations.yaml),
[`claude/agents`](../../claude/agents).
