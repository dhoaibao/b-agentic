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

Use a real browser to verify user-facing flows or author repo-native browser tests.

## When to use

- The user wants a live browser flow tested, reproduced, or inspected.
- The task is UI verification, frontend bug reproduction, or browser-based state inspection.
- The user wants to write or fix an E2E browser test.

## When NOT to use

- The task is a DOM-rendered unit test -> use **b-test**.
- The issue is backend or non-UI runtime debugging -> use **b-debug**.
- The task is planning a flow before implementation -> use **b-plan**.

## Tools required

- `playwright-browser` (required) - see `AGENTS.md` section 4 for MCP and local-CLI fallback.
- `serena-symbol-toolkit` *(optional, for browser test file edits)*
- `bash` and native file tools - target health checks, config discovery, manifests, and repo test files.

Fallbacks: `AGENTS.md` section 4. Graceful degradation: partial; without browser automation, stop or use installed local CLI when available.

## Steps

### Step 1 - Prepare target and safety

Identify the target URL/app/surface and whether auth or writes are needed. Verify localhost targets are reachable before navigating; if not reachable, ask whether to start the repo's dev server with approval, use a user-started target, or abort. Do not start a dev server without approval.

Production-like targets are read-only by default. Mutating steps require explicit approval naming the environment. Use ephemeral auth unless reusable stored auth is explicitly approved; if stored auth is expired, ask whether to refresh, re-auth ephemerally, or abort.

Create repo-local artifacts only when evidence must be saved; otherwise rely on the global happy-path compression rule. Sensitive/auth artifacts stay outside the worktree by default. Artifacts and a manifest are required when writing tests, saving screenshots/snapshots, using auth/session state, creating test data, or encountering partial writes/failures.

### Step 2 - Pick mode

- **Verify mode:** drive the flow once, capture evidence, report result. Do not write tests.
- **Author mode:** inspect existing browser-test setup, preserve the repo's framework, and write/fix test code. If no browser-test framework exists, ask before adding one.

If the user wants both, verify first, then use the captured flow as the authoring spec.

### Step 3 - Drive or author

In verify mode, snapshot before interacting, navigate, execute with browser tools, wait for specific UI state, re-snapshot/screenshot relevant state, and inspect console/network when the outcome depends on client or API behavior.

Check only the requested viewport unless responsive behavior or both mobile/desktop are in scope. Include a focused accessibility check for interacted controls, labels, roles, and focus order. Default to functional assertions; visual baselines require approval.

For non-trivial flows, record the browser evidence context: URL, viewport/device, auth mode, data created or reused, key console/network findings, and the final UI assertion. Prefer seeded or namespaced test data; if data cannot be cleaned up safely, report it rather than deleting blindly.

In author mode, translate the verified flow into stable test code with accessible selectors and clear assertions, then run the project's normal browser-test command once.

### Step 4 - Cleanup and report

Close the browser. Clean up only run-created test data and only when cleanup was approved. If a partial flow wrote data before failing, list those writes and cleanup status. Namespace approved test data with a unique run prefix.

## Output format

```text
Mode -> Target -> Driver -> Interactions -> Assertions -> Test code -> Artifacts/Cleanup
```

## Rules

- Always snapshot before interacting.
- Do not start dev servers or mutate production-like data without approval.
- Preserve the repo's browser-test framework.
- Do not introduce visual baselines or Playwright in a non-Playwright repo without approval.
- Persist reusable auth state only with explicit opt-in and outside the worktree by default.
- Always close the browser.

## Reference pointers

- `skills/b-e2e/reference.md` - fallback checklist for focused keyboard, label, focus-order, dialog, and responsive checks.
