# b-agentic

**An 11-skill agent workflow kernel for Claude Code.**

`b-agentic` turns rough developer intent into disciplined loops: clarify, plan, build, validate, debug, review, and audit. It is optimized around scoped execution, repo evidence, MCP tools, verification, and clean handoffs.

Claude Code is the reference runtime. Skills install as native Claude skills and appear as `/b-*` slash commands.

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

The installer deploys this repo into Claude Code's personal config:
- `global/CLAUDE.md` -> `~/.claude/CLAUDE.md` when missing or approved
- `skills/<name>/` -> `~/.claude/skills/<name>/`
- `references/*.md` -> `~/.claude/b-agentic/references/`
- `references/*.md` -> `~/.claude/skills/<name>/references/b-agentic/` for each skill
- `claude/*.json` -> `~/.claude/b-agentic/templates/`
- `claude/settings.recommended.json` -> merged into `~/.claude/settings.json`
- `claude/mcp.user.template.json` -> merged into `~/.claude.json`
- install metadata and backups -> `~/.claude/b-agentic/`

If an existing `~/.claude/CLAUDE.md` is preserved, the installer exits with `activationState: pending`. Review `~/.claude/b-agentic/CLAUDE.md`, then rerun with `--replace-memory` or merge the kernel manually.

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

Global MCP setup merges Serena, Context7, Brave Search, Firecrawl, Playwright, and GitNexus into `~/.claude.json` under user scope. Playwright uses isolated browser state by default. GitNexus indexing, generated skills, hooks, root guidance writes, and `gitnexus setup` remain user-run steps outside the installer.

MCP templates use environment placeholders such as `${CONTEXT7_API_KEY}`, `${BRAVE_API_KEY}`, and `${FIRECRAWL_API_KEY}`; set secrets in your environment, not in tracked files.

The first Claude-native release supports personal-global install only. Project-local `.claude/` installs, plugin packaging, hooks, and dynamic context injection are deferred until validator and smoke coverage prove global parity.

## Skills

| Skill | Phase | Use |
|---|---|---|
| `/b-orchestrate` | End-to-end | Coordinate phase handoffs until PR-ready, ready with follow-ups, or blocked |
| `/b-spec` | Clarify | Clarify unclear goals, constraints, acceptance criteria, non-goals, and assumptions |
| `/b-plan` | Decide | Turn a clear goal into an execution plan |
| `/b-research` | Decide | Fetch external docs, API facts, comparisons, or recent evidence |
| `/b-implement` | Build | Execute approved plans or small direct requests |
| `/b-refactor` | Build | Rename, extract, move, inline, simplify, or delete behavior-preserving code |
| `/b-debug` | Validate | Confirm runtime root cause and fix minimally |
| `/b-test` | Validate | Write or fix unit, integration, and contract tests |
| `/b-browser` | Validate | Collect browser, visual, screenshot, live UI, or e2e evidence |
| `/b-review` | Validate | Review changed code for blockers, regressions, security, and coverage |
| `/b-audit` | Validate | Audit named repo or suite surfaces for systemic risk |

Typical flow:

```text
/b-orchestrate [feature/fix request]  # full PR-readiness workflow
/b-spec [rough idea] -> /b-plan [scoped task] -> approve plan -> /b-implement -> /b-test -> /b-review
/b-browser [UI/e2e verification]
/b-research [question]  # external docs, API facts, comparisons, or recent information
/b-debug [symptom]      # runtime bugs, errors, broken behavior, slow paths
/b-refactor [target]    # mechanical behavior-preserving transforms
/b-audit [surface]      # repository, maintainer, or suite-slice audit
```

Mutating or coordinating skills are manual-only in Claude Code with `disable-model-invocation: true`: `b-orchestrate`, `b-plan`, `b-implement`, `b-refactor`, `b-debug`, `b-test`, and `b-browser`. Read-only clarification, research, review, and audit skills may be model-invocable when their descriptions match the request.

## Repository Map

```text
b-agentic/
├── CLAUDE.md              # Claude Code maintainer guidance for this source repo
├── global/CLAUDE.md       # Claude Code runtime kernel source
├── claude/                # settings and MCP templates
├── references/            # shared runtime references copied into skill support dirs
├── skills/<name>/         # Claude skill instructions and optional reference.md files
├── install.sh             # Claude Code installer, updater, and uninstaller
└── scripts/               # validation and smoke-test helpers
```

## Docs

- `README.md` is the brief repo overview.
- `CLAUDE.md` is the Claude Code maintainer guide for editing this source repo.
- `REFERENCE.md` is the skill-by-skill reference guide.
- `global/CLAUDE.md` is the runtime kernel source.
- `references/runtime-contract.md` is the detailed runtime contract; referenced sections are required read gates when a skill needs their schemas, checklists, or protocols.
- `references/performance-checklist.md` is a reusable cross-skill reference.
- `claude/README.md` documents the Claude Code runtime layout and first-release non-goals.

Run `scripts/validate-skills.sh` and `scripts/smoke-install.sh` before installing or committing suite changes.
