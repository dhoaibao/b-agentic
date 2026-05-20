# b-nexus — Agent Workflow Kernel Reference

Reference guide for the 10-skill set that makes up `b-nexus`, an agent workflow kernel for AI coding agents, with OpenCode as the reference runtime. For install and high-level repo overview, see [README.md](README.md). For maintainer guidance, see [AGENTS.md](AGENTS.md).

When this document cites `global/AGENTS.md`, that is the source-repo runtime kernel path. Installed skill prose should reference the runtime path `AGENTS.md`; detailed runtime behavior lives at `references/runtime-contract.md` in this repo and `references/b-nexus/runtime-contract.md` after install. Runtime references are required read gates when a skill needs their schemas, checklists, or protocols.

Runtime enforcement is intentionally mechanical: `global/AGENTS.md` owns the runtime gate checklist, each skill step uses explicit read gates for shared schemas/protocols/checklists, slash commands remind agents to follow the active kernel, and `scripts/validate-skills.sh` rejects passive pointers that would rely on memory.

Browser, DOM-rendered, visual, and e2e tests are unsupported by this suite. Do not route jsdom, Playwright, Cypress, Puppeteer, WebDriver, or equivalent browser/DOM work to `b-test`; narrow the task to repo-local code review, non-browser tests, or static analysis that does not render through a DOM or drive a browser. For UI/browser-relevant work, readiness claims require external evidence for those checks or an accepted follow-up.

---

## Skill reference

### b-orchestrate

Coordinates a complete PR-readiness workflow by handing work to phase skills.

**Core behavior**
- Owns phase selection, handoffs, checkpoints, and final synthesis only; the phase skills do the actual spec, plan, implementation, test, debug, refactor, research, or review work.
- Starts from a workflow goal and defines success as a `b-review` readiness verdict with required suite-supported verification complete.
- Requires external evidence before `READY FOR PR` when browser, DOM, visual, or e2e verification is relevant; otherwise the workflow can only be ready with accepted follow-ups.
- Mints and carries a run-id for non-trivial workflows, and checkpoints phase state when the workflow pauses, enters a review-fix loop, or needs durable resume state.
- Reads runtime contract gates before routing across phase skills, treating plans as approved, applying review-fix loops, or emitting non-trivial status output.
- Uses `b-spec` only when the target outcome is unclear, then `b-plan` for non-trivial sequencing or `b-implement` for small direct workflows.
- Hands actual build work to `b-implement`, runtime failures to `b-debug`, behavior-preserving transforms to `b-refactor`, and non-browser test work to `b-test`.
- Runs `b-review` against the current diff with the spec or approved plan as baseline, then routes findings back to the responsible phase skill.
- Re-reviews after each coherent fix set until `READY FOR PR`, user-accepted `READY WITH FOLLOW-UPS`, or a blocker.

**Output**
- Workflow goal, phase state, changes/verification, review verdict, blockers/follow-ups, and next action.

---

### b-spec

Clarifies rough or underspecified asks before planning.

**Core behavior**
- Stays active only while the target outcome is underdetermined.
- Reads runtime contract gates before applying clarification budgets, handoff envelopes, or non-trivial status output.
- Locks goal, constraints, acceptance criteria, non-goals, and assumptions with the smallest useful question loop.
- Uses repo evidence and optional `CONTEXT.md` / `CONTEXT-MAP.md` terminology before asking the user what the repo already answers.
- Enforces the global clarification budget; after two unresolved rounds, offers concrete interpretations with named assumptions.
- Outputs a compact chat spec and hands off to `b-implement`, `b-plan`, or `b-research`.

**Output**
- Goal, constraints, acceptance criteria, non-goals, assumptions, and next skill.

### b-plan

Turns a clear goal into an execution-ready plan without implementing.

