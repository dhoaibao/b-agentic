# b-agentic

**An agent workflow kernel for Claude Code, OpenCode, Codex CLI, and Gemini CLI.**

`b-agentic` turns rough developer intent into disciplined loops: clarify, plan, build, validate, debug, review, and ship. Claude Code is the reference runtime; OpenCode, Codex CLI, and Gemini CLI are supported through runtime-specific adapters.

Skill names are runtime-neutral: Claude Code, OpenCode, and Gemini CLI commonly expose `/b-*`, while Codex CLI uses `/skills`, `$skill-name`, or implicit matching.

## Install

Default install for Claude Code:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash
```

Install for OpenCode:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --runtime=opencode
```

Install for Codex CLI:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --runtime=codex-cli
```

Install for Gemini CLI:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --runtime=gemini-cli
```

Install for all registered runtimes:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --runtime=all
```

Codex CLI config merge uses Python 3.11+ standard-library TOML parsing.

Useful flags:

- `--runtime=all` to run install or uninstall across every runtime in `runtimes/registry.yaml`
- `--dry-run` to preview changes
- `--replace-memory` to replace an existing managed kernel file
- `--uninstall` to remove managed files

Re-run the installer to update.

The installer writes only to user-scope runtime locations. It does not create `.b-agentic/` or `.b-agentic/.gitignore` in the current repo just because you run install from inside a git worktree.

## One Command

The installer is designed to be a one-command bootstrap. It installs the kernel, syncs skills, writes runtime templates, and prints numbered stage progress followed by a short `Summary`, `Readiness`, `Shell tooling`, and `Next steps` report so you can see what changed without reading installer internals. The shell-tooling section includes a default core tier for `rg`, `fd`/`fdfind`, `jq`, `tmux`, and `fzf`, plus a separate optional tier for `bat`/`batcat`, `yq`, `git-delta`, and `gh`. When the installer can detect Homebrew, `apt`, or `dnf`, it prints matching package commands for both tiers. The installer never auto-installs those packages.

## What You Get

- A runtime kernel installed into the active tool: `~/.claude/CLAUDE.md`, `~/.config/opencode/AGENTS.md`, `~/.codex/AGENTS.md`, or `~/.gemini/GEMINI.md`
- The `b-agentic` skill set under the runtime-local skills tree (`~/.claude/skills/`, `~/.config/opencode/skills/`, `~/.codex/skills/`, or `~/.gemini/skills/`)
- Recommended runtime config templates, MCP config, and shared references
- For OpenCode, thin `/b-*` command wrappers in `~/.config/opencode/commands/`
- For Codex CLI, skill registration and MCP server config in `~/.codex/config.toml`
- For Gemini CLI, `/b-*` commands exposed by installed Gemini skills in `~/.gemini/skills/`

If an existing kernel file is preserved, the install stays in a pending state until you replace or merge it.

## Skills

The table below is generated from `skills/registry.yaml`.

<!-- generated:skills-table:start -->
| Skill | Phase | Use |
|---|---|---|
| `b-orchestrate` | End-to-end | Coordinate phase handoffs until PR-ready, ready with follow-ups, or blocked |
| `b-plan` | Decide | Clarify unclear goals or turn a clear goal into an execution plan |
| `b-research` | Decide | Fetch external docs, API facts, comparisons, or recent evidence |
| `b-implement` | Build | Execute approved plans or small direct requests |
| `b-refactor` | Build | Rename, extract, move, inline, simplify, or delete behavior-preserving code |
| `b-debug` | Validate | Confirm runtime root cause and fix minimally |
| `b-test` | Validate | Write or fix unit, integration, contract, and simulated-DOM tests |
| `b-browser` | Validate | Collect real-browser, visual, screenshot, live UI, or e2e evidence |
| `b-review` | Validate | Review changed code for blockers, regressions, security, and coverage |
| `b-audit` | Validate | Audit the b-agentic suite for systemic risk (suite-only) |
| `b-ship` | Ship | Commit, push, and open a PR after READY FOR PR |
<!-- generated:skills-table:end -->

Typical flow:

```text
b-orchestrate [feature/fix request]
b-plan [goal] -> approve plan -> b-implement -> b-test -> b-review
b-browser [UI/e2e verification]
b-research [external docs or recent info]
b-debug [runtime bug]
b-refactor [behavior-preserving change]
b-ship [commit, push, open PR]
```

## Repository Layout

```text
b-agentic/
├── CLAUDE.md              # Maintainer guide for this source repo
├── skills/
│   ├── registry.yaml      # Skill metadata and generated SKILL.md frontmatter
│   └── <name>/
│       ├── prompt.md      # Canonical skill prompt source
│       ├── SKILL.md       # Generated delivery asset
│       └── reference.md   # Optional skill-local support material
├── runtimes/
│   ├── registry.yaml      # Runtime metadata for generation and validation
│   ├── claude-code/
│   │   ├── kernel.md      # Claude Code runtime kernel
│   │   ├── configs/       # Settings and MCP templates
│   │   ├── scripts/       # Runtime-specific install and validate scripts
│   │   └── tests/         # Runtime-specific smoke lane
│   ├── opencode/
│   │   ├── kernel.md      # OpenCode runtime kernel
│   │   ├── commands/      # Thin /b-* command wrappers
│   │   ├── configs/       # Runtime config templates and docs
│   │   ├── scripts/       # Runtime-specific install and validate scripts
│   │   └── tests/         # Runtime-specific smoke lane
│   ├── codex-cli/
│   │   ├── kernel.md      # Codex CLI runtime kernel
│   │   ├── configs/       # Runtime config templates and docs
│   │   ├── scripts/       # Runtime-specific install and validate scripts
│   │   └── tests/         # Runtime-specific smoke lane
│   ├── gemini-cli/
│   │   ├── kernel.md      # Gemini CLI runtime kernel
│   │   ├── configs/       # Runtime config templates and docs
│   │   ├── scripts/       # Runtime-specific install and validate scripts
│   │   └── tests/         # Runtime-specific smoke lane
│   └── runtime-template/  # Scaffold for a future runtime adapter
├── references/
│   ├── contract/          # Detailed runtime contract
│   └── *.md               # Shared support references
├── tooling/
│   ├── generate/          # Renderers for kernels, skills, wrappers, and doc blocks
│   ├── install/           # Shared installer core
│   └── validate/          # Shared validation harness
├── tests/
│   └── smoke/             # Shared smoke harness
├── install.sh             # Bootstrap installer entrypoint
└── scripts/               # Stable validate and smoke wrappers
```

## Source Of Truth

- `skills/registry.yaml` and `skills/*/prompt.md` define the skill surface
- `runtimes/registry.yaml` and `references/contract/kernel.template.md` define runtime behavior
- `tooling/generate/registry_sync.py` regenerates committed delivery assets
- `scripts/validate-skills.sh` and `scripts/smoke-install.sh` are the main verification entrypoints
- `tooling/validate/` contains the shared validation harness
- `tests/smoke/` contains the shared smoke harness
- `runtimes/runtime-template/` is the scaffold for a new runtime adapter

## Docs

- `CLAUDE.md` is the maintainer guide for this source repo
- `references/contract/` contains the detailed runtime contract
- `runtimes/<name>/configs/README.md` describes runtime-specific layout details
