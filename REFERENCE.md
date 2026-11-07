# b-agentic operational reference

[Back to the public overview](README.md)

This reference defines the two supported runtimes, Claude Code and Codex, with a
read-only subagent as the independent reviewer
([ADR-003](docs/decisions/ADR-003-subagent-review-gate.md),
[ADR-004](docs/decisions/ADR-004-codex-runtime.md)). It covers installation, the
permission boundary, the review gate, MCP configuration, and validation; the
Codex differences are in [Codex runtime](#codex-runtime). The OpenCode runtime
(ADR-004) and the earlier Pi runtime (last commit `ac38e4a`) were removed and are
not maintained here.

## Install and lifecycle

```bash
git clone https://github.com/dhoaibao/b-agentic.git && cd b-agentic && ./install.sh
```

`./install.sh` installs from the checkout that contains it. Piped
(`curl -fsSL .../install.sh | bash`), it clones the source to
`~/.b-agentic-claude` first; it never uses `~/.b-agentic`, which may still hold
the frozen Pi installer. The script never runs vendor installers and never
writes under `~/.pi`.

- `--dry-run` prints the plan and changes nothing.
- On a terminal each runtime installer shows a step timeline, a summary box, and asks before
  writing (and whether to add the optional ClickUp MCP server on a first
  install). Questions are read from `/dev/tty`, so they work when piped. `-y` /
  `--yes`, `--dry-run`, `--uninstall`, or a non-terminal stdout keep plain output
  and the defaults; `NO_COLOR` disables color. Answering No leaves that runtime's
  configuration untouched (`~/.claude` and `~/.claude.json`, or `~/.codex` and
  `~/.agents/skills`). A piped run has already cloned or updated the source
  checkout by then, because the summary needs it. With `--runtime=both`, each
  runtime confirms separately; declining Codex does not undo Claude's install.
- `--update` fast-forwards the checkout (`--ref=<tag-branch-or-commit>` checks
  out a ref) and then syncs. A plain run is already idempotent: unchanged
  inputs write nothing.
- `--force` replaces a managed file you modified, or a same-named file b-agentic
  did not install, after a backup. Without it such files are kept with a warning.
- `--uninstall` removes only recorded, unmodified assets and entries and keeps
  `~/.claude/b-agentic/backups`.
- `--with-clickup` / `--without-clickup` (or `B_AGENTIC_CLICKUP_MCP=yes`) select
  the optional ClickUp MCP server. The choice is recorded and preserved.
- `--runtime=claude|codex|both` selects the runtime (default `claude`). Each
  runtime's install and uninstall leave the other untouched. `--runtime=opencode`
  is refused with a pointer to ADR-004; remove an old OpenCode install with the
  installer from a commit before the removal.
- Only `~/.claude` is supported for Claude Code. A different `CLAUDE_CONFIG_DIR`
  is refused because the managed hooks, agents, and instructions refer to that path.

What it manages, all recorded in `~/.claude/b-agentic/install.json`:

| Asset                              | Installed path                                                                       |
| ---------------------------------- | ------------------------------------------------------------------------------------ |
| Skills (also `/b-<name>` commands) | `skills/b-*/SKILL.md`                                                                |
| Specialists                        | `agents/b-*.md`                                                                      |
| Hooks and CLIs                     | `b-agentic/hooks/*.mjs`, `b-agentic/bin/*.mjs`                                       |
| References                         | `b-agentic/references/`                                                              |
| Kernel                             | block between `<!-- b-agentic:start -->` and `<!-- b-agentic:end -->` in `CLAUDE.md` |
| Permissions, hooks, status line    | entries merged into `settings.json`                                                  |
| MCP servers                        | entries merged into `~/.claude.json`                                                 |

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
git directory is under `~/.pi`. Claude Code rewrites `~/.claude.json` while it
runs, so restart it after an install. The installer reports missing tools (`rtk`,
`codegraph`, `bunx`, `claude`) and never runs vendor installers. The review gate
needs no extra tool, login, or plugin.

## Codex runtime

`./install.sh --runtime=codex` (or `both`) installs the same canonical skills,
specialists, and safety checks for Codex CLI, rendered from the same sources
through [`references/runtimes.yaml`](references/runtimes.yaml). Only the default
`~/.codex` is supported (a different `CODEX_HOME` is refused), plus
`~/.agents/skills` for skills. Everything is recorded in
`~/.codex/b-agentic/install.json`.

| Asset          | Installed path                                                                       |
| -------------- | ------------------------------------------------------------------------------------ |
| Skills         | `~/.agents/skills/b-*/SKILL.md` (invoked as `$b-<name>`, not slash commands)         |
| Specialists    | `~/.codex/agents/b-*.toml` (agent roles with a pinned model and effort)              |
| Rules          | `~/.codex/rules/b-agentic.rules` (prefix rules for denied and asked commands)        |
| Hooks and CLIs | `~/.codex/b-agentic/hooks/*.mjs`, `bin/*.mjs` (verify gate shared)                   |
| Kernel         | block between `<!-- b-agentic:start -->` and `<!-- b-agentic:end -->` in `AGENTS.md` |
| Hook entries   | entries merged into `~/.codex/hooks.json`, with absolute installed paths             |
| MCP servers    | `[mcp_servers.*]` tables appended to `~/.codex/config.toml`, owned by name and value |

- **Your policy stays yours.** The installer never writes `sandbox_mode` or
  `approval_policy`. Set `workspace-write` with `on-request` approvals yourself to get
  prompts for writes outside the project.
- **MCP approvals.** Every managed server prompts by default
  (`default_tools_approval_mode = "prompt"`); classified tools get a per-tool
  `approval_mode` (`approve` for auto-allowed classes, `prompt` otherwise). ClickUp
  `createTask` and `updateTask` prompt on every call because a Codex hook cannot ask.
  Each managed table is owned by its name and parsed value, not by position or markers, so
  Codex rewriting `config.toml` (`codex features enable`, `codex mcp add`, hook trust)
  never orphans it; a table you or Codex changed, or one you already define, is kept and
  reported. An unknown
  `approval_mode` makes Codex reject the whole config, so the generator validates every
  value. The IDE-managed DataGrip server has no table.
- **Specialist models.** The registry's `codex_model` and `codex_effort` pin each role
  (omit them to inherit the session's). Defaults, from the model catalog bundled in Codex
  0.167.0 (`codex debug models`): `b-planner`, `b-reviewer` `gpt-6.1-sol` at `high`;
  `b-auditor` `gpt-6.1-sol` at `xhigh`; `b-debugger` `gpt-6.1-terra` at `xhigh`;
  `b-researcher` `gpt-6.1-terra` at `medium`. Codex reports the pin in each role's
  `spawn_agent` description. A role can only use models of the session's provider, and
  whether your account can use these two is not checked here; edit the registry and
  regenerate to change a pin.
- **Specialists** are agent roles. Codex agent files cannot restrict the sandbox, tools, or
  MCP servers they inherit, so read-only is instructed, and a hook denies `apply_patch`
  and MCP tools outside the role's allowlist when the hook payload names the role
  (`agent_type`). Shell writes are not blocked.
- **Hooks** run through one adapter (`b-codex-hooks.mjs`) for `PreToolUse`, `PostToolUse`,
  and `Stop`. Codex skips a hook until you trust it: run `/hooks` after install and after
  every update, because trust is tied to the hook's hash. Hooks fail open on error, cannot
  ask, and do not run for hosted tools, so they are a guardrail rather than a boundary.
- **Kernel size.** The global `~/.codex/AGENTS.md` does not count toward Codex's
  `project_doc_max_bytes` (per the 0.167.0 source).
- **Review gate** is the same read-only `b-reviewer` specialist as on Claude Code.
- **Uninstall** removes the managed tables and the kernel block and keeps everything else,
  including tables Codex wrote. `config.toml` and `AGENTS.md` return byte for byte unless
  something else edited around the managed text (surrounding blank lines are normalized);
  `hooks.json` keeps your entries but is re-serialized with two-space indentation.

Known differences from Claude Code, accepted in ADR-004:

Both runtimes share workflow and authorization obligations. Native prompts depend
on effective user settings: missing prompts do not authorize outside-project
mutations or unclassified MCP calls. Codex profile eligibility checks explicit
read-only instructions; Claude checks tool lists. Neither is a filesystem sandbox.
The shared acceptance scenarios and distinction between instruction checks and
live evidence are in [ADR-004](docs/decisions/ADR-004-codex-runtime.md).

| Claude Code feature                | Codex                                                                                                                      |
| ---------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Read-only specialists by tool list | Instructed, plus a best-effort `apply_patch` and MCP allowlist hook; shell writes are not blocked                          |
| Path guard on `Read`/`Grep`/`Glob` | `apply_patch` paths and shell command words are checked; other read paths are not                                          |
| ClickUp image-reference prompt     | Replaced by prompting on every ClickUp create or update                                                                    |
| Shell `deny`/`ask` patterns        | Exact-prefix rules only; a flag not directly after the prefix, `gh` global options, or a refspec elsewhere are not matched |
| Hook `ask`                         | Not supported by Codex (parsed, then ignored as a failed hook run)                                                         |
| Outside-project writes prompt      | Your `sandbox_mode` and `approval_policy`; nothing managed                                                                 |
| `AskUserQuestion`                  | Available, permitted structured question tool; plain text as fallback                                                      |

Verified against the Codex 0.167.0 binary and source: agent roles and skills load from
the installed layout, hooks are discovered and show as untrusted, the generated rules and
MCP tables parse and match. No live Codex turn is run by this repository's checks. Before
relying on the hooks, confirm in a real session that `agent_type` reaches hook payloads
inside a subagent, that an `apply_patch` on `.env` is denied, and that the model-facing MCP
tool names are `mcp__<server>__<tool>`.

## Kernel and skills

Claude Code loads `~/.claude/CLAUDE.md` and discovers `skills/b-*/SKILL.md`.
The main session reads one skill before acting or invokes `/b-<name>`.
`skills/registry.yaml` and `skills/*/prompt.md` are canonical;
`tooling/generate/registry_sync.py` generates `SKILL.md`, `claude/agents/*.md`,
the kernel's generated blocks, and `claude/configs/settings.template.json`.
Explicit-request skills (`b-commit`, `b-pr`) route only on explicit
user request and stay model-invocable.

The five specialists are `b-planner`, `b-researcher`, `b-debugger`, `b-auditor`,
and `b-reviewer`. Their tool lists omit `Edit`, `Write`, `NotebookEdit`, and nested
delegation and carry only read-only MCP tools (plus three bounded Firecrawl
tools for `b-researcher`). Read-only behavior is instructed, not enforced by a
child-specific permission block: shell access can still mutate state. Delegated
skills never run in the main session; the generated `Delegation boundary` and
the kernel carry this, so a missing subagent is reported instead of bypassed. A
child result is evidence, not authorization. Claude Code models are Anthropic
aliases from the registry's `model` field, with an optional `effort` field
(`low`–`max`) rendered as subagent frontmatter; current Claude Code defaults are
`opus`/`high` for `b-planner` and `b-reviewer`, `opus`/`xhigh` for `b-auditor`,
`sonnet`/`xhigh` for `b-debugger`, and `sonnet`/`medium` for `b-researcher`. The
`high` choice for the planner and reviewer follows Anthropic's guidance to reserve
`xhigh` for work with a measured quality gain. One vendor code-review benchmark
(Qodo, 2026-10) scored Opus 5.5 at `high` above `xhigh` on F1 (`xhigh` had the
highest recall on hard bugs but lower precision), and Artificial
Analysis puts `high` at about half the per-task cost of `xhigh` for a small
index drop. None of this was replayed on this repository's own reviews, so
revisit it with measured time, tokens, and blocker counts ([ADR-003](docs/decisions/ADR-003-subagent-review-gate.md)).
On Claude Code the registry values are defaults: a per-call `model` or `effort` on
the agent call overrides them, `CLAUDE_CODE_EFFORT_LEVEL` overrides the effort, and
`CLAUDE_CODE_SUBAGENT_MODEL` overrides the model only together with
`CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1`.

## Review gate

`b-review` is a delegated skill: it runs only in the read-only `b-reviewer`
subagent, called by its named type so it starts with a fresh context instead of a
fork of the implementer's conversation. It needs no second subscription, login,
or plugin, and the candidate goes to no recipient beyond the model provider that
already serves the session ([ADR-003](docs/decisions/ADR-003-subagent-review-gate.md)).
The gate sequence is:

1. Freeze the candidate: `node ~/.claude/b-agentic/bin/b-candidate-snapshot.mjs`
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
   `NEEDS FIXES` rounds. A missing, failing, or verdict-less reviewer is
   reported to the user, never replaced by a self-review.

Accepted trade-offs against the retired Codex gate:

- The reviewer shares the main session's model family, so some blind spots
  correlate; the independence comes from a fresh context, a separate review
  prompt, and a read-only role. For a high-risk change (security, permissions,
  secrets) you can still run the Codex plugin by hand as an extra opinion; it is
  not part of the gate, and b-agentic no longer checks such a direct call (no
  approval or protected-path check applies), so you run it at your own risk.
- Read-only is instructed on Claude Code, not sandboxed: the tool list omits
  `Edit`, `Write`, `NotebookEdit`, and nested delegation, but shell access can
  still mutate state.
  The fingerprint recomputation catches any change to tracked or named files,
  but not a change to an ignored or outside-repository file that was never named.
- The reviewer reads the repository as the main session's provider already does,
  so no new recipient exists and no approval store is needed. Review never
  commits or pushes.

The Codex wrapper (`b-codex-review.mjs`), the verdict mapper
(`b-codex-verdict.mjs`), and the `b-codex-guard` hook were
removed. An upgrade retires them from an existing install: the installer drops the
recorded `b-codex-guard` hook entry from `settings.json` before it deletes the
script, deletes unmodified copies, keeps and reports an edited hook (and keeps its
script until that entry is gone), and leaves your `codex-approved-repos.json` in
place with a note. A kept, edited guard hook can no longer work, because the
snapshot CLI exports it imported are gone: it errors without blocking on each Bash
call until you remove the entry from `settings.json`.

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
`b-path-guard` hook applies the exact path rules to the file tools (including the
`*.env.example` allowance that deny rules cannot express). Hooks:
`b-path-guard` and `b-clickup-guard` run before tools (`b-clickup-guard` asks before an
auto-approved ClickUp `createTask` or `updateTask` whose markdown references an image other than an
existing ClickUp attachment URL, since the MCP uploads local and downloaded images); `b-verify-gate` tracks
edits and, when the main session edited a non-prose file after its last non-inspection shell
command, blocks the first stop once with the verify and review reminder. Both PreToolUse guards set
`onFailure: "block"` (Claude Code 2.1.295 or later), so a guard that crashes, times out, or
cannot start blocks the call, and malformed input still fails open by design. To recover from a
guard that fails closed (for example a missing `node` or hook script), repair or reinstall: Bash is
not guarded and still works. Older Claude Code versions' handling of the unknown key is undocumented.
Managed Claude Code rules ask for outside-project writes; effective prompts depend
on user settings. These
rules are not a process or filesystem sandbox; shell indirection and MCP
arguments they cannot see remain residual risks (only `b-clickup-guard` inspects
ClickUp task arguments). Native Linux and macOS Claude Code builds run `Grep`
and `Glob` searches through Bash, so `b-path-guard` sees no searches there. The
kernel additionally
requires approval for other destructive, privileged, ambiguous, protected, or
external/shared actions.

## MCP and readiness

`claude/configs/mcp.base.json` configures CodeGraph, Context7, Brave Search,
Firecrawl, Playwright, Notion, Excalidraw, draw.io, and shadcn;
`mcp.clickup.json` is the optional ClickUp server. Tools are addressed as
`mcp__<server>__<tool>`. Credentials are `${VAR}` references; the installer
collects none.

| MCP          | Local prerequisite                                                    |
| ------------ | --------------------------------------------------------------------- |
| CodeGraph    | `codegraph` and an index for graph questions                          |
| Context7     | `CONTEXT7_API_KEY`                                                    |
| Brave Search | `bunx`, `BRAVE_API_KEY`                                               |
| Firecrawl    | `bunx`, `FIRECRAWL_API_KEY`                                           |
| Playwright   | `bunx` (isolated/headless testing)                                    |
| Notion       | approved OAuth when Notion content is requested                       |
| Excalidraw   | approved `create_view` calls, MCP UI viewer                           |
| draw.io      | `bunx`, approved `open_drawio_*` calls, default browser (optional)    |
| shadcn       | `bunx`, project `components.json`                                     |
| ClickUp      | optional install opt-in, `bunx`, `CLICKUP_API_KEY`, `CLICKUP_TEAM_ID` |
| DataGrip     | IDE-managed: DataGrip with MCP Server enabled; no b-agentic template  |

Notion is the official hosted server and reaches the user's whole private
workspace, so workspace reads are `conditional-read` (allowed in the main session,
never granted to the specialists), calendar and contact reads are `private-read`
and ask, and every write asks. Excalidraw's
`create_view` and draw.io's `open_drawio_*` ask on every call and send diagram
text to a hosted endpoint or open the draw.io web editor. draw.io runs
`bunx @drawio/mcp@1.6.3` with `DRAWIO_ICON_SERVICE_URL=off`; the pin freezes only
the top-level package, and the package runs unsandboxed with your permissions.
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

`scripts/mcp-doctor.sh --allow-degraded` reports local launcher, configuration,
and environment-variable presence only. It never reads credential values, starts
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
npm run quality
rtk git diff --check
```

Plain `scripts/validate-skills.sh` runs the generator self-test and check, the
policy and routing checks, the hook probe
(`tests/hooks/hooks-probe.sh`), the Codex hook probe
(`tests/hooks/codex-hooks-probe.sh`), and the snapshot CLI probe
(`tests/snapshot/cli-probe.sh`). `--release` (CI) adds the sandbox installer
probes (`tests/install/claude-install-probe.sh` and
`tests/install/codex-install-probe.sh`) and the RTK readiness check. None
needs Claude Code, Codex, credentials, or a network.

`skills/` and `references/` hold canonical workflow guidance; `claude/` holds
generated specialists and settings plus the hooks, CLIs, and MCP templates;
`codex/` holds the generated Codex agents, skills, rules, and config templates plus
the hook adapter;
`tooling/generate/`, `tooling/install/`, and `tooling/validate/` own
generation, lifecycle, and static checks; `tests/` covers behavior, hooks,
snapshots, and the installer. See the [ADR-001 design record](docs/decisions/ADR-001-b-agentic-design-record.md).
