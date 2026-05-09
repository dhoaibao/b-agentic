# b-skills — Skill reference

Detailed contract reference for the b-skills suite. For install and overview, see [README.md](README.md).

---

## Skill reference

### b-plan

Think before coding. Decompose tasks into ordered steps, evaluate competing approaches, surface risks, and produce an execution-ready plan file.

**Core behavior**
- **Step 0** picks **quick mode** vs **full mode** before any other work. Quick = scoped daily tasks (chat plan, approval, then `b-implement`). Full = unclear/high-risk/multi-layer (saved plan file, then `b-implement`).
- Auto-selects mode from task complexity, announces it in one sentence, and asks the user only when both modes are genuinely valid and preference matters.
- Escalates quick → full when discovery reveals broad references, unclear requirements, structural decisions, external API uncertainty, or deployment risk.
- Owns broad or unclear refactors until they're reduced to concrete rename/extract/move/inline steps that can be handed off to `b-refactor`.
- Hands approved implementation work to `b-implement` by default so planning and execution stay distinct.
- Uses `sequentialthinking` for approach selection and ordered execution steps when available; otherwise reasons inline with the same structure.
- For existing-code tasks, follows a strict supported-Serena read-order in Step 2: onboarding check → symbol discovery → overview → references → narrow native reads only when needed.
- Issue/ticket scrape (when present) lives in Step 2 as a context source for the scan.
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
- Quick mode: returns a concise 2–5 step chat plan with a verification step.
- Full mode: writes a plan file to `.opencode/b-plans/[task-slug].md`.
- Full-mode plans include: `## Decision` (approach + rejected alternatives), ordered checkbox steps, dependencies, risks, unknowns, and optional `## Feasibility` and `## Mapping outline`.
- Final plans must be self-contained enough that a fresh agent can execute them without clarifying questions.
- Saved plan files are always in English.

**Key rules**
- Do not implement until the user approves the plan; after approval, use `b-implement` unless the user explicitly asks to continue in the same session.
- Full mode must write to `.opencode/b-plans/`; quick mode may stay in chat unless the user asks for a saved plan.
- The feasibility gate only confirms blockers and scope; it does not replace `/b-research` for deep unknowns.
- All unresolved unknowns must be surfaced — never deferred silently.
- **Handoff standard: 90%+** — every step must be detailed enough that a fresh agent with zero prior context can implement it without asking a follow-up question.

---

### b-research

All external knowledge in one skill: auto-detects quick lookup vs full multi-source research.

**Core behavior**
- Starts with mode detection: quick lookup for single-fact questions, full mode for comparisons, cited reports, recency, or page-reading.
- For library/framework API questions: Context7 first.
- In quick mode: answers in 1–3 sentences with a minimal example, capped at 2 tool calls, never scrapes.
- Starts with quick mode when plausible, then escalates automatically when the answer needs more than 2 tool calls, more than 1 source, or any page scraping.
- In full mode: classifies query into VERSION / COMPARE / NEWS / HOWTO/API → Brave Search → Firecrawl scrape/extract → quality gate → synthesis report.
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
- Never fill factual gaps from training data in full mode when sources do not support them.

---

### b-implement

Approved-plan execution: read the source of truth, apply one step at a time, verify each step, and stop when new decisions appear.

**Core behavior**
- Resolves implementation source from `$ARGUMENTS`, `.opencode/b-plans/[slug].md`, or an approved chat plan.
- Extracts confirmed decisions, planned touch points, ordered steps, dependencies, and `Done when` checks before editing.
- Checks `git status --short` and preserves unrelated user changes.
- Uses Serena for symbol-aware code changes: onboarding check -> symbol/file discovery -> overview -> references -> minimal edit.
- Implements exactly one dependency-ready step at a time, then verifies with the plan's `Done when` command or the narrowest relevant check.
- Marks saved plan checkboxes complete only after verification passes.
- Stops for new product/behavior decisions instead of self-inferring.

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
- Implement only approved scope; unclear scope goes back to `b-plan`.
- Work one step at a time and verify before moving on.
- Do not refactor opportunistically while implementing a feature step.
- Do not overwrite unrelated user changes.
- Do not commit unless explicitly asked.

---

### b-debug

Systematic, hypothesis-driven debugging with full-loop execution by default.

**Core behavior**
- Uses supported Serena tools to map execution path, references, suspicious symbols, and file structure (Step 2).
- If Serena is unavailable, falls back to bash/read with reduced cross-file confidence.
- Initializes Serena project knowledge with onboarding check before tracing when needed.
- **Step 3a** forms ranked hypotheses with evidence/verification per item.
- **Step 3b** runs fast-path lookups (library-error shortcut + error-string codebase search) before verifying — these often eliminate wrong hypotheses.
- Library error shortcut: web search → Firecrawl scrape (top 1–2 URLs) → Context7 verification.
- Dynamic verification loop in Step 4 when static analysis is insufficient (max 3 instrumentation rounds).
- After confirming root cause, implements the minimal fix using symbol-aware tools and states exact verification steps.

