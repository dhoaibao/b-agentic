## 10. Cross-cutting decisions

### High-risk challenge gate

Before a skill reports completion on work touching auth/authz, security boundaries, migrations, public or external contracts, or irreversible external writes:

1. State the claim in one sentence.
2. Name the strongest remaining risk.
3. Name the evidence that makes the claim acceptable now.

Keep it short. If the evidence is missing or indirect, do not present the work as settled: widen verification, lower confidence, or stop.

For developer-tooling suites, public or external contracts include command wrappers, CLI flags, MCP tool names or schemas, installer behavior, generated config formats, exported APIs, route shapes, and documented runtime skill behavior.

### Test failure vs runtime bug

Owned here so `b-test` and `b-debug` agree. Use this table when a test is red:

| Signal | Lane |
|---|---|
| Assertion mismatch and production behavior is confirmed correct | `b-test` — update the test |
| Missing mock, fixture, setup, async/await, leaked state, snapshot drift after intentional change | `b-test` |
| Production behavior is uncertain, ambiguous, or under dispute | `b-debug` — confirm root cause first |
| Test reproduces a real reported symptom | `b-debug` |
| Newly added test exposes pre-existing wrong behavior | `b-debug` |
| Flaky test (passes on rerun without code change) | `b-test` — diagnose flake source; if root cause is a real race or timing bug in product code, switch to `b-debug` |

Never modify production code purely because a test is red. Never modify an assertion, snapshot, or golden file without confirming the intended behavior first.

### Snapshot confirmation procedure

1. State the intended new behavior in one sentence.
2. Point to the source change or product decision that justifies it.
3. Then update the snapshot.

### Flake handling

Rerun the suspected test up to 2 times in isolation. If it passes some runs and fails others without any code change, mark it `flaky`, capture the failing output under the active runtime's temp scratch path (for example, `/tmp/claude-code/b-agentic/b-test/`, `/tmp/opencode/b-agentic/b-test/`, `/tmp/codex-cli/b-agentic/b-test/`, or `/tmp/antigravity-cli/b-agentic/b-test/`), and investigate ordering, shared state, async timing, or external time/network dependence before either skipping or rewriting it.

### Browser and DOM verification boundary

| Test / Task | Skill | Why |
|---|---|---|
| React Testing Library + jsdom rendering a `<Button>` component in isolation | `b-test` | Simulated DOM, no real browser, no user interaction |
| Vue Test Utils mounting a component and checking computed props | `b-test` | Simulated DOM, no browser driver |
| Playwright clicking through a checkout flow end-to-end | `b-browser` | Real browser, user interaction, real network |
| Cypress component test mounting a button and firing click events | `b-test` | Component-level, no page navigation or real browser needed |
| Screenshot diff comparing two page renders | `b-browser` | Visual evidence requires real rendering context |
| jsdom testing that a form validation error appears on submit | `b-test` | Simulated DOM event, no real browser |
| Playwright navigating to login, filling credentials, asserting redirect | `b-browser` | Real browser navigation, auth/session state |
| React Testing Library testing a modal open/close with `fireEvent` | `b-test` | Simulated events, no real browser |

- jsdom, happy-dom, React Testing Library, Vue Test Utils, Svelte testing-library, and component tests using simulated DOM → `b-test`.
- Playwright, Cypress, WebdriverIO, Puppeteer, WebDriver, and any test that drives a real browser, captures screenshots, or tests across page navigations → `b-browser`.
- Visual, screenshot, browser-cookie, browser-session, real-network UI, and e2e flows are `b-browser` evidence surfaces.
- Do not add browser, DOM, visual, or e2e project tooling as a side effect. Adding or choosing a new framework requires `b-plan` first, then explicit dependency-write approval when implementation reaches that point.
- `b-browser` may assess supplied/CI evidence, run existing repo-provided commands, or use `playwright-browser-operator` after the §6 safety gates allow it. If no approved evidence path exists, stop with `cause: evidence_gap` or report an accepted follow-up.
- If real-browser, visual, or e2e evidence is relevant to PR readiness, do not report `READY FOR PR` until `b-browser` verifies supplied/CI evidence, existing-tool evidence, or approved live-browser evidence. If the user accepts the gap as a follow-up or skipped check, report `READY WITH FOLLOW-UPS` instead.

