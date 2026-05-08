---
name: b-e2e
description: >
  Browser-based end-to-end testing. ALWAYS invoke when the user asks to test the UI,
  run end-to-end tests, use the browser, or verify frontend flows: "test UI", "chạy E2E",
  "test trên trình duyệt", "browser test". Uses Playwright to navigate, interact, and assert
  state. Unlike b-test (which handles unit/integration code tests), b-e2e drives a real
  browser to test user-facing functionality.
effort: medium
---

# b-e2e

$ARGUMENTS

Drives a real browser using Playwright to verify frontend user flows, interact with elements, inspect the DOM/accessibility tree, and author or debug E2E test scripts.

## When to use
- Running end-to-end (E2E) tests in the browser.
- Verifying UI state, visuals, or frontend workflows.
- Writing or debugging Playwright/Cypress test files.
- Interacting with a running web application to reproduce a bug.

## When NOT to use
- Writing or fixing unit tests → use `/b-test`.
- Debugging backend logic or API failures without UI involvement → use `/b-debug`.
- Planning the user flow before implementation → use `/b-plan`.

## Tools required

- `mcp__playwright__browser_navigate` — from `playwright` MCP server *(Primary)*
- `mcp__playwright__browser_snapshot` — from `playwright` MCP server *(Primary)*
- `mcp__playwright__browser_click` / `browser_fill_form` / `browser_type` / `browser_press_key` — from `playwright` MCP server *(Primary)*
- `mcp__playwright__browser_take_screenshot` — from `playwright` MCP server *(Secondary, for visual diffs)*
- `mcp__playwright__browser_evaluate` — from `playwright` MCP server *(optional, for complex DOM assertions)*
- `mcp__playwright__browser_network_requests` — from `playwright` MCP server *(optional, for asserting API calls)*
- `mcp__playwright__browser_close` — from `playwright` MCP server *(used in cleanup)*
- `find_symbol`, `get_symbols_overview`, `insert_before_symbol`, `insert_after_symbol`, `replace_symbol_body` — from `serena` MCP server *(optional, for writing test code in Step 5)*
- `Bash`, `Write`, `Edit` — for managing temporary artifacts, dev-server health checks, and creating new test files when needed.

If `playwright` MCP is unavailable: stop and inform the user that E2E browser interactions require the Playwright MCP server.
If `serena` is unavailable in Step 5: write test code with native `Write`/`Edit` instead.

Graceful degradation: ❌ Not possible — this skill inherently requires browser automation.

## Steps

### Step 1 — Setup environment and navigate

Use `Bash` to ensure the temporary artifact directory exists: `mkdir -p .claude/b-e2e`.

Determine the target URL (local dev server or staging). If the URL is a `localhost` address, verify the dev server is reachable before navigating:
```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:PORT | grep -qE "^[23]" || echo "Server not responding"
```
If the server is not reachable, ask the user to start it before proceeding. Do not attempt `browser_navigate` to a non-responding host.

Once confirmed reachable (or for remote URLs), call `browser_navigate` to load the application.

---

### Step 2 — Map the UI and capture visuals

Call `browser_snapshot` (saving to `.claude/b-e2e/snapshot.md`) and `browser_take_screenshot` (saving to `.claude/b-e2e/screenshot.png`) to capture the accessibility tree and visual state. Always use the accessibility snapshot to find exact target references before attempting to click or type.

---

### Step 3 — Execute interactions

Execute the requested user flow by calling `browser_click`, `browser_fill_form`, `browser_type`, or `browser_press_key` using the precise targets mapped in Step 2. Keep interactions sequential — verify state after major actions (form submission, navigation).

---

### Step 4 — Verify state

Capture a new snapshot/screenshot in `.claude/b-e2e/` or use `browser_evaluate` to assert that the expected text, elements, or state changes have appeared. Optionally use `browser_network_requests` for API-level assertions when the UI depends on backend calls.

---

### Step 5 — Author or fix test code *(optional)*

If the user asked to write or fix a test file:

1. Locate the appropriate spec file:
   - Use Bash to find existing specs (`find . -name "*.spec.ts" -o -name "*.e2e.ts"`).
   - Use `find_symbol` on existing describe blocks to identify the right insertion point.
2. Map the successful manual interactions from Steps 3–4 into Playwright code:
   - Mirror selectors from the snapshot (prefer accessible roles/names over CSS).
   - Mirror assertions from Step 4 verification.
3. Insert the test:
   - Existing describe block → `insert_after_symbol` on the last test in the block.
   - New describe block needed → `insert_after_symbol` on the last describe in the file.
   - No spec file exists → use `Write` to create one in the conventional location for this project.
4. Run the new test once via Bash to confirm it passes:
   ```bash
   npx playwright test path/to/spec.ts
   ```

If no test code is requested, skip this step and just report the verified flow.

---

### Step 6 — Cleanup

When testing, verification, and code generation are complete:

1. Close the browser session: `browser_close`.
2. Remove temporary artifacts: `rm -rf .claude/b-e2e`.

---

## Output format

```
### b-e2e: [flow name]

**URL**: [target URL]
**Scope**: [user flow tested — e.g. "checkout flow", "login → dashboard redirect"]

#### Interactions
- [Action 1: navigate / click / type / fill]
- [Action 2: ...]

#### Assertions
✅ [expected state confirmed — description]
❌ [unexpected state — description and screenshot reference if captured]

#### Network requests *(optional — only if browser_network_requests was used)*
- [Method + URL] — [status / payload note]

#### Test code *(optional — only if writing or fixing a test file)*
\`\`\`ts
// Playwright test code
\`\`\`
Saved to: `[path/to/test.spec.ts]`

#### Cleanup
✅ Browser closed, `.claude/b-e2e/` removed
```

---

## Rules
- Always use `browser_snapshot` to get exact element targets before interacting; never guess selectors blindly.
- Save all intermediate snapshots, screenshots, and visual outputs strictly to `.claude/b-e2e/`.
- Always close the browser and delete `.claude/b-e2e/` when the testing flow finishes.
- Ensure the local dev server is running before attempting to navigate to `localhost`.
- Keep interactions sequential and verify state changes after major actions.
- Prefer accessible roles/names from the snapshot over brittle CSS selectors when authoring tests.
- Never trigger destructive git commands.