**Core behavior**
- Defaults to quick mode for low-risk, chat-sized scoped work and uses full mode only for durable, multi-session, dependency-heavy, or risky coordination.
- Reads runtime contract and `skills/b-plan/reference.md` gates before saved-plan metadata, artifact paths, templates, staleness, or status output.
- Avoids promoting routine multi-step work to a saved plan solely because it has several obvious substeps.
- Saves full plans under `.opencode/b-nexus/b-plan/<plan-file-slug>.md` with durable frontmatter and `contract_version` from `global/AGENTS.md`; the filename stays English while frontmatter `slug` remains the canonical task slug.
- Promotes quick plans to saved plans when risk, breadth, or coordination grows.
- Uses repo evidence only when it materially improves sequencing or touch-point accuracy.
- Records assumptions separately from confirmed decisions unless the user confirms them.
- Uses stable anchors for prose/config-heavy work so later patches have reliable targets.
- Keeps broad refactors here until they become concrete mechanical transforms for `b-refactor`.

**Output**
- Quick mode: concise chat plan with scope, risk, 2-5 likely steps, and verification.
- Full mode: saved plan using `skills/b-plan/reference.md`.

**GitNexus use**
- Optional only for graph-shaped planning.

---

### b-research

Answers external-knowledge questions from fetched evidence.

**Core behavior**
- Chooses lookup for one fact/signature/config/capability and research for synthesis, comparison, recency, or conflicts.
- Reads runtime contract gates before tool fallback, external extraction/privacy decisions, freshness/citation claims, deep extraction, or non-trivial status output.
- Pins library versions when APIs, configs, migrations, signatures, or examples depend on version.
- Treats user-provided URLs/files/documents as direct-source lookup when one source is likely sufficient.
- Prefers structured extraction or query for specific fields, parameters, prices, tables, or lists, and keeps full markdown for full-page understanding, summaries, or quoted context.
- Requires approval before sending local rich documents or likely internal documents to external extraction unless that document class was already approved for the run.
- Uses Context7 for library/framework APIs, `brave-discovery` to find unknown official URLs, recent advisories/release notes, and comparison sources, and Firecrawl extraction for final page/document evidence when page substance matters; searches before extracting when the authoritative URL is unknown.
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
- Reads runtime contract gates before plan staleness, worktree safety, manual patching, verification, high-risk completion, or status/handoff output.
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
- Reads runtime contract gates before baseline taxonomy, containment/safety decisions, cannot-reproduce handling, manual patching, verification, or non-trivial status output.
- Uses the shared baseline source taxonomy when expected behavior is disputed or weak.
- Checks the regression window when available: recent commits, dependency/lockfile changes, config drift, feature flags, data shape changes, and environment differences.
- Keeps a repro record for non-trivial or blocked bugs: command or interaction, target/workspace, versions/config flags, data mode, expected/actual behavior, determinism, and evidence without secret values.
- Uses fast path when a trace strongly implicates one file/function.
- Ranks suspects only as needed and confirms root cause before applying the final fix.
- Allows approved reversible containment before root cause only for active production, data-loss, or security impact, and labels it as containment rather than the final fix.
- Tags temporary probes with `b-debug-probe`, removes probes, and re-verifies after cleanup.
- Measures perf bugs before and after.
- Uses bounded instrumentation for intermittent, remote-only, timing-dependent, or swallowed-error symptoms when it can collect decisive evidence.
- Uses the global cannot-reproduce protocol instead of defensive speculation.
- Hands structural redesign back to `b-plan`.

**Output**
- Symptoms, root cause, fix, verification, cleanup/next.

**Shared reference**
- `references/b-nexus/performance-checklist.md` — multi-layer slowdown guidance.

---

### b-review

Reviews diffs, ranges, or checkpoints.

**Core behavior**
- Runs `git status --short` before scoping, includes staged, unstaged, and in-scope untracked files for current-worktree review, and supports `--range` for changed-code review.
- Reads runtime contract and `skills/b-review/reference.md` gates before baseline taxonomy, security checklist use, severity/status output, or saved reports.
- Reviews cumulative WIP diffs from the best available base when appropriate.
- Uses fast path only for low-risk single-area changes; contract/auth/security/migration/dependency changes force standard review.
- Establishes a sufficient baseline from arguments, plan, checkpoint, clarification, or the shared baseline source taxonomy; otherwise labels the review diff-only.
- Labels no-baseline reviews as `baseline-missing` and avoids requirements-coverage claims.
- Inspects highest-risk symbols and boundaries first.
- Names relevant security checklist sections when they affect findings or confidence.
- Checks tests/operability unless `--skip-tests` is present.
- Reports findings first, includes checked-and-clean areas for standard reviews, and emits READY FOR PR, READY WITH FOLLOW-UPS, or NEEDS FIXES.
- Blocks READY FOR PR when there is no baseline, required verification was skipped, or unsupported browser/DOM/e2e evidence remains relevant but absent.
- Saves `report.md` only when requested, needed for a durable checkpoint/handoff, or too large for chat.

