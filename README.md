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

Useful flags:

- `--dry-run` previews changes
- `--replace-memory` replaces an existing managed kernel file
- `--uninstall` removes managed files
- `--install-rtk` installs [RTK](https://github.com/rtk-ai/rtk) and adds the `rtk` shell-command rule to the kernel
- `--install-serena` installs the [Serena](https://github.com/hellocode-io/serena) MCP agent via `uv tool install -p 3.13 serena-agent` (will prompt to install `uv` if missing)

Requirements: `bash`, `git`, Python 3.11+, and `pnpm` for MCP entries that use `pnpm dlx`.

## RTK (Rust Token Killer)

When `--install-rtk` is used, the installer downloads and runs the RTK install script from `https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh`. This is a remote shell script; only use it if you trust the RTK repository. RTK is otherwise optional and the installer skips it by default.

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

`--install-serena` installs the Serena MCP agent, which provides symbol discovery, references, diagnostics, and symbol edits.

If `uv` is already installed, the installer runs:

```bash
uv tool install -p 3.13 serena-agent
```

If `uv` is missing, the installer prompts to install it from `https://astral.sh/uv/install.sh` before proceeding with Serena. As with any remote install script, only proceed if you trust the source.

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
| `b-ship` | Ship | Commit, push, and open a PR on explicit request after review readiness |
<!-- generated:skills-table:end -->

Typical flow:

```text
b-plan [goal] -> approve -> b-implement -> b-test -> b-review -> b-ship
b-research [external facts]
b-debug [runtime bug]
b-browser [UI/e2e evidence]
b-refactor [behavior-preserving transform]
```

## MCPs

The installer writes recommended MCP entries for:

- Serena: symbol discovery, references, diagnostics, and symbol edits.
- Context7: versioned library/framework docs.
- Brave Search: public/current discovery.
- Firecrawl: bounded extraction and approved deeper research.
- Playwright: live browser, visual, console/network, and e2e evidence.

The installer does not start MCP servers, install `pnpm dlx` packages ahead of time, or run Serena onboarding. It does report local MCP readiness blockers such as missing binaries or API keys.

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

## Docs

- `README.md` is the repository overview.
- `CLAUDE.md` is maintainer guidance.
- `references/contract/` contains the runtime contract shipped to adapters.
