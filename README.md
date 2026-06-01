# b-agentic

**An agentic workflow harness for Claude Code, OpenCode, Codex CLI, Antigravity CLI, Cursor, and Zed.**

`b-agentic` is a behavioral harness, not a skill suite. A runtime kernel enforces routing, safety gates, evidence standards, and handoff contracts. Skills are phase owners that execute within that envelope: clarify, plan, build, validate, debug, review, and ship.

Claude Code is the reference runtime; OpenCode, Codex CLI, Antigravity CLI, Cursor, and Zed are supported through runtime-specific adapters.

Skill names are runtime-neutral: Claude Code, OpenCode, Antigravity CLI, Cursor, and Zed commonly expose `/b-*`, while Codex CLI uses `/skills`, `$skill-name`, or implicit matching.

## Runtime Support

All supported runtimes install the same runtime-neutral skills, detailed contract snapshot, decision cards, and recommended MCP bundle. Runtime adapters own only the user-scope paths, command exposure, config merge format, and documented limitations.

| Runtime | Skill invocation | MCP config | Continuation support |
|---|---|---|---|
| Claude Code | Native `/b-*` skills from `~/.claude/skills/` | `~/.claude.json` | Operator-resumed via `[status]` and `[handoff]` blocks |
| OpenCode | Native skill tool plus `/b-*` wrappers in `~/.config/opencode/commands/` | `~/.config/opencode/opencode.json` | Operator-resumed; wrappers do not automate phase-to-phase continuation |
| Codex CLI | `/skills`, `$skill-name`, or implicit skill matching | `~/.codex/config.toml` | Operator-resumed via `[status]` and `[handoff]` blocks |
| Antigravity CLI | Native `/b-*` skills from `~/.gemini/antigravity-cli/skills/` | `~/.gemini/antigravity-cli/mcp_config.json` | Operator-resumed via `[status]` and `[handoff]` blocks |
| Cursor | Native slash commands from `~/.cursor/skills/` | `~/.cursor/mcp.json` | Operator-resumed via `[status]` and `[handoff]` blocks |
| Zed | Native slash commands from `~/.agents/skills/` | `~/.config/zed/settings.json` | Operator-resumed via `[status]` and `[handoff]` blocks |

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

## Upgrade And Operator Notes

After upgrading from an older b-agentic install, re-run the installer for every runtime you use so the kernel, skills, shared contract snapshot, decision cards, MCP templates, and command wrappers stay aligned. Use `--runtime=all` for the registered runtime set, or repeat `--runtime=<name>` for selected runtimes.

Daily workflows remain operator-resumed: run a phase skill, keep the returned `[status]` or `[handoff]` block in context, then invoke the next skill explicitly. No runtime adapter promises native phase-to-phase automation. OpenCode command wrappers and native slash-command runtimes preserve invocation ergonomics, not automatic continuation.

Release checks live behind stable wrappers:

- `bash scripts/check-conformance.sh --self-test tests/conformance/cases.json`
- `bash scripts/check-scenarios.sh --self-test tests/scenarios/cases.json`
- `bash scripts/validate-skills.sh`
- `bash scripts/validate-skills.sh --release`

Known caveats: live MCP requests still need user-scope API keys where a server requires them, Codex CLI validation needs Python 3.11+, and real-browser or visual readiness requires existing browser evidence or a `b-browser` pass before claiming PR readiness.

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

## Behavior Modes

`b-agentic` uses three behavior modes:

- `lite` for trivial local work with no remaining design decision.
- `standard` as the default day-to-day mode.
- `strict` for public contracts, sensitive paths, dependency changes, CI/build/release work, multi-phase workflows, and shared-environment or external mutation.

The runtime infers the mode from risk, and users may always ask for stricter handling. `lite` is never allowed when a strict trigger applies. Point-of-use summaries live under `references/cards/`; the detailed contract under `references/contract/` remains authoritative.

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
- `references/cards/*.md` define the short point-of-use decision cards used by prompts and kernels
- `tooling/policy/schema.json` and `tooling/policy/output-policy.json` define the machine-readable output/readiness policy used by validation
- `tooling/conformance/checker.py` checks transcript status blocks, handoff envelopes, and readiness claims against the policy model
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

## Conformance Checker

Use `bash scripts/check-conformance.sh <transcript-file>` to validate a saved transcript or snippet that contains canonical fenced `[status]` or `[handoff]` blocks.

Examples:

```bash
bash scripts/check-conformance.sh tests/conformance/valid-status.md
bash scripts/check-conformance.sh tests/conformance/valid-handoff.md
```

The checker is fixture-tested through `tests/conformance/cases.json` and runs as part of `bash scripts/validate-skills.sh`. The first version validates canonical block fields, policy vocabularies, run-id shape, next-skill names, and narrow readiness overclaim rules such as `READY FOR PR` without explicit verification evidence.

## Scenario Runner

Use `bash scripts/check-scenarios.sh --self-test tests/scenarios/cases.json` to run the golden workflow scenario suite.

Examples covered in the first suite:

- small direct edit
- stale approved plan
- dirty worktree conflict
- review-fix loop
- browser evidence missing
- dependency approval denied
- test failure routed to debug
- unsafe success overclaim

Scenario fixtures assert structured outcomes instead of whole-prose snapshots. The runner reuses the conformance checker and is wired into `bash scripts/validate-skills.sh --release`.