**Output**
- Scope/mode/path/baseline, findings, checked-clean areas, coverage/tests/observability, verdict.

**Shared references**
- `references/b-nexus/performance-checklist.md`

**Skill reference**
- `skills/b-review/reference.md` — security checklist for auth, untrusted input, sensitive data, uploads, webhooks, and external integrations.

---

### b-audit

Audits named repository or suite surfaces outside diff-first review.

**Core behavior**
- Locks a named surface from arguments or `--surface` and refuses to default to a whole-repository audit.
- Reads runtime contract and `skills/b-audit/reference.md` gates before baseline taxonomy, surface checklist selection, severity/status output, or saved reports.
- Establishes a sufficient baseline from arguments, `--baseline`, approved plan, checkpoint, clarification, or the shared baseline source taxonomy; otherwise labels the audit `baseline-missing`.
- Chooses a surface-specific checklist: installer/update path, runtime contract, validator, route/tool boundary, dependency/lockfile, generated artifact, or security-sensitive rule.
- For b-nexus suite audits, checks routing boundaries, skill-command wrapper alignment, runtime-contract consistency, docs sync, validator coverage, artifact paths, and safety-gate drift.
- Names sampled files/symbols, skipped surfaces, and residual risk so no-findings audits are not mistaken for exhaustive proof.
- Runs only narrow checks that materially support the audit unless `--skip-checks` is present.
- Reports findings first and emits AUDIT PASS, AUDIT PASS WITH FOLLOW-UPS, or NEEDS FIXES.
- Blocks AUDIT PASS when there is no baseline, required verification was skipped, or sampled coverage leaves material unreviewed risk.
- Saves `report.md` only when requested, needed for a durable checkpoint/handoff, or too large for chat.

**Skill reference**
- `skills/b-audit/reference.md` — concrete audit criteria for installer/update paths, runtime contracts, validators, route/tool boundaries, dependencies, generated artifacts, security-sensitive rules, and b-nexus suite audits.

**Output**
- Scope/mode/baseline, findings, checked-clean sampled areas, coverage/verification/operability, verdict.

---

### b-test

Owns non-browser code-level testing work.

**Core behavior**
- Discovers framework and narrowest runnable command from manifests/CI.
- Reads runtime contract gates before test-vs-bug routing, baseline taxonomy, flake handling, test data lifecycle handling, skipped-check labels, manual patching, or non-trivial status output.
- Routes red tests through the global test-vs-bug decision.
- Uses the shared baseline source taxonomy before changing assertions, snapshots, or behavior-defining tests.
- Confirms intended behavior from user-confirmed intent, an approved spec/plan, product contract, existing passing tests, intentional source changes, or fetched framework docs before changing assertions or snapshots.
- Stops or hands off to `b-spec` for unclear intended behavior or `b-debug` for uncertain product behavior unless the user explicitly asks for structural coverage only.
- Handles failing tests, new tests, coverage review, and flaky tests.
- Uses red-first behavior when feasible for TDD or regression tests, then hands off with intended behavior, failing test path, command, current failure, likely source area, and verification target before production changes.
- Chooses test type by boundary: pure logic unit tests and existing integration/contract tests for cross-module contracts.
- Ranks coverage gaps by user impact, changed behavior, risk boundary, and edge-case value.
- Treats browser, DOM-rendered, visual, and e2e tests as unsupported by this suite.
- Updates snapshots/goldens only after intended behavior is confirmed.
- Uses `baseline-missing` tests only for explicitly requested structural coverage and limits claims to structural coverage.
- Bounds coverage work and avoids introducing new frameworks without approval.
- Uses global patch discipline for test edits.

**Output**
- Type, framework, findings, changes, verification, remaining gaps.

---

### b-refactor

Handles concrete behavior-preserving transforms.

**Core behavior**
- Locks exact target before editing.
- Reads runtime contract gates before risk classification, manual patching, rollback/cascade/iteration handling, or non-trivial status output.
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
