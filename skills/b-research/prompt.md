# b-research

$ARGUMENTS

Answer external-knowledge questions at the lightest reliable depth, with fetched-source evidence.

## When to use

- Library, framework, SDK, API, config, method signature, setup, migration, or capability questions.
- Comparisons, deep dives, cited reports, recency-sensitive topics, or multi-source synthesis.
- Questions about known URLs, local docs, PDFs, spreadsheets, or other source material when extraction is needed.

## When NOT to use

- Runtime tracing -> use **b-debug**.
- Planning/sequencing work -> use **b-plan**.
- Changed-code review -> use **b-review**.
- The repo itself can answer the question with one local lookup/read.
- The active skill needs only one narrow inline lookup.

## Tools required

- `context7-docs` (primary for library/framework API lookups)
- `brave-search` (open-web discovery for unknown URLs, recent sources, and comparisons)
- `firecrawl-extraction` (known URLs and local documents)
- `firecrawl-extended` *(optional, for site maps or structured fields)*
- `firecrawl-deep` *(last resort; explicit approval required)*

## Steps

### Step 1 - Classify question and sources

Default to the lightest authoritative source. Auto-deepen when evidence is stale, contradictory, non-authoritative, or indirect; never auto-trigger `firecrawl-deep`.

If the user provides a URL/file/document, classify it as public URL, internal/private URL, local plain text, local rich document, or likely internal document. Read `{{runtime_reference_root}}/contract/safety-tools.md` before external extraction of internal/private URLs, rich documents, or likely internal documents unless already approved.

### Step 2 - Pin version when material

For APIs, config keys, migrations, method signatures, or code examples, pin the closest manifest and lockfile version before Context7. State limitations when versions float, conflict, or docs mismatch. Skip pinning for conceptual questions.

### Step 3 - Gather evidence

**Context7 workflow for library/framework APIs:**
1. `resolve-library-id` with the exact official library name to get the Context7-compatible ID.
2. `query-docs` with that ID and a specific, detailed question.
3. If Context7 returns nothing relevant, fall back to Brave search for authoritative URLs, then extract.

Use Context7 first for pinned library/framework APIs when it can answer. Otherwise search to discover authoritative URLs, then extract only the highest-signal source(s). Prefer official docs, source repos, release notes, standards, and vendor materials.

For recency-sensitive topics, use news/search before extraction and include `as of <date>` or publication dates. For security, licensing, pricing, breaking migrations, or production-impacting compatibility, require primary evidence when available.

Use `firecrawl-extended` only for maps or structured fields. Auto-depth stops at `firecrawl-extended`. Do not escalate to `firecrawl-deep` automatically — it requires an explicit approval ask before use:

```text
[approval] firecrawl-deep agent research
Effect: runs an autonomous web agent; may fetch many pages, incur significant credits, and take minutes.
Proceed? (y/n)
```

Only proceed with `firecrawl-deep` after an affirmative response in the current session, or when the user has pre-authorized it with a run-scoped numeric cap recorded in the status/handoff.

### Step 4 - Synthesize

Prefer pinned-version sources, then publisher docs over third-party tutorials. If authoritative sources disagree, present both and lower confidence. Answer only from gathered evidence and cite fetched/session-provided sources.

## Output format

Lookup: direct answer, optional minimal example, source, confidence when not high.

Research: answer, key findings, limitations, sources, confidence.

## Rules

- Never ask the user to choose lookup vs research; decide and auto-deepen.
- Use the lightest depth that answers correctly.
- Prefer 2-4 authoritative sources over long weak lists.
- Hand off code changes to **b-implement**, tracing to **b-debug**, and planning to **b-plan**.
