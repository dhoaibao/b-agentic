## 1. Routing

Match the user's intent to one active skill before acting. If a request spans phases, sequence `Decide -> Build -> Validate`.

The intent and trigger tables below are generated from `skills/registry.yaml`; keep the surrounding precedence rules hand-authored.

<!-- generated:routing-intents:start -->
| Intent | Skill |
|---|---|
| End-to-end PR readiness workflow across phases | `b-orchestrate` |
| Decide how to build, decompose work | `b-plan` |
| External docs, API facts, comparisons | `b-research` |
| Execute approved or clearly scoped work | `b-implement` |
| Mechanical rename, extract, move, inline, simplify, delete | `b-refactor` |
| Runtime bug, error, "not working" | `b-debug` |
| Unit/integration/component tests, coverage, failing tests | `b-test` |
| Real-browser, visual, and e2e verification | `b-browser` |
| Pre-PR changed-code review and b-agentic suite audit | `b-review` |
<!-- generated:routing-intents:end -->

### Trigger precedence (when intents overlap)

- Explicit end-to-end PR-readiness workflows use `b-orchestrate` to coordinate phase-skill handoffs; single-phase asks stay with the phase owner.
- A failing test that likely exposes a real product bug beats `b-test`; use `b-debug`. See §10.
- A named behavior-preserving rename/extract/move/inline/simplify/delete beats `b-implement`; use `b-refactor`.
- Unclear user goal, end state, or acceptance criteria stays in `b-plan` (Clarification mode).
- Unclear implementation approach or sequencing with a clear goal beats `b-implement`; use `b-plan`.
- `b-research` is for genuine external-knowledge blockers, not for questions the codebase or repo docs can answer locally.
- Simulated DOM/component-test work routes to `b-test`; real-browser, visual, browser-session, live UI, and e2e verification routes to `b-browser`. No skill may add browser or DOM tooling as a side effect; see §10 for the boundary table and tool list.
- `b-ship` is explicit-command-only after readiness is established; do not route natural-language shipping intent to `b-implement` or any other phase skill.
- Bare mentions like `PR`, `ship`, or `lint` are ambiguous. Ask one clarifying question unless the user explicitly invoked `b-review`, `b-ship`, or a native command.
- b-agentic suite self-audits use `b-review --audit-suite` or explicit suite-audit prose; use `b-review` without the flag for all other codebase review tasks, including surface-wide checks. See §10 for the tiebreaker and inline Context7 threshold.
- `b-research` is invoked for ≥ 2 distinct doc questions or any deep extraction; ≤ 1 narrow inline lookup is acceptable within the active skill. See §10.

### One active skill

Keep one active skill until its stop condition is hit. Do not switch skills for optional enrichment or minor lookups that the current skill can finish with bounded evidence.

### Mid-flow switch policy

- A new request mid-flow does **not** auto-cancel the active skill. State the conflict in one line, ask the user whether to pause, queue, or abandon, then proceed.
- An explicit skill command from the user always overrides. Emit a handoff envelope (§9) before switching.
- A required sub-task (e.g., a research blocker discovered during `b-implement`) is a handoff, not a parallel run. Pause, hand off, resume — never both skills active.
- **Concurrency adjudication.** If the active skill is mid-iteration-cap (§7) or mid-transform (`b-implement` / `b-refactor`), the default is **queue** — finish the current verified step, emit a status block, then switch. If the active skill is mid-discovery only (no edits yet), the default is **pause**. The user may override either default; if they do, record the override in the handoff envelope.

### Clarification budget

Ask at most **2 clarification rounds** unless a real decision gate still blocks safe progress.

### Trigger phrases

The phrases below are routing aids only; do not duplicate them inside individual skill descriptions.

<!-- generated:routing-triggers:start -->
| Skill | Triggers |
|---|---|
| `b-orchestrate` | orchestrate, workflow, end-to-end, ready for PR, full cycle |
| `b-plan` | plan, design, decompose, approach, "how should I", clarify, requirements, scope |
| `b-research` | docs, library, API, compare, look up |
| `b-implement` | implement, add, build, execute, finish |
| `b-refactor` | rename, extract, move, inline, simplify, delete |
| `b-debug` | bug, broken, error, stack trace, "not working", regression |
| `b-test` | tests, coverage, failing test, snapshot, mock, component test, jsdom, happy-dom, React Testing Library |
| `b-browser` | browser, e2e, visual, screenshot, browser session, live UI, Playwright, Cypress e2e, Puppeteer, WebDriver |
| `b-review` | review, pre-PR, "what would a reviewer", b-agentic audit, suite audit, maintainer audit |
<!-- generated:routing-triggers:end -->

`b-ship` is intentionally absent from the routing tables above because it is invoked explicitly after review readiness is already established.

Ignore legacy or alternate skill trees that do not match the installed runtime contract unless the user explicitly asks to inspect or edit them.

---
