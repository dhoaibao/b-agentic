# b-agentic Decision Design

This is a compact, evidence-backed summary of current b-agentic design decisions.
Canonical sources remain authoritative: this record does not replace the kernel,
skill prompts, policy, installer, or tests. It records durable choices and
boundaries, not a change history or a second runtime contract. Evidence:
`README.md`, `AGENTS.md`, `references/kernel.template.md`,
`tooling/validate/decision_design.py`.

## Scope and evidence

b-agentic and Pi are one integrated personal workflow product with Pi as the shipped runtime; this record summarizes current decisions supported by tracked repository sources.

### Slim, strong, and usable

- **Slim:** choose the smallest evidence-backed fit; remove duplication, ceremony, and speculative complexity.
- **Strong:** preserve explicit safety, evidence, and verification boundaries, with a small observable check when a decision changes.
- **Usable:** retain direct, predictable user paths.
  This decision applies to future b-agentic repository source, docs, tooling, and CI changes, including skills, installers, extensions, configuration, validators, and tests; it does not apply to the installed runtime kernel or create a generic runtime policy. Necessary compatibility/security fixes remain in scope, so slimness never demands cosmetic reduction.
  Evidence: `AGENTS.md`, `README.md`, `REFERENCE.md`, `tooling/validate/decision_design.py`.
- **Measured kernel budget and routing metadata:** Keep the 12,800-byte ceiling and 120-line cap for the always-loaded `references/kernel.template.md`; `tooling/validate/suite_audit.py` enforces both. Registry routing intents remain in the kernel, while trigger vocabulary is rendered into each active skill description so routing detail does not consume global context. Any future limit raise remains a measured exception for a guarantee that cannot be expressed elsewhere, not a standing allowance.

## Product boundary and architecture

### Runtime and ownership

- Ship a compact Pi kernel, native skills, first-party Pi extensions, and
  recommended MCP configuration; do not add a runtime-neutral adapter layer.
- Keep shared guidance in `references/`; keep Pi integration, configuration,
  extensions, scripts, and smoke coverage under `pi/`. Keep the always-loaded
  kernel within its measured line and byte limits; a limit exception requires an
  explicit decision rather than a silent increase or weakened rule.
- `skills/registry.yaml` owns skill metadata, routing, phase, and execution
  ownership; each `skills/*/prompt.md` owns its canonical skill body.
  `references/kernel.template.md` and `references/mcp_operations.yaml` own the
  shared kernel and managed MCP classifications.
- `tooling/generate/registry_sync.py` renders generated skills, README and kernel
  blocks, role prompts, and runtime policy sets. Generated assets are delivery
  outputs, not sources; registry and policy files use the repository's
  dependency-light JSON-compatible YAML subset.

### Extension seams

Local shell/filesystem policy, MCP approval, roles, auto mode, and synchronization
use separate Pi entrypoints; focused support modules are not discovered as extra
standalone extensions. The inline Markdown preview is a default first-party
extension and an independently distributable package under
`pi/packages/preview-markdown/`.

Evidence: `references/kernel.template.md`, `skills/registry.yaml`,
`tooling/generate/registry_sync.py`, `pi/extensions/b-agentic-permissions.ts`,
`pi/extensions/b-agentic-support/mcp.ts`,
`pi/packages/preview-markdown/package.json`.

## Workflow and skill design

### Routing and roles

Route each request to one active phase skill rather than mixing planning,
building, validation, and shipping. The registry groups skills into Decide,
Build, Validate, and Ship. `b-plan` resolves ambiguity; `b-research` supplies
external or versioned facts; `b-frontend` owns UI implementation;
`b-implement` handles scoped non-UI implementation; named refactors, runtime
diagnosis, test mechanics, browser evidence, changed-code review, repository
audit, commits, and PR summaries stay with their respective skills. `b-pr-summary`
also owns supplied PR-prose review/rewrite; editorial feedback does not require a
frozen code candidate or confer a changed-code review disposition.

Sessions default to `off`; `/b-role` or `pi --b-role` selects explicit
executor or architect protocol roles. The architect is the read-only Architect:
it owns `b-plan`, `b-research`, diagnosis-only `b-debug`, independent `b-review`,
and `b-agentic-audit`. The executor is the sole worktree-writing Executor and owns
the remaining skills. Protocol v3 uses executor/architect identifiers: legacy v1 planner/worker
and v2 implementer/reviewer state stays inactive until explicitly reselected, while
legacy model preferences map to the corresponding v3 role only.

### Coordination

- Compatible same-CWD peer payloads use protocol v3; unknown, v1, v2, or mixed
  payloads fail closed and never grant an Executor writer claim. Roles preserve normal
  Pi tools and shared approval policy.
