# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog 2.0.0](https://keepachangelog.com/en/2.0.0/),
and this project adheres to Calendar Versioning: `vYYYY.MM.DD`, with one release
section per date and same-day changes aggregated in that section.

## [v2026.09.20] - 2026-09-20

### Added

- Add a `--force` flag (and `B_AGENTIC_FORCE` override) that bypasses the new
  `--sync` up-to-date check, and a `B_AGENTIC_PLAIN`/`NO_COLOR` opt-out that
  forces plain newline output on a TTY with no picker, stage bar, or escapes.
- Record the installed source commit and ref (`sourceCommit`, `sourceRef`) in
  the install manifest and refresh them on each `--sync`.

### Changed

- Speed up the installer bootstrap: the kept `~/.b-agentic` checkout now uses a
  blobless partial clone (`--filter=blob:none`, git ≥ 2.27, remote URLs only),
  cutting first-install transfer roughly in half while still allowing full
  `git fetch`, and throwaway `--dry-run` clones use `--depth=1`. A plain
  `--sync` now probes the remote head with `ls-remote` and skips the
  fetch/pull when it already equals `HEAD`, while the local reconcile stages
  still run so a deleted managed file is repaired.
- Consolidate all installer escape-sequence decisions behind a single
  `supports_ansi` predicate (TTY + `TERM` + `NO_COLOR`/`B_AGENTIC_PLAIN`).
- Replace the optional long-session memory package: the installer now installs
  `@cortexkit/pi-magic-context` instead of `pi-observational-memory`. Magic
  Context runs its background historian/dreamer work in separate child Pi
  processes, so a worker failure does not take down the main session, and it
  adds cross-session project memory on top of compaction continuity. Because
  the installer never removes Pi packages, existing installs should uninstall
  `pi-observational-memory` manually so it does not run as a second memory
  layer.

### Security

- Validate `--ref`/`B_AGENTIC_REF` and `B_AGENTIC_REPO` as untrusted input
  before they reach git arguments or URLs, rejecting path-traversal and
  option-injection shapes, and wrap the whole script so a truncated
  `curl | bash` download executes nothing instead of running a partial body.

## [v2026.09.19] - 2026-09-19

### Added

- Install managed `pi-subagents` planner, researcher, debugger, and reviewer profiles with disabled bundled agents, inherited parent-model defaults, local readiness reporting, and technically enforced read-only child tool access.
- Manage the Mobbin MCP server as an optional, read-only design-reference source that `b-design` queries in a bounded way for real product screens, flows, and sections, recording links as labelled evidence in `docs/DESIGN.md` and degrading gracefully when unauthenticated; it is OAuth-backed through the approval-gated `auth` class and verified only in-session.
- Manage the shadcn MCP server as an optional, read-only registry lookup that `b-frontend` uses to prefer real registry components and examples over bespoke equivalents when a shadcn stack (`components.json`) is already present.

### Changed

- Replace the Executor/Architect and `pi-intercom` workflow with a single main-session workflow that delegates bounded read-only evidence work to named subagents and requires a fresh frozen `b-reviewer` review for changed candidates.
- Preserve modified or symlinked managed child read-only guards during sync and both normal and manifest-only uninstalls, while removing unchanged managed guards safely.

### Removed

- Retire role selection, role state, role-specific extensions, candidate handoff modules, and the managed `pi-intercom` integration.

### Fixed

- Document that delegated `pi-subagents` launches must run as background children (`async: true`) because foreground children never load the ambient extensions providing the managed `mcp` and `recall` tools, replacing the ambiguous "synchronously" guidance that caused managed agent launches to fail at startup.
- Tighten canonical skill and kernel guidance after a conformance audit: resolve a `b-commit` routing self-contradiction, move Ship-skill routing into `skills/registry.yaml` with explicit-request metadata so no skill can be silently omitted from kernel routing, replace unexecutable "ask for approval" phrasing in `b-research` with main-session escalation, remove an out-of-scope sentence from `b-plan`, pin the `b-agentic-audit` delegation mapping in behavior validation, record the subagent guard's real source path in `capabilities.yaml`, and mark kernel Core Rules 3/4/10 as main-session-only obligations for read-only children. Add negative self-test coverage and a phase allowlist so these invariants fail loudly if weakened.

## [v2026.09.14] - 2026-09-14

