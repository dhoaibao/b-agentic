# ADR-033: Opt-in interactive vendor tool installs after config sync

- Status: Accepted
- Date: 2026-11-23
- Supersedes: [ADR-001](ADR-001-b-agentic-design-record.md) in part (the "never runs vendor installers" rule under Installation, configuration, and lifecycle) and [ADR-030](ADR-030-pi-runtime-rendered-at-install.md) in part (the "installer never installs Pi" rule for interactive terminal runs)

## Context

[ADR-001](ADR-001-b-agentic-design-record.md) and [ADR-030](ADR-030-pi-runtime-rendered-at-install.md) forbade running
any vendor installer during `install.sh` so configuration sync stayed deterministic, offline-safe for Pi, and confined
to `~/.claude` + `~/.claude.json` or `~/.pi/agent`. On a fresh machine, however, users still had to look up and copy
the native `curl` commands for the runtime (`claude` or `pi`), `rtk`, `codegraph`, and `rtk init -g --hook-only --auto-patch`
separately after running `install.sh`.

With official native `curl` installers documented for all four tools (`https://claude.ai/install.sh`,
`https://pi.dev/install.sh`, `rtk-ai/rtk`, and `colbymchenry/codegraph`), the user decided to add opt-in interactive
`[y/N]` prompts after b-agentic's own configuration sync completes, while preserving non-interactive, dry-run,
statusline-only, and uninstall safety guarantees.

## Decision

- **Post-sync interactive `[y/N]` prompts only:** `tooling/install/vendor_tools.py` offers one `[y/N]` prompt (default
  No) per missing tool on `/dev/tty` only after `installer.install()` has committed `b-agentic`'s own manifest and
  configuration. Prompts and vendor commands never run under `-y`/`--yes`, `--dry-run`, `--uninstall`,
  `--statusline-only`, a non-terminal stdout, or when `/dev/tty` is unavailable.
- **Per-runtime scope and fixed commands:**
  - Claude Code (`tooling/install/claude_install.py`): offers `claude` (`curl -fsSL https://claude.ai/install.sh | bash`),
    `rtk` (`curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh`), `codegraph`
    (`curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh | sh`), and—only when `rtk`
    is found on `PATH` or `~/.local/bin` and `rtk init --show` does not report `[ok]` for `~/.claude/settings.json`
    RTK hooks—`rtk init -g --hook-only --auto-patch`.
  - Pi (`tooling/install/pi_install.py`): offers `pi` (`curl -fsSL https://pi.dev/install.sh | sh`), `rtk`, and
    `codegraph`. Pi never runs `rtk init`, and once `pi` is installed the stale `pi is not on PATH` warning is
    re-evaluated.
- **Non-blocking failure and prerequisite handling:** `bun` remains a hard upfront requirement for Claude Code, while
  `bun`, `node`, `npm`, `git`, `curl`, and `codex` are never auto-installed. When `curl` is missing on `PATH`, the
  installer warns which tools were skipped and skips their prompts. Any non-zero exit status, `OSError`, or
  cancellation adds a warning without changing `b-agentic`'s installed state or exit status.

## Consequences

- `b-agentic`'s own sync still touches only `~/.claude` and `~/.claude.json` (or `~/.pi/agent` for Pi), while an
  approved vendor `curl` installer writes its binary to its upstream target (for example `~/.local/bin` for `rtk`), and
  `rtk init -g --hook-only --auto-patch` adds the user-owned RTK `PreToolUse` hook to `~/.claude/settings.json`.
- Existing automated install probes (`tests/install/claude-install-probe.sh` and `tests/install/pi-install-probe.sh`)
  remain 100% offline using a logging `curl` stub, a filtered `no-vendor` `PATH`, and `rtk`/`pi` stubs.

## Rejected

- **Single multi-select checklist for all vendor tools:** rejected in favor of explicit per-tool `[y/N]` prompts so the
  user inspects and approves each exact command individually.
- **Default `[Y/n]` or running under `-y`:** rejected because downloading and executing upstream shell scripts from
  the network must require an explicit interactive `y`.
- **Auto-installing `bun` or `node`/`npm`:** rejected to keep the installer's scope narrow and avoid mutating system
  package managers or shell profiles.

Evidence: [`tooling/install/vendor_tools.py`](../../tooling/install/vendor_tools.py),
[`tooling/install/claude_install.py`](../../tooling/install/claude_install.py),
[`tooling/install/pi_install.py`](../../tooling/install/pi_install.py),
[`tests/install/claude-install-probe.sh`](../../tests/install/claude-install-probe.sh), and
[`tests/install/pi-install-probe.sh`](../../tests/install/pi-install-probe.sh).
