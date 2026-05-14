---
name: b-e2e
description: >
  Real-browser end-to-end work. ALWAYS invoke when the user asks to verify a
  UI flow, run an end-to-end test, or drive a real browser. Two modes —
  verify (drive once, capture evidence) and author (write or fix browser test
  code). Unlike b-test, which handles DOM-rendered unit tests, b-e2e drives
  a live Chromium/Firefox/WebKit against user-facing behavior.
compatibility: opencode
metadata:
  suite: b-skills
---

# b-e2e

$ARGUMENTS

Use a real browser to verify user-facing flows, then optionally turn a successful flow into repo-native browser test code. Two modes: **verify** and **author**.

## When to use

- The user wants a live browser flow tested or reproduced.
- The task is UI verification, frontend bug reproduction, or browser-based state inspection.
- The user wants to write or fix an end-to-end browser test (Playwright, Cypress, WebdriverIO, Puppeteer).

## When NOT to use

- The task is a DOM-rendered unit test (jsdom, RTL, Vue Test Utils) → use **b-test**. See the **DOM-unit vs browser-flow boundary** in `AGENTS.md` §10.
- The issue is backend or non-UI runtime debugging → use **b-debug**.
- The task is planning a feature or flow before implementation → use **b-plan**.

## Tools required

- `playwright-browser` (required) — see `AGENTS.md` §4 for the bundle, including the local-CLI fallback.
- `serena-symbol-toolkit` *(optional, for editing existing browser test files)*
- `bash` and native file tools — target health checks, config discovery, manifests, and writing repo test files when needed.

Fallbacks: per `AGENTS.md` §4, prefer Playwright MCP; if unavailable, drive the project's local Playwright CLI via `bash`; if neither is available, stop and tell the user browser automation is unavailable.

Graceful degradation: ⚠️ Partial — MCP path is fastest; CLI fallback works when the project already has Playwright installed.

## Steps

### Step 1 — Prepare the run

1. Create a session-specific artifact directory using the run-id format from `AGENTS.md` §8. Use `.opencode/b-skills/b-e2e/<run-id>/` only when `.opencode/` is already ignored by git in the current repo; otherwise use `~/.config/opencode/b-skills/b-e2e/<run-id>/` for persistent artifacts or `/tmp/opencode/b-skills/b-e2e/<run-id>/` for disposable ones.
2. Determine the **target**: a URL, an extension surface, a local app, or an authenticated entry point. Record the target type.
3. Before touching `localhost`, verify the server is reachable. Do not start a dev server without approval (canonical approval ask in `AGENTS.md` §6).
4. Clarify only what blocks the flow: auth/session state, test data, and whether writes are allowed.
5. **Auth state reuse:** if a safe stored auth state file already exists (for example under `~/.config/opencode/b-skills/b-e2e/.../storage-state.json`), load it instead of re-authenticating. If no auth state exists and the flow needs auth, store the post-login state in a non-worktree path such as `~/.config/opencode/b-skills/b-e2e/<run-id>/storage-state.json` so later steps and re-runs can reuse it. Do not create real auth state under repo-local `.opencode/...` unless that path is already ignored and the user explicitly wants repo-local persistence.

### Step 2 — Pick the mode

- **Verify mode** — drive the browser once, capture evidence, report findings. No test files are written. Continue at Step 3V.
- **Author mode** — write or fix repo-native browser test code. Often starts with a verify pass to confirm the flow works manually. Continue at Step 3A.

If the user wants both ("verify it then write a test"), do verify first, then transition to author with the captured flow as the spec.

### Step 3V — Drive the browser (verify mode)

1. Navigate to the target.
2. Capture an accessibility snapshot before interacting.
3. Execute the requested flow with first-class tools from `playwright-browser`. Wait for specific UI state instead of arbitrary sleeps.
4. If the MCP bundle is unavailable, run the equivalent flow through the project's local Playwright CLI; record the command.
5. Re-snapshot or screenshot the relevant state.
6. Inspect console or network when the UI outcome depends on client errors or API calls.
7. **Viewport check defaults.** Test only the requested viewport unless the user explicitly asks for multi-viewport, the task is responsive-layout work, or the changed UI is intended for both mobile and desktop. For responsive UI work, check one representative mobile and one representative desktop viewport unless the user narrows scope.
8. If a step looks flaky, apply the flake handling rule in `AGENTS.md` §10 before reporting flake.
9. Distinguish **functional snapshot** (assert state or text content) from **visual regression** (pixel diff). Use the former by default; do not introduce visual regression baselines without approval.

### Step 3A — Author or fix browser tests (author mode)

1. Inspect the repo's existing browser-test setup first: `playwright.config.*`, `cypress.config.*`, package scripts, test directories, naming conventions.
2. Preserve the repo's current framework instead of forcing Playwright everywhere.
3. **Empty state** (`AGENTS.md` §7): if no browser-test framework exists and the user wants new test code, ask before introducing one.
4. Translate a successful flow into stable test code using accessible selectors and clear assertions.
5. Persist auth state via `storageState` when the test would otherwise re-authenticate every run.
6. Run the new/updated test once via the project's normal command and confirm it passes.

### Step 4 — Cleanup

1. Close the browser.
2. Clean up only test data created by this run, and only when that cleanup was approved.
3. **Partial-run cleanup:** if the flow failed mid-way, enumerate every write the run completed before the failure (accounts created, records inserted, files uploaded, sessions opened) and clean those up too — do not assume "test failed → nothing to undo." If cleanup of a partial write was not pre-approved, surface the list explicitly so the user can decide.
4. When writes are allowed, prefer clearly namespaced test data (unique prefix, timestamp, or run id) so cleanup can target only this run's records.
5. Record artifact paths, generated test files, partial writes, and cleanup status in the run manifest per `AGENTS.md` §8.

Close with the skill-exit status block (`AGENTS.md` §9).

## Output format

```text
### b-e2e: [flow]

**Mode:** [verify / author]
**Target:** [URL / extension / local app / authenticated surface]
**Driver:** [MCP / local CLI]
**Scope:** [flow tested]

#### Interactions
- [step]
- [step]

#### Assertions
- [passed or failed state]

#### Test code
- [none / file updated / file created]

#### Artifacts
- `.opencode/b-skills/b-e2e/<run-id>/` or a non-worktree fallback path
```

## Rules

- Always snapshot before guessing where to click or type.
- Do not start a dev server without approval.
- Do not mutate production-like data without explicit confirmation.
- Preserve the repo's existing browser-test framework when editing test files.
- Do not introduce Playwright test files into a non-Playwright repo unless the user approves.
- Multi-viewport checks are opt-in except for responsive UI work or UI intended for both mobile and desktop.
- Namespace test data created by browser flows whenever writes are approved.
- Do not introduce visual regression baselines without approval; default to functional snapshots.
- `*_unsafe` tool variants require explicit user approval per invocation (`AGENTS.md` §4).
- Always close the browser when the run is complete.
- Persist auth state in a non-worktree path when re-login would be repeated work; never commit auth state files containing real credentials.
