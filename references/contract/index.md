# b-agentic — Agent Workflow Kernel Contract

> Detailed schemas, rubrics, edge-case protocols, tool bundles, and operational rules for the `b-agentic` agent workflow kernel. The active runtime kernel lives in the runtime's installed memory file. Installed skills should read shared contract files from the runtime's shared reference snapshot (for example, `~/.claude/b-agentic/references/contract/`, `~/.config/opencode/b-agentic/references/contract/`, `~/.codex/b-agentic/references/contract/`, `~/.gemini/antigravity-cli/b-agentic/references/contract/`, `~/.cursor/b-agentic/references/contract/`, or `~/.agents/b-agentic/references/contract/`) and skill-local support files from their own skill directory when a skill points to detailed behavior. Installed contract files live in the active runtime's b-agentic reference directory, and temporary run artifacts in the active runtime's temp scratch path (for example, `/tmp/claude-code/b-agentic/`, `/tmp/opencode/b-agentic/`, `/tmp/codex-cli/b-agentic/`, `/tmp/antigravity-cli/b-agentic/`, `/tmp/cursor/b-agentic/`, or `/tmp/zed/b-agentic/`).

## Quick Index

Use this index to jump to the smallest section file that owns the needed schema, rubric, protocol, or checklist. Skills should keep referencing stable section files, not copy these rules locally.

## Decision Cards

Use these when you need a short point-of-use reminder before opening the full contract section.

| Card | File | Use before |
|---|---|---|
| Routing | `cards/routing.md` | switching skills or choosing between nearby phase owners |
| Before edit | `cards/before-edit.md` | editing files, mutating environments, or writing artifacts |
| Before ready | `cards/before-ready.md` | claiming completion or readiness |
| Review verdict | `cards/review-verdict.md` | closing `b-review` or a review-driven workflow |
| Browser boundary | `cards/browser-boundary.md` | deciding between `b-test` and `b-browser` |
| Output and handoff | `cards/output-handoff.md` | emitting `[status]`, `[handoff]`, or a non-trivial closeout |

| Section | File | Owns | Read before |
|---|---|---|---|
| §0 Relationship To Runtime Kernel | `contract/00-kernel.md` | reference-gate mechanics, gate taxonomy, contract version | applying shared gates or checking kernel/detail boundaries |
| §1 Routing | `contract/01-routing.md` | skill selection, trigger precedence, mid-flow switches, clarification budget | switching skills or resolving overlapping intents |
| §2 Source of truth and plan lifecycle | `contract/02-source-of-truth.md` | source ladder, saved-plan metadata, staleness, revisions | executing, validating, or revising saved plans |
| §3 Definitions and rubrics | `contract/03-definitions.md` | non-trivial threshold, small-direct threshold, readiness, severity, risk, confidence | classifying work, risk, findings, or confidence |
| §4 Tool model | `contract/04-tool-model.md` | tool priority, MCP bundles, fallbacks, cost/depth heuristics | choosing or degrading MCP/tool paths |
| §5 Evidence standards | `contract/05-evidence.md` | evidence hierarchy, baseline taxonomy, citations, freshness, token budget | making claims from code/docs/web evidence |
| §6 Safety gates | `contract/06-safety.md` | approvals, privacy, sensitive files, artifacts, worktree, patch and git safety | mutating files, environments, dependencies, or external/shared state |
| §7 Execution discipline | `contract/07-execution.md` | scope expansion, verification ladder, iteration/cascade/rollback, skipped checks | verifying work, handling failures, or claiming completion |
| §8 Artifacts | `contract/08-artifacts.md` | slugs, run-ids, artifact paths, manifests, retention | writing plans, reports, logs, screenshots, or run artifacts |
| §9 Output contract | `contract/09-output.md` | language, status blocks, saved reports, error causes, handoffs, verbosity caps | emitting non-trivial final output or handoffs |
| §10 Cross-cutting decisions | `contract/10-decisions.md` | high-risk completion, test-vs-bug, snapshots, flakes, browser boundary, cannot-reproduce | resolving shared edge cases across skills |
| §11 Session lifecycle | `contract/11-session.md` | session preflight, crash/resume, cross-skill conventions | starting non-trivial work or resuming prior runs |
| §12 Common rationalizations | `contract/12-anti-patterns.md` | suite-wide anti-patterns and counters | checking whether a shortcut violates suite discipline |

---
