# Decision design

## Scope and evidence

b-agentic is a slim OpenCode workflow kernel. Its maintained scope is the
always-loaded kernel, canonical skills, native MCP configuration, read-only
specialist subagents, and a merge-safe installer. This record describes the
single supported runtime and deliberately avoids a runtime-neutral abstraction.

Evidence: [`references/kernel.template.md`](../references/kernel.template.md),
[`skills/registry.yaml`](../skills/registry.yaml), and
[`opencode/configs/opencode.base.json`](../opencode/configs/opencode.base.json).

## Product boundary and architecture

The runtime boundary is native OpenCode: global assets install under
`~/.config/opencode`, project guidance remains in repository `AGENTS.md`, and
OpenCode discovers skills, agents, commands, and MCP servers from its standard
locations. `references/` and `skills/` are canonical sources;
`tooling/generate/registry_sync.py` renders delivery assets. The installer owns
only b-agentic-managed files, snapshots, backups, and configuration entries.

Evidence: [`install.sh`](../install.sh),
[`opencode/scripts/install.sh`](../opencode/scripts/install.sh), and
[`tooling/generate/registry_sync.py`](../tooling/generate/registry_sync.py).

## Workflow and skill design

The kernel routes an intent to one skill at a time. OpenCode's `skill` tool
loads the canonical skill descriptor; generated `/b-<skill>` commands provide an
explicit path when model-driven selection is unsuitable. Worktree mutation,
user interaction, verification, and reporting remain main-session duties.
Planning, research, debugging, and review delegate through native `subagent` to
four `mode: subagent` profiles, with synchronous returned evidence.

Evidence: [`references/kernel.template.md`](../references/kernel.template.md),
[`skills/registry.yaml`](../skills/registry.yaml), and
[`opencode/agents/b-reviewer.md`](../opencode/agents/b-reviewer.md).

## Safety and approval design

OpenCode v2's ordered native `permissions` rules are the enforcement boundary.
Global rules allow ordinary local work while denying named destructive command
patterns and likely-secret file reads; external directories and consequential MCP
tools remain `ask`. Specialist agents deny `edit`, `shell`, `subagent`, and
`question`.
The kernel adds the workflow requirement to preserve unrelated changes and to
obtain explicit approval for protected, destructive, outside-project, or
external/shared actions.

Native permissions are glob-based. They do not normalize shell wrappers or
compound commands, and direct MCP permissions cannot inspect arguments. An
allowed shell command can also bypass native `read` path rules, so b-agentic
does not claim shell-level secret-path protection. Those limitations are
accepted instead of adding a custom plugin or policy engine.

Evidence: [`opencode/configs/opencode.user.template.json`](../opencode/configs/opencode.user.template.json),
[`opencode/agents/b-researcher.md`](../opencode/agents/b-researcher.md), and
[`references/kernel.template.md`](../references/kernel.template.md).

## MCP and external-evidence design

Managed servers are configured through OpenCode v2 `mcp.servers` with Code Mode
disabled, exposing direct `<server>_<tool>` names. The managed `plugins` array
ships `@cortexkit/opencode-magic-context` for cross-session context management
and sets `compaction.auto: false` so the plugin owns compaction exclusively;
the installer unions managed plugin entries ahead of user entries and removes
them on uninstall. `references/mcp_operations.yaml` classifies each tool;
the generator renders that classification to native `allow`, `ask`, or `deny`
rules. Read-only tools are allowed. Formerly conditional operations are allowed
only by their named tool because argument-aware validation has no native home.
Upload, mutation, monitor-lifecycle, and authentication tools ask first.

Configuration is not evidence that an MCP server is authenticated, reachable,
or used. `mcp-doctor` is local and does not start or authenticate servers.

Evidence: [`references/mcp_operations.yaml`](../references/mcp_operations.yaml),
[`opencode/configs/opencode.user.template.json`](../opencode/configs/opencode.user.template.json), and
[`tooling/validate/mcp_doctor.py`](../tooling/validate/mcp_doctor.py).

## Installation, configuration, and lifecycle

The installer upgrades an existing OpenCode CLI with `opencode upgrade` and
runs OpenCode v2's current curl installer (`https://opencode.ai/v2/install`)
only when `opencode` is not on PATH. It does not manage OpenCode's auto-update preference. Bootstrap repository and
ref inputs are constrained before reaching Git. It installs global kernel, skills, agents,
commands, references, and snapshots under `~/.config/opencode`. It merges the recommended configuration
without replacing unrelated user keys. Since OpenCode configuration may be
JSONC but merge output is JSON, the installer backs up the existing file before
writing and does not promise comment preservation. Uninstall restores only
unmodified managed assets and removes only configuration values introduced by
b-agentic.

Evidence: [`install.sh`](../install.sh),
[`opencode/scripts/install.sh`](../opencode/scripts/install.sh),
[`tooling/install/common.sh`](../tooling/install/common.sh), and
[`tooling/install/manifest_uninstall.py`](../tooling/install/manifest_uninstall.py).

## Verification and change discipline

Canonical sources regenerate before validation. The default suite checks
routing, generated OpenCode assets, capability and MCP policy contracts,
decision-record traceability, behavior rules, and static readiness. Release
validation adds installer smoke coverage. A live OpenCode v2 smoke against a
sandboxed install confirmed `AGENTS.md`, skills, `b-*` agents and commands,
ordered permissions, `mcp.servers`, and `experimental.subagent_depth` load
correctly; MCP servers connect and the only failures are expected credential
gaps. A changed candidate is frozen after fresh checks and reviewed by the
read-only reviewer before normal completion.

Evidence: [`scripts/validate-skills.sh`](../scripts/validate-skills.sh),
[`tooling/validate/behavior.py`](../tooling/validate/behavior.py), and
[`tests/smoke/install.sh`](../tests/smoke/install.sh).

## Intentional non-goals

b-agentic does not maintain a second runtime, compatibility shim, custom
permission engine, argument-aware MCP gate, or TUI extension
package. It does not promise background subagent orchestration, in-session
installer controls, usage reporting, or a bundled theme.
Those omissions keep the supported boundary native, inspectable, and small.
The shipped Magic Context plugin is a managed third-party dependency, not a
b-agentic-authored plugin; it owns context management in place of native
compaction (`compaction.auto: false`).

Evidence: [`README.md`](../README.md),
[`REFERENCE.md`](../REFERENCE.md), and
[`opencode/configs/README.md`](../opencode/configs/README.md).
