# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog 2.0.0](https://keepachangelog.com/en/2.0.0/),
and this project adheres to Calendar Versioning: `vYYYY.MM.DD`, with one release
section per date and same-day changes aggregated in that section.

## [v2026.09.23] - 2026-09-23

### Changed

- Assigned `b-planner` and `b-debugger` to `openai/gpt-6-sol#xhigh`,
  `b-reviewer` to `openai/gpt-6-sol#high`, and `b-researcher` to
  `hdwebsoft/swe-2-high` in the agent registry and generated profiles.
- Added bounded background delegation and compatible child-session continuation
  rules, with refreshed evidence requirements for continuing research and a
  fresh-session requirement for independent reviews.

### Fixed

- Isolated the installer smoke test from host OpenCode configuration overrides
  so CI checks the sandbox installation path consistently.

## [v2026.09.22] - 2026-09-22

### Changed

- Removed the obsolete repository-local Pi dependency ignore rule after the
  retired runtime cleanup.
- Clarified that delegated skills execute only in their named read-only
  subagent, reserving external/shared mutation, uploads, lifecycle, and
  authentication actions for the main session. Regenerated agent profiles and
  strengthened canonical-prompt and behavioral regression coverage across all
  delegated skills.
- Guided `b-research` to check Firecrawl's tool catalog before generic web
  discovery when a request needs structured records, filterable listings,
  transcripts, or data APIs, while preserving terms and approval escalation.
- Generated specialist-agent profiles from `skills/registry.yaml` and made
  delegated commands name and load the selected skill. Subagents now return the
  selected skill's own output format instead of a generic evidence or handoff
  response; runtime validators and delegation regressions enforce that binding.
- Reassigned `b-researcher` and `b-reviewer` to `hdwebsoft/swe-2-high`.
- Assigned `b-planner` to `openai/gpt-5.6-terra#xhigh` and
  `b-researcher` to `zai/glm-5.3-flash#high`, while retaining the SWE-2
  assignments for debugging and independent review.
- Made the curl installer output more visual: TTY- and `NO_COLOR`-gated
  colors, `==>` step markers on staged work, a green `✓` on completion, a
  non-interactive notice when stdin is not a TTY or `CI` is set, and a
  closing `Next steps:` block that folds the optional-tool warnings
  (rtk/codegraph/bunx) into one checklist.
- Widened read-only specialist access so each subagent can use the tools
  its skill needs: `b-researcher` gains `webfetch` and
  `firecrawl_firecrawl_find_tools`, `b-debugger` gains `brave_search_*`
  plus Firecrawl search/developer/GitHub-issue tools for error and
  known-bug lookup, and `b-reviewer` gains `webfetch` and
  `firecrawl_firecrawl_scrape` for fetching cited sources. The
  `edit`/`shell`/`subagent`/`question` denies are unchanged.
- Adopted native OpenCode v2 permission resource patterns: the managed
  `subagent` rule now allows `b-*` specialists while asking before any other
  agent, and kernel/reference prose was corrected to reflect that `resource`
  patterns match tool inputs (shell commands, file paths, subagent names)
  while MCP tool arguments remain unpatterned.
- Removed the dead V1 `compaction.prune` field from the managed base config;
  `compaction.auto` stays off so the managed context-pruning plugin owns
  compaction.
- Replaced the managed Magic Context plugin with DCP for dynamic context
  pruning. The installer now warns when a preserved Magic Context entry would
  conflict with DCP, and the operational guidance clarifies that DCP does not
  provide persistent memory.
- Managed specialist agents now pin models in frontmatter: `b-researcher`
  uses `hdwebsoft/gemini-3.8-flash-high` for cheaper lookups, `b-reviewer`
  uses `openai/gpt-5.6-terra` for the review gate, and `b-planner` and
  `b-debugger` use `hdwebsoft/swe-2-max` for reasoning-heavy planning and
  diagnosis.
- Simplified the four specialist agents' permission lists to three denies —
  `edit`, `subagent`, `question` — and dropped the per-agent `shell` deny
  and the duplicated MCP allow/deny lists. Delegated agents can now run
  read-only shell commands (`git diff`, `git status`, `rg`) and inherit the
  global managed MCP policy, so `b-reviewer` can inspect the candidate diff
  directly instead of reporting that no git tooling is available. Skill
  prompts, the kernel, validators, and docs were updated to match.

### Fixed

- Firecrawl MCP permission actions now match the real tool names. The
  firecrawl-mcp server self-prefixes its tools (`firecrawl_search`), so
  OpenCode resolves them as `firecrawl_firecrawl_*`; the canonical
  `mcp_operations.yaml` listed them unprefixed, which left every specific
  rule dead and let the `firecrawl_*` deny win — `b-researcher` reported
  "Firecrawl isn't available." All Firecrawl tool keys are now prefixed
  and the generated template and `b-researcher` allows resolve correctly.

## [v2026.09.21] - 2026-09-21

### Added

- Native OpenCode v2 runtime: global kernel at `~/.config/opencode/AGENTS.md`,
  15 skills under `skills/`, 15 generated `/b-*` commands under `commands/`,
  and four read-only `mode: subagent` specialist profiles under `agents/`.
- Ordered v2 `permissions` rules: last-match-wins with managed defaults before
  user rules, explicit denies for destructive git commands and secret paths
  (`.env`, `*.pem`, `*credentials.*`, `*secrets.*` at root and nested), and
  `ask` for external-directory access and mutating MCP tools.
