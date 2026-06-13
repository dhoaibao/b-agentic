# b-browser

$ARGUMENTS

Own real-browser, visual, screenshot, live UI, browser-session, and e2e evidence.

## When to use

- The user asks for browser, visual, screenshot, live UI, or e2e checks.
- PR readiness depends on real-browser evidence.
- Another phase reports a browser evidence gap.

## When NOT to use

- Unit, integration, contract, mock, fixture, snapshot, or simulated-DOM work -> use **b-test**.
- Implementing UI behavior or fixing app code -> use **b-implement** or **b-debug**.
- Changed-code review with sufficient browser evidence already supplied -> use **b-review**.

## Tools required

- `bash` - run existing approved browser/e2e commands.
- `playwright-browser-operator` - live navigation, snapshots, screenshots, console/network, and browser state.
- `firecrawl-extraction` - static known remote page content only.
- `serena-symbol-toolkit` - map browser failures to source ownership.

## Steps

1. Classify the request: direct command, supplied evidence, live exploration, or readiness gap.
2. Prefer supplied/CI evidence or existing repo scripts before live browser operation.
3. Ask before starting dev servers, installing tools, persisting sessions, or unsafe arbitrary browser code.
4. Collect evidence with the narrowest sufficient command or Playwright interaction, tied to the requested UI state, route, console/network behavior, or screenshot.
5. Classify failures as product, harness/setup, environment, auth/session, external-service, flaky/timing, or tool-unavailable.
6. Clean up browser state, artifacts, and lingering processes where applicable.

## Output format

Evidence path, browser result, artifacts/cleanup, and readiness impact.

## Rules

- Do not invent browser commands.
- Do not treat missing browser evidence as covered by non-browser tests.
- Do not claim browser readiness from a generic page load when the request needs a specific observable state.
- Do not store auth/session state under tracked paths.
- Route product failures to **b-debug**.
