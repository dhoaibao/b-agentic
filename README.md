# b-agentic

**A slim personal workflow kernel for Claude Code, with a read-only subagent as the independent reviewer.**

b-agentic routes coding work to focused skills, preserves evidence and review
gates, and keeps the main session responsible for all worktree changes. It
installs an always-loaded kernel, skills (also `/b-*` commands in Claude Code),
read-only specialist agents, safety hooks, and managed MCP configuration for
Claude Code. Changed-code review runs in the read-only
`b-reviewer` subagent, so it needs no second subscription and sends nothing to
another vendor.

- [Operational reference](REFERENCE.md) — install, lifecycle, safety, review gate, MCP, and validation.
- [Configuration layout](claude/configs/README.md) — managed paths and ownership boundaries.
- [Project guidance](AGENTS.md), the [ADR-001 design record](docs/decisions/ADR-001-b-agentic-design-record.md), and [ADR-004](docs/decisions/ADR-004-codex-runtime.md) (OpenCode removed, Codex planned as the second runtime).

## Install

```bash
git clone https://github.com/dhoaibao/b-agentic.git
cd b-agentic
./install.sh
```

The installer copies skills, agents, hooks, and CLIs under `~/.claude`, adds the
kernel to `~/.claude/CLAUDE.md` as a marked block, merges permission rules and
hooks into `settings.json` and MCP servers into `~/.claude.json`, and preserves
everything else. It never runs vendor installers and never writes under
`~/.pi`. Piped installs
(`curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash`)
clone to `~/.b-agentic-claude`. After installing, restart Claude Code. See
[REFERENCE.md](REFERENCE.md) for flags and lifecycle behavior.

## How it works

Each request uses one active skill rather than mixing planning, building,
validation, and shipping. The main Claude Code session owns user interaction,
decisions, verification, and mutations. It delegates bounded planning,
research, diagnosis, repository audits, and changed-code review to read-only
subagents. A change that touches security, permissions, contracts,
configuration, or workflow policy is frozen as a fingerprinted candidate and
reviewed by the `b-reviewer` subagent in a fresh context; the main session
recomputes the fingerprint afterward and voids the review if the candidate
moved. The reviewer is read-only by its tool list and prompt, not a sandbox, and
shares the main session's model family, which is the accepted trade-off against
a cross-vendor reviewer.

## Skills

<!-- generated:skills-table:start -->
| Skill | Phase | Use |
|---|---|---|
| `b-plan` | Decide | Figure out what to do when scope or approach is fuzzy, then produce an execution-ready plan |
| `b-research` | Decide | Fetch outside truth: docs, API facts, comparisons, or recent evidence |
| `b-design` | Decide | Create or refresh docs/DESIGN.md as a frontend design standard |
| `b-frontend` | Build | Implement contextual frontend/UI code, styling, responsive behavior, interactions, visual refreshes, and landing pages |
| `b-excalidraw` | Build | Sketch conceptual, whiteboard, and explanatory diagrams in Excalidraw from explicit facts |
| `b-drawio` | Build | Draw formal or editable technical diagrams in draw.io from explicit facts |
| `b-implement` | Build | Make the scoped non-UI change from an approved plan or a small direct request |
| `b-clickup` | Build | Create and update ClickUp tasks with a consistent four-section description |
| `b-datagrip` | Build | Inspect and query DataGrip databases safely through the DataGrip MCP |
| `b-init` | Build | Initialize or refresh repo-local agent instruction docs |
| `b-refactor` | Build | Rename, extract, move, inline, simplify, or delete behavior-preserving code |
| `b-debug` | Decide | Confirm the runtime root cause and produce an evidence-backed fix handoff without editing product code |
| `b-test` | Validate | Write or fix unit, integration, contract, and simulated-DOM tests |
| `b-browser` | Validate | Collect real-browser, visual, screenshot, live UI, or e2e evidence |
| `b-agentic-audit` | Validate | Audit b-agentic repository conformance, health, skill/kernel quality, and currentness |
| `b-review` | Validate | Review changed code |
| `b-qa` | Validate | Check a reviewed candidate against its acceptance criteria with fresh evidence and a QA verdict |
| `b-commit` | Ship | Split working-tree changes into cohesive commits from an explicit user request |
| `b-pr` | Ship | Push the current branch and open a draft PR from its commits |
<!-- generated:skills-table:end -->

Claude Code discovers the installed `SKILL.md` files, and each is also a command:
`/b-plan`, `/b-research`, `/b-implement`, `/b-test`, `/b-review`, and so on.

## Learn more

- [Operational reference](REFERENCE.md) — lifecycle, permissions, review gate, MCP, and verification.
- [Configuration layout](claude/configs/README.md) — installed paths and ownership boundaries.
- [ADR-001 design record](docs/decisions/ADR-001-b-agentic-design-record.md) — evidence-backed architecture decisions.
