# b-agentic

**Agentic workflow kernel for Claude Code, OpenCode, and Codex CLI.**

`b-agentic` is a workflow harness, not just a skill bundle. It installs a compact runtime kernel, phase skills, a slim shared contract snapshot, and recommended MCP config so agents route work, preserve safety gates, ground claims in evidence, verify before reporting, and hand off cleanly.

Claude Code is the primary reference runtime. Other runtimes are supported through adapters that own install paths, config merge behavior, command exposure, and caveats.

## Install

Default install for Claude Code:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash
```

Install another runtime:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --runtime=<name>
```

Use `<name>` as `opencode`, `codex-cli`, or `kimi-code-cli`. Use `--runtime=all` for every registered runtime.

Useful flags:

- `--dry-run` previews changes
- `--replace-memory` replaces an existing managed kernel file
- `--uninstall` removes managed files

The installer writes only to user-scope runtime locations. Re-run it to update. Codex CLI and Kimi Code CLI config installs require Python 3.11+ for standard-library TOML parsing.

## Runtime Support

| Runtime | Skill invocation | MCP config |
|---|---|---|
| Claude Code | Native `/b-*` skills from `~/.claude/skills/` | `~/.claude.json` |
| OpenCode | Native skill tool plus `/b-*` wrappers in `~/.config/opencode/commands/` | `~/.config/opencode/opencode.json` |
| Codex CLI | `/skills`, `$skill-name`, or implicit matching | `~/.codex/config.toml` |
| Kimi Code CLI | Native `/skill:<name>` skills plus a managed kernel hook | `~/.kimi-code/mcp.json` |

Capability support and adoption intent are generated from `runtimes/registry.yaml`. `native` means the runtime has a first-class surface, `adapter` means b-agentic can approximate the shared intent through adapter-owned runtime behavior, and `unsupported` means the adapter must not rely on that capability. Non-shared adoption labels are `adapter-only`, `deferred`, or `unsupported`.

<!-- generated:runtime-capabilities:start -->
| Runtime | Skills | Permissions | Hooks | Rules | Subagents | Plugins | Wrappers | Custom tools |
|---|---|---|---|---|---|---|---|---|
| Claude Code | native | native | native | native | native | native; deferred | unsupported | unsupported |
| OpenCode | native | native | adapter | native | native | native; deferred | native; adapter-only | native; adapter-only |
| Codex CLI | native | native | native | native | native | native; deferred | unsupported | unsupported |
| Kimi Code CLI | native | native | native | native | native | native; deferred | unsupported | unsupported |
<!-- generated:runtime-capabilities:end -->

Claude Code is the capability ceiling: shared b-agentic behavior can adopt a runtime-native capability only when the Claude Code registry entry marks that capability as `adoption: "shared"`. If Claude Code supports a capability and marks it shared, b-agentic may adopt it even when other runtimes need adapters or lack parity. Other runtimes can provide native or adapter implementations for that shared intent, but non-Claude-only capabilities stay adapter-only.

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

## Runtime Kernel And MCPs

The installed runtime surface is intentionally small: the kernel plus `runtime.md`, `safety-tools.md`, `output.md`, and `decisions.md`. Runtime adapters may also install managed permissions, hooks, rules, and optional subagent profiles when the capability registry allows the shared intent. Runtime details stay in adapters; skill-specific detail stays with each skill.

The installer writes a recommended MCP template with `serena`, `context7`, `brave-search`, `firecrawl`, and `playwright`. These are not decorative add-ons: Serena owns symbol work, Context7 owns versioned official docs, Brave owns current/open discovery, Firecrawl owns extraction and approved deeper research, and Playwright owns live browser/e2e evidence through `b-browser`. Native local tools remain first for exact repo evidence.

## Repository Layout

```text
b-agentic/
├── skills/                # Skill sources and generated delivery assets
├── runtimes/              # Runtime adapters, configs, scripts, and smoke lanes
│   └── runtime-template/  # Scaffold for new runtime adapters
├── references/            # Shared support references and slim runtime contract
├── tooling/               # Renderers, shared installer core, and validation harness
│   ├── validate/          # Shared validation harness
│   ├── conformance/       # Status/handoff policy checker
│   └── scenarios/         # Golden workflow scenario runner
├── tests/                 # Shared smoke and internal release fixtures
│   └── smoke/             # Smoke test harness
├── install.sh             # Bootstrap installer entrypoint
└── scripts/               # Stable validate and smoke wrappers
```

Key directories: `tooling/validate/`, `tooling/conformance/`, `tooling/scenarios/`, `tests/smoke/`, and `runtimes/runtime-template/`.

Validation entrypoints:

```bash
scripts/validate-skills.sh          # shared + runtime validation
scripts/validate-skills.sh --release # adds conformance, scenario, and smoke coverage
scripts/smoke-install.sh             # installer smoke tests
```

## Docs

- `CLAUDE.md` is the maintainer guide for this source repo.
- `references/contract/` contains the detailed runtime contract.
- `runtimes/<name>/configs/README.md` documents runtime-specific layout details.