### Changed

- Activate explicitly selected, restored, and startup-flag Executor roles directly without same-CWD peer arbitration, role-payload compatibility, or Intercom availability, while retaining durable role state and coordination handoff safeguards.
- Require independent Architect review before an Executor reports completion for any task that leaves tracked or relevant untracked/derived candidate content, while leaving no-change outputs outside changed-code review.

## [v2026.09.10] - 2026-09-10

### Added

- Add a concise role-owned-skills line to `/b-role` selection and startup role-restore notifications, rendered from the generated registry ownership map, displayed once per non-Off session across persisted, lineage, pane, and flag sources, and omitted for Off selections, unrecorded panes, legacy inactive state, and extension reloads.

### Fixed

- Restore the canonical coordination phrases in the Executor and Architect role prompts and reconcile the stale handwritten smoke assertions so the role behavioral fixture passes linearly again.

### Changed

- Clarify coordinated Architect and Executor handoffs so blocking requests stay threaded, proactive plan delivery remains nonblocking, and ambiguous peer or pending-request state fails closed.

## [v2026.09.09] - 2026-09-09

### Added

- Shape every agent response answer-first: no preamble, narration, or closing pleasantries, numbered multi-step instructions, and one concrete next step while work remains, with skill output contracts, final-line verdicts, and role markers still taking precedence.
- Notify the executor when waiting on blocking extension UI prompts via `ui_prompt_start`, while coalescing nested prompts and suppressing redundant notifications for active `ask_user_question` tool calls.
- Classify Playwright MCP testing capability tools: enable `--caps=testing` in the template launcher, trust `browser_generate_locator` as read-only, and permit `browser_verify_*` verification operations with validated arguments.

### Changed

- Split runtime diagnosis from product fixes: the Architect now establishes an evidence-backed `b-debug` handoff while the Executor applies the surface-appropriate change and reruns performance measurements from its baseline.
- Rename the coordinated roles to Executor and Architect, advancing their peer protocol to v3; older planner/worker and implementer/reviewer session state now stays inactive until reselection while saved model preferences migrate to the new roles.
- Raise the workflow kernel's measured byte ceiling to 12,800 so the response-shape guidance fits, keeping the 120-line slimness guard and documenting the exception as bounded rather than a standing allowance.
- Keep concise routing intents in the always-loaded kernel while rendering detailed trigger vocabulary into active skill descriptions, with validation that each routing signal remains runtime-visible.
- Simplify and align canonical skill guidance, including browser evidence, review handback, capability activation, MCP scripting limits, and local repository Q&A routing.
- Document that shell command decisions govern the `bash` tool while Windows `powershell` falls to fail-closed custom-tool handling, and note that schema probing covers only managed MCP servers while template specifications resolve latest via `bunx`.
- Update `b-browser` guidance to reflect Playwright verification and locator-generation tools alongside existing snapshot and inspection commands.

### Fixed

- Fail closed Executor writer arbitration until same-CWD peer discovery confirms zero peers or one compatible Architect, including disconnects, role transitions, and stale discovery races.
- Align repository documentation, skills, and validation with current architecture boundaries: record `b-diagram`'s executable payload boundary and include it in the build phase catalog, drop the stale measured kernel byte figure, correct role-article phrasing, prune obsolete writer rules from `b-debug`, and clean up unused script variables.
- Allowlist the first-party `todo` task tool in specialized support policy so task list operations do not trigger generic custom-tool approval prompts or fail closed without UI.
- Support `pi-intercom` 0.13.0 schema additions: permit `focus` and non-spawning `openProjectPaneIfMissing: false` in auto-approved Intercom calls while approval-gating session spawning.
- Update pinned Pi developer dependencies `@earendil-works/pi-coding-agent` and `@earendil-works/pi-tui` to 0.85.1 and verify resolver compatibility.

## [v2026.09.08] - 2026-09-08

### Changed

- Allow explicit implementer roles to remain active without a same-CWD reviewer while retaining multi-peer and implementer-collision safeguards.

### Fixed

