# Pi permission integration probe

This gate checks the proposed Pi runtime extensions against a local stub model
and a local stdio MCP server. No model credentials or external MCP connections
are needed. It exercises main-session decisions, read-only specialist tool
visibility and policy, protected paths, MCP proxy denial, and dynamically
registered direct MCP tools. The probe does not test interactive approval UI,
real providers, or the seven production MCP servers.

Run `bash tests/pi/permission-probe.sh --setup` to install the six unpinned
extension packages into the ignored `node_modules/.pi-migration-probe` profile
and execute the cases. Setup downloads public npm packages. Subsequent offline
runs use `bash tests/pi/permission-probe.sh`. The isolated profile sets
`PI_CODING_AGENT_DIR`, `PI_OFFLINE`, `PI_SKIP_VERSION_CHECK`, and `PI_TELEMETRY`;
the stub provider never contacts its dummy endpoint. The script writes its
fixture policy, agent, and JSON event traces only under the ignored profile.

Installed package declarations use bare `npm:` names. Re-running setup updates
the installed extensions to their latest available releases. The probe does
not establish live readiness for production MCP servers or real providers.
