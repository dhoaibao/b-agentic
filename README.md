# b-agentic

**Slim workflow kernel for coding agents across Claude Code, OpenCode, and Codex CLI.**

b-agentic installs a compact runtime kernel, focused phase skills, runtime adapters, and recommended MCP config. Its job is simple: route work, preserve safety gates, use the right evidence, verify before claiming done, and keep multi-runtime setup consistent.

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

Default install also prepares the selected runtime CLI. If the CLI is already installed, b-agentic runs that runtime's native upgrade command. If it is missing, b-agentic attempts the vendor install script and still installs the b-agentic files if the CLI step fails.

Useful flags:

- `--dry-run` previews changes
- `--replace-memory` replaces an existing managed kernel file
- `--uninstall` removes managed files
- `--install-rtk` installs [RTK](https://github.com/rtk-ai/rtk) and adds the `rtk` shell-command rule to the kernel
- `--install-shell-tools` installs `rg`, `fd`/`fdfind`, and `jq` with the detected package manager
- `--install-serena` installs the [Serena](https://github.com/oraios/serena) MCP agent via `uv tool install -p 3.13 serena-agent` (will prompt to install `uv` if missing)
- `--install-codegraph` installs [CodeGraph](https://github.com/colbymchenry/codegraph) via its installer script

Production pinning knobs:

- `B_AGENTIC_BRAVE_MCP_PACKAGE` overrides `@brave/brave-search-mcp-server`
- `B_AGENTIC_FIRECRAWL_MCP_PACKAGE` overrides `firecrawl-mcp`
- `B_AGENTIC_PLAYWRIGHT_MCP_PACKAGE` overrides `@playwright/mcp@latest`

Requirements: `bash`, `git`, Python 3.11+, and `pnpm` for MCP entries that use `pnpm dlx`. Default runtime install may also invoke the selected runtime's native CLI installer or upgrade command.

Interactive installs prompt for missing shell tooling. When present, the runtime requires `rg` instead of `grep`, `fd` or `fdfind` instead of `find`, and `jq` instead of `python -m json.tool`, `awk`, or `grep` for JSON.

## RTK (Rust Token Killer)

When `--install-rtk` is used, the installer downloads and runs the RTK install script from `https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh`. If `rtk` is already installed, the installer skips the prompt and runs the same command as an upgrade. This is a remote shell script; only use it if you trust the RTK repository. RTK is otherwise optional and the installer skips it by default.

Once installed, the kernel instructs the agent to route every shell command through RTK by prefixing it with `rtk`:

```bash
rtk git status
rtk cargo test
rtk npm run build
rtk pytest -q
```

Meta commands:

```bash
rtk gain            # Token savings analytics
rtk gain --history  # Recent command savings history
rtk proxy <cmd>     # Run raw command without filtering
```

Verification: `rtk --version`, `rtk gain`, `which rtk`.

## Serena MCP agent

`--install-serena` installs the Serena MCP agent, which provides symbol discovery, references, diagnostics, and symbol edits. If `serena` is already installed, the installer skips the prompt and runs `uv tool upgrade serena-agent`.

If `uv` is already installed, the installer runs:

```bash
uv tool install -p 3.13 serena-agent
```

If `uv` is missing, the installer prompts to install it from `https://astral.sh/uv/install.sh` before proceeding with Serena. As with any remote install script, only proceed if you trust the source.

## CodeGraph MCP agent

b-agentic writes a default [CodeGraph](https://github.com/colbymchenry/codegraph) MCP entry that runs `codegraph serve --mcp` with `CODEGRAPH_TELEMETRY=0`. `--install-codegraph` installs CodeGraph with `curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh | sh`; if CodeGraph is already installed, the installer runs `codegraph upgrade`. Otherwise the installer prompts in interactive sessions. Run `codegraph init` in each repository where you want a local pre-indexed code graph.

Use CodeGraph for architectural flows, call graphs, impact radius, route-to-handler discovery, and affected-test discovery. Use Serena for symbol declarations, references, diagnostics, and symbol-aware edits. Use local reads/search to verify exact edited content.

## Runtime Support

| Runtime | Skill invocation | MCP config |
|---|---|---|
| Claude Code | Native `/b-*` skills from `~/.claude/skills/` | `~/.claude.json` |
| OpenCode | Native skill tool plus `/b-*` wrappers in `~/.config/opencode/commands/` | `~/.config/opencode/opencode.json` |
| Codex CLI | `/skills`, `$skill-name`, or implicit matching | `~/.codex/config.toml` |

<!-- generated:runtime-capabilities:start -->
| Runtime | Skills | Permissions | Rules | Wrappers |
|---|---|---|---|---|
| Claude Code | native | native | native | unsupported |
| OpenCode | native | native | native | native; adapter-only |
| Codex CLI | native | native | native | unsupported |
<!-- generated:runtime-capabilities:end -->

Adapters preserve user-owned config and report what they changed. They do not promise automatic phase continuation or deterministic enforcement beyond the runtime's normal permission model.

Permission defaults follow each runtime's native model, so the baseline differs: Claude Code has its own default-mode behavior, including built-in read-only Bash allowances; Codex CLI applies managed rules to commands that request to run outside the sandbox; and OpenCode defaults unlisted shell commands to `ask` while allow-listing read-only and required tools. The managed safety gates (commits, pushes, dependency writes, destructive commands) prompt or deny on every runtime regardless of this baseline.

## Skills

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
| `b-commit` | Ship | Write a Conventional Commits message from staged changes |
<!-- generated:skills-table:end -->

Typical flow:

```text
b-plan [goal] -> approve -> b-implement -> b-test -> b-review -> b-commit
b-research [external facts]
b-debug [runtime bug]
b-browser [UI/e2e evidence]
b-refactor [behavior-preserving transform]
```

## MCPs

The installer writes recommended MCP entries for:

- Serena: symbol discovery, references, diagnostics, and symbol edits.
- CodeGraph: local pre-indexed code structure, flows, impact radius, and affected tests.
- Context7: versioned library/framework docs.
- Brave Search: public/current discovery.
- Firecrawl: bounded extraction and approved deeper research.
- Playwright: live browser, visual, console/network, and e2e evidence.

The installer does not start MCP servers, install `pnpm dlx` packages ahead of time, run `codegraph init`, or run Serena onboarding. It does report local MCP readiness blockers such as missing binaries or API keys.

## Repository Layout

```text
b-agentic/
├── skills/                # Skill sources and generated delivery assets
├── runtimes/              # Runtime adapters, configs, scripts, and smoke lanes
├── references/contract/   # Slim runtime contract
├── tooling/generate/      # Registry and generated asset sync
├── tooling/install/       # Shared installer core
├── tooling/validate/      # Validation harness
├── tests/smoke/           # Installer smoke tests
├── install.sh             # Bootstrap installer entrypoint
└── scripts/               # Validation and smoke wrappers
```

Validation:

```bash
scripts/validate-skills.sh
scripts/validate-skills.sh --release
scripts/smoke-install.sh
scripts/mcp-doctor.sh --runtime=claude-code
scripts/mcp-doctor.sh --runtime=codex-cli
scripts/mcp-doctor.sh --runtime=opencode
scripts/skill-doctor.sh --runtime=claude-code
scripts/skill-doctor.sh --runtime=codex-cli
scripts/skill-doctor.sh --runtime=opencode
```

The validation suite and doctors prove generated sync, install safety, runtime config shape, skill payloads, and local MCP readiness blockers. They do not prove a live runtime session has loaded the kernel or that remote MCP calls succeed.

Professional release readiness requires both automated validation and one fresh-session acceptance pass for each changed runtime. Treat automated checks as install/config evidence; treat fresh-session checks as runtime behavior evidence.

Production acceptance for each runtime should include a fresh-session check:

- Kernel/memory file is loaded by the runtime.
- One installed `b-*` skill can be invoked.
- Configured MCP servers start or report actionable local blockers.
- Approval gates prompt or deny for commits, pushes, dependency writes, and destructive commands.
- Browser/MCP/API checks state any missing keys, packages, auth, or remote-service gaps.

## Docs

- `README.md` is the repository overview.
- `AGENTS.md` is maintainer guidance.
- `references/contract/` contains the runtime contract shipped to adapters.