**Default contract**: `trace → confirm root cause → fix → verify`
Diagnosis-only is allowed only when the caller explicitly requests it.

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

---

### b-review

Human-judgment pre-PR review: correctness, requirements, edge cases, tests, and minimum observability on new entry points.

**Core behavior**
- Reads git diff and builds requirements baseline from plan file, `$ARGUMENTS`, or user clarification.
- If no requirements baseline is available after bounded clarification, continues as a clearly labeled diff-only risk review and skips strict requirements coverage.
- Defines fast-path threshold (`≤50 lines AND ≤2 files`) once at the top of the skill — referenced by Steps 2, 3, and 6.
- Uses supported Serena tools to prioritize review depth by changed symbols, references, and affected files.
- Initializes Serena project knowledge with onboarding check before reviewing changed symbols when needed.
- Follows a strict read-order: find symbol → find referencing symbols → overview → narrow reads. Never jumps straight from diff to full file reads.
- Reviews changed files outline-first, then opens only high-risk symbols/source paths.
- Uses `sequentialthinking` only when blocker/suggestion classification is genuinely ambiguous.
- Always checks **injection vectors**, even on very small diffs.
- Runs observability check (Step 6) only for newly added endpoints/handlers/jobs/consumers.
- Skips test-adequacy + observability when `$ARGUMENTS` contains `skip test adequacy`.

**Step layout**
1. Get the diff
2. Establish requirements baseline or mark diff-only risk review mode (fast-path eases this)
3. Logic correctness (fast-path skips expanded security checklist; injection-vector check ALWAYS runs)
4. Requirements coverage check
5. Edge case + test adequacy check
6. Observability check (skipped if fast-path or no new entry points)
7. Consolidate findings

**Good triggers**
```text
/b-review
review before PR
kiểm tra logic trước khi push
/b-review skip test adequacy
```

**Output**
```
Logic findings → Requirements coverage table or diff-only limitation → Edge cases / test adequacy → Observability
→ Reviewer question → READY FOR PR or NEEDS FIXES
```

**Handoff**
- `READY FOR PR` → implement any non-blocking suggestions, then commit.
- `NEEDS FIXES` → fix blockers, re-run tests, then `/b-review` again.

---

### b-test

Test-driven development, test debugging, and test coverage evaluation.

**Core behavior**
- Discovers test files and framework via bash, then inspects structure with Serena symbol tools.
- Step 2 picks a branch:
  - **Branch A — Failing test**: read test + source, identify assertion/mock/setup/async issue, apply minimal fix.
  - **Branch B — Write tests**: map source symbol, list edge cases, add tests via Serena symbol tools or `write` for new files.
  - **Branch C — Evaluate coverage**: run coverage report, rank gaps, optionally write top 1–3 missing tests.
- Runs tests via bash after every change to confirm fix or coverage improvement.
- Distinguishes test-specific failures from runtime bugs. Unconfirmed production behavior failures hand off to `b-debug` instead of patching production code from test output alone.
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
- Write behavior tests (assert on output), not implementation tests (assert on internal state).
- Keep test fixes minimal — one assertion at a time.
- Browser/UI testing and user-flow verification go to `b-e2e` — `b-test` owns code-level unit and integration tests only.

---

### b-e2e

Browser-based frontend testing and E2E script authoring.

**Core behavior**
- Uses Playwright MCP to navigate to the target web application.
- Before navigating to `localhost`, verifies the dev server is reachable via a bash health check; asks the user to start it if not responding.
- Creates a session-specific directory under `.opencode/b-e2e/[run]/` to store intermediate artifacts (screenshots and snapshots).
- Relies on accessibility tree snapshots (`browser_snapshot`) to map the UI and get precise target references.
- Performs sequential user interactions (clicks, typing, form fills).
- Verifies UI state changes via updated snapshots; optionally monitors network requests with `browser_network_requests` for API-level assertions.
- Translates successful manual interactions into Playwright test code via Serena symbol tools when an existing spec exists, or `write` when no spec file exists.
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
- Never guess element selectors; always read the `browser_snapshot` first.
- For `localhost` targets, run a bash health check before calling `browser_navigate`.
- All testing artifacts must go into a session-specific `.opencode/b-e2e/[run]/` directory.
- Always close the browser at cleanup; do not delete artifacts by default.
- Distinct from `b-test`, which handles code-level unit testing without a live browser.

---

### b-refactor

Code refactoring with impact analysis and safe mechanical transformation.

