# ADR-034: All-runtimes installer (`--runtime=all`)

- Status: Accepted
- Date: 2026-11-23
- Supersedes: None (extends [ADR-030](ADR-030-pi-runtime-rendered-at-install.md), [ADR-032](ADR-032-equal-runtimes-three-tier-support.md), and [ADR-033](ADR-033-opt-in-vendor-tool-installs.md))

## Context

With Claude Code (`./install.sh`) and Pi (`./install.sh --runtime=pi`) as equal main-flow runtimes ([ADR-032](ADR-032-equal-runtimes-three-tier-support.md)), users running both tools on one workstation had to invoke `install.sh` twice, answer overlapping vendor prompts (`rtk`, `codegraph`) twice, and risk leaving Claude Code installed if Pi preflight failed on the second command.

## Decision

- **`--runtime=all` selector:** `install.sh` accepts `--runtime=all` (no standalone `--all` alias; `--runtime=both` and other unsupported values stay refused with the [ADR-020](ADR-020-claude-code-only-again.md) and [ADR-030](ADR-030-pi-runtime-rendered-at-install.md) pointers) and dispatches to `tooling/install/all_install.py`.
- **Preflight and plan both before any write:** `tooling/install/claude_install.py` and `tooling/install/pi_install.py` separate `prepare_install`/`replan_install`/`apply_install` and `prepare_uninstall`/`apply_uninstall`. Under `--runtime=all`, both `Installer` objects are constructed, preflighted, and planned before either writes or removes anything; a refusal in either aborts with both roots unchanged. On a terminal, each runtime shows a runtime-labeled optional-component checklist (`Claude Code`, `Pi`), both summaries, and one `Proceed with installation?` confirm, followed by a re-plan of both before applying Claude Code then Pi.
- **Per-runtime manifests and `--uninstall`:** Each runtime keeps its own manifest (`~/.claude/b-agentic/install.json` and `~/.pi/agent/b-agentic/install.json`), backups, and optional-component selection. `--runtime=all --uninstall` plans both removals first, removes each recorded runtime, and treats an absent manifest as a clean no-op (exit 0).
- **Pi flag restrictions:** `--runtime=all` applies the `--runtime=pi` restrictions, refusing `--statusline-only`, `--update`, `--ref`, and piped (cloning) installs before any git call or write.
- **Deduplicated vendor prompts:** Extending [ADR-033](ADR-033-opt-in-vendor-tool-installs.md), `tooling/install/vendor_tools.py` adds an `"all"` entry offering each missing tool once in the order `claude`, `pi`, `rtk`, `codegraph`, plus the `rtk init -g --hook-only --auto-patch` prompt once when `rtk` is present and its Claude hook is absent, and refreshes the Pi version warning if `pi` was installed.

## Consequences

- Single-runtime behavior (`./install.sh`, `--runtime=claude`, `--runtime=pi`) keeps identical manifests, output, and CLI semantics.
- An I/O error while applying Pi after Claude Code has already applied leaves Claude Code installed; rerunning `--runtime=all` or `--uninstall` recovers cleanly using each runtime's `pending` manifest.
- `tests/install/all-install-probe.sh` verifies `--runtime=all` offline in `tooling/validate/run.sh --release`.

## Rejected

- **Sequential shell invocations in `install.sh`:** rejected because a Pi preflight or planning failure would leave Claude Code already mutated.
- **One shared optional-component checklist across both runtimes:** rejected because pre-checking unioned components could silently remove a component from a runtime where only the other had it installed.
- **Standalone `--all` flag:** rejected to keep `--runtime=<target>` as the single runtime selector.

Evidence: [`install.sh`](../../install.sh), [`tooling/install/all_install.py`](../../tooling/install/all_install.py), [`tooling/install/claude_install.py`](../../tooling/install/claude_install.py), [`tooling/install/pi_install.py`](../../tooling/install/pi_install.py), [`tooling/install/vendor_tools.py`](../../tooling/install/vendor_tools.py), and [`tests/install/all-install-probe.sh`](../../tests/install/all-install-probe.sh).
