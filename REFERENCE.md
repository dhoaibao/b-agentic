# b-agentic operational reference

[Back to the public overview](README.md)

This reference defines b-agentic's equal main-flow runtimes: the default
`./install.sh` runtime Claude Code (with Codex as the primary reviewer and the
read-only `b-reviewer` subagent as fallback;
[ADR-003](docs/decisions/ADR-003-subagent-review-gate.md),
[ADR-007](docs/decisions/ADR-007-codex-first-review-gate.md)) and the
[Pi runtime](#pi-runtime) ([ADR-030](docs/decisions/ADR-030-pi-runtime-rendered-at-install.md),
[ADR-032](docs/decisions/ADR-032-equal-runtimes-three-tier-support.md)). It covers
installation, the permission boundary, the review gate, MCP configuration, and
validation. OpenCode was removed by [ADR-020](docs/decisions/ADR-020-claude-code-only-again.md)
(the last OpenCode tree is commit `f80281b7`; the earlier Pi tree was last in `ba7bc2db` and is replaced, not restored, by
the Pi runtime of [ADR-030](docs/decisions/ADR-030-pi-runtime-rendered-at-install.md)) and Antigravity by
[ADR-027](docs/decisions/ADR-027-antigravity-runtime-removed.md) (last tree at `caf570fd`). An install an earlier
release left under `~/.config/opencode` is never touched: uninstall it from a checkout of
`f80281b7` (`./install.sh --runtime=opencode --uninstall`) or remove the b-agentic entries there by hand.
The same holds for an Antigravity install under `~/.gemini` (manifest `~/.gemini/config/b-agentic/install.json`):
uninstall it from a checkout of `caf570fd` (`./install.sh --runtime=antigravity --uninstall`) or remove the
b-agentic entries there by hand, including the `b-agentic` hook group, because a failing hook blocks every tool.

## Install and lifecycle

```bash
git clone https://github.com/dhoaibao/b-agentic.git && cd b-agentic && ./install.sh
```

`./install.sh` installs from the checkout that contains it. Piped
(`curl -fsSL .../install.sh | bash`), it clones the source to
`~/.b-agentic-claude` first; it never uses `~/.b-agentic`, which may still hold
a frozen earlier installer. Without an explicit `y` on a post-sync interactive
`[y/N]` prompt, the script runs no vendor installers (`-y`, `--dry-run`,
`--uninstall`, `--statusline-only`, and non-terminal runs skip them). A Claude
Code sync touches only `~/.claude` and `~/.claude.json`; approved vendor
installers write their own binaries (outside `~/.claude`), and `rtk init -g
--hook-only --auto-patch` adds RTK's `PreToolUse` hook to
`~/.claude/settings.json`.

- `--dry-run` prints the plan and changes nothing.
- On a terminal the installer shows a step timeline, a summary box, and asks before
  writing. Questions are read from `/dev/tty`, so they work when piped. `-y` /
  `--yes`, `--dry-run`, `--uninstall`, or a non-terminal stdout keep plain output
  and the defaults; `NO_COLOR` disables color. Answering No leaves the
  configuration untouched (`~/.claude` and `~/.claude.json`). A piped run has already
  cloned or updated the source checkout by then, because the summary needs it.
- The kernel's "Peer agent messaging" section applies only when the user asks agents to talk to each other and adds no other rules: `herdr` skill under `HERDR_ENV=1`, otherwise `hc --skill` if `hc` is on `PATH`.
- Optional components (`optional_components` in `skills/registry.yaml`: `datagrip`,
  `tablepro`, `excalidraw`, `drawio`, `notion`) are installed only after a choice. Each is its skill, its kernel routing
  line, its `mcp__<server>__*` permission rules, and its MCP server
  entry (DataGrip's entry stays IDE-managed, so `datagrip` covers only the skill, routing line, and
  rules; `notion` has no skill because no b-agentic skill uses it, so it covers only the server entry
  and its `allow` rules). Deselecting also drops lines marked `<!-- requires: b-x -->` from installed skills, so none points to an absent sibling; a full install keeps them byte for byte. A terminal shows a checkbox list before the summary: nothing is checked on a fresh
  install, and an existing install's recorded choice is pre-checked, so Enter keeps it. `--with=ID[,ID]` and
  `--without=ID[,ID]` (additive, repeatable) answer non-interactively and skip the list. With `-y`,
  `--dry-run`, or no terminal, the choice recorded in the manifest is reused and a fresh install selects
  none. A component with no recorded choice, whether the manifest predates the feature or the component
  was added later (as `notion` was), is treated as selected when the manifest already owns it, so an
  existing install keeps its Notion entry until you pass `--without=notion`.
  Deselecting a component removes only its recorded, unmodified skill, `allow` rules, and server (a modified
  one is kept with a warning); its `ask` and `deny` rules stay, so a server that is still configured keeps its
  prompts and denials. Neither flag combines with `--uninstall`.
- `--statusline-only` installs `b-agentic/bin/b-statusline.mjs` and the `statusLine`
  entry in `settings.json` and nothing else: no skills, agents, hooks, kernel block, permissions, MCP
  servers, or optional components. An existing `statusLine` is kept with a warning, as in a full install.
  The manifest records `"scope": "statusline"`; a plain `--uninstall` removes exactly that, and a later full
  install upgrades it in place (dropping the scope). It is refused over a full install, and cannot combine with
  `--with`, `--without`, or `--uninstall`.
- The status line also adds a compaction hint, only where the project records a b-flow run
  (`.b-agentic/active`). Claude Code's docs name no percentage for compacting by hand; every hint starts at 40% of
  the context window, whatever the token count, and is yellow below 80% and red from 80%. A finished run (`done`)
  or a just-approved run (`approved`) shows `/compact or /clear` or `/compact before implement`, because the run
  state on disk already holds what a compaction would drop. These two hints show only in the session that holds the
  run's lock (the lock owner equals the status line's `session_id`), so a later unrelated conversation does not see
  them; it shows `context high: /compact soon` instead. In any other phase, or a blocked run, the hint says to
  finish the phase, then compact. It is read-only and fixed text; any read error shows nothing. The model cannot run `/compact`, so
  this is a hint for you, not an automatic step. To check whether a change saved tokens, follow
  [Measure token cost](docs/runbooks/measure-token-cost.md).
- Bun is required ([ADR-018](docs/decisions/ADR-018-bun-only-runtime.md)): Claude Code runs the managed hooks
  and status line with `bun --no-env-file --config=/dev/null`, so a repository's `bunfig.toml` preload and
  `.env` never load into a hook. Install, `--dry-run`, and `--statusline-only` refuse without a working Bun
  (nothing is written); `--uninstall` does not need it. The installer writes the absolute Bun path it found
  (symlinks kept), with no Node fallback: if Bun is removed later, a fail-closed guard blocks until you
  reinstall Bun. A re-install swaps only the entries the manifest recorded (plain `node` or the earlier
  bun-or-node form) and never your own hooks; an unrecorded `node` entry for a managed script is kept and
  reported.
  The skills and kernel call five short wrappers in `~/.claude/b-agentic/bin/` instead of the long runtime commands
  ([ADR-028](docs/decisions/ADR-028-short-helper-wrappers.md)): `b-state`, `b-run` (`python3 -I -B`), `b-snapshot`, `b-codex-review`,
  and `b-codex-guard` (the secret preflight). Each is a one-line `sh` script, installed owner-executable, that runs its target with
  the same hardening flags and the absolute Bun path; they are owned by the manifest and removed on uninstall.
  `b-run` and `b-state` print their usage on `help`, `--help` or `-h` (exit 0), a wrong command or argument exits 2 and names the valid ones, a run outside a git worktree exits 3 naming the folder, and the commands they print (`next` lines, refusals, the path guard) are the wrapper paths ([ADR-029](docs/decisions/ADR-029-self-describing-helper-clis.md)).
- `--update` fast-forwards the checkout (`--ref=<tag-branch-or-commit>` checks
  out a ref) and then syncs. A plain run is already idempotent: unchanged
  inputs write nothing.
- `--force` replaces a managed file you modified, or a same-named file b-agentic
  did not install, after a backup. Without it such files are kept with a warning.
- `--uninstall` removes only recorded, unmodified assets and entries and keeps
  `~/.claude/b-agentic/backups`.
