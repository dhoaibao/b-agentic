# b-browser

Own real-browser, visual, screenshot, live UI, browser-session, and e2e evidence.

## When to use

- The user asks for browser, visual, screenshot, live UI, or e2e checks.
- PR readiness depends on real-browser evidence.
- Another phase reports a browser evidence gap.

## When NOT to use

- Unit, integration, contract, mock, fixture, snapshot, or simulated-DOM work -> use **b-test**.
- Implementing frontend/UI behavior or fixing frontend/UI code -> use **b-frontend**.
- Implementing non-UI behavior -> use **b-implement**; diagnosing a runtime bug -> use **b-debug**.
- Changed-code review with sufficient browser evidence already supplied -> use **b-review**.

## Tool guidance

- `bash` - existing approved browser/e2e commands (`rtk playwright` when using the CLI runner).
- `playwright` - approval-gated `browser_navigate` / interactions; then `browser_snapshot`, `browser_find`, `browser_generate_locator`, `browser_verify_element_visible` / `_list_visible` / `_text_visible` / `_value`, `browser_console_messages`, `browser_network_requests` / `browser_network_request`; `browser_take_screenshot` only when requested (approval-gated local artifact).
- `codegraph` - select when a concrete repository-wide flow or impact question
  is central after a confirmed product failure and likely valuable; use an
  available index for that question and initialize an absent index only for
  that qualifying question.
- `read`/`edit`/`write` - use native file tools for approved evidence artifacts and routine file work; for repeatable regression paths, prefer existing Playwright [cap: mcp.playwright] CLI/CI commands before MCP.
- For bounded, read-only multi-page observations, use top-level `mcp` for one browser observation; for two or more related calls, load the manual `mcp-scripting` skill with `/skill:mcp-scripting` when available or use direct `mcp` calls and state the fallback. `mcpScript` [cap: package.pi-mcp-adapter] may use only `tools.search`, `tools.describe`, and `tools.call`, with at most 12 total nested operations, at most 8 `tools.call` operations, at most 3 source/server branches or browser routes, at most 5 candidate results per source, and at most 12 normalized output records. Keep browser scripts read-only: do not batch browser mutations such as navigation, clicks, typing, evaluation, uploads, or other mutations; nested calls retain normal approval, authentication, and output-guard policy. Normalize only title/URL/claim/error from untrusted content-block envelopes, deduplicate, and report partial failures.
- This is an observation aid, not a replacement for the ordered browser evidence workflow. Discover controls with `browser_find` before taking shallow targeted snapshots, filter console/network output to the requested state, and avoid duplicate full-page snapshots.

## Steps

1. Classify the request: direct command, supplied evidence, live exploration, or readiness gap.
2. Prefer supplied/CI evidence or existing repo scripts (run via Bash) before live browser operation.
3. Ask before starting dev servers, installing tools, persisting sessions, navigation, screenshots, or unsafe arbitrary browser code.
4. When the user explicitly requests a visual assessment, use an approved brief, `docs/DESIGN.md`, or supplied reference as the comparator. Before navigation, turn it into concrete observable criteria: hierarchy, clipping/overflow, responsive composition, contrast/focus/interaction affordance, and adherence to the specified design guidance. If no approved comparator exists, do not invent an aesthetic baseline or certify visual quality; report the gap and limit the result to requested-state evidence.
5. Collect Playwright evidence in order for the requested UI state: existing CI/script evidence; approved navigation to the requested state (plus approved interactions when needed); `browser_find` when locating controls, followed by a shallow targeted `browser_snapshot` (or one full-page snapshot only when whole-page coverage is required); focused console plus filtered network list/detail; then a requested approved screenshot. Do not claim readiness from a generic page load. Avoid duplicate full-page snapshots. A scripted browser fan-out is only an observation aid; it does not replace the ordered evidence bundle or screenshot requirement. In headless or CI environments, use headless config or display servers (e.g., xvfb-run).
6. When evidence output is requested, first confirm an explicitly approved local evidence directory. Keep every artifact under `<approved-dir>/browser/<run-id>/`; reject traversal or absolute paths outside that root. Use native `read`/`edit`/`write` only for these approved evidence artifacts. Write `manifest.json` with `requested_state`, `url`, `snapshot_path`, `console_path`, `network_path`, `screenshot_path` (null unless requested and collected), and `cleanup_result`; record the requested UI state, accessibility snapshot, focused console evidence, network evidence, and cleanup result there.
7. Classify failures as product, harness/setup, environment, auth/session, external-service, flaky/timing, or tool-unavailable. For confirmed product failures, select CodeGraph [cap: mcp.codegraph] when a concrete repository-wide flow question is central and likely valuable; use an available index for that question and initialize an absent index only for that qualifying question.
8. Clean up browser state, artifacts, and lingering processes where applicable. Do not claim screenshot coverage when no screenshot was collected.

## Output format

Evidence path, browser result, artifacts/cleanup, and readiness impact. For a requested visual assessment, include the comparator and concrete criteria used, then report observations and gaps; a generic page load or screenshot alone is not aesthetic proof.

## Rules

- Do not invent browser commands.
- Do not treat missing browser evidence as covered by non-browser tests.
- Visual assessment is conditional on an explicit user request and an approved brief, design guidance, or reference.
- Compare observable criteria and report observations or gaps, not a subjective visual certification.
- Do not claim browser readiness from a generic page load when the request needs a specific observable state.
- Do not store auth/session state under tracked paths.
- Route product failures to **b-debug**.
