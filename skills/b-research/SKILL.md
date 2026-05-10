---
name: b-research
description: >
  External knowledge, from quick lookup to full research. ALWAYS invoke when the user says "research", "tìm hiểu", "deep dive", "so sánh", "tổng hợp", "lookup", "tra cứu nhanh", "what's the API for", "method signature of X", or "config key for Y". Auto-detects quick vs full mode. Unlike b-debug or b-plan, it fetches docs/web info instead of tracing code or choosing implementation.
compatibility: opencode
metadata:
  suite: b-skills
---

# b-research

$ARGUMENTS

One entry point for external knowledge. Detect whether the question is a quick lookup or full research, answer in the lightest mode that fits, and escalate automatically when the first pass is not enough.

If `$ARGUMENTS` is provided, treat it as the research question — proceed directly to Step 1. Do not ask the user to restate it.

## When to use

- Single-fact lookup: method signature, config key, yes/no capability, minimal example.
- Library/framework/SDK docs, setup, configuration, migration, feature support.
- Comparisons, deep dives, multi-source synthesis, or cited reports.
- User says: "tìm hiểu", "research", "deep dive", "so sánh", "tổng hợp", "lookup", "tra cứu nhanh", "what's the API for", "method signature of X", "config key for Y".

## When NOT to use

- Runtime bug or failure → use **b-debug**
- Need to decide what to build or sequence work → use **b-plan**
- Pre-PR correctness review → use **b-review**

## Tools required

- **Quick mode primary**: `resolve-library-id`, `query-docs` — from `context7` MCP server for library/framework API questions
- **Search**: `brave_web_search` — from `brave-search` MCP server
- **NEWS full mode**: `brave_news_search` — from `brave-search` MCP server
- **Full-mode page reads**: `firecrawl_scrape` — from `firecrawl` MCP server
- **Full-mode fallbacks**: `firecrawl_search`, `firecrawl_map`, `firecrawl_extract`, `firecrawl_crawl`, `firecrawl_check_crawl_status`
- **Conflict resolution**: `sequentialthinking` — from `sequential-thinking` MCP server *(optional)*
- **GitNexus is intentionally outside the `b-research` workflow.** This skill handles external knowledge only; repo-internal graph intelligence is not its responsibility.

If context7 is unavailable: continue with Brave for library questions.
If brave-search is unavailable:
- quick mode with a clear Context7 answer may still complete;
- otherwise stop and tell the user: `❌ brave-search MCP is not connected. Please check your MCP configuration.`
If firecrawl is unavailable:
- quick mode may still complete without scraping;
- full mode is blocked — tell the user: `❌ firecrawl MCP is not connected. Please check your MCP configuration.`
If sequential-thinking is unavailable: summarize conflicts inline as `Source A says X / Source B says Y / Best fit: Z`.

Graceful degradation: ⚠️ Partial — quick mode works with Context7 and/or Brave; full mode requires live search plus Firecrawl.

## Steps

### Step 1 — Detect mode

Choose the lightest mode that can answer correctly.

Use **quick mode** when the question is likely answerable in 1–3 sentences or a tiny code snippet:
- method signature
- config key or flag
- yes/no capability
- minimal example
- one specific API behavior

Use **full mode** when the question needs:
- comparisons
- multiple sources
- citations or report output
- recency or news
- reading full pages or extracting structured details from pages

If uncertain, start in quick mode and escalate automatically to full mode if the answer needs more than 2 tool calls, more than 1 source, or any page scraping.

### Step 2 — Quick mode

1. Classify the question:
   - **Library API / SDK / framework** → Context7 first
   - **General tool / config / web fact** → Brave first
2. For library questions:
   - Call `resolve-library-id`
   - Call `query-docs` with the exact feature/question
   - If Context7 gives a clear answer, stop and return the quick output format
3. If Context7 has no clear answer, or the question is not library-specific:
   - Run one `brave_web_search` with the exact question
   - Return the answer directly if one high-confidence result is enough
4. Do not scrape, crawl, or synthesize in quick mode.
5. If a confident direct answer is still not possible, continue to Step 3 instead of telling the user to switch skills.

### Step 3 — Full-mode type classification

Classify the query into one of four full-mode types:

| Type | Signals | Strategy |
|---|---|---|
| **VERSION** | "latest version", "what's new", "changelog", "release notes", "current version of X" | Official docs/changelog first, then community context |
| **COMPARE** | "vs", "so sánh", "which is better", "A or B", "compare X and Y" | Balanced coverage for both sides |
| **NEWS** | "recent", "2025/2026", "mới nhất", "latest news", time-sensitive topics | `brave_news_search` with freshness |
| **HOWTO / API** | "how to", "cách dùng", "tutorial", "setup", "configure", API usage | Context7 first, then official/community sources |

If the topic is library/framework API, also run Step 4 before Step 5.

### Step 4 — Context7 lookup *(HOWTO/API full mode only)*

- Detect the installed version from manifests/lockfiles when possible.
- Use `resolve-library-id` to find the right docs target.
- Use `query-docs` for the specific API/feature.
- If Context7 has no match, continue with web search.
- If Context7 returns a different major version than the project, flag the mismatch.
- Use Context7 for API accuracy, but do not rely on it as the only source in full mode.

### Step 5 — Search

Apply the search strategy for the full-mode type:

**VERSION**
- Prefer the official changelog or release notes page first.
- Then search for community context.

**COMPARE**
- Run two balanced Brave searches, one per option.
- Include at least one neutral source.

**NEWS**
- Use `brave_news_search`.
- Start with `freshness: "pd"`, widen to `"pw"` if needed.
- Include the current year in the query.

**HOWTO / API**
- After Context7, search for official docs, examples, and high-quality community explanations.

Universal rules:
- Use English queries unless the topic is Vietnamese-specific.
- Prefer 3 high-quality sources over 5 mixed ones.
- If Brave returns fewer than 3 relevant results, retry with `firecrawl_search`.

### Step 6 — Scrape or extract

- Scrape only high-signal pages.
- Use `firecrawl_scrape` with `formats: ["markdown"]` and `onlyMainContent: true`.
- For structured fields, params, prices, or specs, prefer `firecrawl_extract`.
- Default cap: 3 URLs; 5 for COMPARE queries.
- If JS-rendered pages return empty content, retry once with `waitFor: 5000`, then fall back to `firecrawl_map` if needed.
- If fewer than 2 usable sources remain after quality filtering, stop and tell the user there are not enough reliable sources.

### Step 7 — Synthesize

- Answer only from fetched sources.
- Note freshness/date when available.
- If sources materially disagree, use `sequentialthinking` when available.
- Choose the output format that matches the mode:
  - quick output for resolved quick questions
  - full report for all full-mode work

## Output format

### Quick lookup

```
### `[Library or Topic]` — `[question]`

[1–3 sentence direct answer]

**Example:**
```[lang]
// minimal working example
```

**Source**: Context7 (`library-id`) / Brave Search
```

Keep it short. No citations list, no report structure, no recommendations unless the question explicitly asks.

### Full research report

```
## [Topic / Research Question]

> 📅 Research date: [today's date] | Sources: [N scraped] | Freshness: [Official/Community/Mixed]

### Summary
[2–4 sentence direct answer]

### Key Findings
- **[Finding 1]**: ... *(Source: [Official] / [Community])*
- **[Finding 2]**: ...
- **[Finding 3]**: ...

### [Optional: Comparison Table or Deep Dive Section]
...

### ⚖️ Conflicting findings *(optional)*
[structured reasoning]

### Limitations
- [Unanswered gap]
- [Discarded or failed sources]
- [Potential staleness]

### Sources
- [Official] [Page Title](URL) — [what it contributed]
- [Community] [Page Title](URL) — [what it contributed]
- Context7 (`library-name`) — versioned API reference for [feature]

### Recommended next steps *(optional)*
- [What to do now]
```

## Rules

- Never ask the user to choose between lookup vs research — b-research decides or escalates itself.
- Start with quick mode when it plausibly fits, then escalate automatically if the answer needs more than 2 tool calls, more than 1 source, or any page scraping.
- Quick mode caps at 2 tool calls before escalating or answering.
- Never scrape in quick mode.
- Always attempt Context7 first for library/framework API questions.
- In full mode, always scrape or extract before making factual claims from web results.
- Prefer authoritative sources over aggregators.
- Cite every full-mode claim with its source URL or `Context7 (library-name)`.
- Never fill factual gaps from training data in full mode; use `Limitations` instead.
- Never trigger destructive git commands.
