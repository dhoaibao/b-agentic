# b-skills — Skill reference

Detailed contract reference for the maintained nine-skill suite. For install and high-level overview, see [README.md](README.md).

When this document cites `global/AGENTS.md`, that is the source-repo path. Installed skill prose should reference the runtime path `AGENTS.md`.

---

## Skill reference

### b-spec

Clarify what to build before planning. `b-spec` exists for rough, underspecified asks where the main job is to lock the target outcome, constraints, and acceptance criteria before any sequencing work starts.

**Core behavior**
- Stays active only while the end state is underdetermined.
- Uses the smallest clarification loop needed to lock goal, constraints, success criteria, non-goals, and explicit assumptions.
- Prefers one blocking question at a time when each answer changes the next question, and uses a concrete scenario or counterexample when that collapses ambiguity faster.
- Enforces a **hard 2-round exit**: after two clarification rounds without a confirmed user-visible outcome, proposes 2 concrete interpretations with named assumptions and asks the user to pick one instead of looping. A "round" is one user response after a clarification ask, regardless of how many sub-questions that ask contained.
- Checks local code context before asking the user to answer something the repo already answers.
- Reuses canonical terminology from optional `CONTEXT.md` / `CONTEXT-MAP.md` files when the repo already has them, and surfaces glossary/code contradictions instead of silently picking one.
- Hands off to `b-research` when the remaining blocker is real external feasibility or vendor/library behavior.
- Keeps the output in chat by default instead of creating a second durable artifact.
- Hands off to `b-implement` when the clarified request is now a small direct request, or to `b-plan` when the goal is clear but the work still needs sequencing.
- Carries the spec's `Assumptions` into the handoff envelope's `assumptions` field so the downstream skill sees what was taken for granted.

**Output**
- Compact chat spec: goal, constraints, acceptance criteria, non-goals, **assumptions** (always present, `none` if empty), next skill.

**Key rules**
- Clarify the target outcome; do not drift into implementation planning.
- Prefer repository evidence over extra user questions whenever the codebase already answers the ambiguity.
- Prefer glossary terms over ad-hoc wording when the repo already carries domain docs.
- Keep the clarification loop short; do not turn every rough ask into a long interview.

**Shared reference**
- `references/domain-glossary.md` — optional convention for `CONTEXT.md`, `CONTEXT-MAP.md`, and ADR usage when a repo wants a persistent project glossary.

---

### b-plan

Think before coding. `b-plan` exists for broad or risky work where the goal is already clear and the main job is to decide scope, approach, ordering, and success criteria before editing code.

**Core behavior**
- Chooses **quick mode** for trivial scoped work and **full mode** for non-trivial work.
- Writes new full-mode saved plans with durable frontmatter for `slug`, `status`, approval timestamps, approved git HEAD, risk, and touch points.
- Uses the smallest blocking questions only; does not turn every plan into an interview.
- Produces dependency-ordered steps as short as the work actually is, with exact files or symbols when known.
- Applies a **risk-tiered plan-size guardrail**: ~8 steps / ~6 touch points for trivial/low, ~12 / ~10 for medium, no fixed cap for high risk when every step is independently verifiable. When the cap is exceeded without a structural reason, collapse adjacent steps or split into dependent slices. High-risk migrations that cannot be safely split are marked as a tightly coupled group.
- For prose/config-heavy work, names stable anchors instead of long quoted paragraphs that can drift before implementation.
- Carries incoming `assumptions` from a `b-spec` handoff: copies them into `Confirmed decisions` only after explicit user confirmation, otherwise keeps them in a plan-level `Assumptions` section so they remain visible without being treated as approved decisions.
- Hands target-outcome ambiguity back to `b-spec` before trying to sequence the work.
- Keeps broad or unclear refactors in planning until they reduce to concrete mechanical transforms for `b-refactor`.
- Routes unresolved external feasibility, contract, migration, or security unknowns to `b-research` instead of guessing.
- Treats the approved plan as the execution source of truth for later `b-implement` work.

**Output**
- Quick mode: short chat plan.
- Full mode: English plan file at `.opencode/b-skills/b-plan/<task-slug>.md` after applying the `.opencode/.gitignore` guard in `global/AGENTS.md` §6, where `<task-slug>` follows the slug algorithm in `global/AGENTS.md` §8. Saved plans remain canonical repo-local source-of-truth files. Skeleton: durable frontmatter, `# title`, `Confirmed decisions`, `Assumptions` (when carrying unconfirmed inputs from `b-spec` or planning), `Planned touch points`, `Dependencies`, `Risks`, `Unknowns`, checkbox-style `Steps`, `Verification`, `Rollback` (only when real), and `Revisions` (added when revised).

