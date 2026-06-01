## 4. Tool model

Use the lightest reliable tool. Native local tools (`rg`, `fd`/`fdfind`, `jq`, exact file reads, shell commands) stay first for exact local evidence. MCP bundles are lazy capabilities: activate one only when it closes the next evidence gap.

### Bundle reference

| Bundle name | Server | Role |
|---|---|---|
| `serena-symbol-toolkit` | `serena` | Symbol discovery, references, diagnostics, edits |
| `context7-docs` | `context7` | Library/framework documentation lookup |
| `brave-search` | `brave-search` | Open-web, news, and image discovery |
| `firecrawl-extraction` | `firecrawl` | Known URL and local document extraction |
| `firecrawl-extended` | `firecrawl` | Site maps and structured field extraction |
| `firecrawl-deep` | `firecrawl` | Interaction and agent research, approval-gated |
| `playwright-browser-operator` | `playwright` | Live browser, DOM, visual, and e2e actions |

| Task shape | First choice | Then narrow with |
|---|---|---|
| Browser/DOM/visual/e2e evidence | Supplied/CI evidence or existing repo scripts when they answer the question | `playwright-browser-operator` when live-browser evidence is needed and safety-gated; `firecrawl-extraction` only for static known remote pages |

### MCP bundles

The bundle table is the canonical MCP bundle definition list. Skills must reference these names rather than inventing their own per-tool bundle labels.

#### `serena-symbol-toolkit`

#### `context7-docs`

#### `brave-search`

#### `firecrawl-extraction`

#### `firecrawl-extended`

#### `firecrawl-deep`

#### `playwright-browser-operator`

### Selection rules

- Local strings, prose, config, manifests, git state, and commands: native tools.
- Exact symbols, declarations, references, diagnostics, and symbol edits: Serena first when the language/server is reliable; use native search and `apply_patch` for Bash, YAML, Markdown, and DSLs.
- Library/framework facts: Context7 after pinning the closest manifest or lockfile version; fall back to official docs discovered by search.
- Unknown official URLs or current public facts: Brave first, then Firecrawl only for the pages whose substance matters.
- Known URL or local document substance: Firecrawl extraction; use structured extraction for fields, tables, prices, API params, or lists.
- Browser, DOM, visual, screenshot, or e2e evidence: Supplied/CI evidence or existing repo scripts first, then `b-browser` with Playwright when live evidence is needed.

Do not escalate to another MCP when the current authoritative source answered. Search before extracting when the URL is unknown. Reuse recent source results instead of re-fetching.

### Bundle notes

- `serena-symbol-toolkit`: initialize only when symbol-aware work is needed. Ask before persistent memory writes during review-only/no-mutation work.
- `context7-docs`: use `resolve-library-id`, then `query-docs`; ask when versions conflict.
- `firecrawl-extended`: use only for site maps or structured extraction.
- `firecrawl-deep`: last resort. Requires explicit per-invocation approval unless the user grants a run-scoped numeric cap; record the cap in `notes` or `carve-outs`.
- `playwright-browser-operator`: belongs to `b-browser` unless another skill hands off for browser evidence. Prefer snapshots and ordinary actions over unsafe arbitrary-code browser execution; unsafe code requires explicit approval, trusted target, and a reason ordinary actions cannot answer.

### Fallback ladder

- Serena unavailable -> native search/reads plus `apply_patch`; treat renames and safe deletes as higher risk.
- Context7 unavailable -> official docs via Brave plus Firecrawl extraction.
- Firecrawl unavailable on known URL -> search snippets only; label snippet-only evidence and lower confidence.
- Firecrawl unavailable on local plain text/Markdown/HTML -> native local reads.
- Firecrawl unavailable on local PDF/spreadsheet/DOCX/rich binary -> stop with `[degraded: firecrawl-extraction unavailable]`; do not infer from filenames.
- Playwright unavailable -> supplied evidence, existing repo commands, or Firecrawl for static pages when sufficient; otherwise label degraded or stop with `cause: tool_unavailable`.

When fallback changes the intended evidence or verification path, tag the affected step or finding as `[degraded: <reason>]`.

### Global guards

- Do not invent MCP bundle names.
- Do not write outside §8 paths.
- Do not redefine approval templates, fallback labels, iteration caps, severity, risk, confidence, slug/run-id formats, manifest schema, status blocks, or handoff envelopes.
- Around 12 MCP calls in one skill run, summarize remaining unknowns before continuing.

---