- `--runtime=claude` is accepted as a no-op; `--runtime=pi` selects the
  [Pi runtime](#pi-runtime); `--runtime=all` installs, syncs, or (`--uninstall`)
  removes both Claude Code and Pi from a local checkout ([ADR-034](docs/decisions/ADR-034-all-runtimes-install.md));
  any other value is refused with a pointer to ADR-020 and ADR-030 and nothing is written.
- Only `~/.claude` is supported for Claude Code. A different `CLAUDE_CONFIG_DIR`
  is refused because the managed hooks, agents, and instructions refer to that path.

What it manages, all recorded in `~/.claude/b-agentic/install.json`:

| Asset                              | Installed path                                                                       |
| ---------------------------------- | ------------------------------------------------------------------------------------ |
| Skills (also `/b-<name>` commands) | `skills/b-*/SKILL.md`                                                                |
| Specialists                        | `agents/b-*.md`                                                                      |
| Hooks and CLIs                     | `b-agentic/hooks/*.mjs`, `b-agentic/bin/*.mjs`, `b-agentic/bin/*.py`                 |
| Run CLI bytecode, built at install | `b-agentic/bin/__pycache__/b_run_lib.<tag>.pyc`                                      |
| References                         | `b-agentic/references/`                                                              |
| Kernel                             | block between `<!-- b-agentic:start -->` and `<!-- b-agentic:end -->` in `CLAUDE.md` |
| Permissions, hooks, status line    | entries merged into `settings.json`                                                  |
| MCP servers                        | entries merged into `~/.claude.json`                                                 |

The manifest also records the kit version (`kit_seq`, `kit_date`, `kit_commit`,
`kit_dirty`), all four or none; see the kit version paragraph under the run-stats
store ([ADR-036](docs/decisions/ADR-036-run-stats-kit-version.md)).

It plans in memory and refuses before its first write when a user file is
malformed or wrongly shaped, the kernel markers are duplicated or reversed, or a
managed directory is a symlink; backs up each file it changes under
`b-agentic/backups/`; writes through (never replaces) a symlinked config file;
merges rather than replaces user-owned keys, arrays, and hooks; and treats a
file, hook, or server as its own only when a previous run recorded it, so an
identical user-owned copy survives uninstall and a modified kernel block or hook
is kept. Every destination, including backups and the manifest, is validated
before the first write, and an interrupted run is recorded as `pending` so a
retry or `--uninstall` still recognizes both the old and the new state. The
piped bootstrap honors `--dry-run` before cloning or fetching, runs git with its
destination overrides cleared, and refuses a source checkout whose worktree or
git directory is under `~/.pi` or `~/.config/opencode`. Claude Code rewrites `~/.claude.json` while it
runs, so restart it after an install. The installer reports missing tools (`rtk`,
`codegraph`, `bunx`, `claude`, and `codex` for the optional Codex gate), and on
an interactive full install (`--runtime=claude`, not `-y`, `--dry-run`,
`--uninstall`, or `--statusline-only`), offers post-sync `[y/N]` prompts for
missing `claude` (`curl -fsSL https://claude.ai/install.sh | bash`), `rtk`
(`curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh`),
`rtk init -g --hook-only --auto-patch` (when `rtk` is found and `rtk init --show`
does not report its `settings.json` hook), and `codegraph`
(`curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh | sh`).
If `curl` is missing, it warns and skips those prompts; failures warn without
affecting b-agentic's install or exit status. See
[install prerequisites](docs/runbooks/install-prerequisites.md) for the manual
steps (`bun`, `node`, `git`, `codex`, and offline setup). The Codex review gate on Claude Code needs the `codex` CLI, the
`openai/codex-plugin-cc` plugin, and a Codex login, which the installer prints but
never runs; without them `b-review` falls back to the `b-reviewer` subagent, which needs
none of these.

## Pi runtime

Claude Code stays the `./install.sh` default, while Pi (`--runtime=pi`) has
equal first-class parity across every `b-agentic` main flow under the three-tier
feature model ([ADR-030](docs/decisions/ADR-030-pi-runtime-rendered-at-install.md),
[ADR-032](docs/decisions/ADR-032-equal-runtimes-three-tier-support.md); what ships is
described in [pi/README.md](pi/README.md)). Features are classified in
`references/capabilities.yaml` and ADR-032 as `shared` (Tier 1, identical across
both), `adapted` (Tier 2, runtime-specific adapters under shared parity
contracts), or `exclusive` (Tier 3 extras needing no parity: Claude-only Codex
plugin, status line, `NotebookEdit`, and piped self-update; Pi-only Dracula
theme, subagent config, classifier, and `/b-*` prompt templates):

```bash
./install.sh --runtime=pi [--dry-run] [--force] [-y] [--with=ID[,ID]] [--without=ID[,ID]]
./install.sh --runtime=pi --uninstall
./install.sh --runtime=all [--dry-run] [--force] [-y] [--with=ID[,ID]] [--without=ID[,ID]]
./install.sh --runtime=all --uninstall
```

- Under `--runtime=all`, both runtimes are constructed, preflighted, and planned
  before either writes or removes anything; a refusal in either aborts with both
  roots unchanged ([ADR-034](docs/decisions/ADR-034-all-runtimes-install.md)).
  On a terminal without `-y`, `--dry-run`, or `--uninstall`, it shows a
  runtime-labeled optional-component checklist per runtime, both summary boxes,
  one `Proceed with installation?` confirm, and deduplicated post-sync `[y/N]`
  vendor prompts (`claude`, `pi`, `rtk`, `codegraph`, plus the RTK Claude Code
  hook). It applies the `--runtime=pi` flag restrictions (local checkout only;
  no `--statusline-only`, `--update`, `--ref`, or piped clone), keeps separate
  manifests per runtime, and exits `0` on `--uninstall` even when only one (or
  neither) runtime has a manifest.

- On a terminal without `-y`, `--dry-run`, or `--uninstall`, the installer shows
  the step timeline, optional-component checklist (when neither `--with` nor
  `--without` is given), summary box, and `Proceed with installation?` confirm
  (declining leaves `~/.pi/agent` untouched); `-y`, `--dry-run`, `--uninstall`,
  or a non-terminal stdout keep plain output.

- You install Pi (`@earendil-works/pi-coding-agent`, 1.6.0 or newer, spiked on
  1.6.0) yourself or accept the post-sync `[y/N]` prompt to run its native `curl`
  installer (`curl -fsSL https://pi.dev/install.sh | sh`). Nothing is pinned: not
  Pi, not the four npm packages named in `settings.json`
  (`references/runtimes.yaml` lists them). The installer never installs npm
  packages itself and runs `pi --version` before syncing to warn below the
  floor; Pi installs its four packages on its next start. On an interactive
  terminal (skipped under `-y`, `--dry-run`, `--uninstall`, non-terminal stdout,
  or no `/dev/tty`), after syncing `~/.pi/agent` it also offers `[y/N]` prompts
  for missing `pi` (`curl -fsSL https://pi.dev/install.sh | sh`), `rtk`
  (`curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh`),
  and `codegraph`
  (`curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh | sh`),
  never `rtk init` (approved vendor scripts write outside `~/.pi/agent`); if
  `curl` is missing, it warns and skips.
- It installs only from a local checkout. `--update`, `--ref`, a clone or piped
  install, and `--statusline-only` are refused, as is a `PI_CODING_AGENT_DIR` other
  than `~/.pi/agent` and a `CLAUDE.md` in the agent directory (Pi reads one
  context file per folder). `~/.claude` and `~/.claude.json` are never touched.
- The Pi tree (kernel, skills, prompt templates, agents, permission and MCP
  configuration) is rendered at install time by
  `registry_sync.py --render pi` into a fresh folder outside the checkout and is
  never committed. Hand-written parts live in `pi/` (wrappers and the guard
  extension).
- Installed under `~/.pi/agent`: `skills/`, `prompts/`, `agents/`, `themes/`
  (`themes/dracula.json`, vendored from `dracula/pi-coding-agent`, MIT),
  `extensions/b-agentic/`, and `b-agentic/{bin,hooks,references}`; the manifest
  `b-agentic/install.json` (which also records Pi's own `kit_seq`, `kit_date`,
  `kit_commit`, and `kit_dirty`, all four or none,
  [ADR-036](docs/decisions/ADR-036-run-stats-kit-version.md)); and entries merged into `AGENTS.md` (kernel block),
  `settings.json`, `mcp.json`, `extensions/subagent/config.json`, and
  `extensions/pi-permission-system/config.json`
  (including `authorizerChain: ["permission-judge"]`, added after your own links;
  an earlier install's owned `yoloMode` is removed because the permission system
  no longer reads it, and auto-approve is set per session);
  in `settings.json`, `"theme": "dracula"` is set only when `"theme"` is absent
  (an existing user `"theme"` is preserved silently, and `--uninstall` removes it
  only while it still equals the owned value); in
  `extensions/subagent/config.json`, `inlineToolDisplay: "summary"`,
  `asyncWidget: false`, and `fleetView: false` are merged key by key with
  manifest ownership (user-only keys stay, differing user values stay with a
  warning, and `--uninstall` removes only unchanged owned keys, deleting the
  file when `b-agentic` created it and it becomes `{}`);
  `extensions/pi-permission-classifier/config.json` is created as `{}` only when
  it is absent, never replaced (not even with `--force`) and removed on uninstall
  only while it is still that `{}`. The classifier judges an ask only when both
  exist; `/permission-model` in Pi chooses its judge. With the classifier active,
  Pi takes its allow as final, so the model may approve asks that Claude Code's
  native prompts gate (a push to a named branch, a pull request, or an asked
  MCP/shell call; outside-project mutations rely on kernel approval on both
  runtimes). To switch the judge off, remove every link that
  names it from the effective chain: `permission-judge` and the legacy alias
  `classifier`; that holds until the next install adds the managed link again,
  and an uninstall removes it for good. A project-level permission config
  replaces the chain only when it sets its own `authorizerChain` (an empty array
  switches the judge off for that project), and Pi ignores a project config until
  the project is trusted. The installer leaves the chain and the classifier
  config alone, with a warning, when your settings give the permission system or
  the classifier any version spec (a pin, a range or a tag), and refuses an
  `authorizerChain` that is not an array of strings or would pass 1000 entries.
  Standalone classifier verdicts were not itemized separately in the 2026-11-23 acceptance confirmation (see ADR-030).
  Ownership, backups, `--force`, `--dry-run`, `pending` recovery, and
  `--uninstall` follow the same rules as the Claude Code installer. A config file
  there that is a symlink is written through to its target, even outside
  `~/.pi/agent`; a link into the agent directory, Pi's own state files, `~/.claude`,
  `~/.claude.json` or `~/.config/opencode`, and a symlinked managed directory, are
  refused. A symlinked `~/.pi/agent` itself is followed, so the whole install
  lands at its target; the installer's own wording that only `~/.pi/agent` is
  written means that path as named, not where it resolves.
- A user catch-all `*` permission rule that differs from the shipped one for its
  section sets a floor: managed rules looser than it are not installed, with a
  warning. A catch-all equal to the shipped one sets no floor, so the managed
  per-tool rules (including the allows for managed MCP servers) install as
  shipped. The main session's shell rules are enforced by the permission package,
  not by the guard extension, and no automated check proves that package is
  active: after an upgrade, confirm by hand: ask the model to run `sudo true`
  with its `bash` tool and expect a tool result that reports the permission
  denial, not a shell error (a `!` or RPC shell command does not exercise that
  package). The guard refuses only `subagent` tool launches whose child
  session cannot be gated; slash and RPC launches are not covered (see ADR-030).
- The Pi review gate is the read-only `b-reviewer` subagent (`adapted` Tier 2);
  `b-worker` and parallel worktree steps are supported via `subagent`
  ([ADR-031](docs/decisions/ADR-031-pi-worker-steps.md)). Claude-only and
  Pi-only extras (`b-statusline`, `NotebookEdit`, Codex gate on Claude;
  `dracula` theme and classifier config on Pi) stay `exclusive` Tier 3 extras
  with no parity requirement ([ADR-032](docs/decisions/ADR-032-equal-runtimes-three-tier-support.md)).
- Known limits are in ADR-030's and ADR-032's Consequences. Under the
  maintenance gate in ADR-032, re-run `tests/pi/spike.sh` after any Pi or
  package upgrade; any breakage blocks claiming Pi main-flow parity until fixed,
  and demoting or removing Pi requires a new ADR.

## Kernel and skills

Claude Code loads `~/.claude/CLAUDE.md` and discovers `skills/b-*/SKILL.md`.
The main session reads one skill before acting or invokes `/b-<name>`.
`skills/registry.yaml` and `skills/*/prompt.md` are canonical;
`tooling/generate/registry_sync.py` generates `SKILL.md`, `claude/agents/*.md`,
the kernel's generated blocks, and `claude/configs/settings.template.json`.
Explicit-request skills (`b-commit`, `b-pr`) route only on explicit
user request and stay model-invocable. `b-flow` is the routing entry
(`routing.entry`): changes that route to an implement-phase skill run inside it.

The five specialists are `b-planner`, `b-researcher`, `b-debugger`, `b-auditor`
(serving both `b-agentic-audit` and `b-audit`), and `b-reviewer`. A sixth profile, `b-worker`, is the one writer child of a `b-flow`
run ([ADR-015](docs/decisions/ADR-015-step-writer-worker.md); also rendered on Pi per [ADR-031](docs/decisions/ADR-031-pi-worker-steps.md)),
generated from the registry's separate `workers` map, with edit, write, and bash
on top of the specialists' reads, no prompt, delegation, or notebook tool, and the
instruction to apply exactly one approved plan step in place, touch nothing outside the
scope, the run folder, secrets, or git history, and report. The main session waits for
it and edits nothing; the step gate then checks the result. A plan hands it a step
through `worker_steps`, and two such steps may run at the same time, each in its own
git worktree, through `parallel_steps`
([ADR-016](docs/decisions/ADR-016-parallel-worker-steps.md)). The specialists' tool lists omit `Edit`, `Write`, `NotebookEdit`, and nested
delegation and carry only the read-only MCP tools their skill uses, listed per agent in
`mcp_tools` ([ADR-023](docs/decisions/ADR-023-per-agent-mcp-tool-scope.md); plus three
bounded Firecrawl tools for `b-researcher`). Read-only behavior is instructed, not enforced by a
child-specific permission block: shell access can still mutate state. Delegated
skills never run in the main session; the generated `Delegation boundary` and
the kernel carry this, so a missing subagent is reported instead of bypassed. A
child result is evidence, not authorization. Claude Code models are Anthropic
aliases from the registry's `model` field, with an optional `effort` field
(`low`–`max`) rendered as subagent frontmatter; current Claude Code defaults are
`fable`/`high` for `b-auditor`, `opus`/`high` for `b-planner`, `b-reviewer`, and
`b-debugger`, and `sonnet`/`medium` for `b-researcher` and `b-worker`. The
2026-11-17 retune moved
`b-debugger` from `sonnet`/`xhigh` and `b-auditor` from `fable`/`high` to
`opus`/`high` (Artificial Analysis scores Opus 5.5 `high` at 52 for about $3.46 per
task against $9.08 for Fable 5.2 `high`; Vals Index scores the two within about
1.2 points; Anthropic says to start on Opus 5.5 and move to Fable only when
evals at higher effort fall short, and Fable carries cyber classifiers that can
block a security audit) and `b-worker` from `high` to `medium`
(Anthropic starts Sonnet 5.5 at `medium` for well-specified agentic coding). That
was a literature-based choice, not a replay on this repository: move
`b-debugger` or `b-auditor` to Fable only where Opus misses in practice. On
2026-11-23, `b-auditor` was moved back to `fable`/`high` by user choice. The
`high` choice for the planner and reviewer follows Anthropic's guidance to reserve
`xhigh` for work with a measured quality gain. One vendor code-review benchmark
(Qodo, 2026-10; a later search could not locate it, see ADR-003) reported Opus 5.5 at `high` above `xhigh` on F1
(`xhigh` had the highest recall on hard bugs but lower precision), and Artificial
Analysis puts `high` at about half the per-task cost of `xhigh` for a small
index drop. None of this was replayed on this repository's own reviews, so
revisit it with measured time, tokens, and blocker counts ([ADR-003](docs/decisions/ADR-003-subagent-review-gate.md)).
On Claude Code the registry values are defaults: a per-call `model` or `effort` on
the agent call overrides them, `CLAUDE_CODE_EFFORT_LEVEL` overrides the effort, and
`CLAUDE_CODE_SUBAGENT_MODEL` overrides the model only together with
`CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1`.

## Review gate

On Claude Code, `b-review` runs Codex first, as the independent reviewer,
through the [`openai/codex-plugin-cc`](https://github.com/openai/codex-plugin-cc)
plugin, which you install yourself:

```text
/plugin marketplace add openai/codex-plugin-cc
/plugin install codex@openai-codex
/codex:setup
```

Then sign in to Codex and keep the plugin's review gate (a Stop hook) disabled.
When Codex is unavailable, `b-review` falls back to the read-only `b-reviewer`
subagent ([ADR-007](docs/decisions/ADR-007-codex-first-review-gate.md),
[ADR-003](docs/decisions/ADR-003-subagent-review-gate.md)).

### Codex gate (Claude Code)

The gate sequence is:

0. Probe the plugin: `~/.claude/b-agentic/bin/b-codex-review --available`
   only looks for the plugin script and runs nothing: exit 0 means found, exit 4
   (`status: unavailable`) means Codex cannot run, so main skips steps 2 and 3
   and goes straight to the `b-reviewer` fallback. Exit 2 means a broken `B_AGENTIC_CODEX_COMPANION` override and is
   reported as a refusal. The probe cannot tell whether you are signed in or have
   quota left; those failures still surface as exit 4 from the real run at step 3.
1. Freeze the candidate: `~/.claude/b-agentic/bin/b-snapshot`
   gives HEAD, SHA-256 digests of the staged and unstaged binary diffs, sorted
   untracked paths with type and content digest, and one `fingerprint` (F0). It
   covers the whole repository, lists protected paths and submodules without
   hashing or diffing them, excludes git-ignored files unless named with
   `--include-ignored`, and refuses when a repository clean/process filter would
   run or the repository is a partial clone. A tracked file that git is told to
   skip (`assume-unchanged`, or `skip-worktree` while the file exists on disk)
   is listed in `index_flags` and makes the snapshot incomplete, because both
   diffs would omit its edits; the index is never modified. Exit 0 is complete,
   3 incomplete, 2 refused.
2. Early preflight: `~/.claude/b-agentic/bin/b-codex-guard --check
[--base <ref>]` refuses when a likely-secret path is tracked, staged, or
   untracked-and-not-ignored, when a submodule or embedded repository hides
   paths, when an untracked non-ignored symlink exists (the plugin follows it
   and would send its target; stage, ignore, or remove it), when a `--base` range
   (merge-base..HEAD and every commit inside it) touches a likely-secret path
   or a submodule. There is no per-repository approval
   ([ADR-021](docs/decisions/ADR-021-codex-gate-without-repo-approval.md)): a
   repository that passes these checks goes to Codex (OpenAI) without a question,
   as it goes to Claude. `--approve` and `--revoke` no longer exist, and the
   `codex-approved-repos.json` file an older install wrote is no longer read.
3. Run the gate with the wrapper, from the repository, with nothing editing:
   `~/.claude/b-agentic/bin/b-codex-review --scope working-tree --round
<n> --focus-file <path>` (or `--base <ref>` instead of `--scope working-tree`
   for committed changes since that ref; `--include-ignored <path>` as at step
   1; `--kind native` is refused because its output has no verdict contract).
   The wrapper reruns the secret gate, resolves a `--base` once and
   gives the plugin that commit id, so a ref that moves during the run cannot
   change the reviewed range, freezes the candidate (`f0`), finds the
   plugin's `codex-companion.mjs` under `~/.claude/plugins` (or
   `B_AGENTIC_CODEX_COMPANION`), runs the review in the foreground with an
   argument vector, freezes again (`f1`), and maps the result. It prints JSON:
   `f0`, `f1`, `unchanged`, `base` (`ref`, `oid`, `merge_base`; null for a
   working-tree review), `timed_out`, `truncated`, the raw plugin output, and
   `mapped`. Exit 0 is a completed review. Exit 3 is a void one: the candidate
   changed or could not be re-snapshotted, the run hit `--timeout-minutes` (30 by
   default, at most 35791; stopped with SIGTERM, then SIGKILL after
   `--kill-grace-seconds`, and its pipes closed by the wrapper if a descendant
   still holds them) or
   the 8 MB output cap, or the result was unmappable or finding-less. Exit 2 is a
   refusal or failure, including an incomplete snapshot before the plugin runs.
   Exit 4 means Codex is unavailable: the plugin script was not found, or the
   plugin exited non-zero (signed out, over its usage limit, crashed); the JSON
   then carries `status: "unavailable"` and `unavailable_reason`. A run that was
   cut short is never mapped, whatever status it exited with. Claude Code kills
   a foreground Bash command after at most 10 minutes, so main launches the
   wrapper as a background command (`run_in_background`) and waits for its
   completion notification, editing nothing; the wrapper's own timeout then
   decides a long run.
4. Main checks that `f0` equals the step-1 fingerprint and `unchanged` is true,
   and recomputes the fingerprint itself; a difference voids the review.
5. `mapped` carries finding IDs `R<round>-<n>` and a provisional verdict (the
   same mapping `b-codex-verdict.mjs` applies to saved output). Main classifies
   against the blocker taxonomy and owns the final `Verdict:` line.

The `b-codex-guard` PreToolUse hook is a tripwire for accidental direct calls to
the plugin script, not the boundary: it applies the same checks to plain
spellings and refuses background, implicit-target, or ambiguously spelled
reviews (repeated `--base`/`--scope`/`--wait`, single-dash options, `--`, since
the plugin keeps the last repeat; and any option other than `--wait`, `--scope`,
and `--base`, since a value option such as `--model` can swallow the target
option), but deliberately
obfuscated spellings (ANSI-C quoting, brace or glob expansion, names built at run
time) are out of scope.

Codex's read-only sandbox can read every workspace file and Codex has no ignore
mechanism, so ignored secret files remain an accepted residual risk, as do
secrets that exist only in history outside the reviewed range and secrets copied
under innocent names (the scan reads path names, not content). Plugin command
syntax and result shape come from its documentation and are not exercised live by
this repository's checks.

### Fallback: the `b-reviewer` subagent

Only these cases reach `b-reviewer`: the wrapper exits 4 (Codex unavailable; main
tells you in one line and continues with the same baseline, round, and F0), or you
choose it after a refused (exit 2) or void (exit 3) Codex run. A refusal or void run never falls back on
its own, because that would route around the protection that stopped it. If
`b-reviewer` is also unavailable, fails, or returns no verdict, main reports the
gap and asks; a self-review never substitutes. The sequence is:

1. Freeze the candidate as F0 (as above).
2. Handoff: main calls the `Agent` tool with `subagent_type: b-reviewer` and
   passes the baseline (branch, HEAD, ahead/behind, status), the review target
   (the working tree, or a base ref resolved to a commit id so it cannot move
   during the run), the acceptance criteria, the fresh check results, the kernel
   risk triggers that apply, the exact candidate paths, F0, and every relevant
   ignored/derived path for `--include-ignored`. A re-review also carries prior
   finding IDs, dispositions, correction paths, and the sibling-sweep scope and
   regression-check results. Main does not pass the implementer's rationale or a
   verdict to confirm, and does not edit while the review runs. The reviewer
   never reads likely-secret files and reports them as a coverage gap.
3. The reviewer recomputes the snapshot with the same options and compares only
   the `fingerprint` with F0, inspects the diff with read-only commands,
   classifies findings against the blocker taxonomy with IDs `R<round>-<n>`,
   sweeps each blocker's defect class, recomputes the snapshot as F1, and ends
   with exactly one `Verdict:` line. A missing CLI, `complete: false`, or a
   mismatch blocks with no verdict; there is no hand-computed fallback.
4. Main recomputes the fingerprint itself after the reviewer returns; a
   difference from F0 or from the reviewer's F1 voids the review. Main verifies
   each blocker with `Read` and `Grep` before acting, fixes blockers as a batch
   (whole defect class each), and stops to ask the user after 3 consecutive
   `NEEDS FIXES` rounds. From round 2, before fixing a blocker that shares a root
   cause with a fixed one, main states whether to patch or change the design,
   continuing on a patch and asking before a design change. At the 3-round stop it
   first groups those rounds' blockers by root cause, names the recurring groups,
   and offers a design change, a narrower scope, a deferral with a recorded known
   limit, or more patching. A deferral pauses delivery: the finding stays a
   blocker until a fix, a user-approved scope change that removes it, or evidence
   that it no longer blocks. Both rules are prompt guidance, apply to either gate
   on both runtimes, and no helper enforces them; the design question writes no
   run state, so a resumed session relies on stating the judgment again.
   For every fixed blocker, main also states the invariant it violated, lists the
   ways it can be broken (looking at least for another input or environment form,
   another entry or exit path, state changing midway, and old data or
   configuration), and checks each, beside the search for similar code sites; a
   simple blocker may list one or two. A `b-flow` run keeps the invariant in the
   follow-up's `reason` line and the ways in its `sweep` line (300 characters
   each), and its `fix` phase passes the related checks before `write followups`.
   A re-review checks each list for a missing way, which is a blocker only with
   evidence and within the blocker classes and the limit on new blockers in
   already-reviewed code. When the prior review lists a fixed blocker, the
   `b-run handoff review` packet prints that request, since Codex reads only the
   focus text; a focus written by hand needs it added. This too is prompt
   guidance: no helper checks a list, and whether the rule reduces recurring
   blockers is unproven.

