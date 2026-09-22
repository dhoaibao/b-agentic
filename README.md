# b-agentic

**A slim personal workflow kernel for native OpenCode.**

b-agentic routes coding work to focused skills, preserves evidence and review
gates, and keeps the main session responsible for all worktree changes. It
installs an always-loaded OpenCode kernel, native skills and commands,
read-only specialist agents, and managed MCP configuration.

- [Operational reference](REFERENCE.md) — install, lifecycle, safety, MCP, and validation.
- [OpenCode configuration layout](opencode/configs/README.md) — managed paths and ownership boundaries.
- [Project guidance](AGENTS.md), [changelog](CHANGELOG.md), and [decision design](docs/decision_design.md).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash
```

The installer upgrades an existing OpenCode CLI with `opencode upgrade` (or
uses OpenCode v2's curl installer on first install), writes only under
`~/.config/opencode`, and preserves unrelated configuration. It detects but
never changes a legacy b-agentic installation in a different runtime directory.
See [REFERENCE.md](REFERENCE.md) for flags and lifecycle behavior.

## How it works

Each request uses one active skill rather than mixing planning, building,
validation, and shipping. The main OpenCode session owns user interaction,
decisions, verification, and mutations. It delegates bounded planning,
research, diagnosis, and changed-code review through native read-only
subagents, using background work only when it is independent and safely
continuing compatible research threads through their child session IDs.

| Phase | Skills | Purpose |
|---|---|---|
| **Decide** | `b-plan`, `b-research`, `b-design`, `b-debug` | Resolve ambiguity, gather external facts, diagnose runtime causes, or define a frontend standard. |
| **Build** | `b-frontend`, `b-diagram`, `b-implement`, `b-init`, `b-refactor` | Make the smallest approved change. |
| **Validate** | `b-test`, `b-browser`, `b-agentic-audit`, `b-review` | Confirm tests, browser evidence, repository conformance, and changed-code quality. |
| **Ship** | `b-commit`, `b-pr-summary` | Create explicitly requested local commits or write PR copy from local history. |

## Skills

<!-- generated:skills-table:start -->
| Skill | Phase | Use |
|---|---|---|
| `b-plan` | Decide | Figure out what to do when scope or approach is fuzzy, then produce an execution-ready plan |
| `b-research` | Decide | Fetch outside truth: docs, API facts, comparisons, or recent evidence |
| `b-design` | Decide | Create or refresh docs/DESIGN.md as a frontend design standard |
| `b-frontend` | Build | Implement contextual frontend/UI code, styling, responsive behavior, interactions, visual refreshes, and landing pages |
| `b-diagram` | Build | Create validated, portable technical architecture and flow diagrams from explicit facts |
| `b-implement` | Build | Make the scoped non-UI change from an approved plan or a small direct request |
| `b-init` | Build | Initialize or refresh repo-local agent instruction docs |
| `b-refactor` | Build | Rename, extract, move, inline, simplify, or delete behavior-preserving code |
| `b-debug` | Decide | Confirm the runtime root cause and produce an evidence-backed fix handoff without editing product code |
| `b-test` | Validate | Write or fix unit, integration, contract, and simulated-DOM tests |
| `b-browser` | Validate | Collect real-browser, visual, screenshot, live UI, or e2e evidence |
| `b-agentic-audit` | Validate | Audit b-agentic repository conformance, health, skill/kernel quality, and currentness |
| `b-review` | Validate | Review changed code |
| `b-commit` | Ship | Split working-tree changes into cohesive commits from an explicit user request |
| `b-pr-summary` | Ship | Write commit-backed PR copy or review and rewrite supplied PR prose |
<!-- generated:skills-table:end -->

OpenCode can select skills with its native `skill` tool. For an explicit route,
use generated commands such as `/b-plan`, `/b-research`, `/b-implement`,
`/b-test`, and `/b-review`.

## Learn more

- [Operational reference](REFERENCE.md) — lifecycle, native permissions, MCP, and verification.
- [OpenCode configuration layout](opencode/configs/README.md) — installed paths and ownership boundaries.
- [Decision design](docs/decision_design.md) — evidence-backed architecture decisions.