- Notify the implementer when a completed task has passed b-review instead of notifying the reviewer that the review completed.
- Require implementers to hand off completed frozen candidates before reporting task completion and reviewers to return every review disposition to the implementer, with synchronized guidance and regression coverage.
- Restore the workflow kernel below its enforced size limit without weakening its validated safety, routing, review, or MCP guidance.
- Restore the Validate structural audit after the review-handoff kernel exceeded its prior byte ceiling by documenting a scoped 12,500-byte limit while retaining the 120-line guard.
- Make post-review notification smoke coverage portable across Linux and macOS `osascript` argument shapes while retaining exactly-once verification.

## [v2026.09.07] - 2026-09-07

### Added

- Add the opt-in `b-diagram` skill for validating versioned technical-diagram sources and atomically delivering portable, self-contained HTML/SVG artifacts from explicit architecture and flow facts.

### Changed

- Clarify that active implementer status already reflects compatible-peer arbitration, so role-less Intercom session listings identify the review target without blocking its handoff.

### Fixed

- Resolve simultaneous same-CWD implementer claims deterministically, retaining the preferred claimant while the losing session reports the collision instead of a missing-reviewer error.

### Removed

- Remove the review-peer selector and marker protocol, using direct same-CWD Intercom routing with role-arbitration safeguards instead.

## [v2026.09.06] - 2026-09-06

### Added

- Add an interactive curl-installer component picker for optional MCP support, Pi integrations, and the Dracula theme, with non-interactive fallbacks and state-preserving reconciliation.

### Changed

- Expose validated review-handoff targets and marker metadata directly to agents, tighten handoff-origin matching, and cover the streamlined protocol in Pi smoke tests and guidance.
- Require b-agentic audits to verify branch synchronization with origin before inspecting repository sources, blocking stale or unverifiable branches so findings remain accurate.
- Keep the default Off workflow solo while enabling explicit implementer-role review handoffs with validated same-CWD peer/origin targeting and supporting Pi smoke and behavior coverage.
- Recover always-loaded kernel headroom by moving the detailed MCP adapter example into the research skill and consolidating duplicated guidance without raising size limits.
- Check the current branch against its cached origin ref before non-trivial work begins, fetching only when that ref is missing or stale and surfacing behind or diverged counts for confirmation instead of silently building on outdated code.

### Fixed

- Require approval before a browser snapshot writes a local artifact file, so snapshot output paths are gated like screenshots instead of being auto-approved whenever they stayed inside the project.
- Reconcile the conflicting freshness instructions between the kernel and the audit skill by allowing a skill to mandate a stricter origin check, so an audit's required fetch no longer contradicts the stale-only rule.
- Narrow the browser skill's visual and screenshot routing keywords to evidence-specific phrases so visual work is no longer pulled away from design-standard authoring and frontend implementation.
- Keep installer component-picker arrow keys working on shells that reject fractional read timeouts, so macOS Bash 3.2 no longer treats navigation as a cancel request, with smoke coverage guarding the portable escape window.
- Restore opt-in repository labels in interactive TUI titles while keeping the basename privacy boundary and regression coverage.
- Make commit prerequisites consistent with the active role: Off mode uses local verification unless review is requested, while implementer mode reviews the final candidate after repository-required changelog preparation and checks.
- Keep PR-description review and rewriting in the PR-summary skill rather than the changed-code gate, with evidence-limited editorial feedback, synchronized routing, and cross-skill regression coverage for commit, prose, and privacy boundaries.
- Distinguish task-authorized local proprietary-source reads from external disclosure while retaining explicit permission for protected material; add Off-mode prompt scenarios without injecting an active-role profile.
- Remember an explicit role choice for the session and terminal pane that made it, so a later session there restores implementer or reviewer instead of starting Off while an implementer pane and a reviewer pane in one project keep their own roles. A resumed session keeps its own recorded role, a pane with no earlier choice stays Off, startup flags stay one-session overrides, and same-CWD writer arbitration still decides an implementer claim.

## [v2026.09.05] - 2026-09-05

### Removed

- Retire Serena, Linear, and Mobbin from the default managed MCP portfolio and its installer, policy, readiness, and guidance surfaces while preserving pre-existing user-owned configuration.
- Retire managed Pi LSP lifecycle/defaults/guidance, the legacy rule-guard extension, and built-in b_consult support while preserving user-owned configurations, packages, and modified legacy artifacts.

### Changed

