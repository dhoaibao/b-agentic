# Pi runtime

b-agentic installs Claude Code by default (`./install.sh`) and treats Pi (`./install.sh --runtime=pi`) as an equal
first-class runtime across every main flow under the three-tier feature model
([ADR-030](../docs/decisions/ADR-030-pi-runtime-rendered-at-install.md),
[ADR-032](../docs/decisions/ADR-032-equal-runtimes-three-tier-support.md)). This folder holds the hand-written parts
of the Pi runtime: the helper wrappers, one owned extension, and the vendored Dracula theme (a Pi-only Tier 3 extra).
Everything else Pi needs (kernel, skills, prompt templates, agents, permission, subagent, and MCP configuration) is
rendered from the same sources as the Claude Code files when you install, and the rendered tree is never committed.

## Install and remove

Install Pi yourself (`@earendil-works/pi-coding-agent`, 1.6.0 or newer; nothing is pinned). The installer never installs Pi
or a package, never uses the network, and runs only `pi --version`, to warn below the floor. Pi installs the packages named
in `settings.json` on its next start.

```bash
./install.sh --runtime=pi [--dry-run] [--force] [-y] [--with=ID[,ID]] [--without=ID[,ID]]
./install.sh --runtime=pi --uninstall
```

It installs only from a local checkout (no `--update`, `--ref` or clone) and writes under `~/.pi/agent`; on a terminal
without `-y`, `--dry-run`, or `--uninstall` it shows the timeline, optional-component checklist, summary, and confirm
prompt (declining leaves `~/.pi/agent` untouched, and non-terminal or plain flags keep plain output); a config file
there that is a symlink is written through to its target, wherever that is. See the
[operational reference](../REFERENCE.md#pi-runtime) for the layout, ownership rules and refusals.

## What ships from this folder

- `bin/b-state`, `bin/b-run`, `bin/b-snapshot`: wrappers that set `B_AGENTIC_HELPER_DIR` to `~/.pi/agent/b-agentic/bin`, so the
  shared run helpers print Pi paths and take the Pi rules (`b-worker` and worktree steps per
  [ADR-031](../docs/decisions/ADR-031-pi-worker-steps.md), review gate `reviewer` only), and
  run the Node helpers with bare `node`. `PI_SESSION_ID` is the lock owner.
- `extensions/b-agentic/`: the guard (`guard.mjs`) and its Pi entry point (`index.ts`). The guard reuses the Claude Code hook
  modules, so both runtimes judge secret paths, `.b-agentic` writes and shell inspection the same way. It also gates the
  user's `!` shell commands for `.b-agentic` and secret paths, refuses a `subagent` tool launch whose child session cannot
  be gated, injects the run context, and reminds once to verify. It throws, so Pi runs nothing, when the extension API it
  needs is missing. It does not enforce the main session's shell rules: the permission package does, and nothing automated
  proves that package is active, so after an upgrade confirm by hand: ask the model to run `sudo true` with its `bash`
  tool and expect a tool result that reports the permission denial, not a shell error (a `!` or RPC shell command does not
  exercise that package). Slash and RPC launches of a specialist are not covered by the subagent gate (see ADR-030).

- `themes/dracula.json`: vendored byte-for-byte from `dracula/pi-coding-agent` (MIT License) and installed to
  `~/.pi/agent/themes/dracula.json` as a sha256-tracked managed file. `settings.json` sets `"theme": "dracula"` only
  when `"theme"` is absent (existing user themes stay silently untouched; `--uninstall` removes `"theme"` only while
  it still matches the recorded value).

## Packages and subagent config

Settings name these npm packages without versions, in this order: `pi-permission-classifier` (judges the asks of the
permission system, so it loads first), `@gotgenes/pi-permission-system` (the permission rules), `pi-subagents`
(read-only specialists and the `b-reviewer` gate), and `@juicesharp/rpiv-ask-user-question`. The list lives in
[`references/runtimes.yaml`](../references/runtimes.yaml).

The classifier enables itself in neither place, so the installer does both: it adds `permission-judge` to the
`authorizerChain` of the permission config (after your own links) and creates the classifier's `config.json` as `{}` when
that file is absent. It never replaces an existing one, even with `--force`. With `{}`, by the package's documentation,
the session's chat model judges each ask; run `/permission-model` in Pi to choose another judge. Pi takes the
classifier's allow as final, so the model may approve asks that Claude Code puts to you (a push to a named branch, a
pull request, a tool that changes something outside the project). To switch the judge off, remove every link that names
it from the effective `authorizerChain`: `permission-judge` and the legacy alias `classifier`; that holds until the next
install adds the managed link again, and an uninstall removes it for good. A project-level permission config switches
the judge off for that project only when it sets its own `authorizerChain` (an empty array) and the project is trusted,
since Pi ignores a project config until then. If your settings give the permission system or the classifier any version
spec (a pin, a range or a tag), the installer leaves both alone and warns.
Standalone classifier verdicts were not itemized separately in the 2026-11-23 acceptance confirmation (see [ADR-030](../docs/decisions/ADR-030-pi-runtime-rendered-at-install.md)).

The installer also merges default `pi-subagents` settings (`{"inlineToolDisplay": "summary", "asyncWidget": false, "fleetView": false}`, defined in [`references/runtimes.yaml`](../references/runtimes.yaml)) key by key into `~/.pi/agent/extensions/subagent/config.json`:

- User-only keys stay untouched, and differing values for shipped keys stay with a warning naming the key.
- Only keys added or owned by `b-agentic` are recorded in `b-agentic/install.json`; `--uninstall` removes only those
  unchanged owned keys and deletes `extensions/subagent/config.json` when `b-agentic` created it and it becomes `{}`.

## Checks

- `python3 tooling/generate/registry_sync.py --check` renders Pi in memory and fails on a Claude-only token, an over-budget
  kernel or an agent with an editing tool.
- `tests/pi/guard-cases.mjs` runs the guard cases without Pi; `tests/pi/guard-probe.sh` drives real Pi with a scripted
  offline model (`PI_PROBE_REQUIRE=1` turns a skip into a failure; `PI_PROBE_NPM_DIR` points at a folder whose
  `node_modules` hold the packages).
- `tests/install/pi-install-probe.sh` runs under `scripts/validate-skills.sh --release` against a temporary home.
- `PI_PROBE_NPM_DIR=DIR tests/pi/spike.sh` is the manual spike: run it by hand after every Pi or package upgrade, never in CI.
  `PI_SPIKE_CLASSIFIER=1 PI_SPIKE_MODEL=PROVIDER/MODEL` adds the classifier check with a real model; it prints the verdicts
  for a person to judge.

## Maintenance gate

Because Pi and its four npm packages stay unpinned, run `tests/pi/spike.sh` by hand after every Pi or package upgrade
([ADR-032](../docs/decisions/ADR-032-equal-runtimes-three-tier-support.md)). Any failure blocks claiming Pi main-flow
parity until fixed; demoting or removing Pi requires a new ADR. Known limits and accepted Pi safety divergences are
recorded in [ADR-030](../docs/decisions/ADR-030-pi-runtime-rendered-at-install.md#consequences) and
[ADR-032](../docs/decisions/ADR-032-equal-runtimes-three-tier-support.md#consequences).
