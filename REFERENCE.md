# b-skills — Skill reference

Detailed contract reference for the b-skills suite. For install and overview, see [README.md](README.md).

---

## Skill reference

### b-plan

Think before coding. Decompose tasks into ordered steps, evaluate competing approaches, surface risks, and produce an execution-ready plan file.

**Core behavior**
- **Step 0** picks **quick mode** vs **full mode** before any other work. Quick = scoped daily tasks (chat plan, approval, then `b-implement`). Full = unclear/high-risk/multi-layer (saved plan file, then `b-implement`).
- Auto-selects mode from task complexity, announces it in one sentence, and asks the user only when both modes are genuinely valid and preference matters.
- For clearly scoped tasks, states the interpreted scope and uses final plan approval as the confirmation gate instead of asking twice.
- Escalates quick → full when discovery reveals broad references, unclear requirements, structural decisions, external API uncertainty, or deployment risk.
- Treats user-visible/product decisions as blockers, while allowing low-risk engineering assumptions only when explicitly recorded and non-behavioral.
- Blocks planning for complex research when the answer affects feasibility, architecture, external contracts, security, or migration order.
- Owns broad or unclear refactors until they're reduced to concrete rename/extract/move/inline steps that can be handed off to `b-refactor`.
- Hands approved implementation work to `b-implement` by default so planning and execution stay distinct.
- Uses `sequentialthinking` for approach selection and ordered execution steps when available; otherwise reasons inline with the same structure.
- For existing-code tasks, follows a strict supported-Serena read-order in Step 2: onboarding check → symbol discovery → overview → references → narrow native reads only when needed.
- Uses `find_declaration` and `find_implementations` during Step 2 when planning starts from a call site/import usage or an interface boundary instead of an owning definition.
- Issue/ticket scrape (when user-provided) lives in Step 2 as a context source for the scan; ordinary planning does not pause just to ask for a ticket link.
- Evaluates multiple approaches and documents the chosen one in `## Decision`.
- Includes a feasibility gate for uncertain or large-scope tasks.
- Adds deploy-safety annotations (feature flags, migration ordering, external dependencies).

**Good triggers**
```text
/b-plan add rate limiting to the API
plan: design the notification system
how should I approach refactoring the auth module?
```

**Output**
- Quick mode: returns a concise 2–5 step chat plan with a verification step in the user's chat language.
- Full mode: writes an English plan file to `.opencode/b-plans/[task-slug].md`.
- Full-mode plans include: `## Decision` (approach + rejected alternatives), ordered checkbox steps, dependencies, risks, unknowns, and optional `## Feasibility` and `## Mapping outline`.
- Final plans must be self-contained enough that a fresh agent can execute them without clarifying questions.
- Saved plan files are always in English.

**Key rules**
- Do not implement until the user approves the plan; after approval, use `b-implement` unless the user explicitly asks to continue in the same session.
- Full mode must write to `.opencode/b-plans/`; quick mode may stay in chat unless the user asks for a saved plan.
- The feasibility gate only confirms blockers and scope; it does not replace `/b-research` for deep unknowns.
- All unresolved unknowns must be surfaced. Blocking decisions/research stop planning; non-blocking assumptions must be recorded explicitly.
- **Full-mode handoff standard: 90%+** — every saved-plan step must be detailed enough that a fresh agent with zero prior context can implement it without asking a follow-up question; quick plans stay concise.

**GitNexus use**
- Use only for graph-shaped planning: unfamiliar architecture, broad impact, route/API consumers, process flows, multi-repo or package boundaries.
- Skip GitNexus for known-file, known-symbol, or local-only planning; go directly to Serena/native tools.

---

### b-research

All external knowledge in one skill: auto-detects quick lookup vs full multi-source research.

