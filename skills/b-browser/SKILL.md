---
name: b-browser
description: >
  Browser automation and evidence operator for Playwright, Cypress e2e,
  Puppeteer, WebDriver, visual, screenshot, browser-session, live UI, and
  e2e checks. Unlike b-test, b-browser owns real-browser UI evidence, not
  simulated-DOM unit, integration, or contract tests.
argument-hint: "[browser-or-e2e-request]"
---

<!-- Generated from skills/registry.yaml and skills/b-browser/prompt.md. Edit those sources, not this file. -->

# b-browser

$ARGUMENTS

Own real-browser, visual, screenshot, browser-session, live UI, and e2e evidence.

## When to use

- The user asks for real-browser, visual, screenshot, browser-session, live UI, or e2e checks.
- PR readiness depends on Playwright, Cypress e2e, WebdriverIO, Puppeteer, WebDriver, or equivalent real-browser evidence.
- Another phase reports a browser evidence gap.

## When NOT to use

- Non-browser unit, integration, contract, coverage, mock, fixture, assertion, snapshot, flake, or simulated-DOM/component-test work -> use **b-test**.
- UI/UX critique or visual design feedback without runnable verification.
- Implementing UI behavior or fixing app code -> use **b-implement** or **b-debug**.
- Changed-code review with browser evidence already supplied -> use **b-review**.

## Tools required

- `bash` - run approved existing real-browser/visual/e2e commands.
- `playwright-browser-operator` *(optional, for live-browser navigation, snapshots, screenshots, console/network, and browser state)*
- `firecrawl-extraction` *(optional, for static known remote page content only; never a Playwright substitute)*
- `serena-symbol-toolkit` *(optional, for mapping browser failures to source ownership)*

## Steps

### Step 1 - Classify request

Name whether this is a direct run, live exploration, supplied-evidence review, or readiness gap. If it is actually unit/component/simulated-DOM work, hand off to **b-test**. Do not add browser or DOM tooling as a side effect.

### Step 2 - Choose evidence path

Use the first sufficient path: supplied/CI evidence, existing repo script/documented command, Playwright live-browser actions, Firecrawl for static known remote content only, accepted follow-up/skipped check. If no path exists, hand off to **b-plan** for tool strategy and dependency approval.

Do not invent verification commands.

### Step 3 - Apply safety gates

Read `../../b-agentic/references/contract/safety-tools.md` before running browser/e2e tooling, using Playwright, starting dev servers, persisting browser/session state, writing screenshots/videos/traces, installing dependencies, or mutating shared environments.

Unsafe arbitrary-code browser execution requires explicit approval naming target URL and why ordinary browser actions cannot answer.

### Step 4 - Collect evidence

For supplied evidence, confirm command/workflow, environment, target, timestamp when available, and pass/fail result. For repo commands, run the narrowest existing command. For Playwright, prefer ordinary actions: navigate, snapshot, click, type, fill, screenshot, console/network inspection, and ephemeral state. For Firecrawl, keep extraction bounded to the known URL and static question.

### Step 5 - Classify failures and cleanup

Classify failures as product behavior, harness/setup, environment, auth/session, external-service, flaky/timing, or tool-unavailable. Record command or interaction sequence, URL/target, environment, artifacts, and unknowns.

Product behavior failures hand off to **b-debug** with command, artifacts, summary, environment, and likely source area. Clean up or report screenshots, traces, logs, browser state, test data, and lingering processes.

### Step 6 - Report readiness impact

State whether real-browser/visual/e2e evidence is verified, missing, failed, or accepted as follow-up. Do not claim **READY FOR PR** when relevant browser evidence is absent or failed.

## Output format

```text
Request -> Evidence path -> Browser result -> Artifacts/cleanup -> Readiness impact -> Follow-up/Handoff
```

## Rules

- Do not run browser/e2e commands before safety gates allow them.
- Do not use unsafe arbitrary-code browser tools by default.
- Do not treat missing browser evidence as covered by non-browser tests.
- Do not store real auth/session state under a tracked worktree path.
- Route unclear product behavior to **b-debug** and new tool strategy to **b-plan**.