- The Architect resolves material planning decisions directly with the user. Before
  initiating any new thread, it runs a fresh `list-cwd` with the absolute project
  `cwd` and requires exactly one other peer; zero/multiple peers, missing Intercom,
  or an ambiguous roster is a coordination gap. Once the user approves a `b-plan`
  result with no inbound Executor `ask`, it uses exactly one proactive `send` with
  that `cwd` and omits `to` for a compact Intercom handoff with scope, acceptance,
  paths, invariants, verification, risks, and open items. This is not blocking and
  never pairs `send` plus `ask`. If the plan originated from an Executor `ask`, the
  Architect returns it through the originating threaded `reply` instead. The
  Executor begins the named skill without reopening settled decisions, while the
  Architect remains read-only. For an Executor request for `b-plan`, `b-research`,
  `b-debug`, or `b-review`, the Executor uses exactly one blocking `ask` with the
  absolute project `cwd`, omits `to`, then stops and waits. The Architect begins
  that named skill automatically and replies to the originating request; if its
  triggered turn has ended, it inspects `pending` and uses the exact `replyTo`, never
  a reverse `ask` or unthreaded `send`. `b-debug` may create and remove only
  disposable OS-temporary scratch probes outside the worktree. Its confirmed
  diagnosis handoff names the next skill and carries the exact runnable repro
  command, observable to flip, and confirmed causal mechanism; the Executor owns
  the resulting product change and any performance remeasurement.
- When implementation is complete and required checks pass, the Executor sends a
  frozen candidate handoff for independent review through that single blocking ask,
  then stops editing. The Architect begins `b-review` without waiting for another
  prompt and, on every disposition, returns structured findings to the originating
  Executor while remaining read-only. Shipping requires the exact unchanged
  snapshot, acceptance, fresh passing required checks, no blockers/material gaps,
  and a valid review disposition. Follow-ups need explicit disposition and never
  waive safety evidence. Review does not commit or push;
  changelog changes for an authorized commit are part of the reviewed candidate.
  In default Off mode, commits require local snapshot verification and required
  checks, not automatic independent review, unless the user explicitly requires
  review first. In either mode, repository-required commit preparation precedes
  the final candidate snapshot.

Evidence: `references/kernel.template.md`, `skills/registry.yaml`,
`skills/b-plan/prompt.md`, `skills/b-review/prompt.md`,
`pi/extensions/b-agentic-support/role.ts`, `pi/tests/smoke.sh`.

### Response shape

The kernel constrains response shape, not only length: answer or next action
first, no preamble, self-narration, or closing pleasantries, numbered
multi-step instructions, and one concrete next step while work remains. Shape
is kernel-owned because it applies to every skill; per-skill `Output format`
sections stay content contracts and do not restate it. Skill output contracts,
required final-line verdicts, and role markers outrank the shape rule, so
`b-review` still ends with exactly one verdict line and the executor marker
stays immediately before the final response.

Evidence: `references/kernel.template.md`, `skills/b-review/prompt.md`,
`tooling/validate/behavior.py`.

### Skill payloads and diagram generation

`b-diagram` is an executor-owned Build skill that produces validated, portable technical diagrams from explicit facts without inferring system topology or runtime behavior. It is the sole skill shipping an executable payload (`skills/b-diagram/diagram.py`) and schema (`skills/b-diagram/schema.json`) directly inside `skills/`, keeping artifact validation and self-contained HTML/SVG delivery local to the skill without external dependencies. Repository validation executes diagram self-tests alongside other skill and behavior checks.

Evidence: `skills/registry.yaml`, `skills/b-diagram/prompt.md`,
`skills/b-diagram/diagram.py`, `skills/b-diagram/schema.json`,
`tooling/validate/run.sh`.

## Safety and approval design

### Command and path boundaries

- Routine repository-local commands, including build, test, package, and script
  automation, run automatically. External/shared mutations and dangerous but
  approvable actions require approval; destructive Git and Docker families are
  denied, and approval-required actions fail closed without UI.
- RTK is required for every supported command family. Modern tools are direct
  fallbacks only where RTK has no native family; RTK never bypasses approval.
  Compound shell segments and wrappers such as `rtk`, `env`, `sudo`, and `git -C`
  are normalized before policy matching. Ambiguous expansion, opaque execution,
  unknown package options, and outside-project executables fail closed to ask.
- User-authorized project work permits necessary local proprietary-source reads,
  not external disclosure. Protected material still requires explicit permission;
  private/proprietary external transmission is separately approval-gated.