**Key rules**
- Do not implement while planning.
- Keep quick mode lean.
- Save only full-mode plans unless the user explicitly asks for a saved quick plan.
- Include durable plan frontmatter for new saved plans; update approval metadata in place when approval happens during planning.
- Surface blockers and assumptions explicitly.
- Quick/full threshold is the **non-trivial** definition in `global/AGENTS.md` §3.
- Approved plans are subject to the **plan staleness gate** in `global/AGENTS.md` §2.
- Revisions go in place under `## Revisions`; never write `plan-v2.md` (`global/AGENTS.md` §2).

**GitNexus use**
- Optional only for graph-shaped planning: unfamiliar architecture, broad impact, route/API consumers, or process-flow mapping.

---

### b-research

External knowledge with auto-deepening depth — lookup or research.

**Core behavior**
- Uses **lookup** for one fact, one signature, one config key, or a yes/no.
- Uses **research** for anything requiring more than one source, comparison, multi-step synthesis, or recency-sensitive answer.
- Auto-deepens from lookup to research when first results are stale, contradictory, non-authoritative, or off-target. Never asks the user to choose a mode.
- Treats a user-provided URL, file, or document as **direct-source lookup** when one bounded source is likely sufficient; extraction is allowed in that lookup lane.
- Pins library version from manifests **and** lockfiles; resolves at the closest workspace in monorepos.
- Uses Context7 first for library and framework APIs; search discovers candidate sources, while final claims require Context7, direct extraction, or another primary source unless explicitly labeled snippet-only and low confidence.
- Honors the **citation-provenance rule** (`global/AGENTS.md` §5): every cited URL must come from a result actually fetched in this session — never recalled from memory.
- Refuses to take research questions that the codebase itself can answer; routes them back to the active skill.
- Uses `firecrawl-extraction` for local docs and known URLs; `firecrawl-extended` only for site maps or structured fields; `firecrawl-deep` only with explicit user approval per invocation, or under a run-scoped capped pre-authorization (`global/AGENTS.md` §4 cost warning).
- Reuses fetched results from earlier in the session instead of re-fetching.

**Output**
- Lookup: direct answer, source, and a minimal example only when it helps. Confidence line only when not high.
- Research: answer, key findings, limitations, cited sources, confidence.

**Key rules**
- Never ask the user to choose a mode; the skill decides and auto-deepens.
- Search snippets are discovery only. Do not use them as final evidence unless the answer is explicitly labeled snippet-only with `Confidence: low`.
- Do not scrape broad result sets in open-ended lookup; direct-source lookup from a provided source may extract that one source immediately.
- Pin the library version (manifests + lockfiles) before any `context7-docs` query.
- Prefer 2–4 authoritative sources over a long weak list.
- Resolve cross-source conflicts by preferring the publisher's docs at the pinned version; label the conflict and lower confidence when ambiguity remains.
- Public-web privacy gate (`global/AGENTS.md` §6) applies to every external call.
- Use `Limitations` instead of speculation.

---

### b-implement

`b-implement` executes approved or clearly scoped work one step at a time.

**Core behavior**
- Resolves its source of truth from an approved plan file, plan slug (per the slug algorithm in `global/AGENTS.md` §8), approved chat plan, or a request meeting the **small direct request** threshold (`global/AGENTS.md` §3).
- Reads saved-plan frontmatter when present and requires an executable durable approval state (`approved` or `in-progress`) or explicit current-chat approval before editing; chat approval updates `approved_head` when a git HEAD is available.
- Routes ambiguous end-state questions back to `b-spec`, and broad-but-clear work back to `b-plan`.
- Preserves unrelated worktree changes and edits only files needed for the current step.
- For non-trivial work, prefers an isolated workspace/worktree when dirty state, risky scope, or parallel work would otherwise blur verification or review; reuses existing isolation before asking to create more.
- Uses `serena-symbol-toolkit` for symbol-aware edits and narrow diagnostics before broader checks.
- Uses `gitnexus-radar` only when a shared route, tool, or exported boundary makes graph context genuinely useful.
- Applies the **plan staleness gate** (`global/AGENTS.md` §2) before executing a saved plan.
- Triggers the **plan revision protocol** (`global/AGENTS.md` §2) when the plan is wrong mid-execution.
- Verifies each step before moving on, capped by the iteration cap in `global/AGENTS.md` §7. Treats each step as **atomic** — independently verifiable — unless the plan explicitly marks a **tightly coupled group** (e.g., "Steps 3a–3c verify together") where intermediate verification would fail by design; never silently merges atomic steps to dodge a failing check.
- Defers to the shared **transform rollback** rule in `global/AGENTS.md` §7 when a partial edit has left the tree mid-transform: finish forward to a coherent baseline, or patch-based reverse the in-flight edits; never exit the skill with the tree mid-transform.
- Defers to the shared **cascading-failures** rule in `global/AGENTS.md` §7: one attempted cascade fix, then stop and either trigger plan revision, hand off to `b-debug`, or surface the cascade. Cascades are not absorbed by the iteration cap.
- Follows global `apply_patch` discipline: fresh target slice, small hunks, stale-context retry after missing expected lines.
- Applies the **high-risk challenge gate** from `global/AGENTS.md` §10 on auth/authz, security-boundary, migration, public/external-contract, and irreversible-write work before calling a step done.
- Cites framework/library/vendor sources in the final report when docs materially drove the chosen implementation pattern.
- Updates saved-plan task-list progress in place when the plan uses checkbox-style steps.
- Updates frontmatter progress (`approved` → `in-progress` → `complete`) without stripping metadata.
- Uses milestone-sized review checkpoints: after a coherent high-risk slice, hands off to `b-review` before piling on more changes unless the plan explicitly marks the next steps as tightly coupled, and names the completed plan step or milestone in that handoff so review has a stable baseline.
- Ends non-trivial runs with explicit closure: final verification status, remaining cleanup/process/worktree state, and the natural next branch/worktree action.
- Continues through approved plan steps when the user asks to implement or finish the plan; stops after one verified step when the user asks for only the next step.