**Core behavior**
- Starts with mode detection: quick lookup for single-fact questions, full mode for comparisons, cited reports, recency, or page-reading.
- For library/framework API questions: Context7 first.
- In quick mode: answers in 1–3 sentences with a minimal example, capped at 2 tool calls, never scrapes, and only trusts web snippets when the source is official or high-authority.
- Starts with quick mode when plausible, then escalates automatically when the answer needs more than 2 tool calls, more than 1 source, or any page scraping.
- In full mode: classifies query into VERSION / COMPARE / NEWS / HOWTO/API / VISUAL / LOCALDOC → Brave Search with `firecrawl_search` fallback → Firecrawl scrape/parse/extract when available → quality gate → synthesis report.
- If Firecrawl is unavailable, full mode may continue only from official/high-authority search, source, changelog, or Context7 evidence and must label the limitation.
- NEWS mode widens freshness from daily to weekly to monthly when the topic is not breaking news.
- Structured extraction first locks the exact output fields, then uses Firecrawl extract or JSON scraping when supported.
- Uses `brave_image_search` for visual-reference questions and may use `brave_summarizer` only as a non-citable triage aid when the connected Brave plan supports it.
- Uses `firecrawl_parse` for local PDFs/docs/sheets, `firecrawl_interact` for known JS-heavy pages after scrape/map fails, and `firecrawl_agent` only as a last-resort deep-research fallback.
- Applies source-quality ranking: official docs/changelogs, source repos/releases, vendor engineering posts, reputable community sources, then low-context snippets/SEO content.
- Uses `sequentialthinking` only when conflicting sources materially change the recommendation.
- Prefers 3 high-quality sources over 5 mixed-quality ones.

**Good triggers**
```text
/b-research how do I configure retries in BullMQ?
/b-research what's the signature of Array.prototype.flatMap?
/b-research compare bullmq vs bee-queue for job queues
/b-research best practices for webhook signature verification
tra cứu cách dùng thư viện Prisma
```

**Output**
- **Quick lookup**: concise 1–3 sentence answer with minimal example and source.
- **Research report**: structured report with summary, findings, optional comparison table, limitations, and cited sources.

**Key limits**
- Quick mode caps at 2 tool calls before escalating or answering.
- Default scrape cap in full mode: 3 URLs per session; 5 for COMPARE queries.
- `firecrawl_crawl` is only for user-requested comprehensive coverage of a known site section, capped at `limit <= 10` and `maxDiscoveryDepth <= 2`.
- Never fill factual gaps from training data in full mode when sources do not support them.
- If scraping is unavailable in full mode, answer only from official/high-authority evidence and label the result as limited.
- Escalate quick web lookups to full mode when source authority or context is unclear.

---

### b-implement

Approved/scoped-plan execution: read the source of truth, apply one step at a time, verify each step, and stop when new decisions appear.

**Core behavior**
- Resolves implementation source from `$ARGUMENTS`, `.opencode/b-plans/[slug].md`, an explicitly approved chat plan, or a small clearly scoped direct request.
- Broad work requires a saved plan, explicitly approved chat plan, or explicit approval statement; loose feature descriptions are not treated as implementation-ready.
- Routes broad "build this" requests without approved scope back to `b-plan` instead of treating them as implementation-ready.
- Extracts confirmed decisions, planned touch points, ordered steps, dependencies, and `Done when` checks before editing.
- Checks `git status --short` and preserves unrelated user changes.
- Uses Serena for symbol-aware code changes: onboarding check -> symbol/file discovery -> overview -> declaration/implementation resolution when needed -> references -> minimal edit.
- Uses `search_for_pattern` when an approved step describes behavior or code shape more clearly than a stable symbol name.
- Implements exactly one dependency-ready step at a time, then verifies with the plan's `Done when` command or the narrowest relevant check.
- Uses `get_diagnostics_for_file` as a narrow local verification pass before broader commands when the touched language supports diagnostics.
- Uses GitNexus API-aware checks (`api_impact`, `shape_check`, `tool_map`) when the implementation changes route or tool contracts instead of treating every shared change as generic graph impact.
- Marks saved plan checkboxes complete only after verification passes.
- Stops for new product/behavior decisions instead of self-inferring.
- Hands unplanned mechanical transformations (rename/move/extract/inline/delete) to `b-refactor` unless the approved plan explicitly includes them.

