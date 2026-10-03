# b-agentic

**A slim personal workflow kernel for native Pi.**

b-agentic routes coding work to focused skills, preserves evidence and review
gates, and keeps the main session responsible for all worktree changes. It
installs an always-loaded Pi kernel, native skills and prompt templates,
read-only specialist agents, and managed MCP configuration.

- [Operational reference](REFERENCE.md) — install, lifecycle, safety, MCP, and validation.
- [Pi configuration layout](pi/configs/README.md) — managed paths and ownership boundaries.
- [Project guidance](AGENTS.md) and [decision design](docs/decision_design.md).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash
```

The installer updates Pi to the latest available release, installs nine unpinned
extensions (including [Magic Context](https://github.com/cortexkit/magic-context)), installs the [Dracula theme](https://draculatheme.com/pi-coding-agent)
and selects it when no theme is already chosen, writes managed assets under
`~/.pi/agent`, and preserves unrelated configuration. An interactive install
asks once when no ClickUp choice is recorded; non-interactive first installs or
upgrades default to off unless `B_AGENTIC_CLICKUP_MCP=yes` is set. Later install
and sync runs preserve the recorded choice; uninstall and reinstall to change it.
See [REFERENCE.md](REFERENCE.md) for flags and lifecycle behavior.

To refresh later without leaving Pi, run `/b-sync`: it pulls the installed source
and runs `install.sh --sync --force`, then reloads Pi. It does not update the Pi CLI.

## How it works

Each request uses one active skill rather than mixing planning, building,
validation, and shipping. The main Pi session owns user interaction,
decisions, verification, and mutations. It delegates bounded planning,
research, diagnosis, and changed-code review through native read-only
subagents, using background work only when it is independent and resuming a
compatible child through its supported task identifier.

![b-agentic overview: a user request enters the always-loaded kernel in the main Pi session, which routes it to one skill in the Decide, Build, Validate, or Ship phase and delegates bounded work to native read-only subagents. Built-in guardrails cover frozen review candidates, default-safe permissions, lazy managed MCP servers, and Pi extensions.](assets/b-agentic-overview.png)

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

Pi discovers the installed `SKILL.md` files. For an explicit route, use
generated prompt templates such as `/b-plan`, `/b-research`, `/b-implement`,
`/b-test`, and `/b-review`.

## Learn more

- [Operational reference](REFERENCE.md) — lifecycle, native permissions, MCP, and verification.
- [Pi configuration layout](pi/configs/README.md) — installed paths and ownership boundaries.
- [Decision design](docs/decision_design.md) — evidence-backed architecture decisions.
