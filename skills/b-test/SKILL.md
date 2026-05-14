---
name: b-test
description: >
  Test-driven development, test debugging, and test coverage evaluation.
  ALWAYS invoke when the user asks to write tests, fix failing tests,
  evaluate coverage, or work TDD-style. Unlike b-debug, which traces runtime
  bugs, b-test owns test-specific failures: wrong assertions, missing mocks,
  fixture or setup issues, and coverage gaps. Use the test-vs-bug decision in
  AGENTS.md §10 when a red test could go either way.
compatibility: opencode
metadata:
  suite: b-skills
---

# b-test

$ARGUMENTS

Own code-level test work: write tests, fix test-only failures, and evaluate coverage without treating every red test as proof that production code is wrong.

If `$ARGUMENTS` is provided, treat it as the test task or failing symptom and proceed directly.

## When to use

- User asks to write tests for new or existing behavior.
- A test is failing and the **test-vs-bug decision** in `AGENTS.md` §10 routes the work to the test lane.
- User asks about coverage gaps or missing regression tests.
- DOM-rendered unit tests (jsdom, happy-dom, React Testing Library, Vue Test Utils, Svelte testing-library) — these stay here, not in **b-e2e**. See the **DOM-unit vs browser-flow boundary** in `AGENTS.md` §10.
- **Hybrid component tests** (component-scoped tests that mount a real router, real store, real query client, or other non-trivial provider chain) stay in **b-test** as long as the runner is jsdom/happy-dom/node — the test is still a unit/integration test, just with realistic wiring. Route to **b-e2e** only when a real browser engine drives the flow. When a hybrid test starts requiring real network, real cookies, or visual assertions, that is the signal to promote it to **b-e2e**, not to keep stretching jsdom.

## When NOT to use

- The failing test likely exposes a real runtime or product bug (`AGENTS.md` §10) → use **b-debug**.
- The task drives a real browser (Playwright, Cypress, WebdriverIO, Puppeteer) → use **b-e2e**.
- Scope or acceptance is still unclear → use **b-plan**.
- The request is a pre-PR logic review → use **b-review**.
- The task is only an external docs or testing-framework lookup → use **b-research**.
- The task is designing a new property-based, fuzzing, or contract-testing strategy/framework → use **b-plan** first. Adding a small test in an already-established project pattern may stay in **b-test**.

## Boundary examples

- **Use b-test:** "Fix the Vitest mock setup" or "add regression tests for retry backoff" when the intended behavior is already known.
- **Use b-debug instead:** "The new regression test proves the API now returns the wrong shape" because the red test is evidence of a product bug.
- **Use b-e2e instead:** "Verify the signup flow in a real browser" even if the repo also has unit tests.

## Tools required

- `bash` — run project test and coverage commands, inspect failure output.
- Native file tools — discover test files, manifests, and focused source/test sections.
- `serena-symbol-toolkit` *(preferred for mapping tests to source behavior and editing existing test code)*
- `context7-docs` *(optional, for verifying testing-framework APIs or matcher behavior)*

Fallbacks: `AGENTS.md` §4 MCP fallback ladder. Without Serena, discover tests with native tools and edit carefully with `apply_patch`. The Serena LSP coverage caveat applies.

Graceful degradation: ✅ Possible — the core workflow still works with native file tools, `bash`, and `apply_patch`.

## Steps

### Step 1 — Discover framework and scope

1. Locate the relevant test files and project-specific test commands from manifests or CI config.
2. If the user named a failing test, start from the narrowest runnable target for that test.
3. Initialize Serena per `AGENTS.md` §4 only when symbol-aware inspection adds value.
4. Map the test ↔ source relationship with the cheapest discovery tool that closes the next question.

**Empty-state** (`AGENTS.md` §7): if the repo has no test framework, do not introduce one as a side effect. Ask the user before adding a framework, even when the request implies tests are wanted.

### Step 2 — Choose the lane

