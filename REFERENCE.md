# b-skills — Skill reference

Reference guide for the maintained 9-skill Claude Code suite. For install and high-level overview, see [README.md](README.md).

When this document cites installed `CLAUDE.md`, that runtime memory is sourced from `global/CLAUDE.md` and installs to `~/.claude/CLAUDE.md`. Detailed runtime behavior lives at `references/runtime-contract.md` in this repo and `~/.claude/references/b-skills/runtime-contract.md` after install. Root `CLAUDE.md` is maintainer guidance for this source repository.

---

## Runtime Context

The runtime target is a standalone Claude Code installation. The installer manages Claude user-level files under `~/.claude/` so the suite can preserve short `/b-spec` through `/b-audit` names.

Target file model:

| Concern | Source path | Runtime target |
|---|---|---|
| Always-on suite guidance | `global/CLAUDE.md` | managed Claude memory under `~/.claude/` |
| User-invocable skills | `skills/<name>/SKILL.md` | `~/.claude/skills/<name>/SKILL.md` |
| Isolated delegated lanes | `agents/` | `~/.claude/agents/` |
| Runtime enforcement | `hooks/` | Claude hook configuration and helper scripts under `~/.claude/` |
| Permissions, MCP, hook defaults | `settings/` | managed Claude settings snippets or sections |
| On-demand details | `references/` and `skills/<name>/reference.md` | Claude-readable references under `~/.claude/` or beside installed skills |
Runtime rules belong on the lightest Claude-native surface that can own them: `global/CLAUDE.md` for concise always-on memory, skill files for task-specific workflow, custom agents for forked or isolated lanes, hooks/settings for enforceable policy, and references for details that should stay out of always-on context. The classification source for the current always-on kernel is `references/runtime-contract.md` under `Claude-native runtime placement map`.

Governance assets:

| Source | Runtime role |
|---|---|
| `hooks/b-skills-guard.py` | Emits SessionStart context, denies catastrophic disk/root/home removal commands, and approval-gates dependency, git-history, production-like, and broad rewrite commands |
| `settings/b-skills.settings.json` | Provides the Claude settings template for `SessionStart`, `PreToolUse`, `PermissionRequest`, and ask/deny permission rules |

The hook/settings layer intentionally enforces only high-value gates in phase 1. Detailed runtime policy remains in `references/runtime-contract.md` while hook coverage stays intentionally narrow.

OpenCode-only custom provider configuration and cleanup of old `~/.config/opencode/` installs are intentionally outside the phase 1 Claude-native installer. Any OpenCode config retirement should be manual or handled by a later explicit migration tool.

Execution choices:

| Skill | Claude execution | Agent | Rationale |
|---|---|---|---|
| `b-spec` | inline | none | clarification depends on the active user context |
| `b-plan` | forked | `b-plan-agent` | planning should explore options and return an execution-ready plan |
| `b-research` | forked | `b-research-agent` | external evidence gathering should summarize back into the active context |
| `b-implement` | inline | none | edits, approval state, and verification should stay visible in one thread |
| `b-refactor` | inline | none | mechanical transforms need continuous edit/reference visibility |
| `b-debug` | inline | none | repro, probes, fixes, and verification should stay connected |
| `b-test` | inline | none | test edits and commands should stay tied to the active source context |
| `b-review` | forked | `b-review-agent` | review should inspect independently and return findings |
| `b-audit` | forked | `b-audit-agent` | audits need isolated sampling and risk assessment |

---

## Skill reference

### b-spec

Clarifies rough or underspecified asks before planning.

**Core behavior**
- Stays active only while the target outcome is underdetermined.
- Locks goal, constraints, acceptance criteria, non-goals, and assumptions with the smallest useful question loop.
- Uses repo evidence and optional `CONTEXT.md` / `CONTEXT-MAP.md` terminology before asking the user what the repo already answers.
- Enforces the global clarification budget; after two unresolved rounds, offers concrete interpretations with named assumptions.
- Outputs a compact chat spec and hands off to `b-implement`, `b-plan`, or `b-research`.

**Output**
- Goal, constraints, acceptance criteria, non-goals, assumptions, and next skill.

**Shared reference**
- `references/b-skills/domain-glossary.md` — optional convention for persistent project glossary docs.

---

### b-plan

Turns a clear goal into an execution-ready plan without implementing.

**Core behavior**
- Defaults to quick mode for low-risk, chat-sized scoped work and uses full mode only for durable, multi-session, dependency-heavy, or risky coordination.
- Avoids promoting routine multi-step work to a saved plan solely because it has several obvious substeps.
- Saves full plans under `.b-skills/b-plan/<plan-file-slug>.md` with durable frontmatter and `contract_version` from the runtime contract; the filename stays English while frontmatter `slug` remains the canonical task slug.
- Promotes quick plans to saved plans when risk, breadth, or coordination grows.
- Uses repo evidence only when it materially improves sequencing or touch-point accuracy.
- Records assumptions separately from confirmed decisions unless the user confirms them.
- Uses stable anchors for prose/config-heavy work so later patches have reliable targets.
- Keeps broad refactors here until they become concrete mechanical transforms for `b-refactor`.

