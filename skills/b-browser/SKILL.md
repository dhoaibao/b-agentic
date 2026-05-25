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

Operate real-browser, visual, and e2e verification using the lightest safe evidence path: supplied evidence, existing repo scripts, optional Playwright MCP live-browser actions, or an explicit follow-up.

## When to use

- The user asks to run, review, or account for real-browser, visual, screenshot, browser-session, live UI, or e2e checks.
- PR readiness depends on evidence from Playwright, Cypress e2e, WebdriverIO, Puppeteer, WebDriver, or equivalent real-browser tooling.
- A prior phase reports a UI/browser verification gap that needs supplied evidence, approved local evidence, live-browser evidence, or an accepted follow-up.

## When NOT to use

- The task is non-browser unit, integration, contract, coverage, mock, fixture, assertion, snapshot, flake, or simulated-DOM/component-test work -> use **b-test**. See `../../b-agentic/references/contract/10-decisions.md` for the boundary table with concrete examples.
- The task is UI/UX critique, accessibility design review, or visual design feedback without a runnable verification request -> use the appropriate review skill outside this suite when available.
- The task is implementing UI behavior or fixing app code -> use **b-implement** or **b-debug**.
- The task is only changed-code review with browser evidence already supplied -> use **b-review** and cite the evidence.

## Tools required

- Native tools - inspect manifests, scripts, CI, existing artifacts, logs, and user-supplied evidence.
- `bash` - run approved existing real-browser/visual/e2e commands when the repo already provides them.
- `playwright-browser-operator` *(optional, for live-browser navigation, snapshots, screenshots, console/network, and browser-state evidence)*
- `firecrawl-extraction` *(optional, for static remote page content only — when the evidence question is rendered text or markup at a known URL and no DOM state, interaction, screenshot, console, network, or session evidence is required; never a substitute for Playwright)*
- `serena-symbol-toolkit` *(optional, for mapping a browser failure to source ownership before handing off)*


## Steps

### Step 1 - Classify the verification request

Identify whether the request is a direct real-browser/visual/e2e run, live UI exploration, review of supplied evidence, or a readiness gap from another phase. If the check is actually non-browser unit, integration, contract, coverage, or simulated-DOM/component-test work, hand off to **b-test**.

Read `../../b-agentic/references/contract/10-decisions.md` before applying the browser and DOM verification boundary or making readiness claims.

### Step 2 - Choose the evidence ladder

Choose the first path that can answer the browser evidence question safely:

- External evidence supplied by the user or CI, with command, environment, timestamp, and result.
- Existing repo scripts or documented commands, discovered from manifests, CI config, repo docs, or user instructions.
- `playwright-browser-operator` live-browser actions when existing evidence/scripts are absent, insufficient, or not targeted enough.
- `firecrawl-extraction` **only** when the evidence question is static remote page content at a known URL and no DOM state, interaction, screenshot, console, network, or session evidence is required. Not interchangeable with Playwright when any of those are needed.
- If the repo lacks real-browser/visual/e2e tooling and no existing path above can answer the question, hand off to **b-plan** with the browser evidence gap. Tooling may be added only after explicit `/b-plan` approval and dependency-write approval.
- Accepted follow-up or skipped check when evidence is unavailable and the user accepts the gap.

Do not invent verification commands.

### Step 3 - Apply safety gates before running tools

Read `../../b-agentic/references/contract/06-safety.md` before running real-browser, visual, or e2e tooling, using `playwright-browser-operator`, starting dev servers, using persisted browser/session state, writing screenshots/videos/traces, installing dependencies, or mutating shared environments.

Ask for approval before dependency writes, dev servers, persisted browser state, external services, long-running commands, generated evidence outside normal repo output paths, or unsafe arbitrary-code browser tools.

### Step 4 - Collect evidence

For supplied evidence, validate that it names the relevant command or workflow, environment, target, and pass/fail result.

For existing repo commands, execute the narrowest command that matches the requested real-browser/visual/e2e check. Capture generated artifacts only when needed for the result, and report their paths and cleanup state.

For `playwright-browser-operator`, use ordinary browser actions first: navigate, inspect accessibility snapshots, click, type, fill, capture screenshots, and inspect console or network evidence. Prefer ephemeral browser state. Do not use unsafe arbitrary-code execution unless the user explicitly approves it for a trusted target and ordinary actions cannot answer the question.

For Firecrawl, use extraction only when the request is static remote page content and live browser control would not change the answer; do not substitute Firecrawl for Playwright when the evidence question requires DOM state, interaction, screenshots, console/network, or session evidence. Keep extraction bounded to the known URL and target question. Do not use Firecrawl deep interaction unless the user approves it per the runtime contract.

### Step 5 - Classify failures and cleanup

Classify browser failures as product behavior, harness/setup, environment, auth/session, external-service, flaky/timing, or tool-unavailable. Record command or interaction sequence, URL or target, environment, artifacts, and what remains unknown.

If a failure points to product behavior, hand off to **b-debug** with the command, artifact paths, failure summary, environment, and likely source area. If it is harness/setup-only and in browser tooling, stay in **b-browser** unless the fix requires a plan or code implementation.

Clean up or report generated screenshots, videos, traces, logs, browser state, test data, or lingering dev-server/browser processes. Do not delete user-owned artifacts or state without approval.

### Step 6 - Report readiness impact

State whether real-browser/visual/e2e evidence is verified, missing, failed, or accepted as a follow-up. Do not claim **READY FOR PR** when relevant browser evidence is absent or failed.

Read `../../b-agentic/references/contract/09-output.md` before closing a non-trivial browser verification run with a status block or handoff.

## Output format

```text
Request -> Evidence path -> Browser result -> Artifacts/cleanup -> Readiness impact -> Follow-up/Handoff
```

## Rules

- Do not run real-browser/visual/e2e commands or live-browser actions before the safety gates allow them.
- Do not use unsafe arbitrary-code browser tools by default.
- Do not treat missing real-browser/visual/e2e evidence as covered by non-browser tests.
- Do not store real browser auth/session state under a tracked worktree path.
- Keep generated screenshots, videos, traces, and logs only when they are required evidence; otherwise clean up or report what remains.
- Route unclear product behavior to **b-debug** and new test strategy or dependency choices to **b-plan** with explicit approval.
