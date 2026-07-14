# b-agentic

**Slim workflow kernel for coding agents. Ships the Pi runtime; the registry-driven installer and runtime scaffold keep it multi-runtime-ready.**

b-agentic installs a compact runtime kernel, focused phase skills, runtime adapters, and recommended MCP config. Its job is simple: route work, preserve safety gates, use the right evidence, verify before claiming done, and keep multi-runtime setup consistent.

## Install

Default install for Pi:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash
```

Install another runtime:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --runtime=<name>
```

Use `<name>` as the registered runtime (currently `pi`). Use `--runtime=all` for every registered runtime.

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

MCP servers and RTK are installed from their latest available releases. Run `scripts/mcp-doctor.sh --runtime=<name>` after setting API keys to verify local readiness. Missing credentials or dependencies fail checks by default; use `--allow-degraded` to inspect status without failing.

Requirements: `bash`, `git`, Python 3.11+, and `pnpm` for MCP entries that use `pnpm dlx`. Runtime CLI installation or upgrade is opt-in via the interactive prompt or `B_AGENTIC_INSTALL_RUNTIME_CLI=Y`.

Interactive installs prepare the runtime and install required shell tooling and RTK; Serena and CodeGraph remain optional installs. The runtime requires `rg` instead of `grep`, `fd` or `fdfind` instead of `find`, `bat` (or Debian/Ubuntu's `batcat`) instead of `cat`, `eza` or `exa` instead of `ls`, `sd` instead of `sed` or `awk`, and `jq` instead of `python -m json.tool` for JSON.

## RTK (Rust Token Killer)

During interactive installs, the installer can prompt to download and run the RTK install script from its `master` branch. If `rtk` is already installed, the installer asks separately before upgrading it; the existing installation satisfies the prerequisite. Scripted upgrades require `B_AGENTIC_INSTALL_RTK=Y`. This is a remote shell script; only use it if you trust the RTK repository. RTK is required for b-agentic sessions; installation fails if it cannot be installed.

Once installed, each runtime declares the command families it requires RTK to wrap; other commands run directly instead of receiving an invalid `rtk` prefix. The Pi runtime enforces Git, Cargo, npm/pnpm/yarn/bun, pytest, and the documented classic replacement families. The managed safety gates remain configured for both bare commands and their `rtk`-wrapped forms:

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
| Pi | Native skills from `~/.pi/agent/skills/` | `~/.pi/agent/mcp.json` via `pi-mcp-adapter` |

<!-- generated:runtime-capabilities:start -->
| Runtime | Skills | Permissions | Rules | Wrappers | MCP |
|---|---|---|---|---|---|
| Pi | native | adapter; adapter-only | unsupported | unsupported | adapter; adapter-only |
<!-- generated:runtime-capabilities:end -->

Capability matrix (support labels plus enforceable limits):

<!-- generated:runtime-capability-matrix:start -->
| Runtime | Support tier | Permission granularity | Kernel loading | Skill mode | MCP adapter | Static | Known limitation |
|---|---|---|---|---|---|---|---|
| Pi | operation-enforced | adapter tool_call extension | managed memory file | native | pi-mcp-adapter | yes | print-mode cannot prove UI approval |
<!-- generated:runtime-capability-matrix:end -->

Adapters preserve user-owned config and report what they changed. They do not promise automatic phase continuation or deterministic enforcement beyond the runtime's normal permission model.

Pi has no native permission model, so b-agentic installs a first-party `tool_call` extension at `~/.pi/agent/extensions/b-agentic-permissions.ts`. The Pi extension auto-approves MCP metadata discovery and only the explicitly classified read-only managed MCP operations, while prompting for approval-required shell commands, managed MCP local or external mutations, unclassified managed operations, user/unknown MCP servers, and other custom tools; those approval-required actions fail closed without UI. Pi MCP requires the community adapter `pi-mcp-adapter` (prompted interactively, or `B_AGENTIC_INSTALL_PI_MCP_ADAPTER=Y` noninteractively); uninstall removes managed config/extension files but not the adapter package. On top of this baseline, b-agentic configures managed safety gates for commits, pushes, dependency writes, and destructive commands, including their `rtk`-wrapped forms when RTK is enabled. Pi is support tier `operation-enforced` for Firecrawl/Playwright policy derived from `references/mcp_operations.yaml` and `references/kernel.template.md`.

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

The installer does not start MCP servers, install `pnpm dlx` packages ahead of time, run `codegraph init`, or run Serena onboarding. It reports local MCP readiness blockers such as missing binaries or API keys. Use `scripts/mcp-doctor.sh --session-tools` to verify the active session has RTK and every required shell tool.

## Repository Layout

```text
b-agentic/
├── skills/                # Skill sources and generated delivery assets
├── runtimes/              # Runtime adapters, configs, scripts, and smoke lanes
├── references/            # Runtime kernel and MCP policy
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
scripts/mcp-doctor.sh --runtime=pi
scripts/mcp-doctor.sh --runtime=pi --allow-degraded
scripts/skill-doctor.sh --runtime=pi
```

Prompt effectiveness is an opt-in, human-scored check because it makes potentially billable model calls and is nondeterministic. Pin the model and thinking level when comparing a baseline with a candidate:

```bash
python3 runtimes/pi/tests/prompt_effectiveness.py --allow-model-calls --model=<model> --thinking=<level> --label=baseline > baseline.json
```

The validation suite and doctors prove generated sync, install safety, runtime config shape, skill payloads, MCP operation policy regression, and local MCP readiness blockers. The routing check is a static heuristic over skill registry metadata; only the optional effectiveness check observes model responses, and it still requires human review against the included rubric.

## Docs

- `README.md` is the repository overview.
- `AGENTS.md` is maintainer guidance.
- `CHANGELOG.md` records shipped revisions.
- `references/` contains the runtime kernel and canonical `mcp_operations.yaml` shipped to adapters.
