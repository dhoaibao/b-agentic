# b-agentic

**An agent workflow kernel for AI coding agents, with OpenCode as the reference runtime.**

`b-agentic` is a lean 11-skill agent workflow suite that turns rough developer intent into disciplined loops: clarify, plan, build, validate, debug, review, and audit. It is optimized around scoped execution, repo evidence, MCP tools, verification, and clean handoffs.

Think of it as the coordination layer between user intent, agent skills, repo evidence, MCP tools, verification, and handoffs.

## Install & Update

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash
```

Preview without writing into `~/.config/opencode/`:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --dry-run
```

Uninstall managed files:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --uninstall
```

The installer deploys this repo into OpenCode's global config:
- `skills/` -> `~/.config/opencode/skills/`
- `commands/` -> `~/.config/opencode/commands/`
- `references/` -> `~/.config/opencode/references/b-agentic/`
- `global/AGENTS.md` -> `~/.config/opencode/b-agentic/AGENTS.md`
- `global/AGENTS.md` -> `~/.config/opencode/AGENTS.md` only when missing or approved

Optional MCP config:
- `B_AGENTIC_INSTALL_MCP=Y` merges core MCP defaults: Serena, Context7, Brave Search, and Firecrawl.
- `B_AGENTIC_INSTALL_GITNEXUS=Y` adds optional GitNexus graph radar when core MCP defaults are enabled.
- `B_AGENTIC_INSTALL_PLAYWRIGHT_MCP=Y` adds optional Playwright MCP for `/b-browser` live UI automation when core MCP defaults are enabled.

If an existing `~/.config/opencode/AGENTS.md` is preserved, the installer exits with `activationState: pending`. Rerun with `--replace-agents` or merge the snapshot manually to activate the runtime kernel.

The runtime kernel provides the runtime gate checklist and explicit read gates; details live in `global/AGENTS.md` and `references/runtime-contract.md`.

This repository is an install-only source layout. OpenCode does not load the checked-in `skills/`, `commands/`, or `references/` directories directly from this repo root.

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

## Repository Map

```text
b-agentic/
├── AGENTS.md              # maintainer guidance for this source repo
├── global/AGENTS.md       # runtime kernel source installed into OpenCode config
├── references/            # shared runtime references installed under references/b-agentic/
├── skills/<name>/         # skill instructions and optional per-skill reference.md files
├── commands/<name>.md     # thin slash-command wrappers
├── install.sh             # installer, updater, and uninstaller
└── scripts/               # validation and smoke-test helpers
```

## Docs

- `README.md` is the brief repo overview.
- `AGENTS.md` is the maintainer guide for editing this source repo.
- `REFERENCE.md` is the skill-by-skill reference guide.
- `global/AGENTS.md` is the runtime kernel source.
- `references/runtime-contract.md` is the detailed runtime contract; referenced sections are required read gates when a skill needs their schemas, checklists, or protocols.
- `references/performance-checklist.md` is a reusable cross-skill reference.

Run `scripts/validate-skills.sh` before installing or committing suite changes.
