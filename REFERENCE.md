# b-skills — Skill reference

Detailed contract reference for the maintained eight-skill suite. For install and high-level overview, see [README.md](README.md).

When this document cites `global/AGENTS.md`, that is the source-repo path. Installed skill prose should reference the runtime path `AGENTS.md`.

---

## Skill reference

### b-plan

Think before coding. `b-plan` exists for unclear, broad, or risky work where the main job is to decide scope, approach, ordering, and success criteria before editing code.

**Core behavior**
- Chooses **quick mode** for trivial scoped work and **full mode** for non-trivial work.
- Writes new full-mode saved plans with durable frontmatter for `slug`, `status`, approval timestamps, risk, and touch points.
- Uses the smallest blocking questions only; does not turn every plan into an interview.
- Produces dependency-ordered steps as short as the work actually is, with exact files or symbols when known.
- Keeps broad or unclear refactors in planning until they reduce to concrete mechanical transforms for `b-refactor`.
- Routes unresolved external feasibility, contract, migration, or security unknowns to `b-research` instead of guessing.
- Treats the approved plan as the execution source of truth for later `b-implement` work.

**Good triggers**
```text
/b-plan add rate limiting to the API
plan the auth migration
how should I approach this refactor?
```

**Boundary examples**
- `b-plan`: "Plan the auth migration across middleware, API routes, and session state."
- `b-implement` instead: "Add a help link to Settings" when the behavior is already obvious and safely scoped.

**Output**
- Quick mode: short chat plan.
- Full mode: English plan file at `.opencode/b-skills/b-plan/<task-slug>.md`, where `<task-slug>` follows the slug algorithm in `global/AGENTS.md` §8. Saved plans remain canonical repo-local source-of-truth files even when non-plan runtime artifacts would fall back to a non-worktree path. Skeleton: durable frontmatter, `# title`, `Confirmed decisions`, `Planned touch points`, `Dependencies`, `Risks`, `Unknowns`, checkbox-style `Steps`, `Verification`, `Rollback` (only when real), and `Revisions` (added when revised).

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
- Uses Context7 first for library and framework APIs; page extraction only when lookup is insufficient.
- Uses `firecrawl-extraction` for local docs and known URLs; `firecrawl-extended` only for site maps or structured fields; `firecrawl-deep` only with explicit user approval per invocation (cost warning in `global/AGENTS.md` §4).
- Reuses fetched results from earlier in the session instead of re-fetching.

**Good triggers**
```text
/b-research what's the Prisma transaction API?
/b-research compare BullMQ vs Bee-Queue
tra cứu config key cho NextAuth session timeout
```

**Output**
- Lookup: direct answer, source, and a minimal example only when it helps. Confidence line only when not high.
- Research: answer, key findings, limitations, cited sources, confidence.

**Key rules**
- Never ask the user to choose a mode; the skill decides and auto-deepens.
- Do not scrape in open-ended lookup when a docs or search result already answers; direct-source lookup from a provided source may extract that one source immediately.
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
- Reads saved-plan frontmatter when present and requires an executable durable approval state (`approved` or `in-progress`) or explicit current-chat approval before editing.
- Routes broad or ambiguous work back to `b-plan`.
- Preserves unrelated worktree changes and edits only files needed for the current step.
- Uses `serena-symbol-toolkit` for symbol-aware edits and narrow diagnostics before broader checks.
- Uses `gitnexus-radar` only when a shared route, tool, or exported boundary makes graph context genuinely useful.
- Applies the **plan staleness gate** (`global/AGENTS.md` §2) before executing a saved plan.
- Triggers the **plan revision protocol** (`global/AGENTS.md` §2) when the plan is wrong mid-execution.
- Verifies each step before moving on, capped by the iteration cap in `global/AGENTS.md` §7.
- Updates saved-plan task-list progress in place when the plan uses checkbox-style steps.
- Updates frontmatter progress (`approved` → `in-progress` → `complete`) without stripping metadata.
- Continues through approved plan steps when the user asks to implement or finish the plan; stops after one verified step when the user asks for only the next step.

**Good triggers**
```text
/b-implement add-rate-limit
/b-implement .opencode/b-skills/b-plan/add-rate-limit.md
implement the approved plan
```

**Boundary examples**
- `b-implement`: "Implement the approved rate-limit plan" or "wire the new settings copy into the existing page."
- `b-refactor` instead: "Rename `UserService` to `UserRepository` everywhere" when the work is primarily mechanical.

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
- Handles **cannot-reproduce** reports explicitly: states the gap, captures state diffs, and asks before patching.
- Confirms root cause before editing.
- Applies the smallest fix and verifies with the narrowest relevant runtime check, then re-scans the diff and removes every temporary probe before reporting success.
- Defers the "test failure vs runtime bug" decision to `global/AGENTS.md` §10.