**Good triggers**
```text
/b-implement .opencode/b-plans/add-rate-limit.md
/b-implement add-rate-limit
implement the approved plan
làm theo plan vừa duyệt
```

**Output**
```
Plan source -> Step progress -> Changes -> Verification -> Blockers/Decisions -> Next
```

**Key rules**
- Implement only approved or clearly scoped work; unclear scope goes back to `b-plan`.
- Work one step at a time and verify before moving on.
- Do not refactor opportunistically while implementing a feature step.
- Do not overwrite unrelated user changes.
- Do not commit unless explicitly asked.

**GitNexus use**
- Use only for high-risk shared/exported boundaries or post-change changed-scope validation when the index is fresh and target-aware.
- Treat GitNexus output as graph evidence for prioritization; confirm exact symbols and edits with Serena.

---

### b-debug

Systematic, hypothesis-driven debugging with full-loop execution by default.

**Core behavior**
- Uses supported Serena tools to map execution path, references, suspicious symbols, and file structure (Step 2).
- Uses `find_declaration` to jump from suspicious usages to owning definitions and `find_implementations` to trace polymorphic boundaries without widening reads too early.
- Uses `search_for_pattern` when a suspicious code path is described by behavior or code shape rather than a precise symbol.
- If Serena is unavailable, falls back to bash/read with reduced cross-file confidence.
- Initializes Serena project knowledge with onboarding check before tracing when needed.
- **Step 3a** forms ranked hypotheses with evidence/verification per item, reports them as progress, then continues verification without waiting unless the user requested diagnosis-only mode.
- **Step 3b** runs fast-path lookups (library-error shortcut + error-string codebase search) before verifying — these often eliminate wrong hypotheses.
- Library error shortcut: web search → Firecrawl scrape (top 1–2 URLs) → Context7 verification.
- Dynamic verification loop in Step 4 when static analysis is insufficient (try safe local reproduction first, then max 3 instrumentation rounds; remove added debug logging before stopping unconfirmed).
- Uses `get_diagnostics_for_file` as an optional fast signal when editor/compiler diagnostics may explain the symptom faster than runtime reproduction.
- For API handler or consumer bugs, can prefer GitNexus `api_impact`, `route_map`, or `shape_check` before broad graph or runtime instrumentation.
- Starts from a concrete symptom/error when available; asks only for missing context that blocks the next verification step.
- Inspects the final diff/touched lines to confirm temporary debug logging or probes were removed.
- After confirming root cause, implements the minimal fix using symbol-aware tools and states exact verification steps.

**Default contract**: `trace → confirm root cause → fix → verify`
Diagnosis-only is used when the caller asks only for explanation/root cause or explicitly requests investigation-only output.

**Good triggers**
```text
/b-debug webhook not triggering despite correct URL registration
/b-debug intermittent 500 on /api/send with no error in logs
why is this callback not running?
```

**Output**
```
Symptoms → Code path → Ranked hypotheses → Fast-path findings → Root cause → Fix → Verification
```

**Key rules**
- Never patch before root cause is explicitly confirmed.
- After fixing, keep Serena-aware edits focused on the changed symbols/files only.

**GitNexus use**
- Use only when the bug path is unfamiliar, cross-module, process-flow-driven, or too broad for direct Serena tracing.
- Treat GitNexus as a route into the right subsystem; confirm the execution path with Serena/text/runtime evidence.

---

### b-review

Human-judgment pre-PR changed-code review: correctness, requirements, edge cases, tests, and minimum observability on new entry points.