- Clarify sequential blocker handling, in-scope verification loops, review-finding handoffs, and canonical Firecrawl bounds; recover kernel headroom while preserving MCP and safety guidance.
- Let explicit user commit requests execute the reviewed b-commit plan without redundant path/message confirmation while retaining snapshot, safety, review, and no-push gates.
- Require affirmative CodeGraph selection for central repository-wide architecture, dependency/call-flow, route-to-handler, impact, or affected-test analysis, without initializing it merely because work spans multiple paths.
- Bound MCP scripting guidance and fixtures to distinguish one-call `mcp` from multi-call `mcpScript` workflows, preserve nested approval/authentication/output safeguards, and cap sources, results, normalized records, and primary scrapes.
- Replace legacy planner/worker coordination with explicit implementer and reviewer roles, guarded legacy compatibility, frozen candidate review evidence, and matching installer and validation coverage.

### Fixed

- Apply native Pi path resolution before permissions decisions, preserving protected and outside-project safeguards for URL, Unicode, and read-fallback paths.
- Preserve symlinked MCP configuration during manifest-only cleanup while confining cleanup inputs to safe local paths.
- Recognize Bun, Bunx, and Deno in RTK policy readiness without weakening approval for opaque execution.
- Keep the full Pi behavioral smoke suite runnable when the linked Pi SDK lacks its undeclared `@earendil-works/pi-server` runtime dependency, using a reviewed test-only, fail-closed fallback that bypasses itself when the real dependency is available.
- Bring the Pi workflow kernel back within enforced slimness limits while preserving bounded-MCP safeguards, fixing the Validate workflow failure.
- Restore macOS Validate smoke compatibility by safely handling symlinked temporary paths and Bash 3 argument expansion.
- Allow manifest-only cleanup to handle canonical defaults through symlinked HOME aliases without weakening symlink safeguards.
- Use the repository-pinned Pi 0.84.4 runtime in Validate workflow checks instead of an untested global 0.84.2 install.

## [v2026.09.04] - 2026-09-04

### Changed

- Clarify explicit frontend/UI versus non-UI implementation handoffs across canonical skills, and restore kernel headroom without weakening policy.

### Fixed

- Gate shared user/system Git configuration behind approval and add deterministic coverage for Serena's fail-closed traversal bound.

## [v2026.09.03] - 2026-09-03

### Added

- Add opt-in repository-aware planner notifications and interactive Pi titles while preserving privacy-safe defaults.

### Changed

- Align Pi development tooling to 0.84.4 and extend RTK policy coverage to CTest, Maven Daemon, and PHPT command families.

### Fixed

- Keep planner-notification repository labels free of control characters without triggering ESLint's control-regex rule.

## [v2026.09.02] - 2026-09-02

### Changed

- Guide `b-implement` and `b-frontend` toward evidence-backed minimal implementations—reusing repository or native capabilities before dependencies or bespoke code—while preserving product/design authority, accessibility, trust-boundary safeguards, error/data-loss handling, compatibility, security, and verification; add behavior scenarios covering these choices.
- Optimize Playwright MCP evidence collection with a headless isolated launcher, faster targeted browser guidance, and installer/validation migration coverage.

## [v2026.09.01] - 2026-09-01

### Added

- Initial release of b-agentic, providing a Pi workflow kernel, skills, extensions, validation, and installer tooling.
- Add a canonical managed-capability activation contract with trigger, prerequisite, readiness, and fallback guidance, plus a privacy-preserving `/b-status` snapshot that reports local metadata without inspecting MCP credentials or claiming operational LSP readiness.
- Integrate the installer-managed Pi todo extension with unpinned package lifecycle reconciliation, capability/status tracking, installer smoke coverage, and lightweight guidance for tracking non-trivial multi-step work.

### Changed

- Require workers to send reliable terminal results to the assigning planner and defer worktree-changing reviews to planner-owned b-review.
- Document agent-maintained daily changelog updates, including same-day release aggregation and human-facing entries.
- Redesign b-init repository guidance around a concise, evidence-backed operating guide with explicit migration and developer-rule preservation.
- Streamline two-role b-commit execution: the planner makes one exact, user-approved read-only proposal; the same worker resumes the unchanged approved handoff without duplicate approval, and snapshot or proposal mismatches stop the commit.
- Limit root `AGENTS.md` verification guidance to a concise set of normal repository checks.
- Make b-pr-summary render completed PR descriptions with the Markdown preview tool instead of offering an optional preview.
