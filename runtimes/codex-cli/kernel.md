<!-- b-agentic-managed -->
<!-- Generated from references/contract/kernel.template.md and runtimes/registry.yaml. Edit those sources, not this file. -->

# b-agentic - Agent Workflow Kernel for Codex CLI

Use these rules before any skill-specific instruction.

## Core Rules

1. Route the user's current intent to one active skill. Sequence phases instead of blending them.
2. Follow the source-of-truth order: latest user instruction, approved plan, repo evidence, then stated assumptions.
3. For non-trivial repo work, run `git status --short`, preserve unrelated changes, and define success before editing.
4. Ask before dependency writes, long-lived services, migrations, commits, pushes, PRs, destructive commands, external writes, broad refactors, or shared-environment mutation.
5. Never read or expose likely secrets, customer data, private stack traces, internal URLs, or proprietary code to public tools without explicit approval.
6. Use the lightest reliable evidence: local text and commands for repo facts, symbol tools for code behavior, primary fetched sources for external facts.
7. Use tools by ownership: Serena for symbols, Context7 for versioned docs, Brave for discovery, Firecrawl for extraction, Playwright for browser evidence.
8. Make the smallest coherent change and verify with the narrowest useful check. Do not claim completion with missing or failed required evidence.
9. Keep output concise. Use structured blocks only for handoffs, blockers, review verdicts, or shipping approvals.

## Routing

- Planning, design, unclear scope -> `b-plan`.
- External docs/API/current facts -> `b-research`.
- Approved plan or small direct build -> `b-implement`.
- Named behavior-preserving rename/extract/move/inline/simplify/delete -> `b-refactor`.
- Runtime bug, broken behavior, stack trace, slowdown -> `b-debug`.
- Unit/integration/contract/component/simulated-DOM tests -> `b-test`.
- Browser, visual, screenshot, live UI, session, or e2e evidence -> `b-browser`.
- Changed-code review or b-agentic suite audit -> `b-review`.
- Commit/push/PR -> `b-ship` only on explicit user request.

Detailed refs live under `~/.codex/b-agentic/references/contract/`:
- `runtime.md` - routing, source of truth, work discipline, artifacts.
- `safety-tools.md` - approvals, privacy, git safety, tool ownership.
- `output.md` - handoff, blocked, review, and ship output shapes.

Skill argument injection: `$ARGUMENTS` is the shared argument token. Treat unresolved `$ARGUMENTS` as no arguments provided.

---
