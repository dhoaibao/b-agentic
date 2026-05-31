## 4. Tool model

### Bundle to server quick reference

Skills reference bundles by conceptual name; the actual MCP server name is in the `Server` column.

| Bundle name | Server | Role |
|---|---|---|
| `serena-symbol-toolkit` | `serena` | Symbol discovery, references, diagnostics, edits |
| `context7-docs` | `context7` | Library/framework documentation lookup |
| `brave-search` | `brave-search` | Open-web and news discovery |
| `firecrawl-extraction` | `firecrawl` | Known URL and local document extraction (default tier) |
| `firecrawl-extended` | `firecrawl` | Site maps and structured field extraction (conditional tier) |
| `firecrawl-deep` | `firecrawl` | Deep interaction and agent research (approval-gated tier) |
| `playwright-browser-operator` | `playwright` | Live browser/DOM/visual/e2e actions |

### Tool priority

Use the lightest reliable tool. Native local tools such as exact file reads, `rg`, `fd`/`fdfind`, `grep`, `find`, `jq`, and `bash` stay first for exact strings, manifests, prose, config, and commands. MCP bundles are available capabilities, not default context sources; activate them only when they close the next evidence gap. Native tools are not MCP bundles; skill files may name them separately when they are part of the workflow.

| Task shape | First choice | Then narrow with |
|---|---|---|
| Exact symbol discovery, declarations, references, symbol edits | `serena-symbol-toolkit` | Native tools + `apply_patch` |
| Library/framework docs | `context7-docs` | `b-research` |
| Web/news/image discovery and unknown-URL source shortlisting | `brave-search` | `firecrawl-extraction` for source content |
| Known URL extraction | `firecrawl-extraction` | `firecrawl-extended`, then `firecrawl-deep` (approval) |
| Local document extraction | `firecrawl-extraction` (`firecrawl_parse`) | `firecrawl-extraction` (`firecrawl_scrape`) only if already hosted |
| Browser/DOM/visual/e2e evidence | Supplied/CI evidence or existing repo scripts when they answer the question | `playwright-browser-operator` when live-browser evidence is needed and safety-gated; `firecrawl-extraction` only for static known remote pages |

### Selective leverage by lane

Use deeper MCP guidance where it materially improves evidence quality or coordination, not as a blanket default:

- **High-ROI lanes:** `b-plan` for cross-module or route/tool/consumer scoping, `b-implement` for shared/exported-boundary changes or symbol-heavy edits, `b-review` for blast-radius and shared-risk inspection, `b-research` for external docs/facts, and `b-browser` for browser/DOM/visual evidence.
- **Native-first lanes:** small direct requests, one-file docs/config/prose edits, exact local string checks, obvious single-symbol edits, and ordinary git/status/diff inspection. Prefer `rg`, `fd`/`fdfind`, and `jq` when they are available and materially faster than broader fallbacks.
- **Escalation rule:** if local evidence already answers the next decision, do not add MCP calls just because the bundle exists.
- **Runtime readiness rule:** installers and runtime docs may explain what still needs user setup, but availability messaging does not justify auto-running onboarding, indexing, or other user-scope setup steps.

### Shell tool quick reference

The installer lists these in core (`rg`, `fd`/`fdfind`, `jq`) and optional (`bat`/`batcat`, `yq`, `git-delta`, `gh`, `tmux`, `fzf`) tiers. Use them when available and faster than broader fallbacks.

| Tool | When to use | Agent note | Conditionality |
|---|---|---|---|
| `yq` | Parse/query YAML registries and configs | YAML counterpart to `jq`; check `command -v yq` | Optional |
| `gh` | CI status, PR ops, issue queries, auth checks | Prefer over manual `curl` GitHub API calls; check `gh auth status` before use. Required for `b-ship`; optional otherwise | Optional / `b-ship` required |
| `git-delta` | Syntax-highlighted diff display | When set as `core.pager`, auto-applies to `git diff`; use `GIT_PAGER=cat git diff` or `git --no-pager diff` for raw machine-readable output | Optional |
| `bat`/`batcat` | Syntax-highlighted file display for user-visible output | Agents read files directly; use only when producing visible shell output for the user | Optional |
| `fzf` | Non-interactive `--filter` scoring | `fzf --filter "<q>" < list` only; never pipe to interactive fzf in agent workflows; prefer `rg`/`grep` unless scoring is needed | Optional |
| `tmux` | Multi-hour detached background jobs | For short tasks prefer direct background (`&`) or shell `run_in_background`; `tmux new-session -d -s <n>` for long-lived sessions | Optional |