**Core behavior**
- Maps full impact radius with `find_referencing_symbols` before touching any code.
- Requires a green baseline check for medium/high-risk refactors; low-risk single-file mechanical edits may skip baseline with an explicit note.
- Uses Serena's symbol-aware tools (`rename_symbol`, `safe_delete_symbol`, `replace_symbol_body`) for cross-file safe edits.
- Assumes the target transformation is already concrete; broad or unclear refactors should go through `b-plan` first.
- Executes in dependency order (inner helpers first, outer callers last).
- Verifies after every step: compilation → tests → git diff.
- For large refactors (>3 files or crossing package boundaries): uses `sequentialthinking` to plan phases.
- Hands off post-refactor failures: real regression → `/b-debug`; test-mechanic drift → `/b-test`.

**Transformations supported**
- Rename symbol/file/directory
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
- Prefer `rename_symbol` over manual edit for renames — it updates all references atomically.
- Prefer `safe_delete_symbol` over manual deletion — it prevents accidental removal of still-used code.
- Run compilation check after every mechanical step.
- One commit per logical transformation.

---

## Usage patterns

### Standard feature flow
```
1. /b-plan [task]
2. Approve the quick chat plan or full saved plan
3. /b-implement [approved plan path or slug]
4. Run the targeted checks from each step's "Done when"
5. /b-review [task]
6. commit
```

### Approved-plan implementation
```
/b-implement [.opencode/b-plans/task.md or task-slug]
```

### Debug flow
```
/b-debug [symptom + expected behavior]
```

### Before touching unfamiliar code
```
/b-plan [task]    (b-plan scans existing code as part of planning)
```

### Library choice / comparison
```
/b-research compare [A] vs [B] for [use case]
```

### Known library, API uncertain
```
/b-research [library] — [feature]
```

---

## Trigger tips

- Invoke skills with `/` prefix: `/b-plan`, `/b-implement`, `/b-debug`, `/b-review`, `/b-research`, `/b-test`, `/b-e2e`, `/b-refactor`.
- Use explicit intent words: `plan`, `implement`, `execute plan`, `debug`, `review`, `research`, `lookup`, `test`, `refactor`, `E2E`, `UI test`.
- Mention complexity when relevant: multi-file, unfamiliar module, unclear root cause.

---

## Skill interaction map

```
/b-plan ──────────────── writes ─────────────────► plan file in .opencode/b-plans/
        └── unknown library/approach ────────────► /b-research (before or during planning)
        └── approved plan ───────────────────────► /b-implement
        └── reduced to mechanical steps ─────────► /b-refactor

/b-implement ─────────── step verified ──────────► next step
             └────────── new decision needed ────► /b-plan
             └────────── runtime failure ────────► /b-debug
             └────────── test mechanics failure ─► /b-test

/b-review ────────────── READY FOR PR ───────────► commit
          └──────────── NEEDS FIXES ─────────────► fix → /b-review again

/b-debug ─────────────── bug found during impl ──► fix inline or return to /b-implement
         └──────────── fix introduces new code ──► /b-review (optional)

/b-test ──────────────── test fails ────────────► /b-debug (if failure reveals runtime bug)
        └──────────── coverage gap ─────────────► write tests → run suite

/b-e2e ───────────────── UI flow verified ──────► author Playwright spec → cleanup
       └──────────── backend failure surfaces ──► /b-debug

/b-refactor ─────────── rename/move/extract ────► /b-review (after transformation)
            └────── test failure ───────────────► /b-test (mechanic) or /b-debug (regression)

/b-research ──────────── quick lookup or full research, auto-routes internally
```

---

## Repository layout and maintenance

This repository is the install-only source layout for the suite. OpenCode does not load the checked-in `skills/` or `commands/` directories directly from this repo root; use `install.sh` to deploy them into `~/.config/opencode/`.

### Repository source files
- `AGENTS.md` — maintainer-only guidance for working on this source repo locally.
- `global/AGENTS.md` — source for shared runtime instructions installed into OpenCode.
- `opencode.json` — local repo config; loads `./AGENTS.md` for maintainers.
- `skills/<name>/SKILL.md` — reusable OpenCode skills distributed by the installer.
- `commands/<name>.md` — explicit slash-command wrappers distributed by the installer.

### Runtime artifacts
- `~/.config/opencode/skills/` — installed skill destination created by `install.sh`.
- `~/.config/opencode/commands/` — installed command destination created by `install.sh`.
- `~/.config/opencode/instructions/b-skills.md` — installed runtime instructions file created by `install.sh`.
- `.opencode/b-plans/` — saved plan files created by `/b-plan`.
- `.opencode/b-e2e/[run]/` — browser snapshots and screenshots created by `/b-e2e`.

### Maintenance rules
- Keep one folder per skill under `skills/`.
- Keep command wrappers thin; they are entrypoints, not duplicate logic stores.
- Keep repo-level maintainer guidance in the root `AGENTS.md` and shared runtime rule sources under `global/`.
- When a skill changes, update `README.md` and `REFERENCE.md` in the same commit.
- Keep skill descriptions trigger-focused and specific enough for correct routing.
- Preserve skill behavior; do not silently redesign logic while doing platform migrations.