**Core behavior**
- Reads `git diff HEAD` plus `git status --short`, includes related untracked non-sensitive files, and builds requirements baseline from plan file, `$ARGUMENTS`, or user clarification.
- If no requirements baseline is available after bounded clarification, continues as a clearly labeled diff-only risk review and skips strict requirements coverage.
- Does not silently review `HEAD~1` when no diff exists; asks for a commit, branch, or comparison range instead of retrying a redundant staged-only diff.
- Defines fast-path threshold (`≤50 lines AND ≤2 files`) once at the top of the skill — referenced by Steps 2, 3, and 6, but never used to skip entry-point security checks.
- Treats multiple plan-file candidates as ambiguous and asks which requirements source to use instead of guessing.
- Uses supported Serena tools to prioritize review depth by changed symbols, references, and affected files.
- Adds `find_declaration` / `find_implementations` when the diff highlights a usage or contract boundary more clearly than the owning definition, and may use `get_diagnostics_for_file` for narrow typed-language breakage checks.
- Uses GitNexus `api_impact` / `shape_check` for API diffs and `tool_map` for MCP/RPC tool-handler diffs when those surfaces are the likely review risk.
- Initializes Serena project knowledge with onboarding check before reviewing changed symbols when needed.
- Follows a strict read-order: find symbol → find referencing symbols → overview → narrow reads. Never jumps straight from diff to full file reads.
- Reviews changed files outline-first, then opens only high-risk symbols/source paths.
- Uses `sequentialthinking` only when blocker/suggestion classification is genuinely ambiguous.
- Always checks **injection vectors** and new/changed entry-point security, even on very small diffs.
- Runs observability check (Step 6) only for newly added endpoints/handlers/jobs/consumers; fast-path does not skip tiny diffs that add or change entry points.
- Avoids routine lint/test reruns, but may run a narrow command when reviewer confidence depends on runtime or type evidence.
- Skips test-adequacy + observability when `$ARGUMENTS` contains `skip test adequacy`.

**Step layout**
1. Get the diff
2. Establish requirements baseline or mark diff-only risk review mode (fast-path eases this, but plan-file ambiguity asks the user)
3. Logic correctness (fast-path may skip expanded checks, but injection and entry-point security ALWAYS run)
4. Requirements coverage check
5. Edge case + test adequacy check
6. Observability check (skipped if no new entry points, or fast-path with no entry-point changes)
7. Consolidate findings

**Good triggers**
```text
/b-review
/b-review code review
review before PR
kiểm tra logic trước khi push
/b-review skip test adequacy
```

**Output**
```
Findings → Coverage / tests / observability → READY FOR PR or NEEDS FIXES
```

**Handoff**
- `READY FOR PR` → implement any non-blocking suggestions, then commit.
- `NEEDS FIXES` → fix blockers, re-run tests, then `/b-review` again.

**GitNexus use**
- Use only for broad changed-scope, route/API consumer, process-flow, or cross-module review risk when the index is fresh and target-aware.
- Treat GitNexus findings as prioritization evidence; confirm findings with `git diff`, Serena references, and narrow source reads.

---

### b-test

Test-driven development, test debugging, and test coverage evaluation.

**Core behavior**
- Discovers test files, framework, and project-specific test/coverage commands via manifests and CI config, then inspects structure with Serena symbol tools.
- Step 2 picks a branch:
  - **Branch A — Failing test**: read test + source, identify assertion/mock/setup/async issue, apply minimal fix.
  - **Branch B — Write tests**: map source symbol, list edge cases, add tests via Serena symbol tools or `apply_patch` for new files.
  - **Branch C — Evaluate coverage**: run coverage report, rank gaps, optionally write top 1–3 missing tests.
- Runs the narrowest relevant tests via bash after every change, ensuring the temp output directory exists under `/tmp/opencode/b-skills/b-test/` and capturing full failure output instead of truncating with `tail`.
- Uses `find_declaration` / `find_implementations` to map tests to the real source owner when helpers, imports, or interfaces obscure the target, and `get_diagnostics_for_file` before reruns when local syntax/type errors are likely.
- Handles snapshot/golden and shared-fixture drift explicitly; regenerates or updates only after confirming behavior intentionally changed.
- Runs broader/full suites for new tests only when shared behavior, fixtures, public contracts, or project conventions justify it.
- Distinguishes test-specific failures from runtime bugs. Unconfirmed production behavior failures hand off to `b-debug` instead of patching production code from test output alone.
- Requires behavior confirmation before changing assertions; a red assertion alone is not proof the expected value is wrong.
- Uses `sequentialthinking` for test strategy only when unit vs integration is ambiguous.

