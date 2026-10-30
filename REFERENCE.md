# b-agentic operational reference

[Back to the public overview](README.md)

This reference defines the two supported runtimes, Claude Code and OpenCode,
with Codex as the independent reviewer ([ADR-002](docs/decisions/ADR-002-dual-runtime-support.md)).
It covers installation, the permission boundary, the review gate, MCP
configuration, and validation; the OpenCode differences are in
[OpenCode runtime](#opencode-runtime). The earlier Pi runtime was removed (last
commit `ac38e4a`) and is not maintained here.

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
- On a terminal both runtime installers show a step timeline, a summary box, and ask before
  writing (and whether to add the optional ClickUp MCP server on a first
  install). Questions are read from `/dev/tty`, so they work when piped. `-y` /
  `--yes`, `--dry-run`, `--uninstall`, or a non-terminal stdout keep plain output
  and the defaults; `NO_COLOR` disables color. Answering No leaves that runtime's
  configuration untouched (`~/.claude` and `~/.claude.json`, or `~/.config/opencode`).
  OpenCode also shows legacy migration removals before confirmation; declining
  creates no backups and removes nothing. A piped run has already cloned or updated
  the source checkout by then, because the summary needs it. With `--runtime=both`,
  each runtime confirms separately; declining OpenCode does not undo Claude's install.
- `--update` fast-forwards the checkout (`--ref=<tag-branch-or-commit>` checks
  out a ref) and then syncs. A plain run is already idempotent: unchanged
  inputs write nothing.
- `--force` replaces a managed file you modified, or a same-named file b-agentic
  did not install, after a backup. Without it such files are kept with a warning.
- `--uninstall` removes only recorded, unmodified assets and entries and keeps
  `~/.claude/b-agentic/backups`.
- `--with-clickup` / `--without-clickup` (or `B_AGENTIC_CLICKUP_MCP=yes`) select
  the optional ClickUp MCP server. The choice is recorded and preserved.
- `--runtime=claude|opencode|both` selects the runtime (default `claude`). Each
  runtime's install and uninstall leave the other untouched.
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
| Permissions and hooks              | entries merged into `settings.json`                                                  |
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
`codegraph`, `bunx`, `claude`, `codex`) and prints, but never runs, the Codex
plugin commands.

## OpenCode runtime

`./install.sh --runtime=opencode` (or `both`) installs the same canonical skills,
specialists, and safety checks for OpenCode v2, rendered from the same sources
through [`references/runtimes.yaml`](references/runtimes.yaml). Only the default
`~/.config/opencode` is supported; a different `XDG_CONFIG_HOME` or
`OPENCODE_CONFIG_DIR` is refused. Everything is recorded in
`~/.config/opencode/b-agentic/install.json`.

| Asset            | Installed path                                                                        |
| ---------------- | ------------------------------------------------------------------------------------- |
| Skills           | `skills/b-*/SKILL.md` (skills are not slash commands in OpenCode)                     |
| Specialists      | `agents/b-*.md` (`mode: subagent`, read-only `permissions`)                           |
| Safety plugin    | `plugins/b-agentic.js`, importing the hooks installed beside it                       |
| Hooks and CLIs   | `b-agentic/hooks/*.mjs`, `b-agentic/bin/*.mjs` (shared with Claude Code)              |
| Kernel           | block between `<!-- b-agentic:start -->` and `<!-- b-agentic:end -->` in `AGENTS.md`  |
| Permissions, MCP | rules appended to `permissions`, servers added under `mcp.servers` in `opencode.json` |

- **Permissions.** OpenCode applies the last matching rule, so the managed rules
  are always the final block of `permissions`; your earlier rules are preserved
  in order, and a re-run moves the managed block back to the end. Every
  `<server>_<tool>` asks by default (`*_*`, so a server you added prompts too),
  each managed server asks by default (`<server>_*`), then its classified tools
  follow, so an unclassified tool still prompts. Secret-path denies use
  whole-string patterns (`*.env`, `*.pem`, `*credentials.*`, `*secrets.*`) so
  project-root files match. `external_directory` asks for any read or write
  outside the project, except `~/.config/opencode`, `~/.claude`,
  `~/.local/share/opencode`, and `/tmp/opencode`. ClickUp's trusted
  mutations ask on OpenCode because the image-reference guard cannot prompt there.
  `opencode.jsonc` (comments) and the v1 `permission` map are refused before any
  write.
- **Specialists** deny `edit`, `subagent`, and `question`, deny every other
  `<server>_<tool>` (`*_*`, including servers you added), and then allow only
  their allowlisted MCP tools; unlike Claude Code this is enforced by the
  runtime. They keep the default external-directory access.
- **Skills load once.** `~/.config/opencode/skills` outranks the Claude-compatible
  `~/.claude/skills` for the same skill ID, so a machine with both installs does
  not load two copies. OpenCode v2 does not read `CLAUDE.md`.
