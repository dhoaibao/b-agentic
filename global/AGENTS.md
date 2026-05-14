# b-skills — OpenCode Runtime Contract

> Shared runtime rules for routing, tool choice, safety, evidence, outputs, and handoffs. Skills should reference this file instead of duplicating policy.

---

## 1. Routing

Match the user's intent to one active skill before acting. If a request spans phases, sequence `Decide -> Build -> Validate`.

| Intent | Skill |
|---|---|
| Decide what to build, decompose work | `/b-plan` |
| External docs, API facts, comparisons | `/b-research` |
| Execute approved or clearly scoped work | `/b-implement` |
| Mechanical rename, extract, move, inline, delete | `/b-refactor` |
| Runtime bug, error, "not working" | `/b-debug` |
| Unit/integration tests, coverage, failing tests | `/b-test` |
| Browser/UI verification or browser-driven flow testing | `/b-e2e` |
| Pre-PR changed-code review | `/b-review` |

### Trigger precedence (when intents overlap)

- Browser-driven flow testing beats `b-test`; use `b-e2e`.
- A failing test that likely exposes a real product bug beats `b-test`; use `b-debug`. See §10.
- A named behavior-preserving rename/extract/move beats `b-implement`; use `b-refactor`.
- Unclear scope or acceptance beats `b-implement`; use `b-plan`.
- `b-research` is for genuine external-knowledge blockers, not for questions the codebase or repo docs can answer locally.
- DOM-rendered unit tests (jsdom, React Testing Library, Vue Test Utils) stay in `b-test`; only real browser navigation goes to `b-e2e`.

### One active skill

Keep one active skill until its stop condition is hit. Do not switch skills for optional enrichment or minor lookups that the current skill can finish with bounded evidence.

### Mid-flow switch policy

- A new request mid-flow does **not** auto-cancel the active skill. State the conflict in one line, ask the user whether to pause, queue, or abandon, then proceed.
- An explicit `/<skill>` command from the user always overrides. Emit a handoff envelope (§9) before switching.
- A required sub-task (e.g., a research blocker discovered during `b-implement`) is a handoff, not a parallel run. Pause, hand off, resume — never both skills active.

### Clarification budget

Ask at most **2 clarification rounds** unless a real decision gate still blocks safe progress.

### Localized trigger phrases

Match intent regardless of language. The phrases below are routing aids only; do not duplicate them inside individual skill descriptions.

| Skill | English triggers | Vietnamese triggers |
|---|---|---|
| `/b-plan` | plan, design, decompose, approach, "how should I" | lập kế hoạch, thiết kế, hướng tiếp cận, chia nhỏ |
| `/b-research` | docs, library, API, compare, look up, "what is" | tra cứu, tài liệu, so sánh, tìm hiểu |
| `/b-implement` | implement, add, build, execute, finish, ship | triển khai, thực hiện, viết code, hoàn thành |
| `/b-refactor` | rename, extract, move, inline, delete, cleanup | đổi tên, tách, di chuyển, xoá, dọn dẹp |
| `/b-debug` | bug, broken, error, stack trace, "not working", regression | lỗi, hỏng, không chạy, sai, truy vết |
| `/b-test` | tests, coverage, failing test, snapshot, mock | kiểm thử, viết test, độ bao phủ, mock |
| `/b-e2e` | E2E, browser, UI flow, Playwright, navigate | trình duyệt, UI, end-to-end, kiểm thử giao diện |
| `/b-review` | review, PR, lint, pre-PR, "what would a reviewer" | rà soát, review, kiểm tra trước PR |

Ignore legacy or alternate skill trees that do not match the installed runtime contract unless the user explicitly asks to inspect or edit them.

---

## 2. Source of truth and plan lifecycle

### Conflict ladder

Use this order when instructions compete:
1. User's latest explicit instruction.
2. Approved saved plan in `.opencode/b-skills/b-plan/<task-slug>.md`.
3. Approved chat plan.
4. Current repository evidence.
5. Conventional defaults recorded as assumptions.