**Output**
```text
Plan source -> Step progress -> Changes -> Verification -> Blockers / Decisions -> Next
```

Closes with the **skill-exit status block** from `global/AGENTS.md` §9.

**Key rules**
- Implement only approved or clearly scoped work; "small direct request" is the threshold in `global/AGENTS.md` §3 (≤3 files, no contract change, no sensitive path, no remaining design decision).
- Preserve durable plan frontmatter when updating saved-plan progress.
- Do not refactor opportunistically while implementing a feature step.
- Stop for new product decisions instead of inferring them.
- If docs materially drove the implementation choice, cite them instead of relying on memory.

**GitNexus use**
- Optional radar only for shared/exported boundaries or changed-scope validation.

---

### b-debug

`b-debug` owns runtime and behavior failures. It traces, confirms, fixes, and verifies.

**Core behavior**
- Starts from the concrete symptom or error.
- For active production impact or data-loss/security risk, identifies the safest containment option first and asks for approval before shared-environment action.
- Uses an obvious-stack-trace fast path when one file or function is strongly implicated.
- Maps the path with `serena-symbol-toolkit`, picking the cheapest discovery tool for the next question.
- Biases toward common first suspects: swallowed errors, auth gates, config drift, async ordering, shared-state leaks, off-by-one in new code, and (for perf) N+1 queries, unbounded retries, hot-loop allocations.
- Uses cheap local checks before broader experimentation: exact error search, diagnostics, `context7-docs` for API misuse, and optional public-web lookups under the privacy gate (`global/AGENTS.md` §6).
- Handles non-deterministic bugs explicitly: enumerates non-determinism sources before broader experimentation.
- Handles perf bugs explicitly: measures before and after with profilers, benchmarks, or runtime tracing — never infers speed from code shape.
- Handles **cannot-reproduce** reports via the shared **agent-cannot-reproduce protocol** in `global/AGENTS.md` §10: captures the environment diff, asks for specific signals (exact command/interaction, logs/stack trace at failure, env/version/flag details, minimal repro snippet), and offers three options (instrument and wait, treat as one-shot, investigate the captured diff) rather than speculate-patching.
- Confirms root cause before editing.
- **Tags every temporary probe** with a greppable marker (`b-debug-probe` in the language-appropriate comment form: `// b-debug-probe`, `# b-debug-probe`, `<!-- b-debug-probe -->`) so probes are recoverable at cleanup.
- Applies the smallest fix under global `apply_patch` discipline when manual edits are needed, verifies with the narrowest relevant runtime check, then re-scans the diff: first greps for the `b-debug-probe` tag and removes every match, then scans for untagged probes (`console.log`, `print`, breakpoints, fake clocks, profiler hooks) before reporting success.
- Hands off to `b-plan` when the confirmed root cause requires a structural redesign (new abstraction, contract change, cross-module ordering rework) rather than a localized fix; does not silently expand a debug pass into a redesign.
- Defers the "test failure vs runtime bug" decision to `global/AGENTS.md` §10.
- Points to `references/performance-checklist.md` (installed under `~/.config/opencode/references/b-skills/`) when a slowdown spans multiple layers or the repo lacks a clear measurement playbook.

**Output**
```text
Symptoms -> Code path -> Hypotheses -> Root cause -> Fix -> Verification
```