- **Codex review gate** reuses the `openai/codex-plugin-cc` companion found under
  `~/.claude/plugins`, so Codex review on OpenCode needs that plugin installed
  from Claude Code; without it `b-review` reports the gate unavailable and asks.
  The standing per-repository approval is stored beside the installed hooks
  (`~/.config/opencode/b-agentic/codex-approved-repos.json`). Approval-store
  commands ask through shell rules instead of a hook.
- **Retired install.** A manifest from the removed OpenCode runtime is refused
  unless `--migrate-legacy` is passed, which backs up and removes only the paths
  that manifest names (`skills`, `agents`, `commands`, the whole-file `AGENTS.md`)
  and keeps your `opencode.json` content. It validates the whole replacement
  install before deleting anything and requires `opencode.json` and `AGENTS.md`
  to be regular files (not symlinks) while it runs.

Known differences from Claude Code, accepted in ADR-002:

| Claude Code feature             | OpenCode                                                                                                                 |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Verify gate (blocks first stop) | Not ported: OpenCode has no documented way to block a session from stopping                                              |
| ClickUp image-reference prompt  | Replaced by asking on every ClickUp create or update                                                                     |
| Approval-store tripwire prompt  | Shell `ask` rules (`*b-codex-guard.mjs* --approve*`, the approvals file, `B_AGENTIC_STATE_DIR`)                          |
| Path guard on `Grep`/`Glob`     | Native `read`/`edit` secret denies plus the plugin; `grep`/`glob` resources are not matched natively                     |
| Hook `exit 2` block             | Plugin `setup` registers `ctx.tool.hook("execute.before")` and throws; the 2.1.4 loader fails that call with the message |
| Outside-project writes prompt   | `external_directory` asks for reads as well as writes; managed install and temp directories are allowed                  |

Verified against the OpenCode v2 docs and the locally installed v2.1.4 binary;
no live OpenCode session has been run by this repository's checks. Before relying
on the plugin or the permission translation, confirm in a real session that a
`.env` read is refused, a plugin throw blocks a shell call, and the model-facing
tool name for a shell command is `shell` or `bash` (the plugin accepts both).

## Kernel and skills

Claude Code loads `~/.claude/CLAUDE.md` and discovers `skills/b-*/SKILL.md`.
The main session reads one skill before acting or invokes `/b-<name>`.
`skills/registry.yaml` and `skills/*/prompt.md` are canonical;
`tooling/generate/registry_sync.py` generates `SKILL.md`, `claude/agents/*.md`,
the kernel's generated blocks, and `claude/configs/settings.template.json`.
Explicit-request skills (`b-commit`, `b-pr`) route only on explicit
user request and stay model-invocable.

The four specialists are `b-planner`, `b-researcher`, `b-debugger`, and
`b-auditor`. Their tool lists omit `Edit`, `Write`, `NotebookEdit`, and nested
delegation and carry only read-only MCP tools (plus three bounded Firecrawl
tools for `b-researcher`). Read-only behavior is instructed, not enforced by a
child-specific permission block: shell access can still mutate state. Delegated
skills never run in the main session; the generated `Delegation boundary` and
the kernel carry this, so a missing subagent is reported instead of bypassed. A
child result is evidence, not authorization. Claude Code models are Anthropic
aliases from the registry's `model` field. OpenCode uses the separate optional
`opencode_model` field (`provider/model#variant`); omitting it inherits the
session model. Current OpenCode defaults are:

| Specialist     | Model                | Effort  |
| -------------- | -------------------- | ------- |
| `b-planner`    | `openai/gpt-6.1-sol` | `xhigh` |
| `b-researcher` | `openai/gpt-6-luna`  | `high`  |
| `b-debugger`   | `openai/gpt-6.1-sol` | `xhigh` |
| `b-auditor`    | `openai/gpt-6.1-sol` | `xhigh` |

