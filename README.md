# b-agentic

**Slim workflow kernel for coding agents across Claude Code, OpenCode, Codex CLI, and Antigravity CLI.**

b-agentic installs a compact runtime kernel, focused phase skills, runtime adapters, and recommended MCP config. Its job is simple: route work, preserve safety gates, use the right evidence, verify before claiming done, and keep multi-runtime setup consistent.

## Install

Default install for Codex CLI:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash
```

Install another runtime:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --runtime=<name>
```

Use `<name>` as `codex-cli`, `claude-code`, `opencode`, or `antigravity-cli`. Use `--runtime=all` for every registered runtime.

Default install writes b-agentic files and config only. Interactive installs prompt before installing or upgrading the selected runtime CLI. Non-interactive installs skip runtime CLI changes unless `B_AGENTIC_INSTALL_RUNTIME_CLI=Y` explicitly opts in.

For professional or shared environments, pin both the bootstrap script and installed source to a reviewed tag or commit instead of consuming whatever is currently on `main`:

```bash
export B_AGENTIC_REF=<tag-or-commit>
curl -fsSL "https://raw.githubusercontent.com/dhoaibao/b-agentic/${B_AGENTIC_REF}/install.sh" | bash -s -- --ref="${B_AGENTIC_REF}"
```

The same pin is available as `B_AGENTIC_REF=<tag-or-commit>` for scripted installs.

Useful flags:

- `--dry-run` previews changes
- `--replace-memory` replaces an existing managed kernel file
- `--uninstall` removes managed files
- `--ref=<tag-or-commit>` checks out that b-agentic git ref before installing managed files

Production pinning knobs:

- `B_AGENTIC_BRAVE_MCP_PACKAGE` overrides `@brave/brave-search-mcp-server@2.0.85`
- `B_AGENTIC_FIRECRAWL_MCP_PACKAGE` overrides `firecrawl-mcp@3.22.1`
- `B_AGENTIC_PLAYWRIGHT_MCP_PACKAGE` overrides `@playwright/mcp@0.0.77`

Set these package overrides to exact package versions in professional environments. The defaults are pinned, but you can override them when you need a different version or your own package.

Run `scripts/mcp-doctor.sh --runtime=<name>` after setting package overrides and API keys to verify readiness. Missing credentials, unpinned packages, or missing dependencies will fail checks by default. Run with `--allow-degraded` to inspect status without failing on missing/blocked components.

Requirements: `bash`, `git`, Python 3.11+, and `pnpm` for MCP entries that use `pnpm dlx`. Runtime CLI installation or upgrade is opt-in via the interactive prompt or `B_AGENTIC_INSTALL_RUNTIME_CLI=Y`.

Interactive installs prompt for runtime CLI preparation, missing shell tooling, and optional RTK, Serena, and CodeGraph installs. When present, the runtime requires `rg` instead of `grep`, `fd` or `fdfind` instead of `find`, and `jq` instead of `python -m json.tool`, `awk`, or `grep` for JSON.

## RTK (Rust Token Killer)

During interactive installs, the installer can prompt to download and run the RTK install script from `https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh`. If `rtk` is already installed, the installer asks separately before upgrading it. Scripted upgrades require `B_AGENTIC_INSTALL_RTK=Y`. This is a remote shell script; only use it if you trust the RTK repository. RTK is otherwise optional and the installer skips it by default.

Once installed, the kernel instructs the agent to use RTK for command families it supports when filtering preserves the evidence needed for the task. Unsupported commands run directly instead of receiving an invalid `rtk` prefix. The managed safety gates remain configured for both bare commands and their `rtk`-wrapped forms, but fresh-session acceptance is still required to prove runtime behavior:

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
rtk --help           # Supported command families
rtk proxy <cmd>     # Raw execution with tracking
```

Verification: `rtk --version`, `rtk gain`, `which rtk`.

## Serena MCP agent

Interactive installs can prompt to install the Serena MCP agent, which provides symbol discovery, references, diagnostics, and symbol edits. If `serena` is already installed, the installer asks before running `uv tool upgrade serena-agent`. Scripted upgrades require `B_AGENTIC_INSTALL_SERENA=Y`.

If `uv` is already installed, the installer runs:

```bash
uv tool install -p 3.13 serena-agent
```

If `uv` is missing, the installer prompts to install it from `https://astral.sh/uv/install.sh` before proceeding with Serena. As with any remote install script, only proceed if you trust the source.

## CodeGraph MCP agent