**Key rules**
- Do not patch before the root cause is confirmed.
- For active production impact, containment may precede deep investigation, but shared-environment mutations still require approval.
- Explicitly verify probe removal before reporting success.
- For perf bugs, report measured before/after, not adjectives.
- For cannot-reproduce reports, surface the gap rather than speculate-fix.
- Privacy gate (`global/AGENTS.md` §6) protects private errors and internal data before any public web tool call.

**GitNexus use**
- Optional only when the failing path is unfamiliar, broad, or process-flow-heavy.

---

### b-review

`b-review` is the suite's changed-code review skill and also handles explicitly requested repository audits.

**Core behavior**
- Defaults to `git diff HEAD`; supports `--range=<ref>..<ref>` for a specific commit range and uses `git log` on the range.
- Supports `--repo-audit` for maintainer-style review of an explicitly requested repository area or suite slice; in that mode it names the audited surface and avoids implying full-repository coverage unless the full repository was actually inspected.
- Supports milestone/checkpoint review mid-run when implementation reaches a coherent risky slice that should be inspected before more changes land.
- Picks **self-review** or **external review** mode per the boundary in `global/AGENTS.md` §10. Defaults to self-review when the working tree is dirty and unspecified.
- Fast path is **risk-bucket-gated**, not line-count-gated: allowed only when changes are confined to a single non-sensitive module, no auth/billing/secrets/crypto/migration files are touched, no public contract changes, and no new external dependency. Auth/security/migration/contract touches always force standard review.
- `--repo-audit` always uses the standard path.
- Builds a requirements baseline from `$ARGUMENTS`, `--baseline=<path|url>`, an approved plan, a checkpoint handoff naming the completed milestone, or a short clarification.
- Falls back to clearly labeled **diff-only risk review** or **repo-audit risk review** when no baseline exists after bounded clarification.
- Reviews highest-risk symbols and boundaries first.
- Uses a short surface-specific checklist for `--repo-audit` targets such as installers, runtime contracts, validators, route/tool boundaries, dependency changes, lockfiles, or generated artifacts.
- Runs the **security checklist** (correctness, input validation, injection, auth/authz, sensitive-data exposure, concurrency, dependency hygiene, secret handling, regex DoS, rate limits, error handling) on every changed entry point and shared boundary, even on the fast path.
- Treats lockfile, generated, snapshot, golden, vendored, and minified changes as derived artifacts unless the source or approved generation step is clear.
- Rejects checkpoint reviews of half-finished mid-transform trees; if the slice is not yet coherent enough to review honestly, sends it back to execution instead of forcing a verdict.
- Skips test adequacy and observability only when `--skip-tests` is present.
- Reports findings first, ordered by the **severity rubric** in `global/AGENTS.md` §3 (BLOCKER / MAJOR / MINOR / NIT), and includes "Checked and clean" so the author sees what scope was actually inspected.
- Applies the **output verbosity cap** (`global/AGENTS.md` §9): every BLOCKER is reported (never elided); MAJOR / MINOR / NIT cap at 15 per severity with the remainder surfaced as a one-line follow-up.
- Emits one of three verdicts: **READY FOR PR** (no BLOCKER, no MAJOR), **READY WITH FOLLOW-UPS** (no BLOCKER; MAJORs deferred as explicit follow-up work), or **NEEDS FIXES** (any BLOCKER, or MAJORs that should not ship).

**Output**
```text
Findings -> Coverage / Tests / Observability -> READY FOR PR | READY WITH FOLLOW-UPS | NEEDS FIXES
```

**Key rules**
- Do not claim requirements coverage when no baseline exists.
- Do not run broad verification by default; use only the evidence needed.
- Security-checklist items are never skipped for changed entry points, sensitive paths, or shared boundaries.
- The fast path is gated by risk bucket, not by line/file count.
- In `--repo-audit` mode, say exactly what area was inspected and avoid implying whole-repo coverage unless the review was actually exhaustive.
- In `--repo-audit` mode, report which target-specific checklist was applied.
- Flag unexplained generated/lockfile artifact changes instead of reviewing them as hand-written code.
- For self-review, bias for author blind spots; for external review, be explicit about blocker-vs-style.
- If no findings, say so explicitly and note residual risk or skipped checks; attach the confidence signal from `global/AGENTS.md` §3 when evidence is partial.
- Apply the **high-risk challenge gate** from `global/AGENTS.md` §10 when the diff touches auth/authz, security boundaries, migrations, public/external contracts, or irreversible external writes.
- Cite authoritative framework/library/vendor sources when a finding or a clean judgment depends on API semantics.
- Reuse `references/security-checklist.md` and `references/performance-checklist.md` (installed under `~/.config/opencode/references/b-skills/`) instead of copying long checklists into the skill body.