**Output**
- Quick mode: concise chat plan with scope, risk, 2-5 likely steps, and verification.
- Full mode: saved plan using `skills/b-plan/reference.md`.

**Shared reference**
- `references/b-skills/domain-glossary.md` — optional convention when glossary docs should guide terminology or bounded-context planning.

**GitNexus use**
- Optional only for graph-shaped planning.

---

### b-research

Answers external-knowledge questions from fetched evidence.

**Core behavior**
- Chooses lookup for one fact/signature/config/capability and research for synthesis, comparison, recency, or conflicts.
- Pins library versions when APIs, configs, migrations, signatures, or examples depend on version.
- Treats user-provided URLs/files/documents as direct-source lookup when one source is likely sufficient.
- Uses Context7 for library/framework APIs, `brave-discovery` to find unknown official URLs, recent advisories/release notes, and comparison sources, and Firecrawl extraction for final page/document evidence when page substance matters.
- Falls back to native local reads only for plain-text, Markdown, or HTML documents when extraction is unavailable; otherwise stops and reports the limitation instead of guessing from filenames or metadata.
- Auto-deepens when evidence is stale, contradictory, non-authoritative, or indirect.
- Applies global privacy, citation-provenance, confidence, and deep-research approval rules.
- Requires primary vendor or source-repo evidence when available for security, licensing, pricing, breaking migrations, or production-impacting compatibility.
- Includes `as of` or source dates for recency-sensitive, pricing, security, licensing, compatibility, and migration answers.

**Output**
- Lookup: direct answer, optional example, source, confidence when needed.
- Research: answer, key findings, limitations, sources, confidence.

---

### b-implement

Executes approved or clearly scoped work in coherent verified steps.

**Core behavior**
- Resolves source of truth from saved plan, plan slug, approved chat plan, or small direct request.
- Requires executable plan approval state or current-chat approval before editing.
- Applies plan staleness before source edits and updates saved-plan progress/frontmatter without stripping metadata.
- States a one-line pre-edit checkpoint covering source of truth, expected touch points, behavior that must not change, verification, and approval/review needs.
- Preserves unrelated worktree changes and chooses isolation when global rules say it materially reduces risk.
- Uses Serena for symbol-aware edits and `apply_patch` for small prose/config/glue edits under global patch discipline.
- Allows tiny local mechanical edits required by an approved step; primary or broad mechanical transforms go to `b-refactor`.
- Verifies each coherent step, classifies failures, and uses global rollback/cascade/iteration rules.
- Continues to later plan steps only when they are already approved, dependency-ready, not higher risk, and locally verifiable; otherwise stops at the checkpoint.

**Output**
- Plan source, step progress, changes, verification, blockers/decisions, next action.

**GitNexus use**
- Optional only for shared/exported boundary or changed-scope validation.

---

### b-debug

Owns runtime and behavior failures.

**Core behavior**
- Starts from concrete symptoms, stack traces, repro notes, determinism, and perf baseline when relevant.
- Checks the regression window when available: recent commits, dependency/lockfile changes, config drift, feature flags, data shape changes, and environment differences.
- Keeps a repro record for non-trivial or blocked bugs: command or interaction, target/workspace, versions/config flags, data mode, expected/actual behavior, determinism, and evidence without secret values.
- Uses fast path when a trace strongly implicates one file/function.
- Ranks suspects only as needed and confirms root cause before editing.
- Tags temporary probes with `b-debug-probe`, removes probes, and re-verifies after cleanup.
- Measures perf bugs before and after.
- Uses bounded instrumentation for intermittent, remote-only, timing-dependent, or swallowed-error symptoms when it can collect decisive evidence.
- Uses the global cannot-reproduce protocol instead of defensive speculation.
- Hands structural redesign back to `b-plan`.

**Output**
- Symptoms, root cause, fix, verification, cleanup/next.

**Shared reference**
- `references/b-skills/performance-checklist.md` — multi-layer slowdown guidance.

---

### b-review

Reviews diffs, ranges, or checkpoints.

**Core behavior**
- Defaults to `git diff HEAD` and supports `--range` for changed-code review.
- Reviews cumulative WIP diffs from the best available base when appropriate.
- Uses fast path only for low-risk single-area changes; contract/auth/security/migration/dependency changes force standard review.
- Establishes a baseline from arguments, plan, checkpoint, or clarification; otherwise labels the review diff-only.
- Labels no-baseline reviews as `baseline-missing` and avoids requirements-coverage claims.
- Inspects highest-risk symbols and boundaries first.
- Names relevant security checklist sections when they affect findings or confidence.
- Checks tests/operability unless `--skip-tests` is present.
- Reports findings first, includes checked-and-clean areas for standard reviews, and emits READY FOR PR, READY WITH FOLLOW-UPS, or NEEDS FIXES.
- Blocks READY FOR PR when there is no baseline or required verification was skipped.

**Output**
- Scope/mode/path/baseline, findings, checked-clean areas, coverage/tests/observability, verdict.

