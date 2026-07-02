---
name: b-research
description: >
  External knowledge, from quick lookup to multi-source synthesis, for
  library/framework docs, API facts, config keys, method signatures,
  comparisons, deep dives, or recency-sensitive topics. Auto-detects
  depth, answers with sources, and hands off to implementation when the
  next action is obvious. Unlike b-debug or b-plan, it fetches docs and
  web information rather than tracing code or choosing implementation.
argument-hint: "[question-or-source]"
---

<!-- Generated from skills/registry.yaml and skills/b-research/prompt.md. Edit those sources, not this file. -->

# b-research

$ARGUMENTS

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

## Tools required

- `context7` - versioned official library/framework docs.
- `firecrawl` - primary public web search, known public URLs, structured extraction, maps, structured fields, and paper/GitHub-issue lookup when the question is research-paper- or code-history-shaped.
- `brave-search` - secondary public/current discovery and alternate source finding when useful.

## Steps

1. Classify the question and required source quality.
2. Pin version from manifests/lockfiles when API details matter.
3. Use Context7 first for versioned library/framework APIs when suitable.
4. Use Firecrawl search first for public web discovery and current sources when library docs alone do not answer the question.
5. Use Firecrawl for bounded extraction from known public URLs. Ask before deep autonomous research, broad crawls, or private/internal material.
6. Use Brave when you need a second search lens, broader public discovery, or Brave-specific source types such as news.
7. For academic/paper-grounded questions or prior-art/issue history, use Firecrawl's paper and GitHub search tools directly instead of generic web search.
8. Synthesize only from gathered evidence and cite sources.
9. When the research points directly to a local code or config change, state that the next step belongs in **b-implement**; when uncertainty remains, say what is still unknown.

## Output format

Direct answer, key evidence, limitations, sources, and confidence when not high. Include the next handoff only when it is naturally implied.

## Rules

- Use the lightest depth that answers correctly.
- Prefer primary sources over tutorials.
- Do not send private or internal material to public tools without approval.
- Hand off code changes to **b-implement** and tracing to **b-debug**.
