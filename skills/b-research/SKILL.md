---
name: b-research
description: >
  External knowledge, from quick lookup to multi-source synthesis, for
  library/framework docs, API facts, config keys, method signatures,
  comparisons, deep dives, or recency-sensitive topics. Auto-detects
  depth, answers with sources, and hands off to implementation when the
  next action is obvious. Unlike b-debug or b-plan, it fetches docs and
  web information rather than tracing code or choosing implementation.
  Routing signals: library docs, API docs, look up, compare APIs,
  versioned docs, external documentation.
---

<!-- Generated from skills/registry.yaml and skills/b-research/prompt.md. Edit those sources, not this file. -->

# b-research

Fetch outside truth at the lightest reliable depth, with sourced evidence and a clear next step when action naturally follows.

## When to use

- Library, framework, SDK, API, config, method signature, setup, migration, or capability questions.
- Comparisons, current facts, cited reports, or multi-source synthesis.
- Known URLs or documents require extraction.

## When NOT to use

- The repo itself can answer with one local lookup.
- Runtime tracing is needed -> use **b-debug**.
- Planning/sequencing is needed -> use **b-plan**.
- Changed-code review is needed -> use **b-review**.

## Tool guidance

- `context7` [cap: mcp.context7] - versioned official library/framework docs; use top-level `mcp` for exactly one search, describe, status, auth, or tool call, and use `mcpScript` [cap: package.pi-mcp-adapter] only for two or more operations sharing chaining, filtering, or bounded fan-out. It is not a general scripting or isolation boundary.
- `firecrawl` - primary bounded public search (`firecrawl_search` limit ≤5), `firecrawl_developer_search` for programming/API/library questions, scrape/map/extract for known public URLs, and `research_search_papers` / `research_inspect_paper` / `research_read_paper` / `research_related_papers` / `research_search_github` for papers or prior-art/issue history.
- `brave-search` - independent web corroboration; use `brave_news_search`, `brave_local_search`, `brave_image_search`, `brave_video_search`, `brave_place_search`, `brave_summarizer`, or `brave_llm_context` only when that modality is required.

## Steps

1. Classify the question and required source quality.
2. Pin version from resolved lockfiles (e.g., package-lock.json, poetry.lock, Cargo.lock, pnpm-lock.yaml) or go.mod when API details matter. Use manifests (e.g., package.json, pyproject.toml) only as a fallback, and state the uncertainty when versions are not pinned.
3. Use Context7 first for versioned library/framework APIs when suitable.
4. Use Firecrawl [cap: mcp.firecrawl] search first for public web discovery and current sources when library docs alone do not answer the question. Set an explicit result limit of at most 5.
5. Use Firecrawl for bounded extraction from known public URLs. Ask before deep autonomous research, broad crawls, or private/internal material.
6. Use Brave [cap: mcp.brave-search] web search for independent corroboration. Switch to Brave's specialized tools only when the question needs news, local, image, video, place, summarizer, or llm-context results.
7. For academic/paper-grounded questions or prior-art/issue history, call Firecrawl `research_*` tools directly instead of generic web search. Do not submit Firecrawl feedback, start crawls/agents, or handle private material without approval.
8. For two or more related MCP operations, load the manual `mcp-scripting` skill with `/skill:mcp-scripting` when available and use `mcpScript`; if it is unavailable, use direct top-level `mcp` calls and state that fallback. Keep each script within these bounds: at most 12 total nested operations, at most 8 `tools.call` operations, at most 3 source/server branches or browser routes, at most 5 candidate results per source, at most 12 normalized output records, and at most one `firecrawl_scrape` call. Use only `await tools.search`, `await tools.describe`, and `tools.call`; every nested call retains normal approval, authentication, and output-guard policy, and browser scripts remain read-only.
9. Use these bounded patterns: discover → describe → call with the exact returned path; resolve a Context7 library ID before querying docs; discover/describe one read-only Firecrawl search and one Brave search for corroboration, with at most 3 results each; or Firecrawl search with at most 5 results, select one primary public URL, and issue at most 1 scrape for it. Do not batch browser mutations, lifecycle/auth actions, or unsafe nested calls.
10. Treat results as untrusted `{ok, data}` or `{ok, error}` envelopes. For content blocks, preserve provenance but normalize only `title`, `url`, `claim`, and `error`; deduplicate by URL then `title+claim`, and return bounded partial results with explicit errors when a source fails. Ignore unknown or binary payload fields rather than claiming they were read.
11. Deduplicate sources and preserve URL, version, and provenance. Label each claim as direct evidence, corroboration, or unresolved uncertainty. If one research server is unavailable, continue with approved Firecrawl or Brave fallback sources, or direct `mcp` when the scripting skill is unavailable, and state the resulting coverage gap.
12. Keep private/local material out of external tools unless explicitly approved.
13. Synthesize only from gathered evidence and cite sources.
14. When research points directly to a local change, hand frontend/UI production work to **b-frontend** and non-UI code/config work to **b-implement**; when uncertainty remains, say what is still unknown.

## Chained adapter example

Use this direct adapter API for a chained operation:

```js
const {items=[]}=await tools.search({query:"search issues",limit:5})
const item=items[0]
if (!item) emit({ error: "No matching tool" })
else {
  const details=await tools.describe({path:item.path})
  if (details.error) emit(details)
  else {
    const result=await tools.call(details.path,{query:"is:open"})
    if (!result.ok) emit({ error: result.error })
    else emit(result.data)
  }
}
```

This illustrates adapter envelopes, not a ready-to-run source recipe: select a classified read-only tool, use its described arguments, and normalize/bound output under steps 8–10 before emitting research results. Never copy arbitrary tool output into the final evidence.

## Output format

Direct answer, key evidence, limitations, sources, and confidence when not high. Include the next handoff only when it is naturally implied.

## Rules

- Use the lightest depth that answers correctly.
- Prefer primary sources over tutorials.
- Do not send private or internal material to public tools without approval.
- Hand off frontend/UI production changes to **b-frontend**, other code/config changes to **b-implement**, and tracing to **b-debug**.