**Shared references**
- `references/b-skills/performance-checklist.md`

**Skill reference**
- `skills/b-review/reference.md` — security checklist for auth, untrusted input, sensitive data, uploads, webhooks, and external integrations.

---

### b-audit

Audits named repository or suite surfaces outside diff-first review.

**Core behavior**
- Locks a named surface from arguments or `--surface` and refuses to default to a whole-repository audit.
- Establishes a baseline from arguments, `--baseline`, approved plan, checkpoint, or clarification; otherwise labels the audit `baseline-missing`.
- Chooses a surface-specific checklist: installer/update path, runtime contract, validator, route/tool boundary, dependency/lockfile, generated artifact, or security-sensitive rule.
- For b-skills suite audits, checks routing boundaries, skill-agent/runtime alignment, runtime-contract consistency, docs sync, validator coverage, artifact paths, and safety-gate drift.
- Names sampled files/symbols, skipped surfaces, and residual risk so no-findings audits are not mistaken for exhaustive proof.
- Runs only narrow checks that materially support the audit unless `--skip-checks` is present.
- Reports findings first and emits AUDIT PASS, AUDIT PASS WITH FOLLOW-UPS, or NEEDS FIXES.
- Blocks AUDIT PASS when there is no baseline, required verification was skipped, or sampled coverage leaves material unreviewed risk.

**Skill reference**
- `skills/b-audit/reference.md` — concrete audit criteria for installer/update paths, runtime contracts, validators, route/tool boundaries, dependencies, generated artifacts, security-sensitive rules, and b-skills suite audits.

**Output**
- Scope/mode/baseline, findings, checked-clean sampled areas, coverage/verification/operability, verdict.

---

### b-test

Owns code-level testing work.

**Core behavior**
- Discovers framework and narrowest runnable command from manifests/CI.
- Routes red tests through the global test-vs-bug decision.
- Confirms intended behavior from user-confirmed intent, an approved spec/plan, product contract, existing passing tests, intentional source changes, or fetched framework docs before changing assertions or snapshots.
- Stops or hands off to `b-spec` for unclear intended behavior or `b-debug` for uncertain product behavior unless the user explicitly asks for structural coverage only.
- Handles failing tests, new tests, coverage review, and flaky tests.
- Uses red-first behavior when feasible for TDD or regression tests, then hands off with intended behavior, failing test path, command, current failure, likely source area, and verification target before production changes.
- Chooses test type by boundary: pure logic unit, component DOM, and existing integration/contract tests for cross-module contracts.
- Ranks coverage gaps by user impact, changed behavior, risk boundary, and edge-case value.
- Keeps DOM-rendered and hybrid component tests here; real-browser automation is outside this suite.
- Updates snapshots/goldens only after intended behavior is confirmed.
- Uses `baseline-missing` tests only for explicitly requested structural coverage and limits claims to structural coverage.
- Bounds coverage work and avoids introducing new frameworks without approval.
- Uses global patch discipline for test edits.

**Output**
- Type, framework, findings, changes, verification, remaining gaps.

**Skill reference**
- `skills/b-test/reference.md` — fallback conventions for tests, fixtures, and assertions.

---

### b-refactor

Handles concrete behavior-preserving transforms.

**Core behavior**
- Locks exact target before editing.
- Uses Serena references as the primary static map and augments with exact text search for exported names, config keys, CLI flags, route strings, filenames, docs, generated consumers, and other dynamic/config/prose references.
- Uses a low-friction local fast path only for one-file, non-exported, LSP-supported, behavior-preserving refactors with direct semantic or narrow-test evidence and no generated consumers.
- Promotes risk for weak behavior evidence, non-LSP languages, generated consumers, exports/shared APIs, moves, and broad reference maps.
- Applies the smallest matching transform: rename, safe delete, extract, inline, rename+extract, or move.
- Requires concrete behavior-preserving boundaries for `simplify`, and sends public/package-boundary moves back to planning unless already approved.
- Requires observable equivalence to be named for `simplify`, `inline`, and `extract`; otherwise treats the request as redesign and sends it back to planning.
- Adds move destinations first, updates imports/tests/config/barrels, verifies, then removes origin.
- Hands behavioral redesign or over-broad transforms back to `b-plan`.

**Output**
- Target, risk, impact, changes, verification, follow-up.

**GitNexus use**
- Optional only for broader blast-radius questions.

---

## Source Boundaries

This file is the skill reference guide. For repository overview and install commands, use `README.md`; for maintainer rules, use root `CLAUDE.md`.

Runtime behavior is sourced from `global/CLAUDE.md`, `skills/<name>/SKILL.md`, `agents/`, `hooks/`, `settings/`, and `references/`. The installer copies or merges those files into `~/.claude/`, including `hooks/b-skills-guard.py`, `settings/b-skills.settings.json`, installed `CLAUDE.md`, and shared files such as `references/b-skills/runtime-contract.md`.

Shared references mentioned by skills:
- `runtime-contract.md`
- `domain-glossary.md`
- `performance-checklist.md`
