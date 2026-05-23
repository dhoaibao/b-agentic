# b-agentic

**An 11-skill agent workflow kernel for Claude Code and OpenCode.**

`b-agentic` turns rough developer intent into disciplined loops: clarify, plan, build, validate, debug, review, and audit. It is optimized around scoped execution, repo evidence, MCP tools, verification, and clean handoffs.

Claude Code is the reference runtime; OpenCode is supported via a bridge adapter. Skills install as native skills and appear as `/b-*` commands.

## Install & Update

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash
```

Preview without writing into `~/.claude/`:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --dry-run
```

Replace an existing `~/.claude/CLAUDE.md` after reviewing the managed snapshot:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --replace-memory
```

Uninstall managed files:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --uninstall
```

The installer deploys this repo into the active runtime's personal config:

**Claude Code (default):**
- `runtimes/claude-code/kernel.md` -> `~/.claude/CLAUDE.md` when missing or approved
- `skills/<name>/` -> `~/.claude/skills/<name>/`
- `references/*.md` -> `~/.claude/b-agentic/references/`
- `references/*.md` -> `~/.claude/skills/<name>/references/b-agentic/` for each skill
- `runtimes/claude-code/configs/*.json` -> `~/.claude/b-agentic/templates/`
- `runtimes/claude-code/configs/settings.template.json` -> merged into `~/.claude/settings.json`
- `runtimes/claude-code/configs/mcp.user.template.json` -> merged into `~/.claude.json`
- install metadata and backups -> `~/.claude/b-agentic/`

**OpenCode:**
- `runtimes/opencode/kernel.md` -> `~/.config/opencode/AGENTS.md` when missing or approved
- `skills/<name>/` -> `~/.claude/skills/<name>/` (cross-tool compatibility)
- `references/*.md` -> `~/.config/opencode/b-agentic/references/`
- `references/*.md` -> `~/.claude/skills/<name>/references/b-agentic/` for each skill
- `runtimes/opencode/configs/mcp.user.template.json` -> merged into `~/.config/opencode/opencode.json` with Serena configured as `serena start-mcp-server --context ide --project-from-cwd`
- `runtimes/opencode/configs/*.md` -> `~/.config/opencode/b-agentic/templates/`
- install metadata and backups -> `~/.config/opencode/b-agentic/`