**GitNexus use**
- Optional only for broad route/API/tool/shared-flow risk.

---

### b-test

`b-test` owns code-level testing: writing tests, fixing test-only failures, and ranking coverage gaps.

**Core behavior**
- Discovers the project's test framework and narrowest runnable commands from manifests or CI.
- Routes red tests through the **test-vs-bug decision** in `global/AGENTS.md` §10.
- Separates work into four lanes: failing test, write tests, coverage review, or flaky test (with the flake handling procedure in `global/AGENTS.md` §10).
- Owns DOM-rendered unit tests and **hybrid component tests** (components mounting real router/store/query-client/provider chains under jsdom/happy-dom/node) per the **DOM-unit vs browser-flow boundary** in `global/AGENTS.md` §10. Promotes to `b-e2e` only when a real browser engine drives the flow or when the test requires real network, real cookies, or visual assertions.
- Uses `serena-symbol-toolkit` to map tests to source ownership when helpers, imports, or interfaces hide the real target.
- Captures large failure output under `/tmp/opencode/b-skills/b-test/` instead of depending on truncated terminal output.
- Treats snapshots, golden files, fixtures, mocks, and async timing as explicit test concerns; updates snapshots only after the **snapshot confirmation procedure** in `global/AGENTS.md` §10.
- Ranks coverage gaps using the rubric in the skill (required → strong → useful → opportunistic) and applies a **bounded stop heuristic**: stops when all priority-1 gaps (changed behavior) are closed, or when the next gap is priority-3 or lower without explicit user request, or when 5 gaps have been added in one run with no priority-1 remaining. Never loops through priority-4 gaps autonomously.
- Owns **test utilities** (factories, builders, custom matchers, shared fixtures) when they are added, edited, or extended to support an in-scope test. Mechanical relocation/rename of an existing test utility belongs to `b-refactor`.
- Hands real-browser flows to `b-e2e`; hands product-behavior uncertainty or confirmed product fixes out of the test lane to `b-debug` or `b-implement` with the failing evidence.
- Keeps property-based, fuzz, and contract tests in `b-test` only when the repo already has an established runner and pattern; new strategies or frameworks route to `b-plan` first.
- Uses global `apply_patch` discipline for new test files and small non-symbol edits.

**Output**
```text
Type -> Framework -> Findings -> Changes -> Verification -> Remaining gaps
```

**Key rules**
- Never change production code just because a test is red.
- Never update assertions or snapshots without confirming intended behavior.
- Keep fixture and mock changes as local as practical.
- Never introduce a test, coverage, property-based, fuzzing, or contract-testing framework without explicit approval.
- Explain when broader suites were skipped and why the narrow checks were enough.
- Reuse `references/testing-patterns.md` (installed under `~/.config/opencode/references/b-skills/`) when local test conventions are weak or conflicting.

---

### b-e2e

`b-e2e` uses a real browser to verify user-facing flows and optionally convert them into repo-native browser tests. Two modes: **verify** and **author**.

**Core behavior**
- Uses the `playwright-browser` bundle (`global/AGENTS.md` §4): Playwright MCP when available, local Playwright CLI via `bash` as a documented fallback.
- Creates a session-specific artifact directory under `.opencode/b-skills/b-e2e/<run-id>/` using the run-id format from `global/AGENTS.md` §8.
- Uses repo-local `.opencode/...` artifact paths for non-sensitive artifacts after applying the `.opencode/.gitignore` guard from `global/AGENTS.md` §6; sensitive artifacts and auth/session state still default to `~/.config/opencode/b-skills/...` or `/tmp/opencode/b-skills/...`.
- Verifies localhost targets are reachable before navigating; never starts a dev server without approval.
- Applies a **production-target guard**: production or production-like targets (production hostname, customer-facing domain, real auth realm) are read-only by default; mutating steps require per-step approval naming the environment. Ambiguous targets (staging, preview, ephemeral env, internal hostname) trigger one clarifying question before any mutating step.
- Clarifies only blocking state: auth/session, test data, whether writes are allowed.
- Reuses approved stored auth state (`storageState.json`) when available, but saves reusable post-login auth state only with explicit user opt-in and in a non-worktree path by default.
- Detects **expired stored auth** (post-load snapshot lands on a login page, session-expired banner, or 401/403) and never silently re-authenticates: asks the user to choose between refreshing the stored state, re-auth ephemerally for this run only, or aborting.
- Uses accessibility snapshots before interaction.
- Runs a **focused accessibility check** in verify mode on the changed/interacted surface: inspects the accessibility snapshot for missing roles/labels on interacted elements, confirms focus order through the flow, and reports blocker-level a11y issues (unlabeled controls, focus traps, role/label mismatch) as findings. Full WCAG audits remain out of scope unless requested.
- Verifies state with snapshots, screenshots, console/network evidence. Multi-viewport remains opt-in except responsive UI work or UI intended for both mobile and desktop, where one representative mobile and desktop viewport are checked by default.
- Defaults to functional snapshots over visual regression; visual regression baselines require approval.
- Applies the **flake handling** procedure in `global/AGENTS.md` §10 before reporting flake.
- When writing tests, inspects the repo's existing browser-test framework first and preserves it instead of forcing Playwright everywhere.

