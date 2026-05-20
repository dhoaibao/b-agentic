# b-agentic

**An agent workflow kernel for AI coding agents, with OpenCode as the reference runtime.**

`b-agentic` is a lean 11-skill agent workflow suite that turns rough developer intent into disciplined loops: clarify, plan, build, test, browser verification, debug, review, and audit. It is optimized around scoped execution, Serena-backed symbol work, optional GitNexus graph radar, and explicit safety rules when work crosses risky boundaries.

Think of it as the coordination layer between user intent, agent skills, repo evidence, MCP tools, verification, and handoffs.

Browser, DOM-rendered, visual, and e2e verification is isolated in `/b-browser`. The suite handles non-browser unit, integration, and contract tests in `/b-test`, and it does not add jsdom, Playwright, Cypress, Puppeteer, WebDriver, or equivalent browser/DOM tooling as a project dependency side effect. For UI/browser-relevant work, readiness claims require `/b-browser`-verified supplied/CI evidence, existing-tool evidence, approved live-browser evidence, or an accepted follow-up.

## Install & Update

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash
```

Preview an install without writing into `~/.config/opencode/`:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --dry-run
```

Uninstall b-agentic-managed files from OpenCode config:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --uninstall
```

The installer deploys this source repo into OpenCode's global config:
- `skills/` -> `~/.config/opencode/skills/`
- `commands/` -> `~/.config/opencode/commands/`
- `references/` -> `~/.config/opencode/references/b-agentic/`
- `global/AGENTS.md` -> `~/.config/opencode/b-agentic/AGENTS.md`
- `global/AGENTS.md` -> `~/.config/opencode/AGENTS.md` only when missing or approved

Optional MCP config can be installed by setting environment variables before running the installer:
- `B_AGENTIC_INSTALL_MCP=Y` merges core MCP defaults: Serena, Context7, Brave Search, and Firecrawl.
- `B_AGENTIC_INSTALL_GITNEXUS=Y` adds optional GitNexus graph radar when core MCP defaults are enabled.
- `B_AGENTIC_INSTALL_PLAYWRIGHT_MCP=Y` adds optional Playwright MCP for `/b-browser` live UI automation when core MCP defaults are enabled.

If an existing `~/.config/opencode/AGENTS.md` is preserved, the installer exits with `activationState: pending`. In that state the files are present, but the runtime gate checklist, explicit read gates, and status/handoff rules may not be active until you rerun with `--replace-agents` or merge the snapshot manually.

This repository is an install-only source layout. OpenCode does not load the checked-in `skills/`, `commands/`, or `references/` directories directly from this repo root.

## Runtime Enforcement

- The always-on kernel in `global/AGENTS.md` keeps the compact runtime gate checklist for non-trivial work: source-of-truth at start, approval/safety before edits or external actions, and verification/status before completion or handoff.
- Skill steps use explicit read gates such as `Read references/b-agentic/runtime-contract.md §9 before ...` so shared schemas and protocols are read at the point of use instead of remembered from distant prose.
- Slash-command wrappers reinforce the active runtime kernel and the loaded skill's required read gates without duplicating policy.
- `scripts/validate-skills.sh` enforces this model by failing stale passive pointers, missing point-of-use read gates, wrapper drift, and docs/runtime drift.

## Token-Saving Defaults

- Keep OpenCode compaction and pruning enabled unless you are intentionally debugging context retention.
- Ignore generated outputs, caches, logs, and suite artifacts in watchers so they do not become background context.
- Disable broad, always-on MCP servers by default; enable project-specific MCPs per agent or task when they close an evidence gap.
- Use Serena for symbol work and Context7 for versioned library docs instead of broad file reads or generic web searches.
- Prefer structured extraction or query for specific web/document fields; reserve full-page markdown for source understanding or summaries.

## Skills

| Skill | Phase | When to use |
|---|---|---|
| `/b-orchestrate` | End-to-end | Coordinate explicit handoff/resume cycles between spec, plan, implementation, optional suite-supported tests, review, and review-fix phase skills until PR-ready, ready with accepted follow-ups, or blocked |
| `/b-spec` | Clarify | Clarify unclear end states, constraints, acceptance criteria, non-goals, and assumptions before planning or coding |
| `/b-plan` | Decide | Turn a clear goal into a short chat plan or saved execution plan |
| `/b-research` | Decide | Fetch external docs, API facts, config keys, method signatures, comparisons, recency-sensitive evidence, or approved source/document evidence after privacy classification, using structured extraction when specific fields are enough |
| `/b-implement` | Build | Execute approved plans or small direct requests in coherent verified steps |
| `/b-refactor` | Build | Execute concrete behavior-preserving transforms: rename, extract, move, inline, simplify, or delete |
| `/b-debug` | Validate | Confirm runtime root cause, apply approved containment when urgent, fix minimally, verify, and remove probes |
| `/b-test` | Validate | Write non-browser unit/integration/contract tests, fix test-only failures, evaluate coverage gaps, and route product bugs out of the test lane |
| `/b-browser` | Validate | Operate browser, DOM-rendered, visual, screenshot, browser-session, live UI, and e2e evidence through supplied/CI evidence, existing repo tooling, optional Playwright MCP live-browser actions, Firecrawl extraction, or accepted follow-ups |
| `/b-review` | Validate | Review changed-code diffs, ranges, checkpoints, and in-scope untracked files for blockers, regressions, security, and coverage |
| `/b-audit` | Validate | Audit named repository or suite surfaces for systemic risk, sampled coverage, and residual risk |

Typical flow:

```text
/b-orchestrate [feature/fix request]  # full PR-readiness workflow
/b-spec [rough idea] -> /b-plan [scoped task] -> approve plan -> /b-implement -> /b-test -> /b-review
/b-browser [UI/e2e verification]  # browser/DOM/visual/e2e evidence, live UI operation, or follow-up
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
