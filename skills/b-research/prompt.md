# b-research

$ARGUMENTS

Answer external-knowledge questions at the lightest reliable depth, with sourced evidence.

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
- `brave-search` - public/current discovery and unknown URLs.
- `firecrawl` - known public URLs, structured extraction, maps, and structured fields when needed.

## Steps

1. Classify the question and required source quality.
2. Pin version from manifests/lockfiles when API details matter.
3. Use Context7 first for versioned library/framework APIs when suitable.
4. Use Brave to find authoritative/public/current sources when URLs are unknown.
5. Use Firecrawl for bounded extraction from known public URLs. Ask before deep autonomous research, broad crawls, or private/internal material.
6. Synthesize only from gathered evidence and cite sources.

## Output format

Direct answer, key evidence, limitations, sources, and confidence when not high.

## Rules

- Use the lightest depth that answers correctly.
- Prefer primary sources over tutorials.
- Do not send private or internal material to public tools without approval.
- Hand off code changes to **b-implement** and tracing to **b-debug**.
