# b-agentic

**An agent workflow kernel for Claude Code and OpenCode.**

`b-agentic` turns rough developer intent into disciplined loops: clarify, plan, build, validate, debug, review, and audit. It is optimized around scoped execution, repo evidence, MCP tools, verification, and clean handoffs.

Claude Code is the reference runtime; OpenCode is supported via a bridge adapter. Shared skills and shared contract files stay runtime-neutral, and the OpenCode adapter also installs thin `/b-*` command wrappers.

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
- `runtimes/opencode/commands/` -> `~/.config/opencode/commands/`
- `references/*.md` -> `~/.config/opencode/b-agentic/references/`
- `references/*.md` -> `~/.claude/skills/<name>/references/b-agentic/` for each skill
- `runtimes/opencode/configs/mcp.user.template.json` -> merged into `~/.config/opencode/opencode.json` with Serena configured as `serena start-mcp-server --context ide --project-from-cwd`
- `runtimes/opencode/configs/*.md` -> `~/.config/opencode/b-agentic/templates/`
- install metadata and backups -> `~/.config/opencode/b-agentic/`

The OpenCode wrapper files keep the `/b-*` command names available in the command palette while delegating back to the matching native skill. If a command file with the same name already exists, the installer preserves it and skips that managed wrapper. `${CLAUDE_SKILL_DIR}` support-path usage remains the only intentional shared bridge marker in this iteration.