b-agentic writes a default [CodeGraph](https://github.com/colbymchenry/codegraph) MCP entry that runs `codegraph serve --mcp` with `CODEGRAPH_TELEMETRY=0`. In interactive sessions, the installer can prompt to install CodeGraph with `curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh | sh`; if CodeGraph is already installed, the installer asks before running `codegraph upgrade`. Scripted upgrades require `B_AGENTIC_INSTALL_CODEGRAPH=Y`. Run `codegraph init` in each repository where you want a local pre-indexed code graph.

Use CodeGraph for architectural flows, call graphs, impact radius, route-to-handler discovery, and affected-test discovery. Use Serena for symbol declarations, references, diagnostics, and symbol-aware edits. Use local reads/search to verify exact edited content.

## Runtime Support

| Runtime | Skill invocation | MCP config |
|---|---|---|
| Codex CLI | `/skills`, `$skill-name`, or implicit matching | `~/.codex/config.toml` |
| Claude Code | Native `/b-*` skills from `~/.claude/skills/` | `~/.claude.json` |
| OpenCode | Native skill tool plus `/b-*` wrappers in `~/.config/opencode/commands/` | `~/.config/opencode/opencode.json` |
| Antigravity CLI | Native skills from `~/.gemini/antigravity-cli/skills/` | `~/.gemini/antigravity-cli/mcp_config.json` |

<!-- generated:runtime-capabilities:start -->
| Runtime | Skills | Permissions | Rules | Wrappers |
|---|---|---|---|---|
| Codex CLI | native | native | native | unsupported |
| Claude Code | native | native | native | unsupported |
| OpenCode | native | native | native | native; adapter-only |
| Antigravity CLI | native | native | native | unsupported |
<!-- generated:runtime-capabilities:end -->

Adapters preserve user-owned config and report what they changed. They do not promise automatic phase continuation or deterministic enforcement beyond the runtime's normal permission model.

Permission defaults follow each runtime's native model, so the baseline differs: Claude Code has its own default-mode behavior, including built-in read-only Bash allowances; Codex CLI applies managed rules to commands that request to run outside the sandbox; OpenCode defaults unlisted shell commands to `ask` while allow-listing read-only and required tools; and Antigravity CLI uses deny/ask/allow precedence with managed settings in `~/.gemini/antigravity-cli/settings.json`. On top of that baseline, b-agentic configures managed safety gates for commits, pushes, dependency writes, and destructive commands, including their `rtk`-wrapped forms when RTK is enabled.

## Skills

<!-- generated:skills-table:start -->
| Skill | Phase | Use |
|---|---|---|
| `b-plan` | Decide | Figure out what to do when scope or approach is fuzzy, then produce an execution-ready plan |
| `b-research` | Decide | Fetch outside truth: docs, API facts, comparisons, or recent evidence |
| `b-design` | Decide | Create or refresh docs/DESIGN.md as a frontend design standard |
| `b-implement` | Build | Make the scoped change from an approved plan or a small direct request |
| `b-init` | Build | Initialize or refresh repo-local agent instruction docs |
| `b-refactor` | Build | Rename, extract, move, inline, simplify, or delete behavior-preserving code |
| `b-debug` | Validate | Find the real runtime root cause and fix it only when authorized |
| `b-test` | Validate | Write or fix unit, integration, contract, and simulated-DOM tests |
| `b-browser` | Validate | Collect real-browser, visual, screenshot, live UI, or e2e evidence |
| `b-review` | Validate | Review changed code or run a b-agentic suite self-audit |
| `b-summary` | Ship | Write commit and PR copy for one cohesive staged change |
<!-- generated:skills-table:end -->

Typical flow:

```text
b-plan [goal] -> approve -> b-implement -> b-test -> b-review -> b-summary
b-research [external facts]
b-design [frontend design standard]
b-debug [runtime bug]
b-browser [UI/e2e evidence]
b-refactor [behavior-preserving transform]
```

## MCPs

The installer writes recommended MCP entries for:

- Serena: symbol discovery, references, diagnostics, and symbol edits.
- CodeGraph: local pre-indexed code structure, flows, impact radius, and affected tests.
- Context7: versioned library/framework docs.
- Firecrawl: primary public web search, bounded extraction, arXiv/paper and GitHub issue/discussion lookup, and approved deeper research.
- Brave Search: secondary public/current discovery and alternate source finding.
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
scripts/b-agentic-audit.sh
scripts/smoke-install.sh
scripts/mcp-doctor.sh --runtime=claude-code
scripts/mcp-doctor.sh --runtime=codex-cli
scripts/mcp-doctor.sh --runtime=opencode
scripts/mcp-doctor.sh --runtime=antigravity-cli
scripts/mcp-doctor.sh --runtime=opencode --allow-degraded
scripts/mcp-doctor.sh --runtime=antigravity-cli --allow-degraded
scripts/skill-doctor.sh --runtime=claude-code
scripts/skill-doctor.sh --runtime=codex-cli
scripts/skill-doctor.sh --runtime=opencode
scripts/skill-doctor.sh --runtime=antigravity-cli
```

The validation suite and doctors prove generated sync, install safety, runtime config shape, skill payloads, and local MCP readiness blockers. The default routing check is a static heuristic over skill registry metadata, not a live-model routing test. Automated checks do not prove that a live runtime session has loaded the kernel, that approval gates fire in a real session, or that remote MCP calls succeed.

Professional release readiness requires both automated validation and one fresh-session acceptance pass for each changed runtime. Treat automated checks as install/config evidence; treat fresh-session checks as runtime behavior evidence. Use `scripts/runtime-acceptance.sh --runtime=<name> --production` after installing a runtime to collect local doctor output, enforce production MCP readiness, and print the required fresh-session gates. Add `--active` to run local noninteractive runtime probes for kernel loading, skill routing, MCP tool-call evidence, and approval/deny signals without Git side effects. `--active` is available for Claude Code, Codex CLI, and OpenCode; Antigravity CLI active acceptance is unsupported until a documented non-interactive prompt mode is available.

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