**Good triggers**
```text
/b-debug login callback not firing
why is this endpoint returning 500?
fix this runtime bug
the dashboard is slow after the last deploy
```

**Boundary examples**
- `b-debug`: "This endpoint started returning 500 after the deploy."
- `b-test` instead: "The snapshot changed after the copy update" when production behavior is already confirmed correct.

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
- Picks **self-review** or **external review** mode per the boundary in `global/AGENTS.md` §10. Defaults to self-review when the working tree is dirty and unspecified.
- Fast path is **risk-bucket-gated**, not line-count-gated: allowed only when changes are confined to a single non-sensitive module, no auth/billing/secrets/crypto/migration files are touched, no public contract changes, and no new external dependency. Auth/security/migration/contract touches always force standard review.
- `--repo-audit` always uses the standard path.
- Builds a requirements baseline from `$ARGUMENTS`, `--baseline=<path|url>`, an approved plan, or a short clarification.
- Falls back to clearly labeled **diff-only risk review** or **repo-audit risk review** when no baseline exists after bounded clarification.
- Reviews highest-risk symbols and boundaries first.
- Uses a short surface-specific checklist for `--repo-audit` targets such as installers, runtime contracts, validators, route/tool boundaries, dependency changes, lockfiles, or generated artifacts.
- Runs the **security checklist** (correctness, input validation, injection, auth/authz, sensitive-data exposure, concurrency, dependency hygiene, secret handling, regex DoS, rate limits, error handling) on every changed entry point and shared boundary, even on the fast path.
- Treats lockfile, generated, snapshot, golden, vendored, and minified changes as derived artifacts unless the source or approved generation step is clear.
- Skips test adequacy and observability only when `--skip-tests` is present.
- Reports findings first, ordered by the **severity rubric** in `global/AGENTS.md` §3 (BLOCKER / MAJOR / MINOR / NIT), and includes "Checked and clean" so the author sees what scope was actually inspected.

**Good triggers**
```text
/b-review
/b-review --range=origin/main..HEAD
/b-review --repo-audit runtime contract and installer
review before PR
what would a reviewer flag here?
```

**Boundary examples**
- Default `b-review`: review a diff, branch range, or working tree before PR.
- `--repo-audit`: audit a named repository surface such as the installer, runtime contract, or one subsystem.

