# Decision design

## Scope and evidence

b-agentic supports one runtime, native Pi. It ships an always-loaded kernel,
canonical skills, named read-only specialists, managed MCP configuration, and a
merge-safe installer. The hard cut replaces the previous OpenCode runtime
without maintaining a compatibility shim.

Evidence: [`references/kernel.template.md`](../references/kernel.template.md),
[`skills/registry.yaml`](../skills/registry.yaml), and
[`pi/configs/settings.base.json`](../pi/configs/settings.base.json).

## Product boundary and architecture

Global assets install under Pi's agent directory (`~/.pi/agent` by default);
project guidance remains in repository `AGENTS.md`. Canonical policy and skill
sources live in `references/` and `skills/`; the registry generator renders Pi
prompt templates, subagent profiles, skill descriptors, and permission policy.
The installer owns only its recorded assets, snapshots, backup files, and
merged configuration entries. It does not touch a user's old OpenCode install.

Evidence: [`install.sh`](../install.sh),
[`pi/scripts/install.sh`](../pi/scripts/install.sh), and
[`tooling/generate/registry_sync.py`](../tooling/generate/registry_sync.py).

## Workflow and skill design

The kernel selects one skill at a time. Pi discovers skill descriptors, and generated
`/b-<name>` prompt templates supply an explicit route. Worktree mutation,
user interaction, verification, and reporting stay in the main session. The
`@gotgenes/pi-subagents` extension supplies four named specialists. Each child
reads its named skill, applies a complete tool allowlist and per-agent
permission policy, and returns the skill's own output format. Foreground is
default; background work is independent and read-only, in-process, and lost
when its parent ends. Compatible continuation requires the supported `resume`
identifier; different scope/baseline and an independent reviewer use a fresh
child. The registry retains explicit provider/model and thinking choices; no
silent model substitution is made.

Evidence: [`references/kernel.template.md`](../references/kernel.template.md),
[`skills/registry.yaml`](../skills/registry.yaml), and
[`pi/agents/b-reviewer.md`](../pi/agents/b-reviewer.md).

## Safety and approval design

`@gotgenes/pi-permission-system` gates main and child tools. The generated
global policy allows ordinary local edits, denies protected path patterns and
named destructive commands, and asks before external directories, unknown MCP
tools, and consequential actions. Specialist profiles deny by default and
allow only read, bounded inspection shell, and named observation-only direct
MCP tools; nested delegation and user questions are not on their tool lists.
The kernel additionally requires approval for protected, destructive,
outside-project, and external/shared actions. Pi permission rules and adapter
tool matching are not filesystem or process isolation. Shell indirection and
MCP argument fields not recognized by the path gate remain residual risks.
An offline stub-provider integration probe tests representative parent/child
allow/deny and direct/proxy MCP decisions. Interactive approval UI and real
server/provider access are separate evidence, not inferred from static config.

Evidence: [`pi/configs/permission.user.template.json`](../pi/configs/permission.user.template.json),
[`pi/agents/b-researcher.md`](../pi/agents/b-researcher.md), and
[`tests/pi/permission-probe.sh`](../tests/pi/permission-probe.sh).

## MCP and external-evidence design

Seven servers use `pi-mcp-adapter`'s lazy `mcpServers` config and direct
`<server>_<tool>` names. The generic proxy is separately gated. Script mode
and model-driven installs are disabled. `references/mcp_operations.yaml`
classifies known tools; read-only names are allowed, consequential names ask,
and unknown names ask. The adapter does not make configuration a live server
or authentication proof. `mcp-doctor` checks only local configuration, launcher,
and variable presence; it starts no MCP or browser sessions. Pi native
compaction is the default; no dynamic pruning or durable memory plugin is
installed. Provider usage and Anthropic OAuth request shaping are user-requested
optional capabilities of the six managed extensions, not login or entitlements.

Evidence: [`references/mcp_operations.yaml`](../references/mcp_operations.yaml),
[`pi/configs/mcp.base.json`](../pi/configs/mcp.base.json), and
[`tooling/validate/mcp_doctor.py`](../tooling/validate/mcp_doctor.py).

## Installation, configuration, and lifecycle

Existing Pi is updated with `pi update --self`; first install uses the latest
unversioned npm package. Six extensions are installed with bare npm names and
updated through `pi update --extensions`. Bootstrap repository/ref inputs are
constrained before Git. Installer sync copies the kernel, skills, specialists,
prompts, references, and templates; it merges settings, MCP, and permission
JSON while preserving unrelated values and ordered user arrays. Existing JSONC
is backed up before a JSON rewrite. Uninstall removes only owned unmodified
assets and values; symlinks or changed files retain metadata for a safe retry.
An existing OpenCode installation is outside this lifecycle boundary.

Evidence: [`install.sh`](../install.sh),
[`pi/scripts/install.sh`](../pi/scripts/install.sh),
[`tooling/install/common.sh`](../tooling/install/common.sh), and
[`tooling/install/manifest_uninstall.py`](../tooling/install/manifest_uninstall.py).

## Verification and change discipline

Canonical sources regenerate before static validation. The suite checks
routing, Pi assets, capability/MCP policy, decision traceability, and local
readiness. Release validation adds sandboxed installer smoke. The offline Pi
integration probe uses a deterministic stub model and local MCP fixture, with
explicit limitations for live providers, UI approval, and production servers.
Every candidate gets an inspected diff and applicable checks. Independent
read-only review is required by request or when changing security, privacy,
data integrity, public contracts, dependencies/runtime config, installer or
workflow policy, multiple subsystems, or when acceptance/risk is uncertain.
Review freezes the exact checked candidate; a changed snapshot needs fresh
checks and a new review. A bounded clear low-risk change may skip independent
review only with its exception reported.

Evidence: [`scripts/validate-skills.sh`](../scripts/validate-skills.sh),
[`tooling/validate/behavior.py`](../tooling/validate/behavior.py), and
[`tests/smoke/install.sh`](../tests/smoke/install.sh).

## Intentional non-goals

b-agentic does not maintain a second runtime, custom permission engine,
argument-aware MCP gate, persistent subagent store, or bundled TUI extension.
It does not promise detached background work, authenticated MCP readiness from
configuration, unbounded orchestration, or an automatic migration of the
user-owned OpenCode installation. Native Pi compaction replaces the prior DCP
strategy; `rpiv-todo` and Magic Context are not installed.

Evidence: [`README.md`](../README.md),
[`REFERENCE.md`](../REFERENCE.md), and
[`pi/configs/README.md`](../pi/configs/README.md).