### Tool selection rules

- Single-file or local-only task: use native tools or Serena for exact symbols.
- Known symbol edit: Serena first.
- Planning or review question with no shared/public boundary: stay native or Serena-first.
- Body-last symbol workflow: inspect overviews, declarations, diagnostics, or references before full symbol bodies; request bodies only when needed to decide or edit.
- Do not escalate to a second MCP when the first authoritative source already answered.
- Pick the cheapest discovery tool that closes the next question; there is no required ordering among Serena discovery tools.

### MCP bundles

Skills reference MCP bundles by name instead of repeating per-tool MCP lists. Native tools such as Glob/Grep/Read/Bash are not MCP bundles and may be listed separately in a skill when they are workflow requirements.

#### `serena-symbol-toolkit`

- **Server:** `serena`
- **Session init:** once per session, only when symbol-aware work first becomes necessary: `check_onboarding_performed`, then `onboarding` if needed. If onboarding would require persistent memory writes during a review-only/no-mutation run, skip Serena unless symbol evidence is necessary; when it is necessary, ask before writing persistent memories and keep summaries free of secrets or private data.
- **Discovery:** `find_symbol`, `get_symbols_overview`, `find_referencing_symbols`, `find_declaration`, `find_implementations`, `search_for_pattern`.
- **Verification:** `get_diagnostics_for_file`.
- **Edits:** `replace_symbol_body`, `insert_before_symbol`, `insert_after_symbol`, `rename_symbol`, `safe_delete_symbol`.
- **LSP caveat:** strong for TS/JS, Python, and similar; weak for Bash, YAML, Markdown, Lua, and many DSLs. Treat non-LSP renames/safe-deletes/diagnostics as **not authoritative**; widen verification. When Serena is weak, fall back to `rg`/native reads and `apply_patch` for discovery and edits in Bash, YAML, Markdown, and similar non-LSP files.

#### `context7-docs`