Use `--runtime=opencode` or set `B_AGENTIC_RUNTIME=opencode` to install for OpenCode:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --runtime=opencode
```

If an existing kernel file is preserved, the installer exits with `activationState: pending`. Review the managed snapshot, then rerun with `--replace-memory` or merge the kernel manually.

Internally, `install.sh` now stays as the bootstrap entrypoint only: it syncs the source repo, then sources `tooling/install/common.sh` for shared install and uninstall behavior and the selected `runtimes/<name>/scripts/install.sh` driver for runtime-owned paths, wrapper handling, manifest shape, and report wording.

The top-level verification entrypoints are stable wrappers now:

- `scripts/validate-skills.sh` delegates to `tooling/validate/run.sh`, which runs shared checks plus each registered runtime's `runtimes/<name>/scripts/validate.sh`.
- `scripts/smoke-install.sh` delegates to `tests/smoke/install.sh`, which sources each registered runtime's `runtimes/<name>/tests/smoke.sh` lane.

## One Command

For Claude Code, plain install syncs the runtime, merges recommended settings, and installs all MCP servers at Claude Code user scope:

```text
b-agentic Claude Code install complete
skillsSynced: <skill count> -> ~/.claude/skills
kernel: write|replace|preserve -> ~/.claude/CLAUDE.md
settings: write|merge -> ~/.claude/settings.json
mcp: write|merge -> ~/.claude.json
references: sync -> ~/.claude/b-agentic/references
templates: sync -> ~/.claude/b-agentic/templates
manifest: write -> ~/.claude/b-agentic/install.json
backups: ...
activationState: active|pending
```

For OpenCode, the install report also includes the managed command wrapper sync:

```text
b-agentic OpenCode install complete
skillsSynced: <skill count> -> ~/.claude/skills
commandsSynced: <skill count> -> ~/.config/opencode/commands
kernel: write|replace|preserve -> ~/.config/opencode/AGENTS.md
mcp: write|merge -> ~/.config/opencode/opencode.json
references: sync -> ~/.config/opencode/b-agentic/references
templates: sync -> ~/.config/opencode/b-agentic/templates
manifest: write -> ~/.config/opencode/b-agentic/install.json
backups: ...
activationState: active|pending
```

Settings install merges b-agentic recommendations into existing Claude Code settings. It preserves unknown user keys, appends missing array values, keeps existing scalar values on conflict, and writes a timestamped backup before changing an existing file.

Global MCP setup merges Serena, Context7, Brave Search, Firecrawl, Playwright, and GitNexus into `~/.claude.json` under user scope. The managed Brave Search, Firecrawl, and Playwright entries launch through `bunx`, so Bun must be available on `PATH`. Playwright uses isolated browser state by default. GitNexus uses the installed `gitnexus mcp` command to avoid cold `npx` startup timeouts. GitNexus indexing, generated skills, hooks, root guidance writes, and `gitnexus setup` remain user-run steps outside the installer.

MCP templates use environment placeholders such as `${CONTEXT7_API_KEY:-}`, `${BRAVE_API_KEY}`, and `${FIRECRAWL_API_KEY}` so tracked files never contain real keys. During an interactive install, the installer prompts for Context7, Brave Search, and Firecrawl API keys and writes provided values directly to user-scope `~/.claude.json`; leave a prompt blank to keep the placeholder. Non-interactive installs skip prompts.

The first Claude-native release supports personal-global install only. Project-local `.claude/` installs, plugin packaging, hooks, and dynamic context injection are deferred until validator and smoke coverage prove global parity.

## Skills

The table below is generated from `skills/registry.yaml`.

<!-- generated:skills-table:start -->
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
<!-- generated:skills-table:end -->

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

All skills are model-invocable when their descriptions match the request. Skill descriptions are the primary routing signal; the active runtime loads the skill whose trigger conditions best fit the user's intent.

## Repository Map

```text
b-agentic/
├── CLAUDE.md              # Maintainer guidance for this source repo
├── skills/
│   ├── registry.yaml      # Canonical skill metadata and rendered SKILL.md frontmatter
│   └── <name>/            # prompt.md source, generated SKILL.md, and optional support files
├── runtimes/              # Runtime adapter directories
│   ├── registry.yaml      # Canonical runtime metadata for adapter generation and validation
│   ├── claude-code/       # Claude Code adapter
│   │   ├── kernel.md      # Generated Claude kernel output (installs as ~/.claude/CLAUDE.md)
│   │   ├── configs/       # Settings and MCP config templates
│   │   ├── scripts/       # Claude-specific install and validate scripts
│   │   └── tests/         # Claude-specific smoke lane
│   ├── opencode/          # OpenCode adapter
│   │   ├── kernel.md      # Generated OpenCode kernel output (installs as ~/.config/opencode/AGENTS.md)
│   │   ├── commands/      # Managed /b-* command-wrapper sources for OpenCode
│   │   ├── configs/       # MCP config template and runtime layout docs
│   │   ├── scripts/       # OpenCode-specific install and validate scripts
│   │   └── tests/         # OpenCode-specific smoke lane
│   └── runtime-template/  # Scaffold for adding a new runtime adapter
├── references/            # shared runtime-neutral references and kernel template sources
├── tooling/generate/      # Renderers for kernels, SKILL.md outputs, wrappers, and doc tables
├── tooling/install/       # Shared installer core reused by runtime drivers
├── tooling/validate/      # Shared validation runner and runtime-neutral checks
├── tests/smoke/           # Shared smoke harness reused by runtime lanes
├── install.sh             # Bootstrap installer entrypoint; syncs source then dispatches to shared core + runtime driver
└── scripts/               # Stable wrapper entrypoints for validation and smoke flows
```

## Docs

- `README.md` is the brief repo overview, install guide, and source-layout map.
- `skills/registry.yaml` plus `skills/*/prompt.md` are the canonical skill authoring sources.
- `runtimes/registry.yaml` plus `references/contract/kernel.template.md` are the canonical runtime-kernel authoring sources.
- `skills/*/SKILL.md` and `runtimes/*/kernel.md` are committed generated delivery assets.
- `tooling/generate/registry_sync.py` renders kernels, `SKILL.md` outputs, wrappers, and generated doc blocks before validation or install changes.
- `tooling/validate/run.sh` plus `tooling/validate/shared.py` are the shared validation harness behind `scripts/validate-skills.sh`.
- `tests/smoke/install.sh` plus `tests/smoke/lib.sh` are the shared smoke harness behind `scripts/smoke-install.sh`.
- `runtimes/<name>/tests/smoke.sh` is the adapter-owned smoke lane for each registered runtime.
- `runtimes/runtime-template/` is the adapter scaffold for adding a future runtime without rewriting root wrappers.
- `references/contract/` is the detailed runtime contract; referenced sections are required read gates when a skill needs their schemas, checklists, or protocols.
- `skills/*/reference.md` files are optional skill-local support material, not a root mirror doc.
- `CLAUDE.md` is the Claude Code maintainer guide for editing this source repo.
- `references/performance-checklist.md` is a reusable cross-skill reference.
- `runtimes/claude-code/configs/README.md` documents the Claude Code runtime layout and first-release non-goals.
- `runtimes/opencode/configs/README.md` documents the OpenCode runtime layout and known constraints.

Run `scripts/validate-skills.sh` and `scripts/smoke-install.sh` before installing or committing suite changes.