**Output**
```text
Mode -> Target -> Driver -> Interactions -> Assertions -> Test code -> Artifacts
```

**Key rules**
- Do not start a dev server without approval.
- Do not mutate production-like data without explicit confirmation.
- Do not introduce Playwright test files into a repo that uses another framework unless approved.
- Multi-viewport checks are opt-in except for responsive UI work or UI intended for both mobile and desktop.
- Namespace test data created by browser flows whenever writes are approved, and report what was kept or cleaned up.
- Visual regression baselines require approval; default to functional snapshots.
- `*_unsafe` browser tool variants require explicit user approval per invocation (`global/AGENTS.md` §4).
- Persist reusable auth state only with explicit user opt-in, store it outside the worktree by default, and never commit auth-state files containing real credentials.
- Always close the browser when done.
- Reuse `references/accessibility-checklist.md` (installed under `~/.config/opencode/references/b-skills/`) as the fallback checklist for focused keyboard/label/focus-order verification.

---

### b-refactor

`b-refactor` handles concrete behavior-preserving transforms.

**Core behavior**
- Locks the exact target before editing.
- Runs `find_referencing_symbols` as the primary graph-backed static impact-mapping step, while treating dynamic, config-driven, generated, and prose references as outside that proof unless separately searched.
- Classifies the refactor on the **risk rubric** in `global/AGENTS.md` §3 (trivial / low / medium / high).
- Supports a **trivial local fast path** only when one file, no contract change, few references, behavior preserved, the language is LSP-supported by Serena, **and** no generated-code consumers depend on the target. Non-LSP languages auto-promote to at least **low** risk by design.
- Applies a **generated-code carve-out**: when the target is consumed by generated code (GraphQL clients, Prisma/ORM types, OpenAPI clients, protobuf stubs, `*.generated.*` files, committed codegen output), the refactor auto-promotes to at least **medium** risk regardless of local file count, the reference map must include generated consumers, and verification must regenerate them or confirm the generator source already reflects the change.
- Treats vague "simplify" requests as planning work until the exact behavior-preserving transform is locked.
- Uses `gitnexus-radar` only when exported, shared, route/tool, or broader package boundaries make graph context useful.
- Uses the `serena-symbol-toolkit` rename/delete/body-replacement tools whenever they fit the transformation.
- Uses `apply_patch` only for import updates, config, prose, or non-symbol glue, under the global patch discipline.
- For **rename + extract**, does extract first under the old name, then `rename_symbol`, so each transform is independently verifiable.
- Treats **move between files** as the highest-mechanical-risk refactor: add destination first, update every import and test path, update build config and barrel files, only then `safe_delete_symbol` the origin, then re-confirm references.
- Verifies with diagnostics plus the narrowest risk-appropriate check (verification ladder in `global/AGENTS.md` §7).
- Defers to the shared **transform rollback** rule in `global/AGENTS.md` §7 when verification fails partway through a multi-file transform: the Step 2 reference map is the worklist when finishing forward; otherwise patch-based reverse the in-flight edits, never exiting mid-transform.
- Hands behavioral redesign back to `b-plan` via the handoff envelope in `global/AGENTS.md` §9, including the locked target and the reference map.
- **Splits across runs** when the reference map shows the refactor is too large to verify in one coherent pass: stops, hands back to `b-plan` with the reference map and a proposed slice list, where each slice ends with the tree in a coherent verifiable state and slices that depend on a prior merge go into the new plan's `Dependencies`.

**Output**
```text
Target -> Risk -> Impact -> Changes -> Verification -> Follow-up
```

**Key rules**
- Keep the work behavior-preserving.
- Use the trivial-local fast path only when the contract is clearly untouched and the language is LSP-supported.
- For non-LSP languages, treat every rename or safe-delete as at least **low** risk.
- For non-LSP languages, generated glue, dynamic dispatch, config-driven references, or text/prose references outside Serena's graph, add targeted text search to verification.
- For rename + extract, do extract first, then rename.
- Ask before broad directory moves or similar cascading changes.

**GitNexus use**
- Optional only for broader blast-radius questions.

---

## Repository layout and maintenance

