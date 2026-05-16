# b-skills — Skill reference

Detailed contract reference for the maintained nine-skill suite. For install and high-level overview, see [README.md](README.md).

When this document cites `global/AGENTS.md`, that is the source-repo path. Installed skill prose should reference the runtime path `AGENTS.md`.

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
- `references/domain-glossary.md` — optional convention for persistent project glossary docs.

---

### b-plan

Turns a clear goal into an execution-ready plan without implementing.

**Core behavior**
- Uses quick mode for low-risk scoped work and full mode for non-trivial/risky coordination.
- Saves full plans under `.opencode/b-skills/b-plan/<task-slug>.md` with durable frontmatter from `global/AGENTS.md`.
- Promotes quick plans to saved plans when risk, breadth, or coordination grows.
- Uses repo evidence only when it materially improves sequencing or touch-point accuracy.
- Records assumptions separately from confirmed decisions unless the user confirms them.
- Uses stable anchors for prose/config-heavy work so later patches have reliable targets.
- Keeps broad refactors here until they become concrete mechanical transforms for `b-refactor`.

**Output**
- Quick mode: chat plan with scope, risk, steps, and verification.
- Full mode: saved plan using `skills/b-plan/reference.md`.

**GitNexus use**
- Optional only for graph-shaped planning.

---

### b-research

Answers external-knowledge questions from fetched evidence.

**Core behavior**
- Chooses lookup for one fact/signature/config/capability and research for synthesis, comparison, recency, or conflicts.
- Pins library versions when APIs, configs, migrations, signatures, or examples depend on version.
- Treats user-provided URLs/files/documents as direct-source lookup when one source is likely sufficient.
- Uses Context7 for library/framework APIs, search for discovery, news search for recency-sensitive questions, image search when visual evidence matters, and Firecrawl extraction for final page/document evidence.
- Auto-deepens when evidence is stale, contradictory, non-authoritative, or indirect.
- Applies global privacy, citation-provenance, confidence, and deep-research approval rules.

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
- Preserves unrelated worktree changes and chooses isolation when global rules say it materially reduces risk.
- Uses Serena for symbol-aware edits and `apply_patch` for small prose/config/glue edits under global patch discipline.
- Allows tiny local mechanical edits required by an approved step; primary or broad mechanical transforms go to `b-refactor`.
- Verifies each coherent step, classifies failures, and uses global rollback/cascade/iteration rules.

**Output**
- Plan source, step progress, changes, verification, blockers/decisions, next action.

**GitNexus use**
- Optional only for shared/exported boundary or changed-scope validation.

---

### b-debug

Owns runtime and behavior failures.

**Core behavior**
- Starts from concrete symptoms, stack traces, repro notes, determinism, and perf baseline when relevant.
- Uses fast path when a trace strongly implicates one file/function.
- Ranks suspects only as needed and confirms root cause before editing.
- Tags temporary probes with `b-debug-probe`, removes probes, and re-verifies after cleanup.
- Measures perf bugs before and after.
- Uses the global cannot-reproduce protocol instead of defensive speculation.
- Hands structural redesign back to `b-plan`.

**Output**
- Symptoms, root cause, fix, verification, cleanup/next.

**Shared reference**
- `references/performance-checklist.md` — multi-layer slowdown guidance.

---

### b-review

Reviews diffs, ranges, checkpoints, or explicitly requested repo areas.

**Core behavior**
- Defaults to `git diff HEAD`, supports `--range`, and uses `--repo-audit` for named audit surfaces.
- Reviews cumulative WIP diffs from the best available base when appropriate.
- Uses fast path only for low-risk single-area changes; contract/auth/security/migration/dependency changes force standard review.
- Establishes a baseline from arguments, plan, checkpoint, or clarification; otherwise labels the review diff-only/audit-only.
- Inspects highest-risk symbols and boundaries first.
- Checks tests/operability unless `--skip-tests` is present.
- Reports findings first, includes checked-and-clean areas for standard reviews, and emits READY FOR PR, READY WITH FOLLOW-UPS, or NEEDS FIXES.

**Output**
- Scope/mode/path/baseline, findings, checked-clean areas, coverage/tests/observability, verdict.

**Shared references**
- `references/security-checklist.md`
- `references/performance-checklist.md`

---

### b-test

Owns code-level testing work.

**Core behavior**
- Discovers framework and narrowest runnable command from manifests/CI.
- Routes red tests through the global test-vs-bug decision.
- Handles failing tests, new tests, coverage review, and flaky tests.
- Keeps DOM-rendered and hybrid component tests here; real browsers go to `b-e2e`.
- Updates snapshots/goldens only after intended behavior is confirmed.
- Bounds coverage work and avoids introducing new frameworks without approval.
- Uses global patch discipline and stale-context recovery for test edits.

**Output**
- Type, framework, findings, changes, verification, remaining gaps.

**Shared reference**
- `references/testing-patterns.md` — fallback conventions for tests, fixtures, and assertions.

---