**Good triggers**
```text
/b-test write tests for the auth module
/b-test fix failing login test
/b-test evaluate coverage for the API layer
```

**Output**
```
Type → Framework → Test structure → Issue/Requirements → Fix/Implementation → Verification → [Coverage if Branch C]
```

**Key rules**
- Never modify production code to make a test pass unless the production code is actually buggy.
- Never update an assertion just because it is red; confirm expected behavior from requirements, contracts, or source behavior first.
- Write behavior tests (assert on output), not implementation tests (assert on internal state).
- Keep test fixes minimal — one assertion at a time.
- Browser/UI testing and user-flow verification go to `b-e2e` — `b-test` owns code-level unit and integration tests only.

---

### b-e2e

Browser-based frontend testing and Playwright E2E script authoring.

**Core behavior**
- Uses Playwright MCP (`playwright_browser_*` tools) to navigate to the target web application.
- Before navigating to `localhost`, verifies the dev server is reachable via a bash health check; asks the user to start it or approve a discovered project-specific start command if not responding.
- Creates a session-specific directory under `.opencode/b-skills/b-e2e/[run-id]/` for native notes, manifest, and generated test files; Playwright MCP artifacts use supported filenames or returned artifact paths.
- Clarifies auth/session, seed data, cleanup expectations, and environment safety before executing stateful flows.
- Prefers disposable accounts, seeded state, or pre-authenticated local sessions; it must not ask for real production credentials in chat.
- Relies on accessibility tree snapshots (`playwright_browser_snapshot`) to map the UI and get precise target references.
- Performs sequential user interactions (clicks, typing, form fills, dropdowns, uploads, hover flows, drag/drop, dialogs, and multi-tab checks).
- Verifies UI state changes via updated snapshots, console checks, responsive desktop/mobile passes when relevant, and optional network assertions.
- Translates successful manual interactions into Playwright test code via Serena symbol tools when an existing spec exists, or `apply_patch` when no spec file exists.
- Reads Playwright config and package scripts before authoring tests to preserve test directory, base URL, project, and command conventions.
- Uses stable waits/assertions and reruns generated tests once when manual and scripted results conflict to detect flakiness.
- Keeps `playwright_browser_run_code_unsafe` as a tightly scoped last resort when first-class browser tools cannot express the needed interaction or assertion.
- Closes the browser session when the flow finishes and keeps artifacts unless the user asks to delete this run's directory.

**Good triggers**
```text
/b-e2e write a test for the checkout flow
/b-e2e verify the login page is rendering correctly
chạy E2E test cho form đăng ký
```

**Output**
```
Target URL → UI Snapshot → Interactions → Assertions → [Optional] Test Code → Cleanup
```

**Key rules**
- Inherently requires the `playwright` MCP to function.
- Never guess element selectors; always read the `playwright_browser_snapshot` first.
- For `localhost` targets, run a bash health check before calling `playwright_browser_navigate`.
- Native notes, manifest, and generated test files go into `.opencode/b-skills/b-e2e/[run-id]/`; Playwright MCP artifacts use supported filenames or returned artifact paths.
- Do not start a dev server without user approval, and never mutate production-like data without explicit confirmation.
- Always close the browser at cleanup; do not delete artifacts by default.
- Distinct from `b-test`, which handles code-level unit testing without a live browser.

---

### b-refactor

Code refactoring with impact analysis and safe mechanical transformation.

