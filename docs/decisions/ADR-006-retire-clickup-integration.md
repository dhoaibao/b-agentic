# ADR-006: Retire ClickUp integration

- Status: Accepted
- Date: 2026-11-08
- Supersedes: ADR-001 (ClickUp MCP, skill, and guard); ADR-002 (ClickUp-specific runtime behavior)

## Context

b-agentic previously shipped a ClickUp skill, an opt-in MCP server, and a
Claude Code image-reference guard. The user requested their removal.

## Decision

Remove first-party ClickUp support and installer options in both runtimes.
During upgrades, use the existing manifest ownership and pending-operation
mechanisms to retire unchanged managed entries, preserving user-owned or edited
configuration and any hook script still referenced by user settings.

Evidence: [`tooling/install/claude_install.py`](../../tooling/install/claude_install.py),
[`tooling/install/opencode_install.py`](../../tooling/install/opencode_install.py),
[`references/mcp_operations.yaml`](../../references/mcp_operations.yaml).

## Consequences

ClickUp is no longer included, enabled, or explicitly permitted by b-agentic.
Users may configure their own integrations; unclassified MCP tools remain subject
to the normal approval boundary. Existing tokens and user-owned settings are not
removed.
