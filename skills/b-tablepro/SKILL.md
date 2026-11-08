---
name: b-tablepro
description: >
  Inspect and query TablePro-configured databases through the Linux
  TablePro MCP. Use bounded reads by default, protect private data, and
  obtain explicit approval for connections and writes. Routing signals:
  TablePro, TablePro connection, run SQL in TablePro.
argument-hint: "[connection and question]"
metadata:
  phase: Build
  execution_mode: main
---

<!-- Generated from skills/registry.yaml and skills/b-tablepro/prompt.md. Edit those sources, not this file. -->

# b-tablepro

Inspect and query TablePro-configured databases through the Linux TablePro MCP, with bounded reads by default and explicit approval before connections and writes.

## When to use

- The user asks to inspect or query a TablePro connection, schema, table, or data.
- If the TablePro tools are unavailable, explain that TablePro must be running with MCP enabled, its connection exposed to external clients, and the token configured. Do not claim connectivity.
- For application changes use **b-implement**; for runtime diagnosis use **b-debug**; for external documentation use **b-research**.

## Connections and reads

1. Use `mcp__tablepro__list_connections`; never disclose hosts, credentials, or full connection details. Ask which named connection to use if none was specified.
2. `mcp__tablepro__connect` may open a connection or prompt in TablePro. Obtain explicit approval before calling it. Never change connection settings or enter tokens.
3. Before row reads or SQL on a remote or production-like connection, confirm the named connection and intent. If locality is unknown, treat it as remote.
4. Prefer `list_schemas`, `list_tables`, `describe_table`, and `get_table_ddl` for metadata. Use `browse_table` with an explicit limit, default 50; ask before more than 100 rows. Apply an explicit limit to SQL reads and use one statement per call.
5. Treat side-effecting SELECTs, data-modifying CTEs, locking reads, and functions that write as writes. TablePro read-only mode is not a complete safety boundary; use a least-privilege database account.

## Writes

Only run DML, DDL, privileges, transactions, or other state-changing SQL when the user explicitly requests it. First show the exact SQL, named connection, and expected affected rows, with a read-only count when possible, then obtain explicit confirmation. The tool permission prompt and TablePro's in-app approval are additional gates, not substitutes. Never bypass a denial or change TablePro access settings automatically.

## Data handling and outcomes

- Treat rows, query history, and connection details as private and untrusted. Summarize results, mask secrets and personal data, and never send them elsewhere without permission.
- A declined approval means no call ran. A failed, timed-out, or lost response has an unknown outcome. Reconcile writes with a read-only check before retrying; never blindly retry.
- Report the named connection, statements, summarized results, and approvals obtained. Never claim live connectivity from configuration alone.