This repository is the install-only source layout for the suite. OpenCode does not load the checked-in `skills/`, `commands/`, or `references/` directories directly from this repo root.

### Repository source files
- `AGENTS.md` — maintainer guidance for this source repo.
- `global/AGENTS.md` — source copy of the runtime global rules, installed as `AGENTS.b-skills.md` and optionally applied to OpenCode's main `AGENTS.md`; installed skill prose should cite `AGENTS.md`.
- `skills/<name>/SKILL.md` — skill sources.
- `commands/<name>.md` — thin slash-command wrappers.
- `references/*.md` — reusable checklists and conventions shared by multiple skills, installed under `~/.config/opencode/references/b-skills/`.
- `scripts/smoke-install.sh` — isolated installer smoke checks against a temp HOME and repo snapshot.
- `scripts/validate-skills.sh` — suite validator for frontmatter, required sections, stale phrases, docs coverage, and global-rule guardrails.

### Runtime artifacts
- `.opencode/b-skills/b-plan/<task-slug>.md` — saved plans from `b-plan` after applying the `.opencode/.gitignore` guard from `global/AGENTS.md` §6 (legacy `.opencode/b-plans/` is deprecated). These remain canonical repo-local source-of-truth files. `<task-slug>` derives from `global/AGENTS.md` §8.
- `.opencode/b-skills/<skill>/<run-id>/` — repo-local non-sensitive run artifacts after applying the `.opencode/.gitignore` guard from `global/AGENTS.md` §6, with `run-id = <YYYYMMDD-HHMMSS>-<slug>`.
- `.opencode/b-skills/<skill>/<run-id>/report.md` — saved review/research reports after applying the `.opencode/.gitignore` guard from `global/AGENTS.md` §6.
- `~/.config/opencode/b-skills/<skill>/<run-id>/` or `/tmp/opencode/b-skills/<skill>/<run-id>/` — non-worktree artifacts for sensitive browser/session state.
- `/tmp/opencode/b-skills/<skill>/<slug>.log` — large command output and temporary logs.
- Multi-artifact runs include a `manifest.json` per the schema in `global/AGENTS.md` §8.

### Runtime global conventions
- One active skill at a time.
- Trigger precedence is explicit: browser flow → `b-e2e`; DOM-rendered unit test → `b-test`; likely product bug → `b-debug` (per the test-vs-bug decision in `global/AGENTS.md` §10); named behavior-preserving transform → `b-refactor`; unclear end state or acceptance → `b-spec`; clear goal but unclear sequencing → `b-plan`; external-knowledge blocker → `b-research`.
- After `b-plan` approval, the approved plan is the execution source of truth for multi-step implementation, subject to the **plan staleness gate** and **plan revision protocol** in `global/AGENTS.md` §2.
- New saved plans carry durable frontmatter for approval state, approved git HEAD, risk, and touch points; legacy plans remain valid with explicit current-chat approval.
- Cross-skill handoffs use the **handoff envelope** in `global/AGENTS.md` §9 (`source`, `run-id`, `goal`, `decisions`, `assumptions`, `files`, `verification`, `blockers`, `carve-outs`, `next-skill`). `run-id` and `carve-outs` are omit-when-empty; the `run-id` propagates per §8 so the receiving skill writes artifacts under the same run directory.
- Non-trivial skill runs end with the **skill-exit status block** in `global/AGENTS.md` §9 (`skill`, `run-id`, `state`, `artifacts`, `next`, `blockers`, `cause`, `confidence`, `notes`). Required fields: `skill`, `state`, `artifacts`, `next`, `blockers`. Conditional: `cause` is present only when `state: blocked` (using a canonical cause class in §9) and omitted otherwise. Omit-when-empty: `run-id`, `confidence`, and `notes`.
- Clarification loops are capped (max 2 rounds) unless a real decision gate remains.
- Public-web privacy gate, sensitive-file safety, worktree safety, and git safety are owned in `global/AGENTS.md` §6.
- Approval-required actions use the **canonical approval ask** template in `global/AGENTS.md` §6.
- Commands are classified by risk: read-only, project-write, dependency-write, environment-write, external-write, and destructive (`global/AGENTS.md` §6).
- Generated files, lockfiles, snapshots, goldens, vendored code, and minified files are treated as derived artifacts unless the source or approved generation step is clear.
- High-risk work uses the **high-risk challenge gate** in `global/AGENTS.md` §10 before it is reported as settled.
- Verification follows the ladder: narrow check → broader affected-area check → full check only when scope or risk justifies it. Non-trivial reports include verification provenance, and the iteration cap (3 fix/verify loops per step) is in `global/AGENTS.md` §7.
- Framework/library/vendor docs that materially drive an implementation or review conclusion are cited in the output instead of being left implicit (`global/AGENTS.md` §5).
- Verification command discovery follows explicit plan/user command, project scripts, CI config, repo docs, existing language-native defaults, then clarification. Long-running commands and background jobs require approval when they are persistent or mutating, and cleanup is reported.
- Severity (BLOCKER / MAJOR / MINOR / NIT), risk (trivial / low / medium / high), the **non-trivial** definition, the **small direct request** threshold (≤3 files), and the **confidence signal** all live in `global/AGENTS.md` §3.
- Tool-use heuristics nudge the agent to narrow scope or summarize remaining unknowns after sustained MCP use instead of following brittle hard call ceilings (`global/AGENTS.md` §4).
- **Citation provenance** (`global/AGENTS.md` §5): cited URLs must come from a result actually fetched in this session; URLs recalled from memory must be re-fetched or labeled `Confidence: low — uncited recall`.
- **Transform rollback** (`global/AGENTS.md` §7) is shared across `b-implement`, `b-refactor`, and `b-debug`: never exit a skill with the tree mid-transform.
- **Cascading failures** (`global/AGENTS.md` §7) are shared across `b-implement`, `b-refactor`, and `b-test`: one cascade fix, then stop and revise/handoff/surface.
- **Completion contract** (`global/AGENTS.md` §7) defines "done": verification ran, status block emitted, manifest written for multi-artifact runs, follow-ups captured on an existing report surface, tree coherent.
- **Agent-cannot-reproduce protocol** (`global/AGENTS.md` §10) is shared across `b-debug`, `b-e2e`, and `b-test` for symptoms only the user can trigger.
- **Hybrid component tests** stay in `b-test` per the **DOM-unit vs browser-flow boundary** in `global/AGENTS.md` §10 unless a real browser engine, real network, real cookies, or visual assertions are involved.
- **Output verbosity caps** (`global/AGENTS.md` §9): BLOCKER findings are never elided; MAJOR/MINOR/NIT cap at 15 per severity; "Checked and clean" caps at 5; sources prefer 2–4 (max 8 outside literature scans); narration leads with the result, not tool play-by-play.
- **Common rationalizations** (`global/AGENTS.md` §12) is the suite-wide anti-pattern table; skills do not maintain their own duplicate copies.
- Empty-state defaults (no diff, no plan, no test framework, no MCP) are owned in `global/AGENTS.md` §7.
- Fallback labeling uses `[degraded: <reason>]` consistently across skills (`global/AGENTS.md` §4).
- Session-start preflight and crash/resume rules are owned in `global/AGENTS.md` §11.