### b-e2e

Uses a real browser for flow verification and browser-test authoring.

**Core behavior**
- Uses Playwright MCP or local Playwright CLI fallback.
- Keeps production-like targets read-only unless mutating approval names the environment.
- Uses ephemeral auth unless reusable auth persistence is explicitly approved.
- Snapshots before interaction and verifies concrete UI state.
- Checks focused accessibility on interacted surfaces.
- Preserves the repo's existing browser-test framework in author mode.
- Creates artifacts and manifests when evidence or cleanup must be auditable; sensitive/auth artifacts stay outside the worktree by default.
- Closes the browser and reports cleanup/partial writes.

**Output**
- Mode, target, driver, interactions, assertions, test code, artifacts/cleanup.

**Shared reference**
- `references/accessibility-checklist.md` — focused a11y fallback checklist.

---

### b-refactor

Handles concrete behavior-preserving transforms.

**Core behavior**
- Locks exact target before editing.
- Uses Serena references as the primary static map and augments with text search for dynamic/config/generated/prose references.
- Uses a low-friction local fast path only for one-file, non-exported, LSP-supported, behavior-preserving refactors with no generated consumers.
- Promotes risk for non-LSP languages, generated consumers, exports/shared APIs, moves, and broad reference maps.
- Applies the smallest matching transform: rename, safe delete, extract, inline, rename+extract, or move.
- Adds move destinations first, updates imports/tests/config/barrels, verifies, then removes origin.
- Hands behavioral redesign or over-broad transforms back to `b-plan`.

**Output**
- Target, risk, impact, changes, verification, follow-up.

**GitNexus use**
- Optional only for broader blast-radius questions.

---

## Repository layout and maintenance

This repository is the install-only source layout for the suite. OpenCode does not load checked-in `skills/`, `commands/`, or `references/` directly from this repo root.

### Repository source files
- `AGENTS.md` — maintainer guidance for this source repo.
- `global/AGENTS.md` — runtime global rules source, installed as `AGENTS.b-skills.md` and optionally applied to OpenCode's main `AGENTS.md`.
- `skills/<name>/SKILL.md` — concise skill sources.
- `commands/<name>.md` — thin slash-command wrappers.
- `references/*.md` — reusable checklists and conventions shared by multiple skills.
- `scripts/smoke-install.sh` — isolated installer smoke checks.
- `scripts/validate-skills.sh` — validator for frontmatter, required sections, stale phrases, docs coverage, and global-rule guardrails.

### Runtime artifacts
- `.opencode/b-skills/b-plan/<task-slug>.md` — saved plans after the repo-local ignore guard.
- `.opencode/b-skills/<skill>/<run-id>/` — repo-local non-sensitive run artifacts.
- `.opencode/b-skills/<skill>/<run-id>/report.md` — saved review/research reports.
- `~/.config/opencode/b-skills/<skill>/<run-id>/` or `/tmp/opencode/b-skills/<skill>/<run-id>/` — non-worktree sensitive artifacts.
- `/tmp/opencode/b-skills/<skill>/<slug>.log` — large command output and temporary logs.

### Runtime global conventions
- One active skill at a time; trigger precedence lives in `global/AGENTS.md`.
- Skill bodies are intentionally concise: trigger boundary, task-specific workflow, and task-specific stop conditions only.
- Global rules own rubrics, safety gates, artifacts, status/handoff schemas, skipped-check labels, evidence hierarchy, happy-path compression, fallback labeling, patch discipline, transform rollback, cascading failures, and output caps.
- Non-trivial runs define success, verify with the global ladder, and report skipped checks with global labels.
- Serena is primary hands for symbols and edits. GitNexus is optional radar only when indexed, fresh, and target-aware.
- Cited URLs must come from sources fetched or supplied in the current session.
- Common rationalizations live in `global/AGENTS.md`; skills do not duplicate them.

### Tool model
- Native tools stay first for exact strings, manifests, prose, configs, and small reads.
- Skills reference MCP bundles by name; bundle definitions and fallbacks live in `global/AGENTS.md`.
- Runtime evidence outranks symbol evidence, then graph, text, and snippets.
- `sequential-thinking` is optional for evenly ranked multi-hypothesis decisions.

### Installer behavior
- `install.sh` always installs the suite runtime snapshot at `~/.config/opencode/AGENTS.b-skills.md`.
- It replaces `~/.config/opencode/AGENTS.md` only when missing or explicitly approved.
- Preserve-mode installs are activation-pending until the active `AGENTS.md` is replaced or merged.
- `--dry-run` / `B_SKILLS_DRY_RUN=Y` previews changes without writing.
- Managed config metadata is stored in `~/.config/opencode/b-skills-install.json`.

### Maintenance rules
- Keep command wrappers thin.
- Update `README.md` and `REFERENCE.md` with skill changes.
- Run `scripts/validate-skills.sh` before installing or committing skill changes.
- Keep shared policy in `global/AGENTS.md`; do not duplicate it across skills.