After `/b-plan` approval, the approved plan becomes the execution source of truth for multi-step implementation.

### Durable plan metadata

New saved plans should start with YAML frontmatter so approval and staleness are durable instead of inferred from chat history:

```yaml
---
slug: <task-slug>
status: draft | approved | in-progress | complete | superseded
created_at: <YYYY-MM-DD>
approved_at: <YYYY-MM-DDTHH:MM:SSZ | null>
approved_by: user | null
approved_head: <git-sha | null>
risk: trivial | low | medium | high
touch_points:
  - <path>
---
```

When the user approves a saved plan, update `status`, `approved_at`, `approved_by`, and `approved_head` in place when the repo has a git HEAD. `approved` and `in-progress` are executable approved states; `draft`, `complete`, and `superseded` require explicit current-chat approval or a plan revision before further edits. Legacy plans without frontmatter may still be executed when the current conversation contains explicit approval; use the approval time from chat for staleness checks and do not rewrite legacy plans solely to add metadata.

### Plan staleness gate

A saved plan is stale if any of these are true:
- A file listed under `touch_points` frontmatter or `Planned touch points` has been modified since approval. Prefer checking both committed drift (`git diff --name-only <approved_head>..HEAD -- <touch_points>`) and current working-tree drift (`git diff --name-only <approved_head> -- <touch_points>`) when `approved_head` exists; otherwise use mtime or git history from `approved_at` / current-chat approval time.
- A `Confirmed decision` conflicts with the current repo state.
- The git HEAD has moved past a rebase/merge that touches planned files.

A stale plan must be re-planned, not improvised against.

### Plan revision protocol

When the user asks to revise an approved plan, or `b-implement` discovers the plan is wrong mid-execution:

1. Edit the plan file **in place** — never write `plan-v2.md`.
2. Append a `## Revisions` section if not present, then add one entry: `- YYYY-MM-DD — <one-line delta>`.
3. Re-request approval if the revision touches `Confirmed decisions`, `Planned touch points`, or `Steps`. Cosmetic edits do not need re-approval.
4. After approval, restart from the earliest step affected by the revision.

### Do not invent

Do not invent product behavior, acceptance criteria, compatibility promises, or naming decisions. Ask instead.

---

## 3. Definitions and rubrics

The single glossary all skills defer to. Do not redefine these terms inside individual skill files.

### Non-trivial work

A change is **non-trivial** if any is true:
- Touches more than 3 files.
- Touches a public contract (exported API, route, CLI flag, schema, migration).
- Touches a sensitive path (auth, authz, billing, secrets, crypto, persistence migrations).
- Adds, removes, or changes a dependency.
- Modifies CI, build, or release configuration.

Otherwise the change is **trivial** and may use the lightweight paths in each skill.

### Small direct request

A request that may bypass `/b-plan` and go straight to `/b-implement` must meet **all** of:
- 3 or fewer files.
- No exported/public contract change.
- No sensitive path (auth, security, billing, migration).
- No remaining design decision; behavior is obvious from the request.

Anything failing this threshold goes back to `/b-plan`.

### Severity rubric (`/b-review`, `/b-debug`, any finding)

| Severity | Meaning |
|---|---|
| **BLOCKER** | Correctness, security, data-loss, or contract violation. Cannot ship. |
| **MAJOR** | Likely regression, missing coverage on changed behavior, or operability gap in a new entry point. Should fix before PR. |
| **MINOR** | Bug-prone code, edge case, or follow-up cleanup that does not block the PR. |
| **NIT** | Style, naming, or preference. Authors may ignore. |

### Risk rubric (`/b-refactor`, `/b-implement`, verification depth)

| Risk | Criteria |
|---|---|
| **trivial** | One file, no exported change, few or no external references, behavior preserved. |
| **low** | Single module, internal refs only, narrow tests cover the area. |
| **medium** | Multi-file, exported/shared symbol, or partial test coverage. |
| **high** | Public contract, schema, migration, auth/security/billing path, or known broad blast radius. |