**Core behavior**
- Maps full impact radius with `find_referencing_symbols` before touching any code.
- Uses `find_declaration` and `find_implementations` to lock the exact refactor target before renaming, moving, or deleting when the request starts from usage sites or abstract contracts.
- Uses `search_for_pattern` when the request starts from a repeated code shape or behavior instead of a named symbol.
- Requires a green baseline check for medium/high-risk refactors; low-risk single-file mechanical edits may skip baseline with an explicit note.
- Uses Serena's symbol-aware tools (`rename_symbol`, `safe_delete_symbol`, `replace_symbol_body`) for cross-file safe edits where symbol-level operations apply.
- Uses `get_diagnostics_for_file` as a local post-edit guard before broader typecheck/test commands when supported.
- Uses `apply_patch` for line-level import/config/prose edits where symbol tools do not apply.
- Discovers project-specific typecheck/test commands from manifests or CI instead of using generic chained commands.
- Assumes the target transformation is already concrete; broad, unclear, or vague cleanup requests should go through `b-plan` first.
- Executes in dependency order (inner helpers first, outer callers last).
- Verifies after every step: compilation → tests → git diff.
- Checks public/exported API compatibility before changing signatures or paths.
- Renames files with `apply_patch` move operations when practical; broad directory moves require explicit confirmation because imports, docs, and tooling paths may change.
- Runs full-suite verification only when the refactor scope warrants it; otherwise reports why narrower checks were sufficient.
- For large refactors (>3 files or crossing package boundaries): uses `sequentialthinking` to plan phases.
- Vague cleanup requests without a specific target or behavior-preserving transformation go to `b-plan` first.
- Hands off post-refactor failures: real regression → `/b-debug`; test-mechanic drift → `/b-test`.
- Uses GitNexus `api_impact` or `tool_map` when the refactor target is a route/tool contract instead of a plain internal symbol.

**Transformations supported**
- Rename symbol
- Rename file with `apply_patch` move operations plus Serena impact checks; broad directory rename only after explicit confirmation
- Extract method/function
- Inline variable/function
- Move code between files
- Delete dead code
- Split large function

**Good triggers**
```text
/b-refactor rename UserService to UserRepository
/b-refactor extract validation logic from handleSubmit
/b-refactor delete the unused legacyAuth module
```

**Output**
```
Target → Impact → Risk → Transformation plan → Changes → Verification
```

**Key rules**
- Never perform a medium/high-risk refactor without a green baseline check.
- Always use `find_referencing_symbols` before renaming or deleting.
- Prefer `rename_symbol` over manual `apply_patch` for symbol renames — it updates all references atomically.
- Prefer `safe_delete_symbol` over manual deletion — it prevents accidental removal of still-used code.
- Run compilation check after every mechanical step.
- Run the full test suite after the last step only when scope/risk warrants it; otherwise document the narrower verification.
- Keep changes separated by logical transformation, but do not commit unless explicitly asked.

**GitNexus use**
- Use only for exported/shared targets, package/service boundaries, or >2-file refactors when the index is fresh and target-aware.
- Treat GitNexus impact as blast-radius radar; Serena references and symbol edits remain the source of truth.

---

## Repository layout and maintenance

This repository is the install-only source layout for the suite. OpenCode does not load the checked-in `skills/` or `commands/` directories directly from this repo root; use `install.sh` to deploy them into `~/.config/opencode/`.

### Repository source files
- `AGENTS.md` — maintainer-only guidance for working on this source repo locally.
- `global/AGENTS.md` — source for runtime rules installed as OpenCode's global `AGENTS.md`.
- `skills/<name>/SKILL.md` — reusable OpenCode skills distributed by the installer.
- `commands/<name>.md` — explicit slash-command wrappers distributed by the installer.
- `scripts/validate-skills.sh` — lightweight contract validator for skill frontmatter, required sections, stale tool references, old artifact paths, GitNexus scope drift, runtime-global leakage, and docs coverage.

### Runtime artifacts
- `~/.config/opencode/skills/` — installed skill destination created by `install.sh`.
- `~/.config/opencode/commands/` — installed command destination created by `install.sh`.
- `~/.config/opencode/AGENTS.md` — installed runtime rules file created by `install.sh`.
- `.opencode/b-plans/` — saved plan files created by `/b-plan`.
- `.opencode/b-skills/<skill>/<run-id>/` — skill run artifacts, where `run-id` is `<YYYYMMDD-HHMMSS>-<slug>`.
- `.opencode/b-skills/b-e2e/[run-id]/` — browser snapshots, screenshots, notes, manifest, and generated E2E artifacts created by `/b-e2e`.
- `/tmp/opencode/b-skills/<skill>/<slug>.log` — temporary command output and full failure logs.
- Multi-artifact runs should report or maintain a manifest with artifact paths, generated files, command logs, cleanup status, and external artifact references.

