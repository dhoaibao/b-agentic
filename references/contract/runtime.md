## Runtime Contract

b-agentic is a workflow kernel for developer agents. Its job is to keep work routed, scoped, safe, and verified without adding ceremony.

### Routing

Use exactly one active skill for the user's current intent. If a request spans phases, sequence the work instead of blending responsibilities.

<!-- generated:routing-intents:start -->
| Intent | Skill |
|---|---|
| Decide how to build, decompose work | `b-plan` |
| External docs, API facts, comparisons | `b-research` |
| Execute approved or clearly scoped work | `b-implement` |
| Mechanical rename, extract, move, inline, simplify, delete | `b-refactor` |
| Runtime bug, error, "not working" | `b-debug` |
| Unit/integration/component tests, coverage, failing tests | `b-test` |
| Real-browser, visual, and e2e verification | `b-browser` |
| Pre-PR changed-code review and b-agentic suite audit | `b-review` |
<!-- generated:routing-intents:end -->

Precedence:
- Unclear goal or approach -> `b-plan`.
- External facts that local repo evidence cannot answer -> `b-research`.
- Approved plan or small direct edit -> `b-implement`.
- Named behavior-preserving transform -> `b-refactor`.
- Runtime failure or bug report -> `b-debug`.
- Test mechanics, fixtures, assertions, coverage -> `b-test`.
- Real browser, visual, screenshot, live UI, or e2e evidence -> `b-browser`.
- Review changed code or this suite -> `b-review`.
- Commit, push, or PR -> `b-ship` only on explicit user request.

<!-- generated:routing-triggers:start -->
| Skill | Triggers |
|---|---|
| `b-plan` | plan, design, decompose, approach, "how should I", clarify, requirements, scope |
| `b-research` | docs, library, API, compare, look up |
| `b-implement` | implement, add, build, execute, finish |
| `b-refactor` | rename, extract, move, inline, simplify, delete |
| `b-debug` | bug, broken, error, stack trace, "not working", regression |
| `b-test` | tests, coverage, failing test, snapshot, mock, component test, jsdom, happy-dom, React Testing Library |
| `b-browser` | browser, e2e, visual, screenshot, browser session, live UI, Playwright, Cypress e2e, Puppeteer, WebDriver |
| `b-review` | review, pre-PR, "what would a reviewer", b-agentic audit, suite audit, maintainer audit |
<!-- generated:routing-triggers:end -->

### Source Of Truth

Use this order: latest user instruction, approved saved plan, approved chat plan, current repo evidence, then stated assumptions.

Saved plans under `.b-agentic/b-plan/` are optional coordination artifacts, not required ceremony. Execute them only when approved and still compatible with the worktree.

### Work Discipline

For non-trivial repo work, check `git status --short`, preserve unrelated changes, make the smallest coherent change, and verify with the narrowest useful check.

Do not invent product behavior, acceptance criteria, compatibility promises, names, or verification commands. If evidence is incomplete, say so and lower confidence.

### Operating Bias

Surface ambiguity, assumptions, tradeoffs, and blockers before acting. If multiple interpretations are plausible, do not silently choose one unless the choice is low-risk and reversible.

Prefer the smallest sufficient solution. Do not add speculative flexibility, abstractions, compatibility layers, or error handling that the task and evidence do not require.

Every changed line should trace to the user's request, an approved plan, or cleanup made necessary by the current change. Mention unrelated cleanup opportunities instead of doing them.

Define or infer concrete success criteria and verify them before claiming done. If success cannot be verified with available evidence, state the gap.

### Artifacts

Create artifacts only when they help coordination, auditability, or large-output handling. Do not write artifacts for ordinary chat-only work.

Repo-local b-agentic artifacts belong under `.b-agentic/` and must not contain secrets, browser auth state, private stack traces, or customer data.

### Output Discipline

Default output is concise prose. Use structured blocks only when they reduce ambiguity: handoffs, blockers, review verdicts, or shipping approvals.

Use a handoff only when another skill must continue the work, and include source skill, goal, decisions, assumptions, relevant files, verification, blockers, and next skill.

Use a blocked-work note only when the requested work cannot continue, and include the active skill, blocker, needed user/tool/evidence/approval, and completed work.

Review verdicts are `READY FOR PR`, `READY WITH FOLLOW-UPS`, or `NEEDS FIXES`. Findings come first in reviews, ordered by severity with file references when available.

Before commit, push, or PR creation, report branch, intended staged files, recent commit context, verification, and the exact command that needs approval.

---
