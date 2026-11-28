<!-- b-init-managed:start -->

## Repository Purpose

b-agentic is a slim personal workflow kernel with equal main-flow parity across
Claude Code (default `./install.sh` runtime, with Codex or `b-reviewer` as the
independent reviewer) and Pi (`./install.sh --runtime=pi`, with `b-reviewer`;
[ADR-030](docs/decisions/ADR-030-pi-runtime-rendered-at-install.md),
[ADR-032](docs/decisions/ADR-032-equal-runtimes-three-tier-support.md)). It ships
the always-loaded kernel, skills that double as commands, managed MCP
configuration, read-only specialist agents plus `b-worker`, safety hooks/guards,
and installer/validation tooling. See the [public overview](README.md) and
[operational reference](REFERENCE.md).

## Project Operating Guide

### Architecture and change map

- `skills/` holds registry metadata, canonical prompts, and generated skill files; `references/` holds the shared kernel, capability registry, MCP policy, runtime vocabulary (`runtimes.yaml`), and `b-flow` artifact schemas (`artifacts.yaml`); `claude/` holds generated agents and settings plus the hooks, CLIs, and MCP templates; `pi/` holds the hand-written parts of the Pi runtime (helper wrappers, the guard and input-image-preview extensions, and the vendored Dracula theme in `pi/themes/`; its rendered tree is generated at install time, never committed); `tooling/` holds generation, installation, and validation; `tests/` holds behavior, hook, snapshot, and installer coverage.
- Change shared guidance and schemas in `references/`, runtime hooks and CLIs in `claude/`, installer behavior and shared terminal UI in `install.sh` or `tooling/install/` (`claude_install.py`, `claude_install_ui.py`, `pi_install.py`, `optional_components.py`, `vendor_tools.py`), the Pi guard, input-image-preview extension, wrappers, and theme in `pi/`, and checks in `tooling/validate/` or `scripts/`. Use the [ADR-001 design record](docs/decisions/ADR-001-b-agentic-design-record.md) when a change crosses these boundaries.

### Documentation

- Create and update project docs by the roles in [docs/README.md](docs/README.md) and the naming and templates in each docs folder's README; search for an existing doc first.
- Record deferred work worth keeping, such as open follow-ups, undecided designs, or an evaluation baseline, in a [docs/specs/](docs/specs/README.md) spec: session memory, `.b-agentic/runs/`, and stashes stay on one machine. Keep other repositories' names and text, local paths, and stored data out of it.

### Canonical sources and change flows

- `skills/registry.yaml` owns skill metadata, routing, phase, execution ownership, optional components, specialist-agent profiles, and `workers` (`b-worker`); each `skills/*/prompt.md` owns its canonical skill body. `tooling/generate/registry_sync.py` renders `SKILL.md` files, agents, the settings template, the `README.md` skills table, and kernel delivery blocks (and renders the Pi tree at install time via `--render pi`), so edit sources and regenerate rather than hand-editing output.
- `references/kernel.template.md`, `references/mcp_operations.yaml`, `references/capabilities.yaml`, `references/runtimes.yaml`, and `references/artifacts.yaml` own runtime guidance, capability policy, per-runtime vocabulary, and `b-flow` run artifact schemas (canonical sources use Claude Code wording; `references/runtimes.yaml` holds the `claude` entry, which is the identity render, and the `pi` entry with the `<!-- runtime: NAME[,NAME] -->` marker, glossary, and `kernel_overrides` mechanism). The installer consumes generated output; the [operational reference](REFERENCE.md) documents the installed boundary. Earlier second runtimes were removed by [ADR-008](docs/decisions/ADR-008-claude-code-only.md), by [ADR-020](docs/decisions/ADR-020-claude-code-only-again.md) (last OpenCode tree in commit `f80281b7`; the earlier Pi tree was last in `ba7bc2db`), and by [ADR-027](docs/decisions/ADR-027-antigravity-runtime-removed.md) (last Antigravity tree in commit `caf570fd`); Pi returns rendered at install time under [ADR-030](docs/decisions/ADR-030-pi-runtime-rendered-at-install.md) and [ADR-031](docs/decisions/ADR-031-pi-worker-steps.md), with equal main-flow parity and three feature tiers in [ADR-032](docs/decisions/ADR-032-equal-runtimes-three-tier-support.md).

