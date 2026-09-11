# b-agentic Decision Design

This is a compact, evidence-backed summary of current b-agentic design decisions.
Canonical sources remain authoritative: this record does not replace the kernel,
skill prompts, policy, installer, or tests. It records durable choices and
boundaries, not a change history or a second runtime contract. Evidence:
`README.md`, `AGENTS.md`, `references/kernel.template.md`,
`tooling/validate/decision_design.py`.

## Scope and evidence

b-agentic is a host-neutral personal workflow suite: portable skills, kernel,
MCP configuration, and permission data, delivered to verified hosts through
per-host adapters. Pi is the first full-fidelity adapter, not the product
boundary; every adapter target must be confirmed from official documentation
before an adapter is built (see the host compatibility reference under docs).
This record summarizes current decisions supported by tracked repository
sources.

### Slim, strong, and usable

- **Slim:** choose the smallest evidence-backed fit; remove duplication, ceremony, and speculative complexity.
- **Strong:** preserve explicit safety, evidence, and verification boundaries, with a small observable check when a decision changes.
- **Usable:** retain direct, predictable user paths.
  This decision applies to future b-agentic repository source, docs, tooling, and CI changes, including skills, installers, adapters, configuration, validators, and tests; it does not apply to an installed runtime kernel or create a generic runtime policy. Necessary compatibility/security fixes remain in scope, so slimness never demands cosmetic reduction.
  Evidence: `AGENTS.md`, `README.md`, `REFERENCE.md`, `tooling/validate/decision_design.py`.
- **Measured kernel budget and routing metadata:** Keep the 12,000-character ceiling and 120-line cap for the always-loaded `references/kernel.template.md`; `tooling/validate/suite_audit.py` enforces both. The character ceiling matches the strictest verified host (Antigravity caps each rules file at 12,000 characters; see the host compatibility reference under docs). Registry routing intents remain in the kernel, while trigger vocabulary is rendered into each active skill description so routing detail does not consume global context. Any future limit raise remains a measured exception for a guarantee that cannot be expressed elsewhere, not a standing allowance.

## Product boundary and architecture

### Runtime and ownership

- Ship a portable core — canonical skills, kernel template, managed MCP
  configuration, and permission data — plus per-host adapters; do not fork the
  skill bodies per host. A host adapter is built only for facts confirmed from
  that host's official documentation; unverified hosts stay unimplemented
  rather than guessed.
- Keep shared guidance in `references/`; keep host integration, configuration,
  extensions, scripts, and smoke coverage under their adapter trees, with the
  Pi adapter under `adapters/pi/`. Keep the always-loaded kernel within its measured
  character and line limits; a limit exception requires an explicit decision
  rather than a silent increase or weakened rule.
- `skills/registry.yaml` owns skill metadata, routing, and phase; each
  `skills/*/prompt.md` owns its canonical skill body.
  `references/kernel.template.md` and `references/mcp_operations.yaml` own the
  shared kernel and managed MCP classifications.
- `tooling/generate/registry_sync.py` renders generated skills, README and
  kernel blocks, and runtime policy sets. Generated assets are delivery
  outputs, not sources; registry and policy files use the repository's
  dependency-light JSON-compatible YAML subset.

### Extension seams

Local shell/filesystem policy, MCP approval, auto mode, and synchronization use
separate Pi entrypoints; focused support modules are not discovered as extra
standalone extensions. The inline Markdown preview is a default first-party
extension and an independently distributable package under
`adapters/pi/packages/preview-markdown/`.

Evidence: `references/kernel.template.md`, `skills/registry.yaml`,
`tooling/generate/registry_sync.py`, `adapters/pi/extensions/b-agentic-permissions.ts`,
`adapters/pi/extensions/b-agentic-support/mcp.ts`,
`adapters/pi/packages/preview-markdown/package.json`.

## Workflow and skill design

### Routing and solo execution

Route each request to one active phase skill rather than mixing planning,
building, validation, and shipping. The registry groups skills into Decide,
Build, Validate, and Ship. `b-plan` resolves ambiguity; `b-research` supplies
external or versioned facts; `b-frontend` owns UI implementation;
`b-implement` handles scoped non-UI implementation; named refactors, runtime
diagnosis, test mechanics, browser evidence, changed-code review, repository
audit, commits, and PR summaries stay with their respective skills. `b-pr-summary`
also owns supplied PR-prose review/rewrite; editorial feedback does not require a
code-review disposition or confer a changed-code review verdict.

The workflow is solo: one agent loads one skill at a time, resolves material
decisions directly with the user, and never spawns a coordinating peer or
protocol gate. Skills do not filter tools; shared shell, filesystem, MCP, and
approval policy remains authoritative.

Evidence: `references/kernel.template.md`, `skills/registry.yaml`,
`tests/behavior/routing.json`, `tests/behavior/principles.json`.

### Review and commit gates

- `b-review` is the changed-code review gate. A candidate is review-ready only
  when its exact snapshot (tracked plus relevant untracked/derived content) is
  unchanged, acceptance is met, required checks are fresh and passed, and no
  blocker or material gap remains. `READY WITH FOLLOW-UPS` requires explicit
  accepted disposition and never waives safety evidence; `NEEDS FIXES`, a stale
  verdict, a missing baseline, a changed snapshot, an untracked change, or a
  skipped or failed check blocks shipping. Corrections are reverified and return
  for another review.