Use `AGENTS.md` §10 (test failure vs runtime bug) to pick the lane:

- **Failing test** — fix the test, fixture, setup, or clearly confirmed production bug.
- **Write tests** — add new regression, unit, or integration coverage for known behavior.
- **Coverage review** — identify the highest-value missing tests and optionally add the top ones.
- **Flaky test** — apply the flake handling procedure in `AGENTS.md` §10 before rewriting or skipping.

If the failure might reflect a real product bug and the correct behavior is not already confirmed, switch to **b-debug**.

### Step 3 — Fix or add tests

**Failing test:**
1. Run the narrowest test command.
2. If output is large, capture it under `/tmp/opencode/b-skills/b-test/` (`AGENTS.md` §7) and inspect the failure section.
3. Read the failing test and the source behavior it exercises.
4. Classify per the test-vs-bug table in `AGENTS.md` §10.
5. For snapshot or golden updates, follow the **snapshot confirmation procedure** in `AGENTS.md` §10.

**New tests:**
1. Identify the behavior, branches, and edge cases that matter.
2. Choose unit or integration scope; hand real-browser flows to **b-e2e**.
3. Cover happy path, edge cases, error handling, and the regression that would catch an accidental revert.
4. Prefer local fixtures unless the repo already has a shared fixture that fits the scenario.

**Coverage review** — rank gaps by value:

| Priority | Gap shape |
|---|---|
| **1 — required** | Changed behavior in the current diff without any covering test. |
| **2 — strong** | Public-contract symbols (exports, routes, handlers, CLI flags) without a regression test. |
| **3 — useful** | Widely referenced internal symbols (high fan-in) without a regression test. |
| **4 — opportunistic** | Edge cases of branches already partially covered. |

Discover the project's existing coverage command before inventing one. If the repo has no coverage runner, ask before adding one. Optionally add the top 1–3 missing tests when the user wants implementation, not just analysis.

**Advanced tests** — property-based, fuzz, and contract tests stay here only when the repo already has an established runner and pattern. If the framework, boundary contract, generator strategy, or CI cost needs design, hand off to **b-plan** instead of inventing it inside a test edit.

Prefer `serena-symbol-toolkit` insertions for existing test bodies. Use `apply_patch` when creating a new test file or when a small non-symbol edit is clearer.

### Step 4 — Verify

1. Run `get_diagnostics_for_file` on touched files — both the test and the underlying source — when the language supports it.
2. Re-run the narrowest relevant tests.
3. Widen to a broader suite only when the change touches shared fixtures/helpers, public contracts, or the repo's normal test workflow requires it (verification ladder in `AGENTS.md` §7).
4. Apply the iteration cap from `AGENTS.md` §7.

Close with the skill-exit status block (`AGENTS.md` §9).

## Output format

```text
### b-test: [test task]

**Type:** [failing test / write tests / coverage review / flaky test]
**Framework:** [jest / vitest / pytest / go test / cargo test / other]
**Scope:** [unit / integration / DOM-unit / mixed]

#### Findings
- `[path]` — [what was wrong or what behavior needed coverage]

#### Changes
- `[path:line]` — [test fix or test added]

#### Verification
```bash
[command]
```
[result]

#### Remaining gaps
- [none / uncovered case / follow-up suggestion]
```

## Rules

- Never change production code just because a test is red. Defer to `AGENTS.md` §10.
- Never update an assertion, snapshot, or golden file without confirming intended behavior first; follow the snapshot procedure in `AGENTS.md` §10.
- Real-browser flows belong to **b-e2e**; keep DOM-rendered unit tests here.
- Do not introduce property-based, fuzz, or contract-testing frameworks without a plan and explicit approval.
- Prefer behavior assertions over implementation-detail assertions.
- Keep fixture, mock, and setup changes as local as practical.
- State when broader suite coverage was skipped and why the narrower check was sufficient.
- Never introduce a test framework or coverage runner without explicit approval.
