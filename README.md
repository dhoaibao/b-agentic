# b-agentic

**An agentic workflow harness for Claude Code, OpenCode, Codex CLI, Antigravity CLI, Cursor, and Zed.**

`b-agentic` is a behavioral harness, not a skill suite. A runtime kernel enforces routing, safety gates, evidence standards, and handoff contracts. Skills are phase owners that execute within that envelope: clarify, plan, build, validate, debug, review, and ship.

Claude Code is the reference runtime; OpenCode, Codex CLI, Antigravity CLI, Cursor, and Zed are supported through runtime-specific adapters.

Skill names are runtime-neutral: Claude Code, OpenCode, Antigravity CLI, Cursor, and Zed commonly expose `/b-*`, while Codex CLI uses `/skills`, `$skill-name`, or implicit matching.

## Install

Default install for Claude Code:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash
```

Install for a specific runtime — replace `<name>` with one of `opencode`, `codex-cli`, `antigravity-cli`, `cursor`, or `zed`:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --runtime=<name>
```

Install for all registered runtimes:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --runtime=all
```

Codex CLI config merge uses Python 3.11+ standard-library TOML parsing.

Useful flags:

- `--runtime=all` to install the default runtime set or uninstall across every runtime in `runtimes/registry.yaml`
- `--dry-run` to preview changes
- `--replace-memory` to replace an existing managed kernel file
- `--uninstall` to remove managed files

Re-run the installer to update.

The installer writes only to user-scope runtime locations. It does not create `.b-agentic/` or `.b-agentic/.gitignore` in the current repo just because you run install from inside a git worktree.

## Skills

The table below is generated from `skills/registry.yaml`.

<!-- generated:skills-table:start -->
| Skill | Phase | Use |
|---|---|---|
| `b-orchestrate` | End-to-end | Coordinate resumed phase handoffs until PR-ready, ready with follow-ups, or blocked |
| `b-plan` | Decide | Clarify unclear goals or turn a clear goal into an execution plan |
| `b-research` | Decide | Fetch external docs, API facts, comparisons, or recent evidence |
| `b-implement` | Build | Execute approved plans or small direct requests |
| `b-refactor` | Build | Rename, extract, move, inline, simplify, or delete behavior-preserving code |
| `b-debug` | Validate | Confirm runtime root cause and fix minimally |
| `b-test` | Validate | Write or fix unit, integration, contract, and simulated-DOM tests |
| `b-browser` | Validate | Collect real-browser, visual, screenshot, live UI, or e2e evidence |
| `b-review` | Validate | Review changed code or run a b-agentic suite self-audit |
| `b-ship` | Ship | Commit, push, and open a PR on explicit request after review readiness |
<!-- generated:skills-table:end -->

Typical flow:

```text
b-orchestrate [workflow request] -> handoff/status across resumed turns
b-plan [goal] -> approve plan -> b-implement -> b-test -> b-review
b-browser [UI/e2e verification]
b-research [external docs or recent info]
b-debug [runtime bug]
b-refactor [behavior-preserving change]
b-ship [explicit ship request after review readiness]
```

`b-orchestrate` coordinates via handoff envelopes and returned status blocks; it does not auto-run every phase inside one invocation. Operators resume the next phase with a new explicit invocation. `b-ship` remains explicit even when another skill closes with `Next: b-ship`.

## MCPs

The installer writes a recommended MCP config template to the runtime's standard MCP config location. All runtimes include the same five servers:

| MCP | Role | API Key |
|---|---|---|
| `serena` | Symbol discovery, references, diagnostics, and edits — primary code navigation hands | none |
| `context7` | Library and framework documentation lookup | `CONTEXT7_API_KEY` (optional) |
| `brave-search` | Open-web and news discovery | `BRAVE_API_KEY` |
| `firecrawl` | URL extraction, local document parsing, and agent-driven research | `FIRECRAWL_API_KEY` |
| `playwright` | Live browser, DOM, visual, and e2e actions | none |

The template is a starting point. Skills use MCPs as lazy capabilities — activated only when they close a specific evidence gap, not as defaults. `serena` and native local tools take priority for exact local evidence.

## Repository Layout

```text
b-agentic/
├── skills/          # Skill sources and generated delivery assets
├── runtimes/        # Runtime adapters, configs, scripts, and smoke lanes
├── references/      # Shared support references and detailed runtime contract
├── tooling/         # Renderers, shared installer core, and validation harness
├── tests/           # Shared smoke harness
├── install.sh       # Bootstrap installer entrypoint
└── scripts/         # Stable validate and smoke wrappers
```

## Source Of Truth

- `skills/registry.yaml` and `skills/*/prompt.md` define the skill surface
- `runtimes/registry.yaml` and `references/contract/kernel.template.md` define runtime behavior
- `tooling/generate/registry_sync.py` regenerates committed delivery assets
- `scripts/validate-skills.sh` is the main shared validation entrypoint; use `scripts/validate-skills.sh --release` when delivery changes must also pass installer smoke coverage
- `scripts/smoke-install.sh` remains the standalone smoke entrypoint when you need the installer suite by itself
- `tooling/validate/` contains the shared validation harness
- `tests/smoke/` contains the shared smoke harness
- `runtimes/runtime-template/` is the scaffold for a new runtime adapter

## Docs

- `CLAUDE.md` is the maintainer guide for this source repo
- `references/contract/` contains the detailed runtime contract
- `runtimes/<name>/configs/README.md` describes runtime-specific layout details
