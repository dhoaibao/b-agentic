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

Handle external knowledge with the lightest depth that can answer correctly. Start with a direct lookup; auto-deepen only when evidence quality requires it.

If `$ARGUMENTS` is provided, treat it as the research question and proceed directly.

## When to use

- Library, framework, SDK, or API questions.
- Config keys, method signatures, setup details, capability checks, or migration facts.
- Comparisons, deep dives, cited reports, recency-sensitive topics, or multi-source synthesis.
- Questions about known URLs, local docs, PDFs, spreadsheets, or other source material.

## When NOT to use

- Runtime bug tracing or root-cause analysis → use **b-debug**.
- Deciding what to build or how to sequence work → use **b-plan**.
- Pre-PR review of changed code → use **b-review**.

## Tools required

- `context7-docs` (primary for library/framework API lookups) — including the version-pinning rule in `global/AGENTS.md` §4.
- `brave-discovery` (page discovery).
- `firecrawl-extraction` (default extraction tier).
- `firecrawl-extended` *(optional, for site maps or structured field extraction)*.
- `firecrawl-deep` *(last resort; requires explicit user approval per invocation)*.

Fallbacks: `global/AGENTS.md` §4 MCP fallback ladder.

Graceful degradation: ⚠️ Partial — lookups remain strong with Context7 or authoritative search; deep synthesis is weaker without page tools.

## Steps

### Step 1 — Pick the starting depth

Choose the lightest depth that can plausibly answer:

- **Lookup** — one fact, one signature, one config key, a yes/no capability, or a tiny example.
- **Research** — anything requiring more than one source, comparison, multi-step synthesis, or recency-sensitive answer.

If the user already provided a URL, file path, or document, decide between **direct-source lookup** and broader research: extract that one source immediately when it is likely sufficient, otherwise continue into research.

### Step 2 — Pin the version (library/API questions)

Before any `context7-docs` query:

1. Resolve the library version from manifests **and** lockfiles. Use `package-lock.json` / `pnpm-lock.yaml` / `yarn.lock`, `poetry.lock` / `uv.lock`, `go.sum`, `Cargo.lock`, or equivalent.
2. In monorepos, resolve at the workspace closest to the touched file, not the repo root.
3. If the version is ambiguous or conflicting, ask before querying.

Skip this step for non-library research.

### Step 3 — Gather evidence

**Lookup:**
1. `context7-docs` first for library/framework APIs.
2. Otherwise one focused `brave-discovery` query.
3. Answer immediately when the result is authoritative and directly responsive.
4. **Auto-deepen to research** when the first results are stale, mutually contradict, are not authoritative, or do not directly answer. Do not retry the same shape of query forever.
5. Do not scrape in **open-ended** lookup. The one exception is a **direct-source lookup** from a user-provided URL, file path, or document.

**Research:**
1. Prefer official docs, release notes, source repos, and vendor materials first.
2. Use `brave_news_search` only for recency-sensitive topics; use `brave_image_search` only when the question is genuinely visual.
3. Use `firecrawl-extraction` (`firecrawl_scrape` for known URLs, `firecrawl_parse` for local documents) on the highest-signal pages.
4. Reach for `firecrawl-extended` only for site mapping or structured-field extraction.
5. Reach for `firecrawl-deep` only after default and extended tiers are insufficient. Surface the cost warning and obtain approval per invocation (see canonical approval ask in `global/AGENTS.md` §6).

Honor the public-web privacy gate (`global/AGENTS.md` §6) on every external call. Reuse fetched results from earlier in the session instead of re-fetching (`global/AGENTS.md` §4 cross-turn cache).

### Step 3b — Handle gated sources

When the most authoritative source is paywalled, login-gated, or otherwise inaccessible (academic journals, vendor support portals, gated changelogs, private status pages):

1. Do not bypass the gate — never fabricate credentials, scrape behind auth, or paste user-supplied secrets into a fetch.
2. Try open mirrors in this order: (a) publisher's free abstract or summary, (b) cached or archived versions (e.g., Wayback Machine) — only when policy-compatible, (c) reputable secondary sources that cite the gated original.
3. If the gated source is the only authoritative answer and no mirror exists, stop and tell the user: name the source, what it would resolve, and ask whether to (i) proceed with the best open evidence and mark single-source/medium confidence, or (ii) pause for them to supply the document via `firecrawl_parse` on a local copy.
4. Never silently substitute a weaker source — label the limitation in the `Limitations` section.

### Step 4 — Resolve source conflicts

When two authoritative sources disagree:

1. Prefer the one matching the pinned version (Step 2).
2. If both match, prefer the publisher's own docs over third-party tutorials.
3. If still ambiguous, present both with the conflict labeled and attach `Confidence: medium`.

### Step 5 — Synthesize

1. Answer only from gathered evidence.
2. For lookup, stay concise and direct.
3. For research, cite the sources that support the answer.
4. Note freshness or access limitations when relevant.
5. Attach the **confidence signal** from `global/AGENTS.md` §3 whenever evidence is partial, single-source, or recency-sensitive. Omit the line on trivial high-confidence answers.

Close the run with the skill-exit status block (`global/AGENTS.md` §9) for research-mode work; lookup answers may omit it.

## Output format

### Lookup

```text
### [topic]

[1-3 sentence direct answer]

**Example:** *(optional)*
```[lang]
[minimal example when it helps]
```

**Source:** [Context7 or authoritative URL]
```

(Confidence line only when not high.)

### Research

```text
## [research question]

### Answer
[direct answer]

### Key findings
- [finding]
- [finding]

### Limitations
- [gap, staleness, or unavailable source]

### Sources
- [title](URL)
- Context7 (`library-id`@`version`) for [feature]

**Confidence:** high | medium | low — <one-clause reason>
```

## Rules

- Never ask the user to choose between lookup and research; the skill decides and auto-deepens.
- Use the lightest depth that can answer correctly.
- Public-web privacy gate is owned in `global/AGENTS.md` §6; honor it on every external call.
- Do not scrape in open-ended lookup when a docs or search result already answers; direct-source lookup from a user-provided URL, file path, or document may extract that one source immediately.
- Pin the library version (manifests + lockfiles) before any `context7-docs` query.
- Prefer 2–4 authoritative sources over a long weak list.
- Do not force an example block for fact-only quick answers.
- If only one authoritative source supports the answer, label it as single-source.
- Never use `firecrawl-deep` before exhausting default and extended tiers, and never without explicit user approval.
- Use a `Limitations` section instead of filling factual gaps from prior model knowledge.
- Reuse results fetched earlier in the same session; do not re-fetch identical pages.