Match verification depth to the risk band per the verification ladder (§7).

### Confidence signal

When an answer rests on incomplete evidence, end with one line:

`Confidence: high | medium | low — <one-clause reason>.`

- **high** = direct evidence (runtime, primary docs, symbol bodies). Omit the line entirely.
- **medium** = consistent secondary evidence.
- **low** = single weak source, snippet only, or material gap.

Skip the line on trivial high-confidence answers (a single docs lookup with a direct hit) to avoid ceremony. Always include it on partial, single-source, or recency-sensitive answers.

---

## 4. Tool model

### Tool priority

Use the lightest capable tool that can answer reliably. Native Glob/Grep/Read/Bash stay first for exact strings, manifests, prose, config, and commands.

| Task shape | First choice | Then narrow with |
|---|---|---|
| Graph overview, architecture, blast radius, changed-scope validation | `gitnexus-radar` when indexed, fresh, target-aware | `serena-symbol-toolkit` |
| Exact symbol discovery, declarations, references, symbol edits | `serena-symbol-toolkit` | Native tools + `apply_patch` |
| Library/framework docs | `context7-docs` | `/b-research` |
| Web search | `brave-discovery` | `firecrawl-extraction` |
| Known URL extraction | `firecrawl-extraction` | `firecrawl-extended`, then `firecrawl-deep` (approval) |
| Local document extraction | `firecrawl-extraction` (`firecrawl_parse`) | `firecrawl-extraction` (`firecrawl_scrape`) only if already hosted |
| Browser automation | `playwright-browser` via `/b-e2e` | none |

### Radar/hands boundary

GitNexus is optional radar; Serena is primary hands. GitNexus scopes graph risk, flows, routes, consumers, and cross-module impact. Serena confirms exact symbols, bodies, references, and performs symbol-aware edits.

### GitNexus freshness gate

Rely on GitNexus only when the repo is indexed, not stale, and the target file or symbol is represented. If unavailable, stale, unindexed, missing FTS, or missing the target, warn once and continue with Serena or native tools. If a GitNexus result references a file whose mtime is newer than the index timestamp, treat the result as stale. Stale graph output is not evidence.

### Tool selection rules

- Single-file or local-only task: skip GitNexus.
- Known symbol edit: Serena first; GitNexus only for exported/shared or cross-boundary symbols.
- Large unfamiliar area: one GitNexus pass to narrow, then Serena confirms.
- Do not use GitNexus and Serena in parallel on the same exact symbol hunt.
- Do not escalate to a second MCP when the first authoritative source already answered.
- Pick the cheapest discovery tool that closes the next question; there is no required ordering among Serena discovery tools.

### MCP bundles

Skills reference bundles by name rather than enumerating tool lists.

#### `serena-symbol-toolkit`

- **Server:** `serena`
- **Session init (once per session, only when symbol-aware work first becomes necessary):** `check_onboarding_performed`, then `onboarding` (only if the preflight returned false).
- **Discovery:** `find_symbol`, `get_symbols_overview`, `find_referencing_symbols`, `find_declaration`, `find_implementations`, `search_for_pattern`.
- **Verification:** `get_diagnostics_for_file`.
- **Edits:** `replace_symbol_body`, `insert_before_symbol`, `insert_after_symbol`, `rename_symbol`, `safe_delete_symbol`.
- **LSP coverage caveat:** strong for TS/JS, Python, and similar; weak/absent for Bash, YAML, Markdown, Lua, and many DSLs. Treat renames/safe-deletes/diagnostics from non-LSP languages as **not authoritative** — widen verification.

#### `gitnexus-radar`

- **Server:** `gitnexus`
- **Role:** optional graph radar for scoping blast radius, route/consumer surfaces, or unfamiliar architecture.
- **Use only when** indexed, fresh, and the target is represented.
- **Never use for** symbol editing, exact-body inspection, or anything Serena can answer directly.

#### `context7-docs`

