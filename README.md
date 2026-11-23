# b-agentic

**A slim personal workflow kernel with equal main-flow parity across Claude Code (default install) and Pi.**

b-agentic routes coding work to focused skills, preserves evidence and review
gates, and keeps the main session responsible for worktree changes (an approved
`b-flow` step may be applied by a `b-worker`). It
installs an always-loaded kernel, skills (also `/b-*` commands in Claude Code),
read-only specialist agents, safety hooks, and managed MCP configuration.
Changed-code review runs through Codex (`openai/codex-plugin-cc`) and falls back
to the read-only `b-reviewer` subagent when Codex is unavailable.

- [Operational reference](REFERENCE.md) — install, lifecycle, safety, review gate, MCP, and validation.
- [Configuration layout](claude/configs/README.md) for Claude Code — managed paths and ownership boundaries.
- [Project guidance](AGENTS.md), the [ADR-001 design record](docs/decisions/ADR-001-b-agentic-design-record.md), and [ADR-020 Claude Code only again](docs/decisions/ADR-020-claude-code-only-again.md) (Claude Code is the default runtime).
- [Pi runtime](pi/README.md) — equal main-flow runtime (`./install.sh --runtime=pi`, [ADR-030](docs/decisions/ADR-030-pi-runtime-rendered-at-install.md), [ADR-032](docs/decisions/ADR-032-equal-runtimes-three-tier-support.md)).

## Install

```bash
git clone https://github.com/dhoaibao/b-agentic.git
cd b-agentic
./install.sh
```

