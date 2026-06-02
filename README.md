# b-agentic

**Agentic workflow kernel for Claude Code, OpenCode, and Codex CLI.**

`b-agentic` is a behavioral harness, not just a skill bundle. It installs a runtime kernel, phase skills, a shared contract snapshot, and recommended MCP config so agents route work, preserve safety gates, ground claims in evidence, verify before reporting, and hand off cleanly.

Claude Code is the reference runtime. Other runtimes are supported through adapters that own install paths, config merge behavior, command exposure, and caveats.

## Install

Default install for Claude Code:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash
```

Install another runtime:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --runtime=<name>
```

Use `<name>` as `opencode` or `codex-cli`. Use `--runtime=all` for every registered runtime.

Useful flags:

- `--dry-run` previews changes
- `--replace-memory` replaces an existing managed kernel file
- `--uninstall` removes managed files

The installer writes only to user-scope runtime locations. Re-run it to update. Codex CLI install and validation require Python 3.11+ for standard-library TOML parsing.

## Runtime Support

| Runtime | Skill invocation | MCP config |
|---|---|---|
| Claude Code | Native `/b-*` skills from `~/.claude/skills/` | `~/.claude.json` |
| OpenCode | Native skill tool plus `/b-*` wrappers in `~/.config/opencode/commands/` | `~/.config/opencode/opencode.json` |
| Codex CLI | `/skills`, `$skill-name`, or implicit matching | `~/.codex/config.toml` |

All runtimes are operator-resumed: run a phase skill, keep the returned `[status]` or `[handoff]` block in context, then invoke the next skill explicitly. Runtime adapters preserve invocation ergonomics; they do not promise automatic phase-to-phase continuation.

## Skills

The table below is generated from `skills/registry.yaml`.

<!-- generated:skills-table:start -->
| Skill | Phase | Use |
|---|---|---|
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
b-plan [goal] -> approve plan -> b-implement -> b-test -> b-review
b-browser [UI/e2e verification]
b-research [external docs or recent info]
b-debug [runtime bug]
b-refactor [behavior-preserving change]
b-ship [explicit ship request after review readiness]
```

`b-ship` remains explicit even when another skill closes with `Next: b-ship`.

## Modes And MCPs

Behavior modes are `lite` for trivial local work, `standard` by default, and `strict` for public contracts, sensitive paths, dependency changes, CI/build/release work, multi-phase workflows, and shared-environment or external mutation.

The installer writes a recommended MCP template with `serena`, `context7`, `brave-search`, `firecrawl`, and `playwright`. Skills use MCPs lazily when they close a specific evidence gap; native local tools and Serena stay first for exact local evidence.

## Repository Layout

```text
b-agentic/
├── skills/          # Skill sources and generated delivery assets
├── runtimes/        # Runtime adapters, configs, scripts, and smoke lanes
├── references/      # Shared support references and detailed runtime contract
├── tooling/         # Renderers, shared installer core, and validation harness
├── tests/           # Shared smoke and internal release fixtures
├── install.sh       # Bootstrap installer entrypoint
└── scripts/         # Stable validate and smoke wrappers
```

Source of truth:

- `skills/registry.yaml` and `skills/*/prompt.md` define skills.
- `runtimes/registry.yaml` and `references/contract/kernel.template.md` define runtime behavior.
- `references/contract/` defines the detailed runtime contract.
- `tooling/generate/registry_sync.py` regenerates committed delivery assets.
- `tooling/validate/`, `tooling/conformance/`, `tooling/scenarios/`, `tests/smoke/`, and `runtimes/runtime-template/` protect generated assets, runtime adapters, installer behavior, and release governance.

Validation entrypoints:

```bash
scripts/validate-skills.sh
scripts/validate-skills.sh --release
scripts/smoke-install.sh
bash scripts/internal-check-conformance.sh --self-test tests/internal/conformance/cases.json
bash scripts/internal-check-scenarios.sh --self-test tests/internal/scenarios/cases.json
```

`scripts/validate-skills.sh --release` adds conformance, scenario, and smoke coverage for delivery-sensitive changes. Use `bash scripts/internal-check-conformance.sh <transcript-file>` for a saved status/handoff snippet, and `bash scripts/internal-check-scenarios.sh --self-test tests/internal/scenarios/cases.json` for golden workflow scenarios.

## Docs

- `CLAUDE.md` is the maintainer guide for this source repo.
- `references/contract/` contains the detailed runtime contract.
- `runtimes/<name>/configs/README.md` documents runtime-specific layout details.