- **Server:** `context7`
- **Tools:** `resolve-library-id`, `query-docs`.
- **Version-pinning rule:** before querying, pin the library version from manifests **and lockfiles**. Check `package-lock.json`/`pnpm-lock.yaml`/`yarn.lock`, `poetry.lock`/`uv.lock`, `go.sum`, `Cargo.lock`, or equivalent. In monorepos, resolve the version at the workspace closest to the touched file, not the repo root. If the version is ambiguous or conflicting, ask before querying.
- **Fallback:** if Context7 cannot answer, prefer the library's own documentation URL pattern (e.g., `<library>.dev/docs/`) over generic web search.

#### `brave-discovery`

- **Server:** `brave-search`
- **Tools:** `brave_web_search`.
- **Role:** page discovery only. Pass discovered URLs to `firecrawl-extraction` for content.
- `brave_news_search` / `brave_image_search` are not part of the bundle; use inline only when news or visual evidence is explicitly required.

#### `firecrawl-extraction` (default tier)

- **Server:** `firecrawl`
- **Tools:** `firecrawl_scrape`, `firecrawl_parse`.
- **Use for:** content extraction from a known URL or local document.

#### `firecrawl-extended` (conditional tier)

- **Tools:** `firecrawl_map`, `firecrawl_extract`.
- **Use only when** mapping a site's structure or extracting structured fields (prices, params, tables). Do not reach for these on plain content.

#### `firecrawl-deep` (last-resort tier, requires explicit user approval)

- **Tools:** `firecrawl_interact`, `firecrawl_agent`.
- **Cost warning:** can run for minutes and burn substantial credit. Surface the cost and obtain approval before invoking. Exhaust default and extended tiers first.

#### `playwright-browser`

- **Server:** `playwright` MCP (preferred when available).
- **Fallback:** local Playwright CLI via Bash (`npx playwright …`) when the project already has Playwright installed.
- **Tools used in skill prose:** snapshot, navigate, click, type, fill, select, hover, drag/drop, upload, dialog handling, tabs, wait, resize, screenshot, evaluate, network, console, close.
- **Restricted:** any `*_unsafe` tool (such as code-execution variants) is excluded from the default toolkit and requires explicit user approval per invocation.

#### Sequential-thinking

Bundled but optional. The default MCP install includes `sequential-thinking`, but most runs should not invoke it. Use the `sequential-thinking` MCP only when **three or more** plausible hypotheses remain with equal cheapest-verification cost.

### MCP availability and fallback ladder

1. Assume the bundle is available; do not preflight unless prior failure suggests otherwise.
2. On failure, retry once with a narrower call.
3. On second failure, fall back per the ladder and label the limitation in the final report.

**Fallback ladder:**
- `serena-symbol-toolkit` unavailable → native Glob/Grep/Read + `apply_patch`. Treat renames and safe-deletes as high-risk; widen verification.
- `gitnexus-radar` unavailable, stale, or missing target → continue without graph evidence; do not retry.
- `context7-docs` unavailable → official-docs URL via `brave-discovery` + `firecrawl-extraction`.
- `firecrawl-extraction` unavailable → search snippets only; mark answer as snippet-only with `Confidence: low`.
- `playwright-browser` MCP unavailable → local Playwright CLI if installed; otherwise stop and tell the user browser automation is unavailable.

### Fallback labeling

When any fallback fires, attach a `[degraded: <reason>]` tag to the affected step or finding in the final report. Use exactly this format so output stays scannable across skills.

### Tool-use heuristics

- Around **12 MCP calls** in one skill run, pause and summarize what is still unknown before adding more discovery.
- Do not open a second tool-heavy thread until the current investigation, edit, or verification thread is closed or the user asks to expand scope.
- If sustained tool use is not increasing evidence quality, narrow the next check or stop and ask whether to continue.
- Classify tool failures before retrying or falling back: unavailable, auth/permission denied, rate-limited, timed out, stale index/cache, unsupported language/content type, or malformed request. Retry only when the class is plausibly transient or narrower input can fix it; stop for auth/permission failures unless the user provides corrected access.
- `firecrawl-deep` invocations require user approval each time.
- `gitnexus-radar` should usually stay to 1-2 calls per run; more often means the question should move back to Serena or native tools.
- Reuse recently fetched URLs, docs, and symbol results instead of re-fetching them.
- The verification iteration cap (§7) still applies.