In a `b-flow` run the verdict is recorded with `record review --gate codex|reviewer`;
a `reviewer` gate also records why Codex was not used (`--gate-reason`, for example
the wrapper's exit 4). The gate shows in the run state, its history, and the QA
packet (`Review gate:`), and runs recorded before this existed read `not recorded`.

Trade-offs of the fallback:

- The reviewer may share the main session's model family, so some blind spots
  can correlate; the independence comes from a fresh context, a separate review
  prompt, and a read-only role. Nothing is sent to another vendor.
- Read-only is instructed, not sandboxed: the tool list omits
  `Edit`, `Write`, `NotebookEdit`, and nested delegation, but shell access can
  still mutate state.
  The fingerprint recomputation catches any change to tracked or named files,
  but not a change to an ignored or outside-repository file that was never named.
- Review never commits or pushes.

## Permission boundary

`claude/configs/settings.template.json` is generated from
`references/mcp_operations.yaml`. It allows repository-local tools and named
read-only, conditional-read, and trusted-mutation MCP tools, asks before private-data reads, other classified mutations, uploads, lifecycle, and
auth tools, asks before a `git push` that names its remote and branch and before `gh` commands that change reversible
GitHub state (`gh pr create`/`close`/`edit`, `gh auth switch`, `gh release create`/`upload`/`edit`,
`gh repo create`/`fork`, `gh issue close`/`edit`, `gh workflow run`, and `gh api` with a body or method
flag such as `-f` or `-X`), and denies the
named dangerous commands (`git pull`, `git reset --hard`, `git clean -f`,
`git branch -D`, `rm -rf`, `sudo`, `doas`, `docker system prune`, bare shells,
`bash -s`/`sh -s`, destructive, credential, or code-installing `gh` commands (`gh pr merge`,
`gh repo delete`/`archive`/`rename`/`edit`, `gh release delete`, `gh extension install`,
`gh alias set`, `gh secret`/`ssh-key`/`gpg-key` changes, `gh auth login`/`logout`/`token`/`refresh`,
`gh auth status --show-token`, and `gh api` with `-X` or `--method` `DELETE`, `PUT`, or `PATCH`), and force, delete, mirror,
all/branches, prune, `main` or `master`, and destination-less (`git push`, `git push origin`) pushes, each also under an `rtk` prefix where
relevant) and unambiguous secret files. Global-option forms such as `git -C <dir> push`
(which also asks for `git stash push`) and combined short flags such as `-uf`
are asked about but not pattern-denied, except `git -c <key=value> push` (the form
`b-pr` uses over HTTPS), whose force and `main` or `master` pushes are denied; `:branch` delete refspecs and default
branches not named `main` or `master` also stay at the ask prompt. The
`git reset --hard`, `git clean -f`, `git branch -D`, and `rm -rf` denies also cover option placement and
combined flags (`git reset -q --hard`, `git clean -fd`/`-xdf`/`-d -f`, `git branch --delete --force`,
`rm -fr`/`-Rf`/`-r -f`/`--recursive --force`), while `git clean -n`, `git reset --soft`, `git branch -d`,
`rm -r`, and `rm -f` stay allowed. Not pattern-denied, so only the kernel's prose rule stops them: global-option
forms (`git -C <dir> clean -fd`), flag clusters outside the generated list (`rm -Irf`), wrappers (`command rm`,
`/bin/rm`, `xargs rm -rf`, `bash -c '…'`), and other destructive commands (`git checkout -- .`,
`git restore`, `find -delete`). The
`b-path-guard` hook applies the exact path rules to the file tools (including the
`*.env.example` allowance that deny rules cannot express). Hooks:
`b-path-guard` runs before file tools; `b-codex-guard` is a tripwire on Bash for direct calls to the Codex plugin (see [Review gate](#review-gate)); `b-alexandria-guard` runs before `firecrawl_scrape`, which is auto-allowed by name but whose `alexandria` argument runs the billed provider lookups that `alexandria_library_read`, `people_company_search`, and `people_company_enrich` keep behind a prompt. Permission rules cannot match an argument, so the hook answers `ask` when that argument is present, stays silent otherwise, prints a fixed reason that never echoes the input, and fails closed (`onFailure: block`; input it cannot parse asks). Whether the prompt also reaches a subagent such as `b-researcher` is not exercised live; `b-verify-gate` tracks
edits and, when the main session edited a non-prose file after its last non-inspection shell
command, blocks the first stop once with the verify and review reminder (which also asks the agent to map each confirmed `AC-n` criterion to its check result or a stated gap).
`B_AGENTIC_GATE_MODE=observe` logs what it would have blocked without blocking, `off` disables it, and anything else (the default) enforces; decisions append to
`~/.claude/b-agentic/verify-gate/events.jsonl` (256 KiB cap, no commands or file content; `jq -r .event events.jsonl | sort | uniq -c` counts them, deleting the file resets it). [Review eval](docs/runbooks/review-eval.md) describes how to score reviewer rounds against the cases in `tests/behavior/review-eval.json`.
`b-spec-context` is a `SessionStart` hook matched on `compact` only: after compaction it lists, as plain facts, the paths of up to five `docs/specs/*.md`
files whose first 40 lines carry a `Status: approved` line, newest first, in at most 2,000 characters. It injects no file content, never writes, skips symlinks,
likely-secret names, and unusual file names, sets no `onFailure`, and prints nothing (exit 0) when `docs/specs/` is absent, no spec is approved, or anything fails.
Claude Code also fires it when a subagent compacts and sends no `agent_id` to tell the two apart; this is accepted because the output is a short pointer.
Whether the pointer reaches the model after a live `/compact` is not covered by the offline probe (Claude Code issue #15174 reported it missing), so confirm it by hand.
`b-run-context` is a second `SessionStart` hook, matched on `startup|resume|clear|compact`: when `.b-agentic/active` names a run whose `state.json` is not finished, it prints one line with the run id and phase. It is a pointer only (an explicit `/b-flow resume` is the only way a run continues), reads with `O_NOFOLLOW`, never writes, sets no `onFailure`, and prints nothing on any error. Claude Code drops `SessionStart` context intermittently for `startup` and `fork` sources (issues #10373 and #93458), so the pointer is best effort; the run files are the record.
The file-tool
guard sets `onFailure: "block"` (Claude Code 2.1.295 or later), so a guard that crashes, times out, or
cannot start blocks the call, and malformed input still fails open by design. To recover from a
guard that fails closed (for example a missing `bun` or hook script), repair or reinstall: Bash is
not fail-closed and still works. The Bash Codex tripwire deliberately sets no `onFailure`: it runs
on every Bash call, so a broken copy that blocked Bash would also block its own repair; the
wrapper, not the hook, is the boundary. Older Claude Code versions' handling of the unknown key is undocumented.
Managed Claude Code rules allow `Edit`, `Write`, and `Bash` without a path scope, so
they do not prompt for outside-project writes; any native prompt comes from Claude
Code's built-in protected-path checks, your permission mode, or your own settings, and the kernel requires approval for outside-project mutations even
without one. These rules are not a process or filesystem sandbox; shell indirection and MCP
arguments they cannot see remain residual risks. Native Linux and macOS Claude Code builds run `Grep`
and `Glob` searches through Bash, so `b-path-guard` sees no searches there. Claude Code's
own opt-in sandbox (`/sandbox`, the `sandbox.enabled` setting, off by default) is the
process and filesystem layer these rules do not provide, and its `sandbox.filesystem.denyRead`
setting can cover secret paths that Bash-backed searches skip. With the default
`autoAllowBashIfSandboxed`, deny rules and content-scoped asks still apply. b-agentic neither
installs nor verifies the sandbox, and whether it leaves the Codex review gate and the Bun
hooks working is unverified: after enabling it, run
`~/.claude/b-agentic/bin/b-codex-review --available` and one review round. The
kernel additionally
requires approval for other destructive, privileged, ambiguous, protected, or
external/shared actions.

## MCP and readiness

`claude/configs/mcp.base.json` configures CodeGraph, Context7, Brave Search,
Firecrawl, Playwright, shadcn, and the optional Notion, TablePro, Excalidraw, and
draw.io entries (installed only when selected, see the install options). Tools are addressed as
`mcp__<server>__<tool>`. Credentials are `${VAR}` references; the installer
collects none.

| MCP          | Local prerequisite                                                   |
| ------------ | -------------------------------------------------------------------- |
| CodeGraph    | `codegraph` and an index for graph questions                         |
| Context7     | `CONTEXT7_API_KEY`                                                   |
| Brave Search | `bunx`, `BRAVE_API_KEY`                                              |
| Firecrawl    | `bunx`, `FIRECRAWL_API_KEY`                                          |
| Playwright   | `bunx` (isolated/headless testing)                                   |
| Notion       | approved OAuth when Notion content is requested                      |
| Excalidraw   | approved `create_view` calls, MCP UI viewer                          |
| draw.io      | `bunx`, approved `open_drawio_*` calls, default browser (optional)   |
| shadcn       | `bunx`, project `components.json`                                    |
| DataGrip     | IDE-managed: DataGrip with MCP Server enabled; no b-agentic template |
| TablePro     | TablePro running with MCP enabled; `TABLEPRO_MCP_TOKEN`              |

Notion is the official hosted server and reaches the user's whole private
workspace, so workspace reads are `conditional-read` (allowed in the main session,
never granted to the specialists), calendar and contact reads are `private-read`
and ask, and every write asks. Excalidraw's
`create_view` and draw.io's `open_drawio_*` ask on every call and send diagram
text to a hosted endpoint or open the draw.io web editor. draw.io runs
`bunx @drawio/mcp` with `DRAWIO_ICON_SERVICE_URL=off`; the version is not pinned,
like the other `bunx` servers, and the package and its dependencies run unsandboxed
with your permissions.
`list_pages` and `get_page` are `private-read` and always ask: they read any
`.drawio` or `.xml` path with no directory confinement.

DataGrip's built-in MCP server is enabled in the IDE (Settings | Tools | MCP
Server, then Auto-Configure for Claude Code), so b-agentic ships only its
permission rules. Schema metadata tools are `conditional-read`; tools that
return rows or query history are `private-read` and ask; `execute_sql_query`,
`cancel_sql_query`, and connection create or edit ask. The `b-datagrip` skill
runs in the main session, keeps SQL read-only and row-limited by default,
confirms before a first read on a non-local connection, and asks before any
write. The server enforces no read-only mode, so use a read-only database user
for sensitive connections; other `mcp__datagrip__*` tools stay unclassified and
keep the approval prompt.

TablePro's MCP server is served by the application on loopback, so the optional
`tablepro` component ships an `http://127.0.0.1:23508/mcp` entry whose
`Authorization` header only references `TABLEPRO_MCP_TOKEN`. An entry you already
have that differs is kept with a warning. Whether Pi expands that reference in a
header has not been checked live. Connection, database, schema, table, and DDL
metadata tools are `conditional-read`; `connect`, `browse_table`, `count_rows`,
`export_data`, and every `execute_query` call ask, because a permission rule
cannot see the `read_only` argument. The `b-tablepro` skill runs in the main
session, keeps SQL read-only and row-limited by default, confirms before the first
read of each target on a non-local connection, asks before any write, and never
retries a refusal. Row reads, exports, and SQL stay on the connection's own database; another
database is used for structure only. It also asks the user itself before `connect`
and before every export,
each confirmation of a read, export, or write naming the connection, database,
and schema it covers, because on Pi an active permission classifier may resolve an `ask` rule without a
prompt (see the Pi limits in
[ADR-032](docs/decisions/ADR-032-equal-runtimes-three-tier-support.md)); other row
reads on a local connection have no such question. TablePro's External Clients
level, Safe Mode, and write approval are further gates, so use a least-privilege
database user for sensitive connections.

`scripts/mcp-doctor.sh --allow-degraded` reports local launcher, configuration,
and environment-variable presence only. It requires every variable the configured
entry references as `${NAME}` without a default, and no other. It never reads credential values, starts
servers, authenticates, or navigates a browser. Configured does not mean
connected or usable. `scripts/skill-doctor.sh` checks the installed skill and
specialist payload and the kernel block. RTK remains a prerequisite for
supported shell command families; CodeGraph is the first stop for code-structure,
call-flow, and pre-edit impact questions in an indexed project, and agents never
run its init, index, sync, daemon, or install commands.

## Verification and repository map

```bash
python3 tooling/generate/registry_sync.py --self-test --check
scripts/validate-skills.sh --release
scripts/b-agentic-audit.sh
bun run quality
rtk git diff --check
```

Plain `scripts/validate-skills.sh` runs the generator self-test and check, the
policy and routing checks, the hook probe
(`tests/hooks/hooks-probe.sh`), the snapshot CLI probe
(`tests/snapshot/cli-probe.sh`), the status line probe
(`tests/statusline/statusline-probe.sh`; the hook and status line probes also run under `bun` when it is installed), and the runtime instruction parity check
(`tooling/validate/runtime_parity.py`).
The Pi guard cases (`tests/pi/guard-cases.mjs`) run in the same pass, and `tests/pi/guard-probe.sh` drives real Pi when it is installed (it prints a skip line otherwise).
`--release` (CI) adds the sandbox installer probes (`tests/install/claude-install-probe.sh` and `tests/install/pi-install-probe.sh`) and the RTK readiness check.
`tests/pi/spike.sh` is the manual check after a Pi or package upgrade and never runs in CI.
None needs Claude Code, credentials, or a network.

`skills/` and `references/` hold canonical workflow guidance; `claude/` holds
generated specialists and settings plus the hooks, CLIs, and MCP templates;
`tooling/generate/`, `tooling/install/`, and `tooling/validate/` own
generation, lifecycle, and static checks; `tests/` covers behavior, hooks,
snapshots, and the installer. See the [ADR-001 design record](docs/decisions/ADR-001-b-agentic-design-record.md).

## `b-flow` runs

A change that would route to `b-implement`, `b-frontend`, `b-refactor`, or `b-test` enters a `b-flow` run, and `/b-flow <goal>` starts one explicitly ([ADR-012](docs/decisions/ADR-012-run-first-entry.md)); a large, greenfield, or still-open request is discussed first, with no run and no `b-planner` call, until the user's explicit go, and an oversized one is offered a scaffold-first split ([ADR-022](docs/decisions/ADR-022-discussion-first-entry.md)); a `/b-<name>` the user types runs that skill standalone, and questions, lookups, and utilities start no run. A **quick** run (`size: quick` in the spec) takes the request as its approval and never commits; `b-state.mjs approve --size quick` refuses one over the quick limits (3 plan steps, 3 criteria with automated or inspection evidence, 5 literal scope paths, no answers, no `parallel_checks`, `worker_steps`, or `parallel_steps`, consent `commit: no`), and a review trigger blocks it until the user approves a full run (`unblock clarify` is its only way on). A review trigger a run has met stays its obligation through every later approval: it cannot be approved as quick again or record a low-risk exception. The run size, like the consent, is compared with the approved spec at every step. A run without commit consent ends with `advance done` from `qa`, and may start on a tree that already has changes: `init` records those paths by a digest of content and executable bit (never following a symbolic link above a path), and while a path keeps that identity the scope check ignores it; a recorded path the run changes, deletes, or reverts is checked like any other. `init` refuses while another run is unfinished (`--replace` on the user's answer) and holds a worktree mutex while it checks. A **full** run takes one request from clarified spec to commit in the main session ([ADR-009](docs/decisions/ADR-009-b-flow-automatic-run.md)). Clarification and one approval round (spec and `AC-n`, commit consent, branch target, Codex or `b-reviewer`; the consent is recorded in `spec.md` and `approve` must repeat it, on a clean working tree when it may commit) are the only user interaction; then it implements, verifies, reviews, fixes in-scope blockers, runs QA, and commits under the recorded consent. It never pushes or opens a PR, and it stops and asks after 3 failed verify checks, 3 consecutive `NEEDS FIXES`, or 3 consecutive `QA FAIL`, on a path outside the approved scope, or on a question the approval did not answer.

**Time budget** ([ADR-039](docs/decisions/ADR-039-run-time-budget-stop.md)). From approval, `state.json` counts the run's seconds in `budget`, per phase, between state writes; clarify and blocked time never count, all other time does, and a later approval keeps the total. Once the total reaches 2,700 seconds, the next `check`, `advance`, or `record` keeps its own result, then blocks the run with the reserved reason `run time budget reached` and returns exit 3 with `time_stop` (counted seconds per phase, review rounds, open blocker ids); `check` repeats the report in `next`. The stop waits while a worktree of the run is known to exist (when the artifacts or the worktree list cannot be read, it stops all the same), on `check` in `review` before a verdict, and when the run is in `clarify`, `blocked`, `commit`, or `done`; a refused command never causes it, nothing running is interrupted, and a run approved before the budget existed has none. `b-state unblock continue --reason R` leaves only this block: the run returns to its phase with its evidence, counters, steps, and commits, and stops again 2,700 counted seconds later. It needs the run's repository and branch, `HEAD` on its baseline or a recorded commit, and the approved spec and plan unchanged, a `check` that finds a problem on a time-stopped run reports it without replacing the reason, `advance blocked` refuses the reserved reason, and any other `unblock` past the mark also opens a new window. The budget cannot be configured. Each runtime gets it when it is reinstalled.

**Check timing.** To spend less on costly checks, `b-plan` lists no check whose work another listed check already covers, unless an `AC-n` or a repository rule needs that exact command; `verify` starts once every edit, docs included, is done and its related checks passed, and runs the plan checks cheapest first and the heaviest last; and `fix` fixes its whole batch and passes the related checks before it returns to `verify`. These rules set timing, order, and duplicate runs only: every approved check still runs as listed, and a narrow run is no plan check and never full coverage. They are prompt guidance that no helper enforces. Whether a repository's candidate needs its full suite locally stays that repository's `AGENTS.md` decision.

Run files are untracked, under `.b-agentic/runs/<yyyymmdd-slug>/` at the worktree root (`.b-agentic/.gitignore` is `*`): `spec.md` (the approval; its sha256 is recorded), `plan.md`, `qa.md`, `followups.md`, `state.json` (progress only), and `lock`. `claude/bin/b-state.mjs` is the only writer of state and fails closed: it validates the schema, refuses a symlinked folder, a changed spec, a held lock, or a step whose evidence belongs to another candidate fingerprint (for example `advance commit` without the spec's consent or a current QA PASS; `advance review` needs `--trigger`, and a low-risk exception is refused once a review was triggered or held). `/b-flow resume` runs `b-state.mjs check --takeover`, which re-verifies the repository, branch, spec hash, `HEAD`, and candidate fingerprint; a changed tree voids review and QA evidence and returns the run to `verify`. So that a session can continue a run from the run folder alone, `check` also prints `next` (the steps the phase still owes, derived from the state and the artifacts; a pointer that grants no approval), review, the low-risk exception, and QA need every approved plan check passing for the candidate (a run already past `verify` without them is returned to `verify` by `check`), a `NEEDS FIXES` or `READY WITH FOLLOW-UPS` verdict needs that round's findings already in `followups.md`, and `state.json` keeps a bounded `history` of every write (200 entries; `show` prints the latest 20, `show --history` all) with verdicts, check results, block reasons, and unblock reasons. A plan may list `parallel_checks`, at least two of its checks that may run at the same time ([ADR-013](docs/decisions/ADR-013-concurrent-plan-checks.md)); every other check runs alone. `next` names the listed checks in one line with the candidate fingerprint as `--from`, and `record check --from <fingerprint>` (required for a listed check) records the result only while that is still the candidate: otherwise nothing is recorded and the lost check counts as a failed verify attempt. Claude Code starts the listed checks as background commands, Pi issues one `bash` tool call per listed check together in a single assistant message (no other tool call), and a quick run refuses the list. Progress inside `implement` is recorded with `record step S-n` (a step waits for the steps it depends on), and `advance verify` is refused while a plan step is unrecorded. Each step is checked when it is recorded ([ADR-014](docs/decisions/ADR-014-checked-plan-steps.md)): entering `implement` and every recorded step store a step base (tree id, fingerprint, `HEAD`, state revision), and `record step` refuses a step whose changes since that base include a path outside the approved scope or a likely-secret path (nothing recorded, the base kept, the refusal counted, the third in a row blocking the run) and blocks the run when the state was written or `HEAD` moved in between. A recorded step's history entry carries its tree id, its changed-path count, and how many of those are outside the step's own paths; `scope-check --base T --tree T --step S-n` is the comparison it runs. A full-run plan may list `worker_steps` ([ADR-015](docs/decisions/ADR-015-step-writer-worker.md)): `b-plan` proposes them for self-contained steps and the approval round confirms or drops each, and a quick run refuses the field. On Claude Code the main session first checks every file that may be the `b-worker` profile (one named so in its frontmatter, one called `b-worker.md`, or one whose name cannot be established by a strict reading, in any file under a project or user agents folder) with `b_run.py worker-profile`, which refuses any tool outside the generated native tools plus the read-only MCP tools, any other frontmatter key, unusual YAML in a candidate, two candidates in one scope, and a link under an agents folder, then hands each listed step to one `b-worker` with `b_run.py handoff implement --step S-n` and waits, editing nothing and running neither run CLI; after the report it renders the packet again and stops if its state or follow-ups revision changed, then inspects the diff, runs the step's check, and records the step. `record step` on a listed step needs `--by worker` (or `--by main` when the main session applied it) and is refused before any write otherwise, for `--by` on an unlisted step, for `--by worker` without a step base, and for a listed step already recorded; the history entries of listed steps carry `by`. A plan may also list `parallel_steps` ([ADR-016](docs/decisions/ADR-016-parallel-worker-steps.md)), at least two `worker_steps` with literal, disjoint paths that may be ready together (a quick run refuses the list): the first two such steps that are open with their dependencies recorded form a batch, and each gets its own detached git worktree in an owner-only folder under the temporary folder, made by `b-state.mjs worktree add S-n` from the step base tree (the user's uncommitted work and earlier steps included, no ignored or likely-secret files). The step packet then carries a `Working directory:` line and the two workers run at the same time. After every report the main session, in plan order, runs `worktree collect S-n` (which refuses a moved worktree `HEAD`, a main tree that is not the step base, and any path outside the step's own paths, and prints the `git apply` command), applies it from the repository root, runs the step's check in the main tree, records the step `--by worker`, and runs `worktree remove S-n`. These commands never write `state.json`, never change the main tree, and never apply; `record step` refuses a worker step whose main-tree change differs from the worker's, the history entry carries `worktree: true`, `check` lists remaining worktrees, and `advance verify` is refused while one remains. A step whose check needs installed dependencies must not be parallel. Each skill's `contract` in `skills/registry.yaml` says whether it is a phase skill, an evidence provider, a utility, or the orchestrator, and the `b-flow` skill carries the generated table of phases, skills, and packets. A `/clear` changes the session id, so a resumed run takes the lock over. State holds no file contents, diffs, command output, or secrets, and is untrusted input to every reader.

The four markdown artifacts have one writer too ([ADR-010](docs/decisions/ADR-010-run-artifact-cli.md)): `~/.claude/b-agentic/bin/b-run write <spec|plan|qa|followups>` reads JSON on stdin, validates it against `b-agentic/references/artifacts.yaml` (field grammar, enums, limits, one example per kind) and the cross-artifact rules (contiguous `AC-n` and `S-n`, evidence needs a command or a source, plan checks cover every automated command, plan paths inside the spec scope, QA rows matching the spec, no dropped follow-up ids, and, on new input only, `blocker_class` and `escaped_from` (`unknown` when not known) on each blocker not yet recorded, as far as the installed schema can record them, [ADR-038](docs/decisions/ADR-038-required-blocker-analytics.md)), checks the artifact's phase and the run lock, renders canonical markdown, and records its sha256 and data in `artifacts.json`. `validate` re-renders and compares bytes and refuses unknown files in the run folder; `scope-check` compares changed git paths with the spec scope; `handoff <clarify|implement|verify|review|fix|qa|commit>` renders the packet that briefs that phase from the run folder and the tree. A plan step may name the earlier steps it waits for in `depends_on`; without it a step waits for the one before it. `b-path-guard` refuses native `Edit`, `Write`, and `NotebookEdit` on any `.b-agentic` path, a Bash write is detected rather than prevented, and `b-state` requires valid artifacts, matching spec and plan hashes, approved check commands, and a `qa.md` rewritten in the current QA round before it advances or records.

Old run folders are cleaned up on request, never automatically ([ADR-024](docs/decisions/ADR-024-prune-old-runs.md)). `~/.claude/b-agentic/bin/b-run runs [--days N]` is a read-only report of `.b-agentic/runs`: the run count, the bytes of their plain files, the runs `prune` would remove, a count of the kept runs by reason, and `over_threshold` (more than 40 runs or 50 MB). `prune [--days N]` (default 30, whole days from 1 to 3650) lists the same runs and removes them only with `--apply`; both refuse any other option (for example `--run`) instead of ignoring it. A run is eligible only when its phase is `done`, its `updated_at` is older than N days, it is not the run `active` names, its `state.json` reads cleanly with a matching `run_id`, and its folder holds only plain files; a run in any other phase is kept, including one left behind by `init --replace`. `--apply` refuses while `.b-agentic/mutex` exists or when `.b-agentic` or `.b-agentic/runs` is a link, and deletes file by file through directory file descriptors opened one below the other without following links, removing a run's files through the descriptor of the folder it inspected and its name only while that name is still that folder (no shell `rm -rf`, no recursion); each failure is listed in `problems` and exits 3. `b-state.mjs init` adds a one-line `hint` to its result when more than 40 run folders exist (a count of names only, nothing deleted), and `b-audit` and `b-agentic-audit` run `runs` and report it as a housekeeping note that never changes their verdict and never run `prune`. No statusline, hook, or background task checks the folder.

Finished runs also leave a numbers-only line in a local store ([ADR-035](docs/decisions/ADR-035-local-run-stats.md)): when `advance done` saves the `done` state, `b-state` calls `b-run stats --record --run ID`, which appends one JSON line to `~/.claude/b-agentic/run-stats.jsonl` (Pi: `~/.pi/agent/b-agentic/run-stats.jsonl`; each runtime has its own file) and never fails the advance. The store is on by default, is created 0600 on first use only when that install home already exists as a real folder you own, others cannot write to, and only your own private group (a group of which you are the only member) can write to and no ACL widens that, `advance done` reports the outcome as `run_stats` (`written`, `already`, `skipped:<reason>`, or `failed`), and the first creation adds a one-time `notice`. A line holds only the fields of the `run_stats` block of [`references/artifacts.yaml`](references/artifacts.yaml): counts of steps, criteria, and scope paths, seconds per phase, review rounds and gate, QA verdict, fix rounds, blocked and failed-check counts, `time_stops` (the blocks the time budget made, [ADR-039](docs/decisions/ADR-039-run-time-budget-stop.md); absent from older lines, and `missing.time_stops` in the summary counts those), `AC-n` results, blocker counts by class and escape stage, the run date, two hashes (the repository's root commits and the run), and the kit version fields below; never a request, summary, follow-up text, path, command, branch, or run name, and the helpers put no commit id in it except the b-agentic kit's own `kit_commit` (the writer checks formats, not origins: every field comes from the run's unauthenticated `state.json`). Create `~/.claude/b-agentic/run-stats.off` (any file, folder, or link of that name) to turn it off: nothing is created or appended, and the existing file is kept. Delete `run-stats.jsonl` to delete the data; nothing rotates it, and install, sync, and uninstall leave both files alone. `b-run stats` is a read-only report of counts (store lines, malformed lines, repositories, this repository's finished runs not yet stored); `b-run stats --record` adds the missing lines for this repository's finished runs of the runtime that runs it, which you run once per repository to bring earlier runs in (a shallow clone has no repository key and is skipped). `b-agentic-audit` runs `stats` as a housekeeping note.

**Run-stats summary** ([ADR-035](docs/decisions/ADR-035-local-run-stats.md)). `b-run stats --summary [--since YYYY-MM-DD] [--section repo|kit]` prints one compact line of JSON, made of numbers, enum names, hashes, and dates, for an analysis to read; it states no finding. Without `--section` the output holds the header (`ok`, `since`, `repo`, `stores`, `before_since`), `all`, and `by_runtime`; `--section repo` gives the header with `by_repo` in their place, and `--section kit` with `by_kit`. Any other value, and `--section` without `--summary`, is refused (exit 2). It reads both runtimes' stores and their off flags (a disabled store is still read), writes nothing, and reads no run folder. `--since` keeps the lines whose run date is on or after that day, old lines included, and `before_since` counts the rest; it is refused without `--summary`, as is `--summary` with `--record` or `--run` (exit 2). `repo` is this repository's key, `null` when it has none (a shallow clone). `stores` gives each store's `status` (`read`, `absent`, `not-regular`, `unreadable`; a failure after the store is opened makes it `unreadable` with no lines, and the other store is still summarized), `disabled`, `truncated` (only the first 8 MiB of a larger file is read), and its `lines`, `counted`, `malformed`, `unknown_version` (`v` other than 1), and `duplicates` (a run key already seen: the first line wins, the Claude Code store first); only counted lines reach a block. `all`, each `by_runtime` entry (the line's own `runtime`, else `unknown`), each `by_repo.groups` entry (the 5 repository keys with the most runs), each `by_kit.groups` entry (the 4 newest versions by `kit_date`, then `kit_seq`; one per `runtime`, `kit_seq`, `kit_commit`, and `kit_date`), and `by_kit.without_kit` hold the same block: `runs`; `counts`, which gives each stored count its `n`, `sum`, `min`, nearest-rank `p50` and `p90`, `max`, and a `values` histogram over `0` to `9` and `10+` without empty buckets; `seconds` in total and per phase, from lines with a complete history only, where a phase counts only the runs that were in it; `sums` of sizes, ends, review gates, review and QA verdicts, low-risk reviews, `AC-n` results, blocker classes and escape stages (`unclassified` stays its own key), `kit_dirty`, and `kit_changed`; and `missing`, the number of runs without a `runtime`, a kit version (`kit`; `kit_unchecked` is the part whose kit fields were set aside because the `artifacts.yaml` beside the helpers has none), `kit_changed`, a review or QA verdict, usable `durations`, or `time_stops`. With `n` 0 there is no `min`, `p50`, `p90`, or `max`, and a missing value is never read as zero. `by_repo` and `by_kit` also give `omitted_groups` and `omitted_runs`. One output therefore holds at most five blocks of one breakdown, and on the stats test's large synthetic stores each stays under 30,000 bytes, below the point where an agent's shell tool cuts what it shows (Pi keeps the last 50 KB), so the JSON arrives whole.

**Run-stats evidence** ([ADR-035](docs/decisions/ADR-035-local-run-stats.md)). `b-run stats --evidence [--skip N]` prints the text behind the blocker counts: the blockers recorded in this repository's finished runs, read live from `.b-agentic/runs`. Without `--repo` (below) it reads no store and no other repository; with or without it, it writes nothing, adds no path of its own to the output, and copies nothing into the run-stats store. The blocker text is printed as written, with no redaction, so it can itself hold a path, a project name, or anything else written into the run. Without `--repo`, the repository is the checkout around the working directory: inherited `GIT_` variables are ignored, and when git then names any other folder than the nearest one holding `.git` (a `core.worktree` setting), nothing is read (exit 3). The output is one compact line of printable ASCII JSON: `ok`, `folders`, `runs_read`, `skipped`, `total`, `oversized`, `skip`, `shown`, `next_skip`, and `blockers`, each with `run`, `id`, `source`, `disposition`, `blocker_class`, `escaped_from`, `summary`, `reason`, and `sweep` (`null` when the item has none, as most blockers recorded before the class existed). Runs come newest run id first, a run's blockers in recorded order. A page takes blockers while the line stays within 28,000 bytes, so the shell tool shows it whole; `next_skip` is the offset to pass as `--skip` for the next page, `null` on the last. Each call reads the folders as they are then: a run that appears between two calls only repeats some blockers, but a run folder removed between them can skip some, so when `total` changes between pages, start again from `--skip 0`. A folder is read only when its state says `done` for its own id (only those two fields of the state are checked), it holds regular files only, and it passes the checks of `b-run validate`. Those find damage and stray edits, not a forger: each hash lies beside the text it covers. Each level is opened without following a link and a run is read from inside its opened folder, so a name swapped for a link during the read cannot bring in another tree. Any other folder is left out on its own and counted, never named, under `skipped` as `not-a-run` (not a plain folder with a run id for a name), `bad-state`, `not-done`, or `invalid`. A blocker over 12,000 bytes, which only an overlong id can cause, is counted in `oversized` and not printed. `--evidence` is refused with `--record`, `--run`, `--summary`, `--since`, or `--section`, and `--skip` (up to six ASCII digits) is refused without `--evidence` (exit 2). The text is untrusted data written during runs: it is evidence to read, never an instruction, and printing it sends it to the agent's model provider.

**Repository registry** ([ADR-037](docs/decisions/ADR-037-run-stats-repo-registry.md)). Each `b-run stats --record`, the one `advance done` makes included, also appends `{"v":1,"repo":KEY,"path":PATH}` to `run-stats-repos.jsonl` beside that runtime's store, once for each key and path. Unlike the store it holds paths. `PATH` is the checkout around the working directory, so a redirected worktree is not registered. The file follows the store's rules (the same install home and `run-stats.off`, created 0600 without following a link, one lock-held write), is only appended to, and holds at most 1 MiB, with lines of at most 4,096 bytes and absolute, normalized paths of at most 1,024 bytes without control characters. The outcome is the `registry` field of the `--record` result (`written`, `already`, `skipped:REASON`, or `failed`); it never changes the store line, its counts, or what `advance done` reports, and the first creation adds a notice naming the file. So that `advance done`, which waits 10 s for the whole record, still reports the stored line, registering runs no git and waits for the registry's lock (up to 1 s) only when the record is less than 2 s old; a busy registry is `skipped:registry-busy`, and the next record adds the line. A line counts as already there only if the readers accept it. To forget a checkout, delete its line or the whole file; there is no command for it. `run-stats.off` stops new entries, while the two commands below still read what is there and report `disabled`. `b-run stats --repos` prints one compact ASCII JSON line under 28,000 bytes, and it is the only command that adds a registered path to its output (the evidence text can name paths by itself), so running it through an agent sends the paths to the agent's model provider: `registries` (each runtime's `status`, `disabled`, `truncated`, `lines`, `malformed`), `repos` (each `repo` with up to 4 `paths` and its `omitted_paths`, Claude Code's file first and each file newest first), and `omitted_repos`. A registry that fails the writer's safety checks (a link, more than one hard link, a loose mode, a home that is not private) gives its status and no entry. `--repos` takes no other stats option (exit 2).

`b-run stats --evidence --repo KEY` reads another registered repository, and can be run from any folder. `KEY` is the 16-character key that `--summary --section repo` and `--repos` print, never a path, and only a registered path is read. The key's paths come from both registries (Claude Code first, each newest first, each path once) and the first 4 are tried. A registry line can be stale, so a folder is read only if it is opened without following a link, belongs to you, is the top level git names from inside it (holding `.git`), is not a partial clone, and still has `KEY`; its runs are then read from inside that held folder, with the per-run checks above. The runs of every checkout that passes are merged, newest run id first; a folder reached by two paths is read once. A run is its id and start time, as the summary tells runs apart: a copy of a run already read is only counted in `duplicate_runs`, while two runs two clones gave the same id both print (the later start first; their blockers show the same `run`). A run whose recorded start time is damaged still prints, and is never taken for a copy. The key comes from the root commits, so **clones, worktrees, forks, and template copies that share root commits share one key and are read together**, even when they are separate projects: every one is a checkout of yours that has run b-agentic, but one command can put the blocker text of all of them in front of the model provider. Check the key's paths with `--repos` first. The header adds `checkouts`: `registered`, `read`, `skipped` (`gone`, when the folder or its runs cannot be opened, `not-owned`, `not-a-checkout`, `partial`, `no-key`, `other-key`, `same-folder`, `not-tried`) and `duplicate_runs`. The command prints no registered path and no git error; the blocker text, as above, is printed as written. An unregistered key, or no checkout that passes, exits 3 and reads no run; a malformed key, or `--repo` without `--evidence`, exits 2. Every repository-key lookup (record, report, summary, `--repo`) and the evidence checkout lookup run git from an absolute `PATH` entry only, with relative and empty `PATH` and library-path entries dropped (so a `git` or a library inside the folder never loads), `LD_PRELOAD`, `LD_AUDIT`, `DYLD_INSERT_LIBRARIES`, and every inherited `GIT_` variable dropped, lazy fetch and the filesystem monitor off, stdin closed, and an 8 s limit, which the two git runs of one key lookup share; a key lookup that fails or exceeds it finds no key. The first `git` call that finds the current repository, as in every `b-run` command, is not part of this.

**Kit version** ([ADR-036](docs/decisions/ADR-036-run-stats-kit-version.md)). At install time each installer reads the source's git history, per runtime, and writes four fields to that runtime's `install.json`, all or none: `kit_seq` (how many commits reachable from `HEAD` touch what runs for the runtime, counted with `--full-history`), `kit_commit` (the newest of them), `kit_date` (its committer date, UTC), and `kit_dirty` (those paths have an uncommitted or untracked change, or the install kept a user-owned or modified managed file or kernel block, left a link where a retired file was, or found `settings.json` still running a hook script the source no longer ships; merged settings, permission, MCP, and subagent entries kept as the user's are not reflected, and two installs or uninstalls running into one folder at once can leave files and version that do not match, since the installers take no lock). The path lists are `KIT_PATHS` in `tooling/install/claude_install.py`, without `README.md` files. Both runtimes: `install.sh`, `skills/registry.yaml`, `claude/configs/mcp.base.json`, the kernel template and the `capabilities`, `mcp_operations`, and `artifacts` references, and the Claude Code, all-runtimes, UI, optional-component, and vendor-tool installer modules. Claude Code adds `skills/*/SKILL.md`, `claude/agents/*.md`, `claude/bin`, `claude/hooks`, and `claude/configs/settings.template.json`. Pi adds `skills/*/prompt.md`, the shared helper and hook files it installs, `references/runtimes.yaml`, `pi/bin`, `pi/extensions`, `pi/themes`, the generator, and `pi_install.py`. `tooling/validate/kit_paths.py` (default validation) fails when a list and what that install reads differ. Never remove an entry: move it to the runtime's `retired` list, which still counts. The fields are left out when the source is not the root of its own full SHA-1 git worktree (no git, shallow, a partial clone, no matching commit) or git fails, times out, or refuses it, and when the source changes while the install runs (the version read before the first source file differs from the one read when the manifest is written); a `--dry-run` computes none, a `--statusline-only` install and an interrupted install record none, and `--uninstall` drops them first. `b-state` reads the `install.json` beside its helpers when it creates a run and at `advance done`, only when the manifest's `target` is the run's runtime; a missing, unreadable, malformed, partial, linked, oversized, or non-regular file gives no version and never fails or stalls the command. A run-stats line takes five fields: `kit_seq`, `kit_date`, `kit_commit`, and `kit_dirty` from the start of the run, and `kit_changed` only when both versions are known: `true` when the commit or the dirty flag differs, `false` for the same clean commit, and absent when both are dirty at one commit. A run without a start version has no kit field, `stats --record` never takes one from the installed manifest, and beside an `artifacts.yaml` without the kit fields (a user-edited copy the install kept) the line is written without them. `kit_seq` does not drop from a commit to its descendant, but it does not order diverged branches, a history rewrite can lower it, the runtimes' numbers are unrelated, and adding a path to a list can make it jump; it describes the source at the last install, not later edits to installed files. A `b-run` from before ADR-036 counts a line with these fields as malformed and its run as missing, without writing the run again; reinstall that runtime to update it.
