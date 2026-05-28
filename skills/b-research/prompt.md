# b-research

$ARGUMENTS

Answer external-knowledge questions at the lightest reliable depth, with fetched-source evidence.

## When to use

- Library, framework, SDK, API, config, method signature, setup, migration, or capability questions.
- Comparisons, deep dives, cited reports, recency-sensitive topics, or multi-source synthesis.
- Questions about known URLs, local docs, PDFs, spreadsheets, or other source material when the suite can extract them reliably.

## When NOT to use

- Runtime tracing -> use **b-debug**.
- Planning/sequencing work -> use **b-plan**.
- Changed-code review -> use **b-review**.
- The repo itself can answer the question with one local lookup/read.
- The active skill needs only ≤ 1 narrow inline lookup (one method sig, one config key) — handle inline; route here when ≥ 2 distinct questions or deep extraction needed. See `{{runtime_reference_root}}/contract/10-decisions.md` for the threshold.

## Tools required

- `context7-docs` (primary for library/framework API lookups)
- `brave-search` (open-web discovery for unknown URLs, recent sources, and comparisons)
- `firecrawl-extraction` (known URLs and local documents when extraction is available)
- `firecrawl-extended` *(optional, for site maps or structured fields)*
- `firecrawl-deep` *(last resort; explicit approval required)*


## Steps

### Step 1 - Classify the question and any provided sources

Default to the lightest authoritative source. Do not ask the user to choose between a quick lookup and deep research; Step 3 handles auto-deepening when first evidence is stale, contradictory, non-authoritative, or indirect. Auto-deepening stops at the extraction tier; `firecrawl-deep` never triggers automatically and always requires explicit approval.

If the user provides a URL, file, or document, classify it before extraction: public URL, internal/private URL, local plain-text source, local rich document, or likely internal document. Read `{{runtime_reference_root}}/contract/06-safety.md` before sending internal/private URLs, local rich documents, or likely internal documents to external extraction unless the user already approved that exact source class for this run. Prefer structured extraction or query for specific fields, parameters, prices, tables, or lists; use full markdown when full-page understanding, summarization, or quoted context is needed.

If the user provides a local document and extraction is unavailable, fall back only for plain-text, Markdown, or HTML sources that local tools can read directly. For PDFs, spreadsheets, DOCX files, or other rich binaries, stop and surface the limitation instead of guessing.

### Step 2 - Pin version when material

For APIs, config keys, migrations, method signatures, or code examples, pin library version from the closest manifest and lockfile before Context7. If version is floating, absent, conflicting, or docs mismatch the pinned version, state the limitation and lower confidence or ask when it blocks correctness.

Skip pinning when the question is conceptual and version is not material.

### Step 3 - Gather evidence

Read `{{runtime_reference_root}}/contract/04-tool-model.md` before choosing MCP/search/extraction depth. Use Context7 first for library/framework APIs when it can match the pinned version; otherwise discover authoritative pages, then extract the highest-signal source. Search before extracting when the authoritative URL is unknown, and extract only the highest-signal source(s) needed for the answer. Prefer official docs, source repos, release notes, standards, and vendor materials over blogs or tutorials.

For recency-sensitive questions, read `{{runtime_reference_root}}/contract/05-evidence.md` before using freshness labels or citations. Use the `brave-search` news path before extraction and include `as of <date>` or source publication dates in the answer. Use Brave to shortlist unknown official URLs, recent advisories/release notes, or comparison sources before extraction. Use image search only when visual evidence is material to the answer.

For security, licensing, pricing, breaking migrations, or production-impacting compatibility, require primary vendor or source-repo evidence when available and include the evidence date. If only secondary sources are available, label the limitation and lower confidence.

Auto-deepen when first evidence is stale, contradictory, non-authoritative, or indirect. Use search snippets only for discovery unless explicitly labeled snippet-only with low confidence.

Use `firecrawl-extended` only for maps or structured fields. Read `{{runtime_reference_root}}/contract/04-tool-model.md` and `{{runtime_reference_root}}/contract/06-safety.md` before using `firecrawl-deep`; the deep tier always requires explicit per-run approval per §4 carve-out rules and never auto-triggers.

### Step 4 - Resolve conflicts and synthesize

Prefer the source matching the pinned version, then publisher docs over third-party tutorials. If authoritative sources still disagree, present both and lower confidence.

Answer only from gathered evidence. Include limitations for freshness, access, gated sources, or single-source answers. Cite only fetched/session-provided sources.

## Output format

Depth is auto-determined by Steps 1–3; no user selection required.

Lookup (shallow): direct answer, optional minimal example, source, confidence when not high.

Research (deep): answer, key findings, limitations, sources, confidence.


## Rules

- Never ask the user to choose lookup vs research; decide and auto-deepen.
- Use the lightest depth that answers correctly.
- Pin versions when they affect the answer.
- Do not bypass gated sources or paste secrets into fetches. Read `{{runtime_reference_root}}/contract/04-tool-model.md` for `firecrawl-deep` carve-out rules; the deep tier always requires explicit approval.
- Do not send internal/private URLs, local rich documents, or likely internal documents to external extraction without explicit approval.
- Prefer 2-4 authoritative sources over long weak lists.
- Use limitations and confidence labels instead of filling gaps from memory.
- Cited URLs must come from fetched or user-provided sources in this session.
- Include `as of <date>` for recency-sensitive, pricing, security, licensing, compatibility, and migration answers.
- Do not infer document substance from filenames, metadata, or snippets when a rich local document could not be extracted.
- Read `{{runtime_reference_root}}/contract/09-output.md` before closing a non-trivial research run with a status block or saved report.