### Tool model
- Native tools stay first for exact strings, manifests, prose, configs, and small reads.
- Skills reference **MCP bundles** by name (`serena-symbol-toolkit`, `gitnexus-radar`, `context7-docs`, `brave-discovery`, `firecrawl-extraction`/`firecrawl-extended`/`firecrawl-deep`, `playwright-browser`). Bundle definitions, fallback ladder, cost gates, and language-coverage caveats are owned in `global/AGENTS.md` §4.
- Serena is **primary hands** for symbols, references, diagnostics, and symbol-aware edits.
- GitNexus is **optional radar** for graph-shaped questions only when indexed, fresh, and target-aware.
- Runtime evidence outranks graph evidence; graph evidence outranks text evidence; search snippets are discovery only and require primary/fetched support before final claims unless labeled snippet-only with low confidence.
- `sequential-thinking` is bundled but optional; reach for it inline only when three or more plausible hypotheses remain with equal cheapest-verification cost.

### Installer behavior
- `install.sh` always installs the suite runtime snapshot at `~/.config/opencode/AGENTS.b-skills.md`.
- `install.sh` replaces `~/.config/opencode/AGENTS.md` only when it is missing or the user explicitly approves replacement.
- If replacement is not approved, `install.sh` preserves the existing `AGENTS.md`, writes the suite snapshot, and exits with an activation-pending status plus follow-up instructions; it does not claim the suite runtime contract is active.
- `install.sh` supports `--dry-run` / `B_SKILLS_DRY_RUN=Y` to preview config and runtime-rule changes without writing them.
- Changed `opencode.json` and `AGENTS.md` files are backed up with a timestamped `.bak-*` suffix before overwrite.
- `~/.config/opencode/b-skills-install.json` records what the suite manages in the user's OpenCode config, including whether runtime activation is `active` or `pending`.

### Maintenance rules
- Keep command wrappers thin.
- Update `README.md` and `REFERENCE.md` in the same commit as any skill change.
- Run `scripts/validate-skills.sh` before installing or committing skill changes.
- Keep skill descriptions trigger-focused and keep shared policy in `global/AGENTS.md` rather than duplicating it across every skill.
