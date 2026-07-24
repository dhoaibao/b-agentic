# b-agentic

**A slim workflow kernel for the Pi coding agent. b-agentic and Pi are one integrated product.**

b-agentic installs a compact Pi kernel, focused phase skills, a permission extension, and recommended MCP configuration. Its job is simple: route work, preserve safety gates, use the right evidence, and verify before claiming done.

## Install

Default install for Pi:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash
```

Default install writes b-agentic files and Pi configuration only. Interactive installs prompt before installing or upgrading the Pi CLI. Non-interactive installs skip Pi CLI changes unless `B_AGENTIC_INSTALL_PI_CLI=Y` explicitly opts in.

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

MCP servers and RTK are installed from their latest available releases. Run `scripts/mcp-doctor.sh` after setting API keys to verify local readiness. Missing credentials or dependencies fail checks by default; use `--allow-degraded` to inspect status without failing.

Requirements: `bash`, `git`, Python 3.11+, and `pnpm` for MCP entries that use `pnpm dlx`. Pi CLI installation or upgrade is opt-in via the interactive prompt or `B_AGENTIC_INSTALL_PI_CLI=Y`.

Interactive installs prepare Pi and RTK; Serena and CodeGraph remain optional installs. When modern shell tools are missing, interactive installs prompt to install them: `rg` over `grep`, `fd` or `fdfind` over `find`, `bat` (or Debian/Ubuntu's `batcat`) over `cat`, `eza` or `exa` over `ls`, `sd` over `sed` or `awk`, and `jq` over `python -m json.tool` for JSON when they improve the task. Set `B_AGENTIC_INSTALL_SHELL_TOOLS=Y` to install them non-interactively.

## RTK (Rust Token Killer)

During interactive installs, the installer can prompt to download and run the RTK install script from its `master` branch. If `rtk` is already installed, the installer asks separately before upgrading it; the existing installation satisfies the prerequisite. Scripted upgrades require `B_AGENTIC_INSTALL_RTK=Y`. This is a remote shell script; only use it if you trust the RTK repository. RTK is required for b-agentic sessions; installation fails if it cannot be installed.

Once installed, b-agentic runs command families supported by `rtk --help` through RTK and runs unsupported commands directly. RTK does not bypass approval for commits, dependency writes, services, or other dangerous commands; explicit destructive commands are denied, and protected paths or opaque execution remain approval-gated. The Pi runtime enforces RTK only for supported native command families:

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
rtk proxy <cmd>     # Optional raw execution with RTK tracking
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

## Pi integration

Pi discovers native skills from `~/.pi/agent/skills/` and MCP configuration from `~/.pi/agent/mcp.json` through `pi-mcp-adapter`. b-agentic preserves user-owned configuration and reports every managed change.

Pi has no native permission model, so b-agentic installs a first-party `tool_call` extension at `~/.pi/agent/extensions/b-agentic-permissions.ts`. The extension auto-approves MCP metadata discovery plus classified read-only and safe conditional-read operations. Managed mutations, local uploads, lifecycle actions, auth, user/unknown MCP servers, and other custom tools require approval and fail closed without UI. Protected paths and opaque execution remain approval-gated; explicit destructive shell commands are denied. Pi MCP requires the community adapter `pi-mcp-adapter` (prompted interactively, or `B_AGENTIC_INSTALL_PI_MCP_ADAPTER=Y` noninteractively). The optional `pi-observational-memory` package provides long-session compaction continuity; it is prompted interactively or installed noninteractively with `B_AGENTIC_INSTALL_PI_OBSERVATIONAL_MEMORY=Y`, and should be the sole automatic memory/compaction layer. Uninstall removes managed config/extension files but not any package. Pi enforces managed MCP and RTK policy from `references/mcp_operations.yaml` and `references/kernel.template.md`.

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
| `b-commit` | Ship | Split working-tree changes into approved cohesive commits |
| `b-pr-summary` | Ship | Write general PR copy for recent commits or commits ahead of cached origin |
<!-- generated:skills-table:end -->

Typical flow:

```text
b-plan [goal] -> approve -> b-implement -> b-test -> b-review -> b-commit -> b-pr-summary [commit-count]
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

The installer does not start MCP servers, install `pnpm dlx` packages ahead of time, run `codegraph init`, or run Serena onboarding. It reports local MCP readiness blockers such as missing binaries or API keys. Use `scripts/mcp-doctor.sh --session-tools` to verify the active session has RTK. When live network/process activity is approved, `scripts/mcp-doctor.sh --probe-schemas` explicitly starts or connects to each configured server and compares its current tool inventory with the canonical operation policy.

## Repository Layout

```text
b-agentic/
├── skills/                # Skill sources and generated delivery assets
├── pi/                    # Pi integration, config, extension, and smoke lanes
├── references/            # Pi kernel and MCP policy
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
scripts/mcp-doctor.sh
scripts/mcp-doctor.sh --allow-degraded
scripts/mcp-doctor.sh --probe-schemas  # explicit live server/network probe
scripts/skill-doctor.sh
```

Prompt effectiveness is an opt-in, human-scored check because it makes potentially billable model calls and is nondeterministic. Validate its default inputs without model calls, then pin the model and thinking level when comparing a baseline with a candidate:

```bash
python3 pi/tests/prompt_effectiveness.py --validate-inputs
python3 pi/tests/prompt_effectiveness.py --allow-model-calls --model=<model> --thinking=<level> --label=baseline > baseline.json
python3 pi/tests/prompt_effectiveness.py --routing --validate-inputs
python3 pi/tests/prompt_effectiveness.py --routing --allow-model-calls --model=<model> --thinking=<level> --label=baseline-routing > baseline-routing.json
```

The validation suite and doctors prove generated sync, install safety, Pi config shape, skill payloads, MCP operation policy regression, and local MCP readiness blockers. The default routing check is a static heuristic over skill registry metadata. The opt-in `--routing` effectiveness lane loads every native skill with read-only tools and records the model's reported selection; both effectiveness modes require human review against their included rubrics.

## Docs

- `README.md` is the repository overview.
- `AGENTS.md` is maintainer guidance.
- `CHANGELOG.md` records shipped revisions.
- `references/` contains the Pi kernel and canonical `mcp_operations.yaml` shipped to the Pi integration.