**Output**
```text
Findings -> Coverage / Tests / Observability -> READY FOR PR or NEEDS FIXES
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

**GitNexus use**
- Optional only for broad route/API/tool/shared-flow risk.

---

### b-test

`b-test` owns code-level testing: writing tests, fixing test-only failures, and ranking coverage gaps.

**Core behavior**
- Discovers the project's test framework and narrowest runnable commands from manifests or CI.
- Routes red tests through the **test-vs-bug decision** in `global/AGENTS.md` §10.
- Separates work into four lanes: failing test, write tests, coverage review, or flaky test (with the flake handling procedure in `global/AGENTS.md` §10).
- Owns DOM-rendered unit tests (jsdom, RTL, Vue Test Utils, Svelte testing-library) per the **DOM-unit vs browser-flow boundary** in `global/AGENTS.md` §10.
- Uses `serena-symbol-toolkit` to map tests to source ownership when helpers, imports, or interfaces hide the real target.
- Captures large failure output under `/tmp/opencode/b-skills/b-test/` instead of depending on truncated terminal output.
- Treats snapshots, golden files, fixtures, mocks, and async timing as explicit test concerns; updates snapshots only after the **snapshot confirmation procedure** in `global/AGENTS.md` §10.
- Ranks coverage gaps using the rubric in the skill (required → strong → useful → opportunistic).
- Hands real-browser flows to `b-e2e` and product-behavior uncertainty to `b-debug`.
- Keeps property-based, fuzz, and contract tests in `b-test` only when the repo already has an established runner and pattern; new strategies or frameworks route to `b-plan` first.

**Good triggers**
```text
/b-test fix failing login test
/b-test write regression tests for retry logic
/b-test evaluate API coverage
```

**Boundary examples**
- `b-test`: "Fix the Vitest mock setup" or "add regression tests for retry backoff" when intended behavior is already known.
- `b-debug` instead: "The new regression test proves the API now returns the wrong shape."
- `b-e2e` instead: "Verify the signup flow in a real browser."

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

---

### b-e2e

`b-e2e` uses a real browser to verify user-facing flows and optionally convert them into repo-native browser tests. Two modes: **verify** and **author**.

**Core behavior**
- Uses the `playwright-browser` bundle (`global/AGENTS.md` §4): Playwright MCP when available, local Playwright CLI via `bash` as a documented fallback.
- Creates a session-specific artifact directory under `.opencode/b-skills/b-e2e/<run-id>/` using the run-id format from `global/AGENTS.md` §8.
- Uses repo-local `.opencode/...` artifact paths only when that path is already git-ignored; otherwise falls back to `~/.config/opencode/b-skills/...` or `/tmp/opencode/b-skills/...`.
- Verifies localhost targets are reachable before navigating; never starts a dev server without approval.
- Clarifies only blocking state: auth/session, test data, whether writes are allowed.
- Reuses or stores auth state (`storageState.json`) in a non-worktree path so repeated runs don't re-authenticate from scratch.
- Uses accessibility snapshots before interaction.
- Verifies state with snapshots, screenshots, console/network evidence. Multi-viewport remains opt-in except responsive UI work or UI intended for both mobile and desktop, where one representative mobile and desktop viewport are checked by default.
- Defaults to functional snapshots over visual regression; visual regression baselines require approval.
- Applies the **flake handling** procedure in `global/AGENTS.md` §10 before reporting flake.
- When writing tests, inspects the repo's existing browser-test framework first and preserves it instead of forcing Playwright everywhere.

**Good triggers**
```text
/b-e2e verify checkout flow
/b-e2e reproduce the signup UI bug
write a Playwright test for the new dashboard
```

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
- Never commit auth-state files containing real credentials.
- Always close the browser when done.

---

### b-refactor

`b-refactor` handles concrete behavior-preserving transforms.

**Core behavior**
- Locks the exact target before editing.
- Runs `find_referencing_symbols` once as the canonical impact-mapping step.
- Classifies the refactor on the **risk rubric** in `global/AGENTS.md` §3 (trivial / low / medium / high).
- Supports a **trivial local fast path** only when one file, no contract change, few references, behavior preserved, **and** the language is LSP-supported by Serena. Non-LSP languages auto-promote to at least **low** risk by design.
- Treats vague "simplify" requests as planning work until the exact behavior-preserving transform is locked.
- Uses `gitnexus-radar` only when exported, shared, route/tool, or broader package boundaries make graph context useful.
- Uses the `serena-symbol-toolkit` rename/delete/body-replacement tools whenever they fit the transformation.
- For **rename + extract**, does extract first under the old name, then `rename_symbol`, so each transform is independently verifiable.
- Treats **move between files** as the highest-mechanical-risk refactor: add destination first, update every import and test path, update build config and barrel files, only then `safe_delete_symbol` the origin, then re-confirm references.
- Verifies with diagnostics plus the narrowest risk-appropriate check (verification ladder in `global/AGENTS.md` §7).
- Hands behavioral redesign back to `b-plan` via the handoff envelope in `global/AGENTS.md` §9, including the locked target and the reference map.

**Good triggers**
```text
/b-refactor rename UserService to UserRepository
/b-refactor extract validation from handleSubmit
/b-refactor delete unused legacy auth helper
```

**Boundary examples**
- `b-refactor`: "Extract `parseOptions` from `handleArgs` without changing behavior."
- `b-plan` or `b-implement` instead: "Simplify checkout retries so the product gives up sooner" because the behavior changes.

**Output**
```text
Target -> Risk -> Impact -> Changes -> Verification -> Follow-up
```

**Key rules**
- Keep the work behavior-preserving.
- Use the trivial-local fast path only when the contract is clearly untouched and the language is LSP-supported.
- For non-LSP languages, treat every rename or safe-delete as at least **low** risk.
- For non-LSP languages, generated glue, config-driven references, or text-discovered references outside Serena's graph, add targeted text search to verification.
- For rename + extract, do extract first, then rename.
- Ask before broad directory moves or similar cascading changes.

**GitNexus use**
- Optional only for broader blast-radius questions.

---

## Repository layout and maintenance

This repository is the install-only source layout for the suite. OpenCode does not load the checked-in `skills/` or `commands/` directories directly from this repo root.

### Repository source files
- `AGENTS.md` — maintainer guidance for this source repo.
- `global/AGENTS.md` — source copy of the runtime global rules, installed as `AGENTS.b-skills.md` and optionally applied to OpenCode's main `AGENTS.md`; installed skill prose should cite `AGENTS.md`.
- `skills/<name>/SKILL.md` — skill sources.
- `commands/<name>.md` — thin slash-command wrappers.
- `scripts/smoke-install.sh` — isolated installer smoke checks against a temp HOME and repo snapshot.
- `scripts/validate-skills.sh` — suite validator for frontmatter, required sections, stale phrases, docs coverage, and global-rule guardrails.

### Runtime artifacts
- `.opencode/b-skills/b-plan/<task-slug>.md` — saved plans from `b-plan` (legacy `.opencode/b-plans/` is deprecated). These remain canonical repo-local source-of-truth files. `<task-slug>` derives from `global/AGENTS.md` §8.
- `.opencode/b-skills/<skill>/<run-id>/` — repo-local non-sensitive run artifacts when `.opencode/` is git-ignored, with `run-id = <YYYYMMDD-HHMMSS>-<slug>`.
- `~/.config/opencode/b-skills/<skill>/<run-id>/` or `/tmp/opencode/b-skills/<skill>/<run-id>/` — non-worktree artifacts for sensitive browser/session state.
- `/tmp/opencode/b-skills/<skill>/<slug>.log` — large command output and temporary logs.
- Multi-artifact runs include a `manifest.json` per the schema in `global/AGENTS.md` §8.

### Runtime global conventions
- One active skill at a time.
- Trigger precedence is explicit: browser flow → `b-e2e`; DOM-rendered unit test → `b-test`; likely product bug → `b-debug` (per the test-vs-bug decision in `global/AGENTS.md` §10); named behavior-preserving transform → `b-refactor`; unclear scope → `b-plan`; external-knowledge blocker → `b-research`.
- After `b-plan` approval, the approved plan is the execution source of truth for multi-step implementation, subject to the **plan staleness gate** and **plan revision protocol** in `global/AGENTS.md` §2.
- New saved plans carry durable frontmatter for approval state, risk, and touch points; legacy plans remain valid with explicit current-chat approval.
- Cross-skill handoffs use the **handoff envelope** in `global/AGENTS.md` §9 (`source`, `goal`, `decisions`, `assumptions`, `files`, `verification`, `blockers`, `next-skill`).
- Non-trivial skill runs end with the **skill-exit status block** in `global/AGENTS.md` §9.
- Clarification loops are capped (max 2 rounds) unless a real decision gate remains.
- Public-web privacy gate, sensitive-file safety, worktree safety, and git safety are owned in `global/AGENTS.md` §6.
- Approval-required actions use the **canonical approval ask** template in `global/AGENTS.md` §6.
- Commands are classified by risk: read-only, project-write, dependency-write, environment-write, external-write, and destructive (`global/AGENTS.md` §6).
- Generated files, lockfiles, snapshots, goldens, vendored code, and minified files are treated as derived artifacts unless the source or approved generation step is clear.
- Verification follows the ladder: narrow check → broader affected-area check → full check only when scope or risk justifies it. Non-trivial reports include verification provenance, and the iteration cap (3 fix/verify loops per step) is in `global/AGENTS.md` §7.
- Severity (BLOCKER / MAJOR / MINOR / NIT), risk (trivial / low / medium / high), the **non-trivial** definition, the **small direct request** threshold (≤3 files), and the **confidence signal** all live in `global/AGENTS.md` §3.
- Tool-use heuristics nudge the agent to narrow scope or summarize remaining unknowns after sustained MCP use instead of following brittle hard call ceilings (`global/AGENTS.md` §4).
- Empty-state defaults (no diff, no plan, no test framework, no MCP) are owned in `global/AGENTS.md` §7.
- Fallback labeling uses `[degraded: <reason>]` consistently across skills (`global/AGENTS.md` §4).
- Session-start preflight and crash/resume rules are owned in `global/AGENTS.md` §11.

### Tool model
- Native tools stay first for exact strings, manifests, prose, configs, and small reads.
- Skills reference **MCP bundles** by name (`serena-symbol-toolkit`, `gitnexus-radar`, `context7-docs`, `brave-discovery`, `firecrawl-extraction`/`firecrawl-extended`/`firecrawl-deep`, `playwright-browser`). Bundle definitions, fallback ladder, cost gates, and language-coverage caveats are owned in `global/AGENTS.md` §4.
- Serena is **primary hands** for symbols, references, diagnostics, and symbol-aware edits.
- GitNexus is **optional radar** for graph-shaped questions only when indexed, fresh, and target-aware.
- Runtime evidence outranks graph evidence; graph evidence outranks search snippets.
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