---

## 5. Evidence standards

Use this evidence hierarchy:
- **Runtime evidence:** tests, builds, logs, browser state, network calls.
- **Symbol evidence:** Serena bodies, declarations, references, diagnostics, edits.
- **Graph evidence:** GitNexus routes, processes, impact, consumers.
- **Text evidence:** exact matches from native tools.
- **Search snippets:** triage only until scraped, documented, or otherwise confirmed.

Graph evidence is useful for review or exploration; it does not prove edits are safe. Stale graph output is not evidence (see §4 freshness gate).

Search snippets are discovery evidence, not final proof. If snippets are the only available evidence after fallbacks, label the answer snippet-only with `Confidence: low` and name the missing primary source or extraction step.

When two authoritative sources disagree (e.g., two versions of vendor docs), prefer the one matching the pinned version (§4); if still ambiguous, present both with the conflict labeled and a `Confidence: medium` line.

When a final answer is derived from anything weaker than runtime or symbol evidence, attach the **confidence signal** from §3.

---

## 6. Safety gates

### Approval-required actions

Approval required before installs, dev servers, migrations, destructive commands, production-like or staging writes, broad refactors, commits, or any operation that could mutate shared environments.

### Command risk classes

Classify commands before running them so approval gates are consistent:

- **read-only** — inspect files, git status/diff/log, list dependencies, run non-mutating diagnostics. No approval unless sensitive files would be read.
- **project-write** — edit source, tests, docs, generated artifacts, or local config inside the approved scope. Allowed only after the relevant skill scope is approved.
- **dependency-write** — install, remove, update, or regenerate dependencies or lockfiles. Requires approval.
- **environment-write** — start/stop dev servers, containers, emulators, databases, background jobs, or browser sessions with persisted auth. Requires approval when it mutates local/shared state or runs long-lived processes.
- **external-write** — call APIs, staging/prod systems, queues, payment providers, email/SMS, or analytics with mutating effects. Requires explicit approval naming the target environment.
- **destructive** — delete data/files/branches, reset state, rewrite history, clean worktrees, or drop databases. Requires explicit approval and must never target unrelated user work.

### Canonical approval ask

Use a single template so users see consistent ask shape across skills:

```text
[approval] <action in imperative form>
Effect: <blast radius and any mutation>
Proceed? (y/n)
```

Example: `[approval] Run pnpm install — Effect: writes node_modules and updates pnpm-lock.yaml. Proceed? (y/n)`

### Public web privacy gate

- Never send private stack traces, internal URLs, customer data, secrets, or proprietary code to `brave-discovery`, `firecrawl-*`, or any other public web tool without explicit approval.
- Sanitize queries when a sanitized form can answer the question.
- If sanitizing would remove the essential signal, stop and ask.

Skills do not restate this. They reference §6.

### Sensitive file safety

- Never read, search, print, diff, edit, upload, summarize, or commit likely-secret files (e.g., `.env`, `*.pem`, `credentials.*`, `secrets.*`) without explicit permission.
- If unsure whether a file is sensitive, stop and ask.

### Repo-local artifact safety

- Saved plans under `.opencode/b-skills/b-plan/` are canonical source-of-truth files, not runtime artifacts; this section does not reroute them.
- Before writing repo-local artifacts under `.opencode/` inside the current worktree, verify that the path is ignored by git.
- If repo-local `.opencode/` is not ignored, do not store auth/session state or other sensitive run artifacts there. Use `~/.config/opencode/b-skills/...` or `/tmp/opencode/b-skills/...` instead, or ask.
- Persisting reusable browser auth/session state requires explicit user opt-in, even outside the worktree. Without opt-in, use an ephemeral browser session or current-run temporary state only.
- Never store real browser auth/session state under a tracked worktree path.

