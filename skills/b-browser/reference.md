# b-browser reference

Use for real-browser, visual, screenshot, and e2e evidence.

## Evidence hierarchy

Prefer evidence sources in this order:

1. **Supplied/CI evidence** — existing screenshots, CI artifacts, or repo test output
2. **Existing repo scripts** — `npm run test:e2e`, `pytest` with browser fixtures, etc.
3. **Playwright MCP** — live browser operation after safety gates
4. **Firecrawl extraction** — static pages only; not a substitute for live browser

## Firecrawl depth criteria

Reference names map to MCP invocations: `firecrawl_scrape` → `mcp__firecrawl__firecrawl_scrape`, etc.

- **Extraction** (`firecrawl_scrape` or `firecrawl_extract`) for single static pages with known URLs.
- **Extended** (`firecrawl_map`) for discovering URLs or structured fields across a site section.
- **Deep** (`firecrawl_crawl` or `firecrawl_agent`) only with explicit approval and a stated scope cap; never as a default.

If no approved evidence path exists, stop with `cause: evidence_gap`.

## Screenshot guidelines

- Capture the **smallest viewport** that shows the issue
- **Annotate** screenshots with arrows/boxes for complex UIs
- Include **before/after** for visual changes
- **Full-page screenshots** only when scroll position matters
- State **browser, OS, and viewport size**

## Playwright safety rules

- **Never run arbitrary JavaScript** in the browser without explicit approval
- **Never interact with production/staging** without naming the environment
- **Isolate sessions** — use `--isolated` flag by default
- **Clean up** — close browser contexts after evidence collection

## Common verification patterns

- **Visual regression**: screenshot before/after, pixel-diff if available
- **DOM state**: specific element selectors, text content, attribute values
- **Console errors**: check for uncaught exceptions, 4xx/5xx network errors
- **Network requests**: verify API calls, payloads, and response shapes
- **Accessibility**: run axe or similar if relevant to the change

## When to hand off

- Fix is needed → hand off to **b-implement** with screenshot evidence
- Root cause is unclear → hand off to **b-debug** with browser console/logs
- Test needs to be written → hand off to **b-test**