### Runtime global conventions
- Cross-skill handoffs include `source`, `scope`, `files`, `commands`, `blockers`, and `next skill`.
- Keep one active skill until its documented stop condition is hit; do not switch skills for optional enrichment or minor lookups that the current skill can finish inline.
- Approval is required before package installs, dev-server starts, migrations, destructive commands, production-like/staging writes, broad refactors, or commits.
- Use the lightest capable tool for the evidence needed. Native tools stay first for exact strings, manifests, prose, configs, and small reads; MCPs are for semantic or external tasks that materially reduce ambiguity.
- Verification follows the ladder: narrow check → broader affected-area check → full check only when scope/risk justifies it.
- Worktree checks include relevant untracked non-sensitive files; sensitive-looking files are never read without explicit permission.
- Final implementation/debug/test/refactor/review responses include changes or findings, verification evidence, blockers or skipped checks, and the natural next action.

### Serena/OpenCode contract
- `install.sh` configures Serena as `serena start-mcp-server --context=ide --project-from-cwd`.
- The suite treats OpenCode as a generic Serena `ide` client, not as a custom Serena context with separate runtime semantics.
- Serena is the semantic layer for symbol discovery, references, and structural edits.
- The suite selectively uses Serena additions such as `find_declaration`, `find_implementations`, `search_for_pattern`, and `get_diagnostics_for_file` where they reduce broad reads or replace heavier verification.
- OpenCode's native file and shell tools remain the default for overlapping basic operations that Serena's `ide` context assumes the harness already provides.
- Serena onboarding preflight (`check_onboarding_performed`, then `onboarding` if needed) should run once when symbol-aware work starts in a skill run, not before every later Serena step.
- Manual line/prose/config edits use `apply_patch`; runtime skill instructions should not rely on unavailable native `edit` or `write` tools.
- The activated Serena project is expected to follow the current working directory, so core skill guidance must stay single-project and must not depend on project-switching workflows.
- Serena memory is available for durable project knowledge, but the suite treats it as selective and task-driven rather than a default read/write step in every skill.
- **GitNexus** *(optional radar)* — graph-level repo intelligence (cross-file impact, architecture context, execution-flow discovery, stale-index detection, route/API consumers, multi-repo mapping). Use it only for graph-shaped tasks when the repo is indexed, fresh, and the target file/symbol is represented. Serena then handles exact symbol inspection and edits. If GitNexus is unavailable, stale, unindexed, missing FTS, or missing the target, skills warn once and fall back to Serena and native tools.
- **Non-overlap rule** — GitNexus should answer only the graph question first; Serena should answer the exact-symbol question next. Do not keep both MCPs active on the same exact question unless a new graph question is uncovered mid-flow.

### Evidence model
- **Graph evidence**: GitNexus relationships, routes, processes, and impact. Use for prioritization and risk, not proof that edits are safe.
- **Symbol evidence**: Serena symbol bodies, references, overviews, and symbol edits. Use as the source of truth for code modifications.
- **Text evidence**: Glob/Grep/Read/Bash exact matches. Use for manifests, config, prose, generated files, and import/string confirmation.
- **Runtime evidence**: tests, builds, command output, browser state, network calls, and logs. Use to verify behavior.

### Maintenance rules
- Keep one folder per skill under `skills/`.
- Keep command wrappers thin; they are entrypoints, not duplicate logic stores.
- Keep repo-level maintainer guidance in the root `AGENTS.md` and runtime rule sources under `global/`.
- When a skill changes, update `README.md` and `REFERENCE.md` in the same commit.
- Run `scripts/validate-skills.sh` before installing or committing skill changes.
- After editing source skills or global rules, run `install.sh` or state that the installed runtime under `~/.config/opencode/` was not updated.
- Keep skill descriptions trigger-focused and specific enough for correct routing.
- Preserve skill behavior; do not silently redesign logic while doing platform migrations.