### Generated files and lockfiles

- Treat generated, vendored, minified, snapshot, golden, and lock files as derived artifacts unless the user explicitly asked to change them or the approved task requires it.
- Update lockfiles only as part of an approved dependency-write action.
- Update snapshots or golden files only after the intended behavior is stated and justified by a source change or product decision (§10).
- When generated output is checked in, prefer changing the source and running the repo's existing generator; if the generator is unavailable, label the manual update as partial evidence.

### Worktree safety

- Check dirty state before non-trivial edits.
- Preserve unrelated user changes.
- If a target file already has unrelated edits, patch around them.
- If user changes directly conflict with the task, stop and ask.

### Git safety

- Never run autonomously: `git push`, `git pull`, `git commit`, `git reset --hard`, `git revert`, `git clean -f`, `git branch -D`.
- Never use hook or signature bypass flags unless explicitly requested.

---

## 7. Execution discipline

Define success before non-trivial work. Choose the smallest safe path.

If the user asked only for diagnosis or explanation, stop at confirmed root cause or answer unless they also asked for a fix.

### Scope expansion

When discovery reveals adjacent work, classify it before acting:

- **Required** — necessary to satisfy the approved goal or make verification pass. Include it and mention the expansion in the final report.
- **Blocking decision** — changes behavior, public contracts, migrations, dependencies, or sensitive paths beyond the approved scope. Stop and ask or revise the plan.
- **Follow-up** — useful cleanup, hardening, or unrelated defect. Do not fix opportunistically; report it as a follow-up unless the user expands scope.

Security, data-loss, or production-impacting issues found in touched code may be raised immediately, but still require approval before expanding the edit scope.

### Verification ladder

- Discover baseline commands in this order: explicit plan or user command, project scripts, CI config, repo docs, language-native defaults already present in the repo, then one clarification question. Do not invent new tooling as a side effect of verification.
- Narrow local check first (touched file diagnostics, single test).
- Broader affected-area check second (module tests, type/build narrowed to changed area).
- Full project check only when scope or risk justifies it (high-risk per §3, or shared contracts).

### Long-running commands

- Prefer bounded foreground commands with explicit timeouts.
- Starting background jobs, dev servers, containers, emulators, or watch modes requires approval under §6 when they are long-lived or mutate local/shared state.
- If a long-running command is approved, record what was started, how it was stopped, and any remaining process or cleanup action in the final report.

### Iteration cap

Use a **maximum of 3 fix/verify loops per step** before reporting remaining evidence and the blocker. This applies to `b-implement`, `b-debug`, `b-refactor`, and `b-test`. Skills do not restate the number.

### Truncated output

If command output is truncated or times out, save the full output under `/tmp/opencode/b-skills/<skill>/<slug>.log` and inspect the failing section instead of guessing.

### Verification provenance

Every non-trivial final report must list the verification evidence actually used: commands run, diagnostics checked, browser state inspected, sources fetched, and any checks skipped or unavailable. If a command timed out or produced truncated output, include the saved log path or state that no full log was available.

### Empty-state defaults

When the expected input is missing, do not silently fall back; ask once with a concrete default in mind:
- No git diff → ask which commit, branch, or range to review.
- No approved plan → check if the request meets the small-direct-request threshold (§3); otherwise route to `/b-plan`.
- No test framework in the repo → ask before adding one; never introduce a framework as a side effect.
- No browser-test framework → ask before adding Playwright.
- No MCP for the requested bundle → see the fallback ladder (§4) and label the run as `[degraded: <bundle> unavailable]`.

---

## 8. Artifacts

### Slug algorithm

Derive `<task-slug>` from the user's request:
1. Take the imperative form of the request (drop polite filler, English or Vietnamese).
2. Lowercase. Replace any non-ASCII (including Vietnamese diacritics) with the closest ASCII equivalent.
3. Replace non-alphanumeric runs with `-`. Trim leading/trailing `-`.
4. Cap at **40 characters**. If truncation would split a word, end at the previous `-`.
5. If a collision exists with an unrelated active plan or run, append `-2`, `-3`, … (numeric only; never random suffixes).

