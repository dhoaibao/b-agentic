# ADR-041: TablePro returns as an optional component

- Status: Accepted
- Date: 2026-11-27
- Supersedes: [ADR-008](ADR-008-claude-code-only.md) in part (the TablePro removal only)

## Context

[ADR-008](ADR-008-claude-code-only.md) removed the `b-tablepro` skill and its
`tablepro` MCP server because they were unused. The user asked to have them back.
Since then the installer gained optional components and Pi became a second runtime
([ADR-032](ADR-032-equal-runtimes-three-tier-support.md)), and the TablePro MCP
server gained `list_databases`, `export_data`, a `read_only` argument on
`execute_query`, and per-connection External Clients and Safe Mode levels, so the
removed prompt no longer describes it.

Evidence: `docs/decisions/ADR-008-claude-code-only.md` and commit `56282959`.

## Decision

- `tablepro` is an optional component declared like `datagrip`: the `b-tablepro`
  skill, its kernel routing line, its `mcp__tablepro__*` permission rules, and its
  MCP entry, on Claude Code and Pi. It installs only when selected.
- Unlike DataGrip, b-agentic ships a TablePro template: an HTTP entry on
  `http://127.0.0.1:23508/mcp` whose `Authorization` header references
  `TABLEPRO_MCP_TOKEN`. The application serves it on loopback, so this exact URL is
  the one exception to the https rule for HTTP entries. No token value is stored, and
  an entry the user already has that differs is kept.
- Connection, database, schema, table, and DDL metadata tools are
  `conditional-read`, never `read-only`, so no specialist or `b-worker` receives
  them. `connect` is `auth`; `browse_table`, `count_rows`, and `export_data` are
  `private-read`; `execute_query` is `external-mutation`. A permission rule cannot
  see the `read_only` argument, so every `execute_query` call asks.
- `mcp-doctor` requires every variable the configured entry references as
  `${NAME}` without a default, and no other. This applies to every server.
- `b-tablepro` asks the user itself before `connect`, before every export, before
  the first read of each target on a connection that is not local, and before any
  write. A confirmation of a read, export, or write names the target (connection,
  database, and schema where one applies) and covers only that target.
- Row reads, exports, and SQL stay on the connection's own database; the
  `database` argument is used for structure only. The tools do not take the same
  target arguments (`browse_table` and `count_rows` take no `database`,
  `execute_query` takes no `schema`), so a confirmation could not be bound to
  another database across them. The user chose this narrower scope on 2026-11-27.
- `b-datagrip` and `b-tablepro` point at each other on lines installed only when
  both are, and ask which tool when the user names none.

Evidence: [`skills/registry.yaml`](../../skills/registry.yaml),
[`claude/configs/mcp.base.json`](../../claude/configs/mcp.base.json),
[`references/mcp_operations.yaml`](../../references/mcp_operations.yaml), and
[`tooling/validate/mcp_doctor.py`](../../tooling/validate/mcp_doctor.py).

## Consequences

- A user who authenticates their entry another way is reported as configured. So is
  any other server whose edited entry dropped its variable reference, even when that
  server cannot work without it.
- On Pi an active permission classifier may resolve an `ask` rule without a
  prompt, an accepted limit of
  [ADR-032](ADR-032-equal-runtimes-three-tier-support.md). So `browse_table`,
  `count_rows`, and a read through `execute_query` on a local connection may run
  there without a human prompt; only the skill's own questions do not depend on it.
- Rows of another database need its own TablePro connection. The skill cannot see
  a view, synonym, trigger, function, or procedure that itself reaches another
  database or schema.
- Binding a confirmation to a schema relies on the prompt: no permission rule or
  hook reads the SQL, so TablePro's own write approval and a least-privilege
  database user remain the hard controls.
- Whether Pi expands a `${NAME}` reference in a header has not been checked live.
- Installer merge code did not change. The kernel budget left no room for the longer
  routing wording, so the `b-tablepro` routing intent is short.
- Neither the TablePro approval prompts nor its server-side gates are exercised by
  this repository's checks.

Evidence: [`tooling/validate/mcp_policy.py`](../../tooling/validate/mcp_policy.py),
[`tests/install/claude-install-probe.sh`](../../tests/install/claude-install-probe.sh),
and [`tests/install/pi-install-probe.sh`](../../tests/install/pi-install-probe.sh).