- Protect dotenv, credential, key, certificate, SSH/cloud configuration, Git
  internals, and other secret-like paths. Protected native reads ask; native
  writes and edits are denied. Symlink-resolved paths, directory-wide
  operations, and outside-project paths retain the same project-confined,
  fail-closed boundary.
- `commandDecision` governs the `bash` tool. Pi's optional Windows `powershell`
  tool (included in Pi's `ToolName` union) is out of scope and falls to the
  generic fail-closed custom-tool gate, so the Git deny-list does not apply to
  it.

Approval is a policy guard, not a process sandbox: repository-controlled build
and test tools can execute code. Use Pi sandboxing or an isolated environment for
untrusted code. Commit creation requires an exact snapshot-verified proposal and
an explicit user request; b-commit adds no second confirmation and b-agentic never
pushes.

Evidence: `references/kernel.template.md`,
`pi/extensions/b-agentic-support/shell.ts`,
`pi/extensions/b-agentic-support/mcp.ts`,
`pi/extensions/b-agentic-permissions.ts`, `skills/b-commit/prompt.md`,
`pi/tests/smoke.sh`.

## MCP and external-evidence design

### Canonical policy and tool ownership

`references/mcp_operations.yaml` is the canonical classification for managed
servers, operation classes, conditional arguments, and runtime enforcement.
Generated runtime sets are checked against it. The managed servers are
CodeGraph, Context7, Brave Search, Firecrawl, and Playwright;
roles do not change active tools or MCP approval policy. Gateway calls require an
explicit managed server and matching tool, and nested `mcpScript` calls retain
the same policy. Read-only/trusted lifecycle operations may be automatic; safe
conditional reads and project-local conditional operations require validated
arguments. Unsafe or unclassified operations, uploads, auth, and external
mutations require approval or remain blocked.
Persisted `b-auto-mode` may auto-allow approval requests, but explicit denies
remain effective.

Native `read`/`edit`/`write` is preferred for routine work. Select CodeGraph when
repository-wide architecture, dependency/call-flow, route-to-handler, impact,
or affected-test analysis is central to the task and likely valuable; use an
available index for that question and initialize an absent index only for that
concrete qualifying question. Spanning files alone never justifies selection
or initialization. Context7 is first for versioned API facts; Firecrawl provides
bounded primary public research and Brave provides corroboration. Private
repository material is never sent to public search.

### Browser and UI evidence

Browser work prefers existing checks, approved navigation/interactions,
snapshot/find, focused console or network evidence, requested screenshots, and
cleanup in that order. Evidence bundles stay below an explicitly approved
directory and record requested state and cleanup; screenshots are reported only
when collected. Unsafe browser mutations remain approval-gated.
Playwright testing capability tools (`browser_verify_*`) are classified
`conditional-read` rather than external mutations: although upstream flags them
non-read-only because they auto-wait and perform assertion actions, their
observable outcome is state verification without persistent side effects when
constrained to safe argument schemas.

UI direction is contextual rather than a generic preset. `b-design` and
`b-frontend` make a task-conditional design read using repository and product
evidence; `b-browser` performs visual assessment only when an approved brief,
design guidance, or supplied reference provides concrete criteria.

Evidence: `references/mcp_operations.yaml`,
`pi/extensions/b-agentic-support/mcp.ts`,
`pi/extensions/b-agentic-mcp-permissions.ts`, `skills/b-research/prompt.md`,
`skills/b-browser/prompt.md`, `tooling/validate/mcp_policy.py`,
`tooling/validate/browser_evidence.py`.

## Installation, configuration, and lifecycle

### Source-backed installation

- Root `install.sh` bootstraps or updates a local source checkout and delegates
  managed Pi assets to `pi/scripts/install.sh`. `--ref` supports reviewed pins;
  `--sync` refreshes managed assets; `--update` reconciles RTK, Pi, and configured
  tooling without pulling b-agentic into the source checkout.
- Managed snapshots, backups, references, templates, and the manifest live under
  `~/.pi/agent/b-agentic`. User-owned kernel, configuration, and skill changes
  are preserved; extension collisions are backed up before replacement and
  restored only when installed content is unchanged. Optional tooling readiness
  is reported rather than inferred from a template or hidden behind file copy.

### Configuration, uninstall, and readiness

MCP configuration is merged rather than replaced: unrelated user servers
survive, prompted secrets use the installer's private input path, and managed
entries use lazy launchers or placeholders. Readiness does not claim external
authentication the adapter cannot observe.

Manifest-only uninstall is constrained to the user's home directory. It removes
unchanged managed content, restores recorded backups, preserves modified or
symlinked content, and never removes installed packages or unrelated user data.

`scripts/mcp-doctor.sh` distinguishes missing adapters, malformed configuration,
missing launchers or credentials, configured-but-unverified OAuth, and ready
servers. `scripts/skill-doctor.sh` checks installed skill payloads and kernel
discovery. Live MCP schema probing is opt-in, reports drift without editing
policy, and does not acquire OAuth tokens. `references/capabilities.yaml` is the
single activation contract for managed Pi packages, MCP servers, and first-party
extension entrypoints; it records task triggers, prerequisites, local readiness,
fallbacks, and non-sensitive status signals. The installed contract is
`~/.pi/agent/b-agentic/references/capabilities.yaml`. `/b-status` renders a
read-only local snapshot using file/package/launcher metadata only: it does not
parse MCP configuration, inspect credential/API-key values, start MCP/auth/
browser probes, or persist session content.

Evidence: `install.sh`, `pi/scripts/install.sh`, `tooling/install/common.sh`,
`tooling/install/manifest_uninstall.py`, `pi/configs/mcp.user.template.json`,
`tooling/validate/mcp_doctor.py`, `tooling/validate/skill_doctor.py`,
`tooling/validate/capabilities.py`, `scripts/mcp-doctor.sh`,
`pi/extensions/b-agentic-support/status.ts`.

## Verification and change discipline

- Repository-development quality is separate from the installed runtime. The
  root package owns locked Husky, lint-staged, ESLint, Prettier, and Markdownlint
  tools; pinned Python requirements own Ruff and ShellCheck; the repository
  quality entrypoint enumerates tracked supported files, runs check-only quality gates, and includes
  strict Pi TypeScript checks. The pre-commit hook remains staged-only and does
  not run behavioral or installer suites.
- Source and generated synchronization uses
  `python3 tooling/generate/registry_sync.py --check`. Local validation is
  dependency-light: `scripts/validate-skills.sh` runs generated, skill,
  CHANGELOG, routing, behavior, policy, readiness, prompt-input,
  browser-evidence, and Pi integration checks. `scripts/b-agentic-audit.sh`
  checks the decision record and suite structure.
- Release validation adds RTK compatibility and isolated installer smoke
  coverage. CI runs the release path on Ubuntu and macOS and also runs the
  deterministic b-agentic audit.
- `bash pi/scripts/typecheck.sh` is dependency-backed and opt-in; after Pi
  dependencies are installed it checks root extensions and the standalone
  preview package. Prompt-effectiveness model calls, live MCP probing, and
  browser evidence that starts processes, uses the network, or writes artifacts
  are opt-in; static validation does not imply live readiness or visual proof.
- `b-agentic-audit` is read-only and distinct from changed-code `b-review`. It
  covers source/design conformance, whole-project and first-party-extension
  health, canonical skill/kernel quality, and currentness/MCP compatibility.
  Actual drift is `NEEDS FIXES`; unavailable required evidence is a follow-up;
  `READY FOR PR` requires all required dimensions to be verified.
- Canonical source changes regenerate delivery assets and run the narrowest
  useful checks. Documentation and validator changes remain evidence-backed and
  do not silently alter runtime policy. Review findings identify location,
  evidence, impact, violated baseline, smallest correction, and a check.

Evidence: `tooling/generate/registry_sync.py`,
`tooling/validate/decision_design.py`, `tooling/validate/run.sh`,
`scripts/validate-skills.sh`, `scripts/b-agentic-audit.sh`,
`.github/workflows/validate.yml`, `pi/scripts/typecheck.sh`,
`pi/tests/prompt_effectiveness.py`.

## Intentional non-goals

- No runtime-neutral adapters, non-Pi runtime integrations, or extra runtime
  registry; Pi is the shipped boundary.
- No process-sandbox claim, blanket protection from repository-controlled build
  or test code, or approval shortcut that replaces isolation.
- No automatic external/shared mutation, MCP authentication bootstrap, broad
  crawling, unsafe Firecrawl actions, Playwright navigation, screenshot
  persistence, or public research using private local material.
- No workflow database, automatic Architect/Executor provisioning or reset,
  repeated roster polling, Architect-side implementation, fragmentation of
  `b-debug`, or shipping claim before a valid frozen-candidate `b-review`
  disposition when the explicit Executor gate applies.
- No automatic prompt-effectiveness model calls, live MCP checks, screenshot
  claims from simulated or unit tests, broad cleanup, or speculative
  compatibility work when a smaller evidence-backed change is sufficient.

Evidence: `README.md`, `REFERENCE.md`, `references/kernel.template.md`,
`references/mcp_operations.yaml`, `skills/b-browser/prompt.md`,
`skills/b-research/prompt.md`, `tests/behavior/roles.json`,
`tests/behavior/browser-evidence.json`.