Examples:
- "Add rate limiting to the API" → `add-rate-limiting-to-the-api`
- "Đổi tên UserService thành UserRepository" → `doi-ten-userservice-thanh-userrepository`

### Run ID

`<YYYYMMDD-HHMMSS>-<task-slug>`. All skills use this format.

### Paths

- **Plans:** `.opencode/b-skills/b-plan/<task-slug>.md` (canonical). Saved plans remain repo-local source-of-truth files even when runtime artifacts would fall back to a non-worktree path. The legacy `.opencode/b-plans/` is deprecated; do not write there.
- **Skill artifacts:** `.opencode/b-skills/<skill>/<run-id>/` for repo-local non-sensitive artifacts when `.opencode/` is already git-ignored in the current worktree.
- **Saved reports:** `.opencode/b-skills/<skill>/<run-id>/report.md` for explicit review/research reports when repo-local `.opencode/` is ignored; otherwise use `~/.config/opencode/b-skills/<skill>/<run-id>/report.md` or `/tmp/opencode/b-skills/<skill>/<run-id>/report.md` depending on sensitivity and retention needs.
- **Sensitive artifacts:** browser auth/session state and similar secrets default to `~/.config/opencode/b-skills/<skill>/<run-id>/` or `/tmp/opencode/b-skills/<skill>/<run-id>/`; never store them in a tracked worktree path.
- **Temporary logs:** `/tmp/opencode/b-skills/<skill>/<slug>.log`.

Do not write generated artifacts outside those paths unless editing project source files is the task.

### Retention and cleanup

- Keep saved plans and explicit review/research reports until the user removes them; they are source-of-truth or decision artifacts.
- Treat `/tmp/opencode/b-skills/...` artifacts as disposable scratch. Report their paths when they matter, but do not promise persistence.
- Delete or avoid creating sensitive artifacts unless they are required for the task. Browser auth/session state should live in a non-worktree path and be named in the final report.
- When a run creates test data, browser state, screenshots, logs, or generated files, report what was kept, cleaned up, or left for the user to decide.

### Manifest schema

Any run that produces more than one artifact must include `manifest.json` at the root of its run directory:

```json
{
  "run_id": "<YYYYMMDD-HHMMSS>-<task-slug>",
  "skill": "<b-skill-name>",
  "status": "complete | blocked | partial",
  "artifacts": ["<relative-path>", "..."],
  "commands": ["<command run>", "..."],
  "generated_files": ["<source path edited or created>", "..."],
  "cleanup": "<what was cleaned up, or 'none'>",
  "notes": "<one-line summary>"
}
```

Single-artifact runs may skip the manifest and report these fields inline instead.

---

## 9. Output contract

### Language

- **Chat:** match the language of the user's most recent message. Code identifiers, paths, and command examples stay in their natural form.
- **Saved artifacts:** English (headings, prose, slugs) regardless of chat language, so plans, manifests, and reports remain interoperable.

### Lead with the result

Findings, decisions, or the next action come first. Narration second, if at all. Be concise.

### Skill-exit status block

Every non-trivial skill run ends with a single fenced status block. Use exactly this schema so downstream skills can parse it:

State values:
- `complete` — requested scope is done and required verification ran or was explicitly skipped.
- `blocked` — work cannot continue without an external fix, unavailable dependency, or failed required check.
- `needs-input` — a user decision or approval is required before safe progress.
- `handed-off` — current skill stopped because another skill owns the next required step.

```text
[status]
skill: <b-skill-name>
state: complete | blocked | needs-input | handed-off
artifacts: <comma-separated paths or 'none'>
next: <skill name or 'none'>
blockers: <one-line list or 'none'>
confidence: high | medium | low — <reason>   (omit when high and evidence is direct)
```

For trivial runs (a one-line answer, a tiny edit), the block can be omitted.

### Handoff envelope

When a skill hands off to another skill, emit this fenced block in chat **before** invoking the next skill:

