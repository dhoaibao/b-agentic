---
name: b-research
description: >
  External knowledge, from quick lookup to multi-source synthesis, for
  library/framework docs, API facts, config keys, method signatures,
  comparisons, deep dives, or recency-sensitive topics. Auto-detects
  depth; never asks the user to pick a mode. Unlike b-debug or b-plan, it
  fetches docs and web information rather than tracing code or choosing
  implementation.
argument-hint: "[question-or-source]"
---

<!-- Generated from skills/registry.yaml and skills/b-research/prompt.md. Edit those sources, not this file. -->

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

If the user provides a URL/file/document, classify it as public URL, internal/private URL, local plain text, local rich document, or likely internal document. Read `../../b-agentic/references/contract/06-safety.md` before external extraction of internal/private URLs, rich documents, or likely internal documents unless already approved.

### Step 2 - Pin version when material

For APIs, config keys, migrations, method signatures, or code examples, pin the closest manifest and lockfile version before Context7. State limitations when versions float, conflict, or docs mismatch. Skip pinning for conceptual questions.

### Step 3 - Gather evidence

Use Context7 first for pinned library/framework APIs when it can answer. Otherwise search to discover authoritative URLs, then extract only the highest-signal source(s). Prefer official docs, source repos, release notes, standards, and vendor materials.

For recency-sensitive topics, use news/search before extraction and include `as of <date>` or publication dates. For security, licensing, pricing, breaking migrations, or production-impacting compatibility, require primary evidence when available.

Use `firecrawl-extended` only for maps or structured fields. Use `firecrawl-deep` only with explicit per-run approval per §4 carve-out rules.

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
