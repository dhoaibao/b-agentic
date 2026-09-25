# Decision design

## Scope and evidence

b-agentic supports one runtime, native Pi. It ships an always-loaded kernel,
canonical skills, named read-only specialists, managed MCP configuration, and a
merge-safe installer.

Evidence: [`references/kernel.template.md`](../references/kernel.template.md),
[`skills/registry.yaml`](../skills/registry.yaml), and
[`pi/configs/settings.base.json`](../pi/configs/settings.base.json).

## Product boundary and architecture

Global assets install under Pi's agent directory (`~/.pi/agent` by default);
project guidance remains in repository `AGENTS.md`. Canonical policy and skill
sources live in `references/` and `skills/`; the registry generator renders Pi
prompt templates, subagent profiles, skill descriptors, and permission policy.
The installer owns only its recorded assets, snapshots, backup files, and
merged configuration entries.

Evidence: [`install.sh`](../install.sh),
[`pi/scripts/install.sh`](../pi/scripts/install.sh), and
[`tooling/generate/registry_sync.py`](../tooling/generate/registry_sync.py).

## Workflow and skill design

The kernel selects one skill at a time. Pi discovers skill descriptors, and generated
`/b-<name>` prompt templates supply an explicit route and registry-backed
parent evidence handoffs for audit, debug, and changed-code review. The main
session reads the delegated skill and gathers that evidence before launch.
Worktree mutation, user interaction, verification, and reporting stay in the
main session. b-agentic generates four named specialist profiles for the
`@gotgenes/pi-subagents` extension to run. Each child reads its named skill,
uses a tool list without edit/write, questions, or nested delegation, and returns the skill's own output format. Read-only shell behavior
is instructed rather than enforced by a child-specific permission policy.
Foreground is default; background work is independent and read-only,
in-process, and lost when its parent ends. Compatible continuation requires the supported `resume`
identifier; different scope/baseline and an independent reviewer use a fresh
child. The registry retains explicit provider/model and thinking choices; no
silent model substitution is made.

Evidence: [`references/kernel.template.md`](../references/kernel.template.md),
[`skills/registry.yaml`](../skills/registry.yaml), and
[`pi/agents/b-reviewer.md`](../pi/agents/b-reviewer.md).

## Safety and approval design

`@gotgenes/pi-permission-system` gates main and child tools. The generated
global policy allows ordinary repository-local edits and skill invocation, denies
protected path patterns, named dangerous commands, and outside-project writes,
and asks before outside-project reads, unknown MCP tools, proxy tool calls, and
consequential actions.
Known read-only direct MCP operations are allowed by exact tool name; proxy
calls still ask because its targets cannot securely bind the tool to its server.
Invoking a skill never bypasses tool and path gates for its subsequent work.
Specialist profiles expose read and shell tools plus named observation-only
direct MCP tools; `b-researcher` additionally exposes four bounded public
Firecrawl search/extraction tools classified `conditional-read`. They have no
per-agent permission block; nested delegation and user questions are not on
their tool lists. The global Pi permission policy still applies to their calls. A shell can mutate files inside the repo or
invoke external services, so the read-only specialist boundary now depends on
instructions, not enforcement by a child-specific command allowlist. The shared
permission policy's named denials are not a process sandbox.
The kernel additionally requires approval for other destructive, privileged,
ambiguous, protected, and external/shared actions. Pi permission rules and
adapter tool matching are not filesystem or process isolation. Shell indirection and
MCP argument fields not recognized by the path gate remain residual risks.
An offline stub-provider integration probe tests representative parent/child
allow/deny and direct/proxy MCP decisions. Interactive approval UI and real
server/provider access are separate evidence, not inferred from static config.

Evidence: [`pi/configs/permission.user.template.json`](../pi/configs/permission.user.template.json),
[`pi/agents/b-researcher.md`](../pi/agents/b-researcher.md), and
[`tests/pi/permission-probe.sh`](../tests/pi/permission-probe.sh).

## MCP and external-evidence design