- **Server:** `context7`
- **Tools:** `resolve-library-id`, `query-docs`.
- **Version pinning:** before querying, pin from manifests **and lockfiles** (`package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `poetry.lock`, `uv.lock`, `go.sum`, `Cargo.lock`, etc.). In monorepos, use the closest workspace. Ask when versions conflict.
- **Fallback:** if Context7 cannot answer, prefer the library's own documentation URL pattern (e.g., `<library>.dev/docs/`) over generic web search.

#### `brave-search`

- **Server:** `brave-search`
- **Tools:** `brave_web_search`, plus `brave_news_search` for recency-sensitive questions and `brave_image_search` when visual evidence is material.
- **Role:** open-web discovery only. Use it to find unknown official URLs, recent advisories/release notes, and comparison sources, then pass discovered URLs to `firecrawl-extraction` when the final answer depends on page substance rather than result metadata.

#### `firecrawl-extraction` (default tier)

- **Server:** `firecrawl`
- **Tools:** `firecrawl_scrape`, `firecrawl_parse`.
- **Use for:** content extraction from a known URL or local document.
- **Format selection:** for specific data points, fields, prices, API parameters, tables, or lists, prefer structured extraction or query over full markdown. Use full markdown only when full-page understanding, summarization, or quoted context is needed.

#### `firecrawl-extended` (conditional tier)

- **Tools:** `firecrawl_map`, `firecrawl_extract`.
- **Use only when** mapping a site's structure or extracting structured fields (prices, params, tables). Do not reach for these on plain content.

#### `firecrawl-deep` (last-resort tier, requires explicit user approval)

- **Tools:** `firecrawl_interact`, `firecrawl_agent`.
- **Cost warning:** can run for minutes and burn substantial credit. Exhaust lower tiers, then get approval per invocation by default. A user may grant a run-scoped, capped pre-authorization in lieu of per-invocation asks; see "Tool-use heuristics" in this section for the exact rules.

#### `playwright-browser-operator` (optional live-browser tier)

- **Server:** `playwright`.
- **Use only from:** `b-browser`, unless the user explicitly invokes another skill and that skill hands off to `b-browser` for browser evidence.
- **Use for:** live page navigation, accessibility snapshots, clicks, typing, form fills, screenshots, tabs, dialogs, console/network inspection, and storage-state assessment when browser/DOM/visual/e2e evidence cannot be satisfied by supplied evidence or existing repo scripts.
- **Default posture:** prefer accessibility snapshots and ordinary browser actions over arbitrary code execution. Do not use unsafe arbitrary-code tools such as `browser_run_code_unsafe` in the default workflow; require explicit approval, a trusted target, and a reason ordinary actions cannot answer the question.
- **State safety:** use ephemeral state by default. Persisted profile, cookie, localStorage, or storage-state reuse requires §6 approval, and real auth/session state must never be stored under a tracked worktree path.

### MCP availability and fallback ladder

Assume bundles are available; do not preflight. On failure, retry once narrower, then fall back and label the limitation.

**Fallback ladder:**
- `serena-symbol-toolkit` unavailable → native Glob/Grep/Read + `apply_patch`. Treat renames and safe-deletes as high-risk; widen verification.
- `context7-docs` unavailable → official-docs URL via `brave-search` + `firecrawl-extraction`.
- `firecrawl-extraction` unavailable on a known URL → search snippets only; mark the answer as snippet-only with `Confidence: low`.
- `firecrawl-extraction` unavailable on a local plain-text, Markdown, or HTML document → use native local reads and exact local tools.
- `firecrawl-extraction` unavailable on a local PDF, spreadsheet, DOCX, or other rich binary → stop with `[degraded: firecrawl-extraction unavailable]`; do not infer substance from filenames or metadata alone.
- `playwright-browser-operator` unavailable → use supplied evidence, existing repo-provided browser/DOM/visual/e2e commands, or known-URL Firecrawl extraction when that can answer the browser evidence question; otherwise label `[degraded: playwright-browser-operator unavailable]` or stop with `cause: tool_unavailable` when no approved evidence path exists.

### Fallback labeling

When fallback changes the intended tool path, evidence source, or verification route, tag the affected step or finding as `[degraded: <reason>]`.

### Tool-use heuristics

- Around **12 MCP calls** in one skill run, pause and summarize remaining unknowns before more discovery.
- Search before extract when the authoritative URL is unknown; extract only the highest-signal source(s) needed for the answer.
- Do not open a second tool-heavy thread until the current investigation, edit, or verification thread is closed or the user asks to expand scope.
- If sustained tool use is not increasing evidence quality, narrow the next check or stop and ask whether to continue.
- Classify failures before retry/fallback: unavailable, auth/permission, rate-limit, timeout, stale index/cache, unsupported content, malformed request. Retry only transient or fixable-by-narrowing failures; stop for auth failures.
- `firecrawl-deep` invocations require user approval **per invocation by default**. **Run-scoped pre-authorization carve-out:** the per-invocation default may be relaxed only when the user issues an explicit, scoped grant (e.g., "approved: use deep mode up to 3 times for this research pass") that names **both** (a) a numeric invocation cap and (b) the current run. Without an explicit cap, the carve-out is invalid and the per-invocation rule still applies. Record the granted cap in the status block `notes` and the handoff envelope `carve-outs` field; decrement on each use and surface the remaining count in the next status block. The carve-out expires when the run ends, when the cap is exhausted, or when the user revokes it — whichever comes first. The carve-out never overrides §6 safety gates (privacy, sensitive files, destructive actions).
- Reuse recently fetched URLs, docs, and symbol results instead of re-fetching them.
- The verification iteration cap (§7) still applies.

### Slash-command flags and modes

When a skill declares flags or modes, parse them before tool use. Unknown flags should not be ignored: ask once or continue only if the intended behavior is still unambiguous. For conflicting flags, prefer the safer or narrower mode and state the choice; if both modes would mutate state or change evidence requirements, ask.

Mode precedence is skill-specific, but the global default is: explicit user flag, explicit user prose, approved plan or handoff, then skill default. When a user requests multiple modes in one run, execute the evidence-gathering mode before the authoring or mutation mode unless the skill says otherwise.

### Run cost signal

When a non-trivial run consumes notable budget, include a one-line cost summary in the status block `notes` field:

`cost: serena=14, context7=1, firecrawl-deep=1, iterations=2/3`

Only include counters that were actually used. Skip entirely on trivial runs. This lets the next skill in a chain see whether to slow down before adding more tool work.

### Global bundle/path guards (runtime, not just maintainer norm)

- A skill **must not** invent a new MCP bundle name. Every bundle reference must resolve to a definition in this section.
- A skill **must not** write to a path outside §8. If a use case needs a new path, surface it as a `needs-input` blocker rather than picking one ad hoc.
- A skill **must not** redefine an approval template, fallback label, iteration cap, severity, risk, confidence signal, slug algorithm, run-id format, manifest schema, status block, or handoff envelope. Reference the canonical section.

---