### Project constraints and boundaries

- Keep this supplement slim, strong, and usable: retain evidence-backed orientation, ownership, boundaries, and required flows, and link to deeper docs instead of copying setup, release, readiness, or diagnostic catalogs. This is the repository's b-init output quality standard; see [ADR-001 design record](docs/decisions/ADR-001-b-agentic-design-record.md).
- `skills/registry.yaml`, `references/mcp_operations.yaml`, `references/capabilities.yaml`, `references/runtimes.yaml`, and `references/artifacts.yaml` use the JSON-compatible YAML subset consumed by generators and validators. Do not hand-edit generated assets (`skills/*/SKILL.md`, `claude/agents/*`, `claude/configs/settings.template.json`).
- Main-flow features across Claude Code and Pi must be `shared` or `adapted` (with rendered instruction-contract parity checked by `tooling/validate/runtime_parity.py`); `exclusive` extras need no parity ([ADR-032](docs/decisions/ADR-032-equal-runtimes-three-tier-support.md)).
- Installer and configuration changes cross a user-owned boundary: `tooling/install/` merges user configuration and preserves unrelated content, writes through symlinked config files while refusing symlinked managed directories or manifests, and templates do not prove live MCP or model readiness. b-agentic's own Claude Code sync touches only `~/.claude` and `~/.claude.json`, `install.sh --runtime=pi` syncs only under `~/.pi/agent` and pins no npm packages, and `install.sh --runtime=all` preflights both runtimes before writing either under [ADR-034](docs/decisions/ADR-034-all-runtimes-install.md) (with `--runtime=pi` flag restrictions and deduplicated vendor prompts). On interactive runs (skipped under `-y`, `--dry-run`, `--uninstall`, `--statusline-only`, non-terminal stdout, or no `/dev/tty`), post-sync `[y/N]` prompts offer native `curl` installs (writing outside those sync roots) for missing `claude` (`curl -fsSL https://claude.ai/install.sh | bash`) or `pi` (`curl -fsSL https://pi.dev/install.sh | sh`), `rtk` (`curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh`), and `codegraph` (`curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh | sh`), plus `rtk init -g --hook-only --auto-patch` on Claude Code; any other `--runtime` is refused. See the [Claude Code configuration layout](claude/configs/README.md), the [Pi runtime](pi/README.md), and the [operational reference](REFERENCE.md).
- No database or migration files, infrastructure/deployment manifests, or external-service client source beyond installer/MCP integration is present. Do not invent conventions for absent surfaces; reassess when evidence appears.

## Verification

- `python3 tooling/generate/registry_sync.py --check` — confirm generated delivery assets match canonical sources (add `--self-test` for generator and in-memory Pi render checks).
- `scripts/validate-skills.sh` — run synchronization, behavior, policy, hook, snapshot, status line, Pi guard, and readiness checks (`--release` adds the sandbox installer probes for Claude Code, Pi, and `--runtime=all`).
- `scripts/b-agentic-audit.sh` — run ADR traceability and structural suite slimness/token checks (`--skip-preflight` skips the generated-asset sync check and the default validation suite).
- `bun run quality` — run Prettier, Ruff, ShellCheck, and Markdownlint checks on tracked files when dependencies are installed.
- `rtk git diff --check` — check changed paths for whitespace errors.
- While editing, run only the checks for what changed, such as one probe script under `tests/`, one state shard (`bash tests/state/state-probe.sh <case>`), or one `tooling/validate/` script. Run the required checks on the final candidate, cheap ones first and the full suite last; never skip or weaken one to save time.
- The full suite is costly, so a new plan runs it once per candidate: `scripts/validate-skills.sh --release` already includes the default run, so list it alone when the installer probes are needed, and run the audit with `--skip-preflight` when the suite runs on its own. An approved plan's checks still run as listed.

<!-- b-init-managed:end -->