Seven servers use `pi-mcp-adapter`'s lazy `mcpServers` config and direct
`<server>_<tool>` names. Per-server direct-tool lists eagerly register only
operations allowed by `references/mcp_operations.yaml`; other operations remain
available through the separately gated proxy, which asks for calls. This keeps
the eager set below the adapter's advisory threshold without disabling tools.
Script mode and model-driven installs are disabled. The policy classifies known
tools; allowed direct names avoid proxy approval, while consequential and
unknown operations ask. The adapter does not make configuration a live server
or authentication proof. `mcp-doctor` checks only local configuration, launcher,
and variable presence; it starts no MCP or browser sessions. Magic Context
provides context management and durable memory in the main session, with Pi
native compaction disabled for new settings. The installer excludes Magic Context from specialist children to prevent full main-session
context guidance without its tools; children have no compaction under the new
settings default and should be kept bounded. Project-level pi-subagents
exclusions can override the global list; existing user preferences are preserved.
Provider usage, Anthropic OAuth request shaping, and Antigravity model
routing are user-requested optional capabilities of the eight managed
extensions, not login or entitlements. Antigravity OAuth login (`/login
antigravity`) is at the user's discretion and risk; third-party Antigravity
OAuth clients carry Google account suspension risks. Its registered
`generate_image` tool is gated by the default ask policy in the main session and
excluded from read-only specialists.

Evidence: [`references/mcp_operations.yaml`](../references/mcp_operations.yaml),
[`pi/configs/mcp.base.json`](../pi/configs/mcp.base.json),
[`pi/configs/subagents.base.json`](../pi/configs/subagents.base.json), and
[`tooling/validate/mcp_doctor.py`](../tooling/validate/mcp_doctor.py).

## Installation, configuration, and lifecycle

Existing Pi is updated with `pi update --self`; first install uses the latest
unversioned npm package. Eight extensions are installed with bare npm names and
updated through `pi update --extensions`. Bootstrap repository/ref inputs are
constrained before Git. Installer sync copies the kernel, skills, specialists,
prompts, references, and templates; it merges settings, specialist exclusions,
shared CortexKit config, MCP, and permission JSON while preserving unrelated
values and ordered user arrays. Managed package and specialist-exclusion lists
union with existing user entries. Existing JSONC is backed up before a JSON
rewrite. Uninstall removes only owned unmodified assets and values; symlinks or changed files retain metadata for a safe retry.

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
Every candidate gets an inspected diff and applicable checks. Classify the
final change against the task baseline. Independent read-only review is required
by request or for security/privacy/authority, data integrity, externally
consumed contracts, dependencies/runtime configuration, installer or user-config
merge behavior, approval/safety/delegation/review/commit/routing policy,
behavior across independently owned subsystems, or a concrete risk checks do
not cover. Routine skill-prompt wording is not automatically policy. Direct
tests/docs and faithfully regenerated outputs count with their source, not as
extra subsystems. A bounded, clear, verified low-risk change may skip review
with its reason reported. Failed checks or unexpected paths block completion;
ambiguous acceptance goes to the user. Review records HEAD, staged and
unstaged binary-diff digests, and relevant untracked path/type/content digests.
The reviewer checks that identity at the start and end, and main checks it on
return; a changed snapshot needs fresh
checks and a new review. Protected paths require permission before content is
hashed.

Evidence: [`scripts/validate-skills.sh`](../scripts/validate-skills.sh),
[`tooling/validate/behavior.py`](../tooling/validate/behavior.py), and
[`tests/smoke/install.sh`](../tests/smoke/install.sh).

## Intentional non-goals

b-agentic does not maintain a second runtime, custom permission engine,
argument-aware MCP gate, persistent subagent store, or bundled TUI extension.
It does not promise detached background work, authenticated MCP readiness from
configuration, or unbounded orchestration. Magic Context owns Pi context
management; `rpiv-todo` is not installed.

Evidence: [`README.md`](../README.md),
[`REFERENCE.md`](../REFERENCE.md), and
[`pi/configs/README.md`](../pi/configs/README.md).