- Review completion, task acceptance, and commit creation are distinct. No
  automatic commit or push occurs without an explicit user commit request; once
  requested, `b-commit` executes its snapshot-verified plan without a second
  confirmation. Repository-required commit preparation — same-day changelog
  maintenance only when repository rules require it for an authorized commit —
  precedes the final candidate snapshot.

Evidence: `skills/b-review/prompt.md`, `skills/b-commit/prompt.md`,
`tooling/validate/behavior.py`.

### Response shape

The kernel constrains response shape, not only length: answer or next action
first, no preamble, self-narration, or closing pleasantries, numbered
multi-step instructions, and one concrete next step while work remains. Shape
is kernel-owned because it applies to every skill; per-skill `Output format`
sections stay content contracts and do not restate it. Skill output contracts
and required final-line verdicts outrank the shape rule, so `b-review` still
ends with exactly one verdict line.

Evidence: `references/kernel.template.md`, `skills/b-review/prompt.md`,
`tooling/validate/behavior.py`.

### Skill payloads and diagram generation

`b-diagram` is a Build skill that produces validated, portable technical
diagrams from explicit facts without inferring system topology or runtime
behavior. It is the sole skill shipping an executable payload
(`skills/b-diagram/diagram.py`) and schema (`skills/b-diagram/schema.json`)
directly inside `skills/`, keeping artifact validation and self-contained
HTML/SVG delivery local to the skill without external dependencies. Repository
validation executes diagram self-tests alongside other skill and behavior
checks.

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
`adapters/pi/extensions/b-agentic-support/shell.ts`,
`adapters/pi/extensions/b-agentic-support/mcp.ts`,
`adapters/pi/extensions/b-agentic-permissions.ts`, `skills/b-commit/prompt.md`,
`adapters/pi/tests/smoke.sh`.

## MCP and external-evidence design

### Canonical policy and tool ownership

`references/mcp_operations.yaml` is the canonical classification for managed
servers, operation classes, conditional arguments, and runtime enforcement.
Generated runtime sets are checked against it. The managed servers are
CodeGraph, Context7, Brave Search, Firecrawl, and Playwright; skills do not
change active tools or MCP approval policy. Gateway calls require an
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
`adapters/pi/extensions/b-agentic-support/mcp.ts`,
`adapters/pi/extensions/b-agentic-mcp-permissions.ts`, `skills/b-research/prompt.md`,
`skills/b-browser/prompt.md`, `tooling/validate/mcp_policy.py`,
`tooling/validate/browser_evidence.py`.

## Installation, configuration, and lifecycle

### Source-backed installation

- Root `install.sh` bootstraps or updates a local source checkout and delegates
  managed Pi assets to `adapters/pi/scripts/install.sh`. `--ref` supports reviewed pins;
  `--sync` refreshes managed assets; `--update` reconciles RTK, Pi, and configured
  tooling without pulling b-agentic into the source checkout.
- Managed snapshots, backups, references, templates, and the manifest live under
  `~/.pi/agent/b-agentic`. User-owned kernel, configuration, and skill changes
  are preserved; extension collisions are backed up before replacement and
  restored only when installed content is unchanged. Optional tooling readiness
  is reported rather than inferred from a template or hidden behind file copy.
- Retired managed extensions — including the removed role protocol entrypoints —
  move to the installer's legacy removal list so updates and reinstalls clean
  them from user machines while preserving user-modified content.

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

Evidence: `install.sh`, `adapters/pi/scripts/install.sh`, `tooling/install/common.sh`,
`tooling/install/manifest_uninstall.py`, `adapters/pi/configs/mcp.user.template.json`,
`tooling/validate/mcp_doctor.py`, `tooling/validate/skill_doctor.py`,
`tooling/validate/capabilities.py`, `scripts/mcp-doctor.sh`,
`adapters/pi/extensions/b-agentic-support/status.ts`.

## Verification and change discipline

- Repository-development quality is separate from an installed runtime. The
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
- `bash adapters/pi/scripts/typecheck.sh` is dependency-backed and opt-in; after Pi
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
`.github/workflows/validate.yml`, `adapters/pi/scripts/typecheck.sh`,
`tests/prompt_effectiveness.py`.

## Intentional non-goals

- No host adapter without official-documentation confirmation of that host's
  instruction path, skill discovery, MCP configuration schema, permission
  model, and hook capability; unverified data points ship deferred, never
  guessed. No extra runtime registry.
- No process-sandbox claim, blanket protection from repository-controlled build
  or test code, or approval shortcut that replaces isolation.
- No automatic external/shared mutation, MCP authentication bootstrap, broad
  crawling, unsafe Firecrawl actions, Playwright navigation, screenshot
  persistence, or public research using private local material.
- No workflow database, coordinator/peer protocol, session provisioning or
  reset, roster polling, delegation-side implementation, fragmentation of
  `b-debug`, or shipping claim ahead of a valid `b-review` verdict when the
  user requires review.
- No automatic prompt-effectiveness model calls, live MCP checks, screenshot
  claims from simulated or unit tests, broad cleanup, or speculative
  compatibility work when a smaller evidence-backed change is sufficient.

Evidence: `README.md`, `REFERENCE.md`, `references/kernel.template.md`,
`references/mcp_operations.yaml`, `skills/b-browser/prompt.md`,
`skills/b-research/prompt.md`, `tests/behavior/principles.json`,
`tests/behavior/browser-evidence.json`.