```text
[handoff]
source: <current skill>
goal: <one-line goal for the next skill>
decisions: <confirmed decisions or 'none'>
assumptions: <open assumptions or 'none'>
files: <relevant paths or 'none'>
verification: <expected check or 'none'>
blockers: <known blockers or 'none'>
next-skill: <b-skill-name>
```

### Standard report shape

For non-trivial implementation, debug, test, refactor, review, or research work, final responses include:
- answer, action, or findings first
- verification evidence
- blockers or skipped checks
- confidence signal (§3) when evidence is incomplete
- the natural next action
- the skill-exit status block

---

## 10. Cross-cutting decisions

### Test failure vs runtime bug

Owned here so `b-test` and `b-debug` agree. Use this table when a test is red:

| Signal | Lane |
|---|---|
| Assertion mismatch and production behavior is confirmed correct | `b-test` — update the test |
| Missing mock, fixture, setup, async/await, leaked state, snapshot drift after intentional change | `b-test` |
| Production behavior is uncertain, ambiguous, or under dispute | `b-debug` — confirm root cause first |
| Test reproduces a real reported symptom | `b-debug` |
| Newly added test exposes pre-existing wrong behavior | `b-debug` |
| Flaky test (passes on rerun without code change) | `b-test` — diagnose flake source; if root cause is a real race or timing bug in product code, switch to `b-debug` |

Never modify production code purely because a test is red. Never modify an assertion, snapshot, or golden file without confirming the intended behavior first.

### Snapshot confirmation procedure

1. State the intended new behavior in one sentence.
2. Point to the source change or product decision that justifies it.
3. Then update the snapshot.

### Flake handling

Rerun the suspected test up to 2 times in isolation. If it passes some runs and fails others without any code change, mark it `flaky`, capture the failing output under `/tmp/opencode/b-skills/b-test/`, and investigate ordering, shared state, async timing, or external time/network dependence before either skipping or rewriting it.

### DOM-unit vs browser-flow boundary

- jsdom, happy-dom, React Testing Library, Vue Test Utils, Svelte testing-library, and any test that renders components without launching a real browser → `b-test`.
- Playwright, Cypress, WebdriverIO, Puppeteer, or anything driving a real Chromium/Firefox/WebKit instance → `b-e2e`.
- A test file that boots Playwright but is invoked through the unit-test runner still counts as `b-e2e` because a real browser is launched.

### Self-review vs reviewing-someone-else's-code

`/b-review` handles both. The skill must state which mode it is in:
- **Self-review:** assume author bias. Be harsher on "obviously correct" assumptions; verify the spec the author claims to satisfy.
- **External review:** assume the author cannot answer follow-ups. Be explicit about what would block the merge vs what is style.

---

## 11. Session lifecycle

### Session-start preflight (run once at first non-trivial action)

1. `git status --short` — note dirty state; preserve unrelated changes (§6).
2. Check for an approved plan under `.opencode/b-skills/b-plan/` matching the current request.
3. Confirm MCP availability lazily on first use.
4. Acknowledge dirty state only when it could affect the request.

### Crash/resume

- If a prior session left a partially complete run directory under `.opencode/b-skills/<skill>/<run-id>/`, resume from its manifest's last `complete` artifact rather than restarting.
- If no manifest exists, treat the directory as orphaned; do not delete it without asking.
- For saved plans, use the staleness gate (§2) to decide whether to resume or re-plan.

### Cross-skill conventions

- Skill descriptions cover **intent and disambiguation only**. Trigger keywords live in §1, not duplicated in every skill description.
- Skills must not redefine: severity, risk, "non-trivial," "small direct request," iteration cap, onboarding rule, privacy gate, confidence signal, run-id format, artifact paths, slug algorithm, test-vs-bug decision, DOM/browser boundary, manifest schema, status block, or handoff envelope. Reference §3, §4, §6, §7, §8, §9, or §10 as needed.
- A skill should switch to another skill only on a real stop/block condition — not for optional enrichment the current skill can finish inline with bounded evidence.