### Agent-cannot-reproduce protocol (shared across `b-debug` and `b-test`)

When the user can reproduce a symptom but the agent cannot in the current environment:

1. Do not patch defensively.
2. Capture every state difference between the user's failing context and the current environment: config, version, data, OS, runtime, env vars, feature flags.
3. Ask the user for **one or more** of:
   - the exact command or interaction sequence,
   - logs or stack trace at the moment of failure,
   - environment details (versions, env vars, feature flags),
   - a minimal repro snippet or test.
4. If the user cannot supply more, offer three options explicitly: (a) instrument and wait, (b) treat as one-shot and close, (c) investigate the captured environment diff.
5. Never silently substitute speculation for a real repro.

### b-audit vs b-review tiebreaker

`b-audit` is scoped exclusively to auditing the b-agentic suite itself — runtime contract consistency, skill layout alignment, installer, validator, tool boundaries, safety-gate drift, and documentation sync. It is not a general-purpose codebase auditing tool.

- For any codebase other than b-agentic, use `b-review` for all code inspection tasks, including surface-wide checks.
- For b-agentic suite work: use `b-review` when the request is diff/range-first (changed code review after implementation); use `b-audit` when the request is a surface-wide correctness, consistency, or operability check of the suite itself.

### Inline Context7 lookup threshold

A skill may resolve ≤ 1 narrow, self-contained Context7 lookup inline without invoking `b-research` — for example, one method signature, one config key, or one version-specific flag.

Hand off to `b-research` when the skill run requires:
- ≥ 2 distinct doc questions, regardless of source,
- deep extraction across multiple pages, versions, or documents,
- comparative analysis across libraries or frameworks, or
- any synthesis that would produce meaningful new content beyond a direct citation.

### Self-review vs reviewing-someone-else's-code

`b-review` handles both. The skill must state which mode it is in:
- **Self-review:** assume author bias. Be harsher on "obviously correct" assumptions; verify the spec the author claims to satisfy.
- **External review:** assume the author cannot answer follow-ups. Be explicit about what would block the merge vs what is style.

### Commit and PR boundary

The b-agentic suite stops at `READY FOR PR`. Commit, push, and PR creation are user-initiated actions via `b-ship`, which is explicit-command-only rather than a natural-language routing target. No phase skill (including `b-orchestrate`) creates commits, pushes, or opens PRs as a side effect of a review or implementation step.

For `b-ship`, review evidence means a `b-review` status block with `verdict: READY FOR PR` or `verdict: READY WITH FOLLOW-UPS`, or an explicit current-session user override. Approved plans and implementation status are not review evidence.

When a review, audit, or workflow uses named readiness labels, put that label in the final `[status]` block's `verdict:` field rather than hiding it in prose or `notes:`.

When a workflow closes with `verdict: READY FOR PR`, the final output must include: `Next: b-ship to commit and open the PR`.

### Abandonment protocol

When the user signals stop, cancel, or abort mid-workflow or mid-skill:

1. Emit a final `[status]` block with `state: needs-input`, `cause: user_blocked`.
2. List outstanding artifacts and their paths in the status block's `artifacts:` field.
3. Include a one-line resume hint in `notes:` (e.g., `resume: b-orchestrate <goal> -- continue from <phase>` or `resume: b-implement <plan-slug>`).
4. Do not delete artifacts. Leave the worktree in its current state; report any mid-transform leftovers.
5. Do not continue work after the abandonment signal unless the user explicitly resumes.

---