- Native `mcp.servers` configuration for CodeGraph, Context7, Brave Search,
  Firecrawl, Playwright, Mobbin, and shadcn with Code Mode disabled so direct
  `<server>_<tool>` names apply.
- `opencode/scripts/install.sh` and `opencode/scripts/validate.sh` for the
  OpenCode runtime tree, plus `tests/smoke/install.sh` covering install,
  merge, sync, uninstall, JSONC, permission ordering, and error paths.
- `tooling/install/json_cleanup.py` for inverse-merge config removal and
  `tooling/install/manifest_uninstall.py` for manifest-only uninstall.
- The managed configuration now ships `@cortexkit/opencode-magic-context`
  in `plugins` and sets `compaction.auto`/`compaction.prune` off so the
  plugin owns context management for long sessions.

### Changed

- The installer now upgrades an existing OpenCode CLI in place with
  `opencode upgrade` and only falls back to the curl installer on first
  install, so repeat installs no longer re-run the remote script.
- Hard cut from Pi to native OpenCode v2: `install.sh` now uses
  `curl -fsSL https://opencode.ai/v2/install | bash` and writes only to
  `~/.config/opencode`; legacy Pi installs are detected but never modified.
- `skills/registry.yaml` and `skills/*/prompt.md` are retargeted to native
  OpenCode semantics (`skill` tool, `subagent` delegation, `question`,
  `todowrite`, direct MCP tool names); `references/kernel.template.md` is
  regenerated with OpenCode-native wording.
- `tooling/generate/registry_sync.py` renders OpenCode commands, agents,
  and the `opencode.user.template.json` permission set from canonical
  `references/mcp_operations.yaml`.
- `tooling/install/common.sh` merges `opencode.json`/`opencode.jsonc` with
  user-owned arrays preserved and managed `permissions` prepended so user
  rules stay last and authoritative. Managed `plugins` entries union ahead
  of user entries and are removed on uninstall.
- `tooling/validate/*` and `opencode/scripts/validate.sh` assert v2 config
  shape, permission ordering, agent deny rules, MCP server set, and
  Code Mode off.

### Removed

- Entire `pi/` runtime tree: extensions, packages, configs, scripts, tests,
  and the `preview-markdown` package (moved to its own repository).
- `eslint.config.mjs`, `pi/package-lock.json`, and all Pi-specific CI steps.
- `tests/smoke/lib.sh` (superseded by the self-contained
  `tests/smoke/install.sh`).

### Fixed

- `b-pr-summary` no longer requires the removed `preview_markdown` tool:
  finished PR copy returns in the normal response, and the cross-skill
  validator now pins that contract.
- Kernel rule 10 now falls back to tracking multi-step work in prose when
  `todowrite` is unavailable in the installed OpenCode version.
- `--sync` now refreshes references, templates, and the install manifest
  (previously skipped).
- Source-present `--uninstall` removes unmodified managed skills and
  preserves modified assets and metadata.
- `merge_json_file` preserves user MCP launch arrays and non-array
  `permissions` values with an explicit warning.
- `remove_merged_config` deletes an emptied `opencode.json` and preserves
  metadata when the recorded backup is missing.
- Bootstrap `--ref`/`B_AGENTIC_REPO` inputs are validated before reaching
  Git.

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

### Fixed

- Close conformance-audit findings across the quality gates: extract the
  generated MCP runtime policy sets from `b-agentic-support/mcp.ts` into a
  dedicated `mcp-generated-policy.ts` module (emitted wholesale by
  `registry_sync.py` with `// prettier-ignore` markers, matching the
  capabilities pattern) so the hand-written URL/IP and argument-validation
  safety logic in `mcp.ts` is linted, formatted, and type-checked; bring the
  hand-maintained `tooling/validate/behavior.py` and `shared.py` under Ruff
  by dropping their inaccurate "generated" exclusions; add
  `pi/subagent-read-only-guard.ts` to the Pi TypeScript project so the
  managed child-only guard is type-checked; correct the decision record's
  claim that `registry_sync.py` renders managed subagent profiles (they are
  hand-maintained sources); delete stale `role.ts` exclusion entries; and
  remove dead/duplicated logic in `shell.ts`. Harden the validators that
  cover the split: `validate_mcp_policy.py` now attributes set mismatches to
  the generated module, asserts `MCP_CONDITIONAL_ARGUMENTS` against the
  canonical `conditional_arguments`, fails closed on malformed entries, and
  requires `mcp.ts` to import the generated sets rather than re-declare
  them, while `registry_sync.py --check` now fails when a generated output
  is not tracked by git so untracked artifacts cannot escape the quality
  gates.
- Restore auto-approval of classified read-only managed MCP calls for the
  five servers whose policy keys are namespaced as `{server}_{tool}`
  (brave-search, codegraph, context7, mobbin, shadcn). `managedToolBaseName`
  in `b-agentic-support/mcp.ts` only stripped adapter prefixes for firecrawl
  and playwright, so the bare upstream `originalName` the approval broker
  emits never matched the namespaced policy key and every one of those
  servers' calls failed closed inside managed subagents; the resolver now
  prefixes the upstream id for namespaced servers while still accepting an
  already-classified policy key from a direct tool call.

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
