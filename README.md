# b-agentic

**A slim personal workflow kernel for Claude Code, with Codex (or a read-only subagent) as the independent reviewer, and the Pi coding agent as an opt-in second runtime.**

b-agentic routes coding work to focused skills, preserves evidence and review
gates, and keeps the main session responsible for worktree changes (on Claude
Code, an approved `b-flow` step may be applied by a `b-worker`). It
installs an always-loaded kernel, skills (also `/b-*` commands in Claude Code),
read-only specialist agents, safety hooks, and managed MCP configuration.
Changed-code review runs through Codex (`openai/codex-plugin-cc`) and falls back
to the read-only `b-reviewer` subagent when Codex is unavailable. On Pi the
reviewer is always the `b-reviewer` subagent.

- [Operational reference](REFERENCE.md) — install, lifecycle, safety, review gate, MCP, and validation.
- [Configuration layout](claude/configs/README.md) for Claude Code and [Pi configuration](pi/configs/README.md) — managed paths and ownership boundaries.
- [Project guidance](AGENTS.md), the [ADR-001 design record](docs/decisions/ADR-001-b-agentic-design-record.md), and [ADR-011 Pi as a second runtime](docs/decisions/ADR-011-pi-second-runtime.md) (which supersedes the Claude-Code-only stance of [ADR-008](docs/decisions/ADR-008-claude-code-only.md)).

## Install

```bash
git clone https://github.com/dhoaibao/b-agentic.git
cd b-agentic
./install.sh
```

The installer copies skills, agents, hooks, and CLIs under `~/.claude`, adds the
kernel to `~/.claude/CLAUDE.md` as a marked block, merges permission rules,
hooks, and a status line (only when none is configured) into `settings.json` and MCP servers into `~/.claude.json`, and preserves
everything else. It never runs vendor installers. A Claude Code run only touches `~/.claude` and
`~/.claude.json`. Piped installs
(`curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash`)
clone to `~/.b-agentic-claude`. After installing, restart Claude Code. See
[REFERENCE.md](REFERENCE.md) for flags and lifecycle behavior.

### Pi (optional second runtime)

```bash
./install.sh --runtime=pi      # Pi only, under ~/.pi/agent
./install.sh --runtime=both    # Claude Code and Pi
```

`--runtime` defaults to `claude`. The Pi run installs the Pi skills, `/b-*` prompt
templates, specialist agents, the guard extension, the hooks and run CLIs it uses, and
the kernel as a marked block in `~/.pi/agent/AGENTS.md`. It merges three pinned packages
into `settings.json` (`pi-subagents`, `@gotgenes/pi-permission-system`,
`@juicesharp/rpiv-ask-user-question`) and the MCP servers into `mcp.json`, and it
writes the generated permission config only when none exists or it is b-agentic's own. It only touches
`~/.pi/agent`, never runs `pi install` or npm (Pi installs the pinned packages on its next
start), and reports a missing `pi` binary (Pi needs Node 22.19 or newer). The Codex gate, status line, and todo
list are not ported to Pi. See [REFERENCE.md](REFERENCE.md#pi-runtime) for the payload, the
permission config rules, and the known gaps.

Three skills and their MCP servers are optional and never installed without a
choice: DataGrip, Excalidraw, and draw.io. On a terminal the installer
shows a checkbox list (nothing checked on a fresh install; installed ones are
pre-checked). Non-interactively pass `--with=excalidraw,drawio` to add and
`--without=drawio` to remove; `-y` keeps the recorded choice and otherwise
installs none.

Only want the Claude Code status line? `./install.sh --statusline-only` installs just
`b-statusline.mjs` and its `settings.json` entry (kept if you already have a status
line), with no skills, agents, hooks, kernel, or MCP servers. A later plain
`./install.sh` upgrades it to the full setup, and `--uninstall` removes it.

## How it works

Each request uses one active skill rather than mixing planning, building,
validation, and shipping. The main session (Claude Code, or Pi when installed there) owns user interaction,
decisions, verification, and mutations. It delegates bounded planning,
research, diagnosis, repository audits, and changed-code review to read-only
subagents; on Claude Code only, it may hand one approved `b-flow` step at a time
to the `b-worker` writer. A change that touches security, permissions, contracts,
configuration, or workflow policy is frozen as a fingerprinted candidate and
reviewed independently; the main session recomputes the fingerprint afterward
and voids the review if the candidate moved. On Claude Code that reviewer is
Codex, a different model family, run through a wrapper that checks for secrets
and a per-repository approval before anything is sent to OpenAI. If Codex is
unavailable (plugin missing, signed out, usage limit), the `b-reviewer` subagent
reviews instead, in a fresh context. It is read-only by its tool list and prompt,
not a sandbox, and its independence comes from that context and role, not
necessarily a different model family.

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
| `b-review` | Validate | Review changed code |
| `b-qa` | Validate | Check a reviewed candidate against its acceptance criteria with fresh evidence and a QA verdict |
| `b-flow` | Build | Run a change as a quick or full run with file-backed state, artifacts, and evidence |
| `b-commit` | Ship | Split working-tree changes into cohesive commits from an explicit user request |
| `b-pr` | Ship | Push the current branch and open a draft PR from its commits |
<!-- generated:skills-table:end -->

Claude Code discovers the installed `SKILL.md` files, and each is also a command:
`/b-plan`, `/b-research`, `/b-implement`, `/b-test`, `/b-review`, and so on. On Pi the same
skills install from `pi/skills/`, and thin `/b-*` prompt templates point at them.

## Learn more

- [Operational reference](REFERENCE.md) — lifecycle, permissions, review gate, MCP, and verification.
- [Configuration layout](claude/configs/README.md) and [Pi configuration](pi/configs/README.md) — installed paths and ownership boundaries.
- [ADR-001 design record](docs/decisions/ADR-001-b-agentic-design-record.md) — evidence-backed architecture decisions.