The installer needs [Bun](https://bun.sh): Claude Code runs the hooks, status line, and helper scripts with it, and
the installer refuses without it. It copies skills, agents, hooks, and CLIs under `~/.claude`, adds the
kernel to `~/.claude/CLAUDE.md` as a marked block, merges permission rules,
hooks, and a status line (only when none is configured) into `settings.json` and MCP servers into `~/.claude.json`, and preserves
everything else. Without an explicit `y` on a post-sync interactive `[y/N]` prompt, it runs no vendor installers
(skipped under `-y`, `--dry-run`, `--uninstall`, `--statusline-only`, non-terminal stdout, or no `/dev/tty`).
b-agentic's own Claude sync writes only under `~/.claude` and `~/.claude.json`; interactively after sync, it offers
`[y/N]` prompts for missing `claude` (`curl -fsSL https://claude.ai/install.sh | bash`), `rtk`
(`curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh`),
`rtk init -g --hook-only --auto-patch` (adds RTK's hook to `~/.claude/settings.json`), and `codegraph`
(`curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh | sh`), whose `curl` installers
write outside `~/.claude`. Piped installs
(`curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash`)
clone to `~/.b-agentic-claude`. After installing, restart Claude Code. See
[REFERENCE.md](REFERENCE.md) for flags and lifecycle behavior.

Four optional components are never installed without a choice: DataGrip (`b-datagrip`), Excalidraw (`b-excalidraw` + MCP), draw.io (`b-drawio` + MCP), and Notion (MCP only; no b-agentic skill uses it). On a terminal without `-y`, `--dry-run`, or `--uninstall`, both installers show a step timeline, an optional-component checkbox list (pre-checking already-installed components), a summary box, and a confirm prompt before writing. Non-interactively pass `--with=excalidraw,drawio` to add and `--without=drawio` to remove; `-y` keeps the recorded choice and otherwise installs none.

Only want the Claude Code status line? `./install.sh --statusline-only` installs just
`b-statusline.mjs` and its `settings.json` entry (kept if you already have a status
line), with no skills, agents, hooks, kernel, or MCP servers. A later plain
`./install.sh` upgrades it to the full setup, and `--uninstall` removes it.

For the Pi runtime (`./install.sh --runtime=pi`, equal main-flow parity under [ADR-032](docs/decisions/ADR-032-equal-runtimes-three-tier-support.md) and rendered at install time per [ADR-030](docs/decisions/ADR-030-pi-runtime-rendered-at-install.md)), run from a local checkout with Pi `1.6.0+` (or accept the post-sync `[y/N]` prompt to run `curl -fsSL https://pi.dev/install.sh | sh`). b-agentic's own Pi sync renders the kernel, skills, prompt templates, agents (including `b-worker` per [ADR-031](docs/decisions/ADR-031-pi-worker-steps.md)), permission/subagent/MCP config, guard extension, helper wrappers, and vendored Dracula theme (`dracula.json`, set when `"theme"` is absent) solely into `~/.pi/agent`; on an interactive terminal (unless `-y`, `--dry-run`, `--uninstall`, non-terminal stdout, or no `/dev/tty`), post-sync `[y/N]` prompts offer missing `pi`, `rtk`, and `codegraph` via their native `curl` scripts (writing outside `~/.pi/agent`, never `rtk init`), while npm packages stay Pi-managed; see [pi/README.md](pi/README.md).

## How it works

Each request routes to one active skill rather than mixing planning, building,
validation, and shipping. Changes that route to `b-implement`, `b-frontend`,
`b-refactor`, or `b-test` run through `b-flow` with file-backed state in
`.b-agentic/runs/`: a **quick** run for a small, clear change (request is the
approval; never commits) or a **full** run (clarify, one user approval,
implement, verify, review, QA, and commit only under recorded consent; never
pushes or opens a PR).

The main session owns user interaction, decisions, verification, and worktree
mutations. It delegates bounded planning, research, diagnosis, repository audits,
and changed-code review to read-only subagents, and may hand approved `b-flow`
`worker_steps` (including up to two parallel worktree `parallel_steps`) to
`b-worker`. A change that touches security, permissions, contracts,
configuration, or workflow policy is frozen as a fingerprinted candidate (`b-snapshot`) and
reviewed independently; the main session recomputes the fingerprint afterward
and voids the review if the candidate moved. On Claude Code that reviewer is
Codex, run through a wrapper (`b-codex-guard`) that checks for secrets
before anything is sent to OpenAI, falling back to the read-only `b-reviewer`
subagent in a fresh context when Codex is unavailable. On Pi the review gate is
`b-reviewer`.

## Skills

<!-- generated:skills-table:start -->
| Skill | Phase | Use |
|---|---|---|
| `b-plan` | Decide | Figure out what to do when scope or approach is fuzzy, then produce an execution-ready plan |
| `b-research` | Decide | Fetch outside truth: docs, API facts, comparisons, or recent evidence |
| `b-design` | Decide | Create or refresh docs/DESIGN.md as a frontend design standard |
| `b-frontend` | Build | Implement contextual frontend/UI code, styling, responsive behavior, interactions, visual refreshes, and landing pages |
| `b-excalidraw` | Build | Sketch conceptual, whiteboard, and explanatory diagrams in Excalidraw from explicit facts (optional: `--with=excalidraw`) |
| `b-drawio` | Build | Draw formal or editable technical diagrams in draw.io from explicit facts (optional: `--with=drawio`) |
| `b-implement` | Build | Make the scoped non-UI change from an approved plan or a small direct request |
| `b-datagrip` | Build | Inspect and query DataGrip databases safely through the DataGrip MCP (optional: `--with=datagrip`) |
| `b-init` | Build | Initialize or refresh repo-local agent instruction docs |
| `b-refactor` | Build | Rename, extract, move, inline, simplify, or delete behavior-preserving code |
| `b-debug` | Decide | Confirm the runtime root cause and produce an evidence-backed fix handoff without editing product code |
| `b-test` | Validate | Write or fix unit, integration, contract, and simulated-DOM tests |
| `b-browser` | Validate | Collect real-browser, visual, screenshot, live UI, or e2e evidence |
| `b-agentic-audit` | Validate | Audit b-agentic repository conformance, health, skill/kernel quality, and currentness |
| `b-audit` | Validate | Audit the current project for defects, dependency currentness, architecture drift, test gaps, and docs drift |
| `b-review` | Validate | Review changed code |
| `b-qa` | Validate | Check a reviewed candidate against its acceptance criteria with fresh evidence and a QA verdict |
| `b-flow` | Build | Run a change as a quick or full run with file-backed state, artifacts, and evidence |
| `b-commit` | Ship | Split working-tree changes into cohesive commits from an explicit user request |
| `b-pr` | Ship | Push the current branch and open a draft PR from its commits |
<!-- generated:skills-table:end -->

Claude Code discovers the installed `SKILL.md` files as `/b-*` commands (`/b-plan`, `/b-flow`, `/b-research`, `/b-implement`, `/b-test`, `/b-review`, and so on); Pi installs them as skills and prompt templates.

## Learn more

- [Operational reference](REFERENCE.md) — lifecycle, permissions, review gate, MCP, and verification.
- [Configuration layout](claude/configs/README.md) — Claude Code installed paths and ownership boundaries.
- [Pi runtime](pi/README.md) — Pi install (`--runtime=pi`), packages, theme, maintenance gate, and checks.
- [Project guidance](AGENTS.md) — repository architecture, canonical sources, and verification.
- [ADR-001 design record](docs/decisions/ADR-001-b-agentic-design-record.md) — evidence-backed architecture decisions.
