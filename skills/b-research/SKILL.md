---
name: b-research
description: >
  External knowledge, from quick lookup to multi-source synthesis. ALWAYS
  invoke when the user asks for library/framework docs, API facts, config
  keys, method signatures, comparisons, deep dives, or recency-sensitive
  topics. Auto-detects depth; never asks the user to pick a mode. Unlike
  b-debug or b-plan, it fetches docs and web information rather than tracing
  code or choosing implementation.
compatibility: opencode
metadata:
  suite: b-skills
---

# b-research

$ARGUMENTS

Answer external-knowledge questions at the lightest reliable depth, with fetched-source evidence.

## When to use

- Library, framework, SDK, API, config, method signature, setup, migration, or capability questions.
- Comparisons, deep dives, cited reports, recency-sensitive topics, or multi-source synthesis.
- Questions about known URLs, local docs, PDFs, spreadsheets, or other source material.

## When NOT to use

- Runtime tracing -> use **b-debug**.
- Planning/sequencing work -> use **b-plan**.
- Changed-code review -> use **b-review**.
- The repo itself can answer the question with one local lookup/read.

## Tools required

- `context7-docs` (primary for library/framework API lookups)
- `brave-discovery` (page discovery)
- `firecrawl-extraction` (known URLs and local documents)
- `firecrawl-extended` *(optional, for site maps or structured fields)*
- `firecrawl-deep` *(last resort; approval-gated by `AGENTS.md`)*

Fallbacks: `AGENTS.md` section 4. Graceful degradation: partial; synthesis is weaker without extraction.

## Steps

### Step 1 - Choose lookup or research

- **Lookup:** one fact, signature, config key, yes/no capability, or tiny example.
- **Research:** multi-source synthesis, comparison, recency-sensitive answer, or contradictions.

If the user provides a URL/file/document and one bounded source is likely sufficient, extract it directly.

### Step 2 - Pin version when material

For APIs, config keys, migrations, method signatures, or code examples, pin library version from the closest manifest and lockfile before Context7. If version is floating, absent, conflicting, or docs mismatch the pinned version, state the limitation and lower confidence or ask when it blocks correctness.

Skip pinning when the question is conceptual and version is not material.

### Step 3 - Gather evidence

Use Context7 first for library/framework APIs when it can match the pinned version; otherwise discover authoritative pages, then extract the highest-signal source. Prefer official docs, source repos, release notes, standards, and vendor materials over blogs or tutorials.

For recency-sensitive questions, use the news search path before extraction and include `as of <date>` or source publication dates in the answer. Use image search only when visual evidence is material to the answer.

For security, licensing, pricing, breaking migrations, or production-impacting compatibility, require primary vendor or source-repo evidence when available and include the evidence date. If only secondary sources are available, label the limitation and lower confidence.

Auto-deepen when first evidence is stale, contradictory, non-authoritative, or indirect. Use search snippets only for discovery unless explicitly labeled snippet-only with low confidence.

Use `firecrawl-extended` only for maps or structured fields. Use `firecrawl-deep` only after lower tiers fail and approval is granted. Respect the public-web privacy gate on every external call.

### Step 4 - Resolve conflicts and synthesize

Prefer the source matching the pinned version, then publisher docs over third-party tutorials. If authoritative sources still disagree, present both and lower confidence.

Answer only from gathered evidence. Include limitations for freshness, access, gated sources, or single-source answers. Cite only fetched/session-provided sources.

## Output format

Lookup: direct answer, optional minimal example, source, confidence when not high.

Research: answer, key findings, limitations, sources, confidence.

## Rules

- Never ask the user to choose lookup vs research; decide and auto-deepen.
- Use the lightest depth that answers correctly.
- Pin versions when they affect the answer.
- Do not bypass gated sources or paste secrets into fetches.
- Prefer 2-4 authoritative sources over long weak lists.
- Use limitations and confidence labels instead of filling gaps from memory.
- Cited URLs must come from fetched or user-provided sources in this session.
- Include `as of <date>` for recency-sensitive, pricing, security, licensing, compatibility, and migration answers.
