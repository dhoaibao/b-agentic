## Runtime contract

This is the default detailed reference for routing, source of truth, risk, execution, evidence, artifacts, and session lifecycle. Read it when the kernel or active skill needs more precision than the always-on rules.

### Routing

Match the user's intent to exactly one active skill before acting. If a request spans phases, sequence `Decide -> Build -> Validate`; do not run multiple skills in parallel.

The intent and trigger tables below are generated from `skills/registry.yaml`; keep the surrounding precedence rules hand-authored.

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

Precedence rules:
- Multi-phase asks sequence `Decide -> Build -> Validate`; single-phase asks stay with the phase owner.
- A failing test that likely exposes a real product bug beats `b-test`; use `b-debug`.
- A named behavior-preserving rename/extract/move/inline/simplify/delete beats `b-implement`; use `b-refactor`.
- Unclear goals, end states, acceptance criteria, sequencing, or approach stay in `b-plan`.
- `b-research` is for genuine external-knowledge blockers, not for questions the repo can answer locally.
- Simulated DOM/component-test work routes to `b-test`; real-browser, visual, browser-session, live UI, and e2e verification routes to `b-browser`.
- `b-ship` is explicit-command-only after review readiness.
- Bare mentions like `PR`, `ship`, or `lint` are ambiguous. Ask one clarifying question unless the user explicitly invoked `b-review`, `b-ship`, or a native command.
- b-agentic suite self-audits use `b-review --audit-suite` or explicit suite-audit prose; all other codebase review tasks remain changed-code reviews unless explicitly scoped.
- `b-research` is invoked for >= 2 distinct doc questions or any deep extraction; <= 1 narrow inline lookup is acceptable within the active skill.

Keep one active skill until its stop condition is hit. A required sub-task is a handoff, not a parallel run. If the active skill is mid-transform, finish the current verified step before switching unless the user explicitly overrides.

### Trigger phrases

The phrases below are routing aids only; do not duplicate them inside individual skill descriptions.

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

### Source of truth and plans

Use this ladder: latest user instruction, approved saved plan, approved chat plan, current repo evidence, then stated assumptions.

Saved plans under `.b-agentic/b-plan/` are the local approval cache and execution source of truth. Before executing one, validate frontmatter, approval status or current-chat approval, staleness, touch points, and unchecked steps with `Done when` verification. Legacy plans without frontmatter may execute only with current-chat approval.

Plan frontmatter for durable plans: `slug`, `status`, `created_at`, `approved_at`, `approved_by`, `approved_head`, `risk`, `touch_points`.

### Runtime-native capabilities

Claude Code is the reference runtime and capability ceiling. A runtime-native capability may become shared b-agentic intent only when the Claude Code entry in `runtimes/registry.yaml` marks that capability with `adoption: "shared"`. Other runtimes may adapt that shared intent with `support: "native"` or `support: "adapter"`, but they must not promote a capability to shared behavior when the Claude Code entry is `deferred`, `adapter-only`, or `unsupported`.

Runtime-native capabilities include skills, permissions, hooks, rules, subagents, plugins, command wrappers, and custom tools. Adapter-only capabilities can improve one runtime's ergonomics, but shared prompts and contract prose must not require them. Deferred capabilities are acknowledged but not part of the active workflow contract.

Subagents are optional accelerators. They may gather evidence, isolate broad search output, or review bounded slices, but the active b-agentic skill owns final decisions, verification claims, status blocks, handoffs, and verdicts. Do not use subagents to auto-continue phase-to-phase workflow or bypass approval gates.

### Risk and bypass rules

Small direct requests may bypass `b-plan` only when they touch 3 or fewer files, have no public contract change, have no sensitive path, and leave no design decision.

Severity: **BLOCKER** cannot ship; **MAJOR** should fix before PR; **MINOR** is a non-blocking bug-prone gap; **NIT** is optional preference.

Risk: **trivial** one-file internal work; **low** single-module internal work; **medium** multi-file/shared work; **high** public contract, schema, migration, auth/security/billing, or broad blast radius.

### Evidence and execution

Use the lightest reliable evidence: runtime or symbol evidence for code behavior, exact text for prose/config/contracts, and fetched primary sources for external facts. Label weaker evidence and lower confidence when primary evidence is missing.

Before non-trivial work, define success, run `git status --short`, note relevant dirty state, check for matching approved plans, and confirm the active skill. Preserve unrelated worktree changes.

Implement the smallest coherent step. Classify adjacent discoveries as required, blocking decision, or follow-up before expanding scope. Verify narrowly first, then widen only when risk justifies it. Never report complete while the tree is mid-transform.

Completion requires the requested scope done, required verification run or explicitly skipped, cleanup state known, and no unreported blocker. Use `baseline-missing`, `degraded`, or lower confidence when evidence is incomplete.

### Artifacts

Create artifacts only for coordination, evidence, or auditability. Use slug/run-id form `<YYYYMMDD-HHMMSS>-<task-slug>` when an artifact is written or a handoff chain exists.

Repo-local artifacts:
- Saved plans: `.b-agentic/b-plan/<plan-file-slug>.md`
- Skill artifacts: `.b-agentic/<skill>/<run-id>/`
- Saved reports: `.b-agentic/<skill>/<run-id>/report.md`

Apply the `.b-agentic/.gitignore` guard before writing repo-local artifacts. Do not store secrets or real browser auth/session state under tracked worktree paths.

Runtime user-scope and temp examples:
- Claude Code references: `~/.claude/b-agentic/references/contract/`; temp root: `/tmp/claude-code/b-agentic/`
- OpenCode references: `~/.config/opencode/b-agentic/references/contract/`; temp root: `/tmp/opencode/b-agentic/`
- Codex CLI references: `~/.codex/b-agentic/references/contract/`; temp root: `/tmp/codex-cli/b-agentic/`

---