Use `--runtime=opencode` or set `B_AGENTIC_RUNTIME=opencode` to install for OpenCode:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --runtime=opencode
```

If an existing kernel file is preserved, the installer exits with `activationState: pending`. Review the managed snapshot, then rerun with `--replace-memory` or merge the kernel manually.

## One Command

Plain install syncs the runtime, merges recommended settings, and installs all MCP servers at Claude Code user scope:

```text
b-agentic Claude Code install complete
skillsSynced: 11 -> ~/.claude/skills
kernel: write|replace|preserve -> ~/.claude/CLAUDE.md
settings: write|merge -> ~/.claude/settings.json
mcp: write|merge -> ~/.claude.json
references: sync -> ~/.claude/b-agentic/references
templates: sync -> ~/.claude/b-agentic/templates
manifest: write -> ~/.claude/b-agentic/install.json
backups: ...
activationState: active|pending
```

Settings install merges b-agentic recommendations into existing Claude Code settings. It preserves unknown user keys, appends missing array values, keeps existing scalar values on conflict, and writes a timestamped backup before changing an existing file.

Global MCP setup merges Serena, Context7, Brave Search, Firecrawl, Playwright, and GitNexus into `~/.claude.json` under user scope. Playwright uses isolated browser state by default. GitNexus uses the installed `gitnexus mcp` command to avoid cold `npx` startup timeouts. GitNexus indexing, generated skills, hooks, root guidance writes, and `gitnexus setup` remain user-run steps outside the installer.

MCP templates use environment placeholders such as `${CONTEXT7_API_KEY:-}`, `${BRAVE_API_KEY}`, and `${FIRECRAWL_API_KEY}` so tracked files never contain real keys. During an interactive install, the installer prompts for Context7, Brave Search, and Firecrawl API keys and writes provided values directly to user-scope `~/.claude.json`; leave a prompt blank to keep the placeholder. Non-interactive installs skip prompts.

The first Claude-native release supports personal-global install only. Project-local `.claude/` installs, plugin packaging, hooks, and dynamic context injection are deferred until validator and smoke coverage prove global parity.

## Skills

| Skill | Phase | Use |
|---|---|---|
| `/b-orchestrate` | End-to-end | Coordinate phase handoffs until PR-ready, ready with follow-ups, or blocked |
| `/b-plan` | Decide | Clarify unclear goals or turn a clear goal into an execution plan |
| `/b-research` | Decide | Fetch external docs, API facts, comparisons, or recent evidence |
| `/b-implement` | Build | Execute approved plans or small direct requests |
| `/b-refactor` | Build | Rename, extract, move, inline, simplify, or delete behavior-preserving code |
| `/b-debug` | Validate | Confirm runtime root cause and fix minimally |
| `/b-test` | Validate | Write or fix unit, integration, and contract tests |
| `/b-browser` | Validate | Collect browser, visual, screenshot, live UI, or e2e evidence |
| `/b-review` | Validate | Review changed code for blockers, regressions, security, and coverage |
| `/b-audit` | Validate | Audit the b-agentic suite for systemic risk (suite-only) |
| `/b-ship` | Ship | Commit, push, and open a PR after READY FOR PR |

The suite stops at `READY FOR PR`; commit, push, and PR creation are user-initiated actions via `/b-ship`.

Typical flow:

```text
/b-orchestrate [feature/fix request]  # full PR-readiness workflow
/b-plan [unclear goal or scoped task] -> approve plan -> /b-implement -> /b-test -> /b-review
/b-browser [UI/e2e verification]
/b-research [question]  # external docs, API facts, comparisons, or recent information
/b-debug [symptom]      # runtime bugs, errors, broken behavior, slow paths
/b-refactor [target]    # mechanical behavior-preserving transforms
/b-audit [surface]      # b-agentic suite self-audit only
/b-ship                 # commit, push, and open PR after READY FOR PR
```

All skills are model-invocable when their descriptions match the request. Skill descriptions are the primary routing signal; Claude Code loads the skill whose trigger conditions best fit the user's intent.

## Repository Map

```text
b-agentic/
├── CLAUDE.md              # Maintainer guidance for this source repo
├── runtimes/              # Runtime adapter directories
│   ├── claude-code/       # Claude Code adapter
│   │   ├── kernel.md      # Always-on runtime rules (installs as ~/.claude/CLAUDE.md)
│   │   ├── configs/       # Settings and MCP config templates
│   │   └── scripts/       # Claude-specific install and validate scripts
│   └── opencode/          # OpenCode adapter
│       ├── kernel.md      # Always-on runtime rules (installs as ~/.config/opencode/AGENTS.md)
│       ├── configs/       # Runtime layout documentation
│       └── scripts/       # OpenCode-specific install and validate scripts
├── references/            # shared runtime references copied into skill support dirs
├── skills/<name>/         # Skill instructions and optional reference.md files
├── install.sh             # Shared installer entrypoint; delegates to runtime scripts
└── scripts/               # Shared validation and smoke-test helpers
```

## Docs

- `README.md` is the brief repo overview.
- `CLAUDE.md` is the Claude Code maintainer guide for editing this source repo.
- `REFERENCE.md` is the skill-by-skill reference guide.
- `runtimes/claude-code/kernel.md` is the runtime kernel source.
- `references/contract/` is the detailed runtime contract; referenced sections are required read gates when a skill needs their schemas, checklists, or protocols.
- `references/performance-checklist.md` is a reusable cross-skill reference.
- `runtimes/claude-code/configs/README.md` documents the Claude Code runtime layout and first-release non-goals.
- `runtimes/opencode/configs/README.md` documents the OpenCode runtime layout and known constraints.

Run `scripts/validate-skills.sh` and `scripts/smoke-install.sh` before installing or committing suite changes.