Model and variant syntax follows the [OpenCode V2 agent guide](https://opencode.ai/v2/docs/agents#model).

## Review gate

`b-review` runs in the main session. Codex is the independent reviewer through
the [`openai/codex-plugin-cc`](https://github.com/openai/codex-plugin-cc)
plugin, which you install yourself:

```text
/plugin marketplace add openai/codex-plugin-cc
/plugin install codex@openai-codex
/codex:setup
```

Then sign in to Codex and keep the plugin's review gate (a Stop hook) disabled.
The gate sequence is:

1. Freeze the candidate: `node ~/.claude/b-agentic/bin/b-candidate-snapshot.mjs`
   gives HEAD, SHA-256 digests of the staged and unstaged binary diffs, sorted
   untracked paths with type and content digest, and one `fingerprint` (F0). It
   covers the whole repository, lists protected paths and submodules without
   hashing or diffing them, excludes git-ignored files unless named with
   `--include-ignored`, and refuses when a repository clean/process filter would
   run or the repository is a partial clone. Exit 0 is complete, 3 incomplete,
   2 refused.
2. Early preflight: `node ~/.claude/b-agentic/hooks/b-codex-guard.mjs --check` refuses
   when a likely-secret path is tracked, staged, or untracked-and-not-ignored,
   when a submodule or embedded repository hides paths, or when the repository
   has no standing approval. Approve once per repository with `--approve` after
   the user agrees to send it to Codex (OpenAI); `--revoke` withdraws it. The
   guard hook asks for a native confirmation of any Bash command that records
   the approval, points `B_AGENTIC_STATE_DIR` at another store, or writes
   `codex-approved-repos.json` (a tripwire, not a boundary).
3. Run the gate with the wrapper, from the repository, with nothing editing:
   `node ~/.claude/b-agentic/bin/b-codex-review.mjs --scope working-tree --round
<n> --focus-file <path>` (or `--base <ref>` instead of `--scope working-tree`
   for committed changes since that ref; `--kind native` for the plugin's
   focus-less review; `--include-ignored <path>` as at step 1). The wrapper
   reruns the secret and approval gate, freezes the candidate (`f0`), finds the
   plugin's `codex-companion.mjs` under `~/.claude/plugins` (or
   `B_AGENTIC_CODEX_COMPANION`), runs the review in the foreground with an
   argument vector, freezes again (`f1`), and maps the result. It prints JSON:
   `f0`, `f1`, `unchanged`, `timed_out`, `truncated`, the raw plugin output, and
   `mapped`. Exit 0 is a completed review. Exit 3 is a void one: the candidate
   changed or could not be re-snapshotted, the run hit `--timeout-minutes` (30 by
   default, at most 35791; stopped with SIGTERM, then SIGKILL after
   `--kill-grace-seconds`, and its pipes closed by the wrapper if a descendant
   still holds them) or
   the 8 MB output cap, or the result was unmappable or finding-less. Exit 2 is a
   refusal or failure, including an incomplete snapshot before the plugin runs
   and a non-zero plugin exit. A run that was cut short is never mapped, whatever
   status it exited with. Claude Code kills a foreground Bash command after at
   most 10 minutes, so main launches the wrapper as a background command
   (`run_in_background`) and waits for its completion notification, editing
   nothing; the wrapper's own timeout then decides a long run.
4. Main checks that `f0` equals the step-1 fingerprint and `unchanged` is true,
   and recomputes the fingerprint itself; a difference voids the review.
5. `mapped` carries finding IDs `R<round>-<n>` and a provisional verdict (the
   same mapping `b-codex-verdict.mjs` applies to saved output). Main classifies
   against the blocker taxonomy and owns the final `Verdict:` line.

The `b-codex-guard` PreToolUse hook is a tripwire for accidental direct calls to
the plugin script, not the boundary: it applies the same checks to plain
spellings and refuses background or implicit-target reviews, but deliberately
obfuscated spellings (ANSI-C quoting, brace or glob expansion, names built at run
time) are out of scope.

Codex's read-only sandbox can read every workspace file and Codex has no ignore
mechanism, so ignored secret files remain an accepted residual risk. Review never
commits or pushes. Plugin command syntax and result shape come from its
documentation and are not exercised live by this repository's checks.

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
`b-path-guard`, `b-codex-guard`, and `b-clickup-guard` run before tools (`b-clickup-guard` asks before an
auto-approved ClickUp `createTask` or `updateTask` whose markdown references an image other than an
existing ClickUp attachment URL, since the MCP uploads local and downloaded images); `b-verify-gate` tracks
edits and, when the main session edited a non-prose file after its last non-inspection shell
command, blocks the first stop once with the verify and review reminder.
Claude Code prompts for outside-project writes instead of denying them. These
rules are not a process or filesystem sandbox; shell indirection and MCP
arguments they cannot see remain residual risks (only `b-clickup-guard` inspects
ClickUp task arguments). The kernel additionally
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
workspace, so every read is `conditional-read` (allowed in the main session,
never granted to the specialists) and every write asks. Excalidraw's
`create_view` and draw.io's `open_drawio_*` ask on every call and send diagram
text to a hosted endpoint or open the draw.io web editor. draw.io runs
`bunx @drawio/mcp@1.6.3` with `DRAWIO_ICON_SERVICE_URL=off`; the pin freezes only
the top-level package, and the package runs unsandboxed with your permissions.
`list_pages` and `get_page` are deliberately unclassified so they keep the
approval prompt.

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
policy and routing checks, the hook and verdict-mapper probe
(`tests/hooks/hooks-probe.sh`), and the snapshot CLI probe
(`tests/snapshot/cli-probe.sh`). `--release` (CI) adds the sandbox installer
probe (`tests/install/claude-install-probe.sh`) and the RTK readiness check. None
needs Claude Code, Codex, credentials, or a network.

`skills/` and `references/` hold canonical workflow guidance; `claude/` holds
generated specialists and settings plus the hooks, CLIs, and MCP templates;
`tooling/generate/`, `tooling/install/`, and `tooling/validate/` own
generation, lifecycle, and static checks; `tests/` covers behavior, hooks,
snapshots, and the installer. See the [ADR-001 design record](docs/decisions/ADR-001-b-agentic-design-record.md).
