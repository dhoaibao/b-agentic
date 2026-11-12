# b-agentic operational reference

[Back to the public overview](README.md)

This reference defines the one supported runtime, Claude Code, with Codex as the
independent reviewer and the read-only `b-reviewer` subagent as its fallback
([ADR-008](docs/decisions/ADR-008-claude-code-only.md),
[ADR-003](docs/decisions/ADR-003-subagent-review-gate.md),
[ADR-007](docs/decisions/ADR-007-codex-first-review-gate.md)).
It covers installation, the permission boundary, the review gate, MCP
configuration, and validation. The earlier Pi runtime (last commit `ac38e4a`) and
the OpenCode runtime ([ADR-008](docs/decisions/ADR-008-claude-code-only.md)) were
removed and are not maintained here.

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
- On a terminal the installer shows a step timeline, a summary box, and asks before
  writing. Questions are read from `/dev/tty`, so they work when piped. `-y` /
  `--yes`, `--dry-run`, `--uninstall`, or a non-terminal stdout keep plain output
  and the defaults; `NO_COLOR` disables color. Answering No leaves the
  configuration untouched (`~/.claude` and `~/.claude.json`). A piped run has already
  cloned or updated the source checkout by then, because the summary needs it.
- The kernel's "Peer agent messaging" section applies only when the user asks agents to talk to each other and adds no other rules: `herdr` skill under `HERDR_ENV=1`, otherwise `hc --skill` if `hc` is on `PATH`.
- Optional components (`optional_components` in `skills/registry.yaml`: `datagrip`,
  `excalidraw`, `drawio`) are installed only after a choice. Each is its skill, its kernel routing
  line, its `mcp__<server>__*` permission rules, and its MCP server
  entry (DataGrip's entry stays IDE-managed, so `datagrip` covers only the skill, routing line, and
  rules). Deselecting also drops lines marked `<!-- requires: b-x -->` from installed skills, so none points to an absent sibling; a full install keeps them byte for byte. A terminal shows a checkbox list before the summary: nothing is checked on a fresh
  install, and an existing install's recorded choice is pre-checked, so Enter keeps it. `--with=ID[,ID]` and
  `--without=ID[,ID]` (additive, repeatable) answer non-interactively and skip the list. With `-y`,
  `--dry-run`, or no terminal, the choice recorded in the manifest is reused and a fresh install selects
  none. A manifest that predates the feature is treated as selected for each component it already owns.
  Deselecting a component removes only its recorded, unmodified skill, `allow` rules, and server (a modified
  one is kept with a warning); its `ask` and `deny` rules stay, so a server that is still configured keeps its
  prompts and denials. Neither flag combines with `--uninstall`.
- `--statusline-only` installs `b-agentic/bin/b-statusline.mjs` and the `statusLine`
  entry in `settings.json` and nothing else: no skills, agents, hooks, kernel block, permissions, MCP
  servers, or optional components. An existing `statusLine` is kept with a warning, as in a full install.
  The manifest records `"scope": "statusline"`; a plain `--uninstall` removes exactly that, and a later full
  install upgrades it in place (dropping the scope). It is refused over a full install, and cannot combine with
  `--with`, `--without`, or `--uninstall`.
- `--update` fast-forwards the checkout (`--ref=<tag-branch-or-commit>` checks
  out a ref) and then syncs. A plain run is already idempotent: unchanged
  inputs write nothing.
- `--force` replaces a managed file you modified, or a same-named file b-agentic
  did not install, after a backup. Without it such files are kept with a warning.
- `--uninstall` removes only recorded, unmodified assets and entries and keeps
  `~/.claude/b-agentic/backups`.
- `--runtime=claude` is accepted as a no-op; any other `--runtime` value is refused
  ([ADR-008](docs/decisions/ADR-008-claude-code-only.md)).
- Only `~/.claude` is supported for Claude Code. A different `CLAUDE_CONFIG_DIR`
  is refused because the managed hooks, agents, and instructions refer to that path.

What it manages, all recorded in `~/.claude/b-agentic/install.json`:

| Asset                              | Installed path                                                                       |
| ---------------------------------- | ------------------------------------------------------------------------------------ |
| Skills (also `/b-<name>` commands) | `skills/b-*/SKILL.md`                                                                |
| Specialists                        | `agents/b-*.md`                                                                      |
| Hooks and CLIs                     | `b-agentic/hooks/*.mjs`, `b-agentic/bin/*.mjs`, `b-agentic/bin/*.py`                 |
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
`codegraph`, `bunx`, `claude`, and `codex` for the optional Codex gate) and never runs vendor installers; see
[install prerequisites](docs/runbooks/install-prerequisites.md) for the manual
steps. The Codex review gate on Claude Code needs the `codex` CLI, the
`openai/codex-plugin-cc` plugin, and a Codex login, which the installer prints but
never runs; without them `b-review` falls back to the `b-reviewer` subagent, which needs
none of these.

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

0. Probe the plugin: `node ~/.claude/b-agentic/bin/b-codex-review.mjs --available`
   only looks for the plugin script and runs nothing: exit 0 means found, exit 4
   (`status: unavailable`) means Codex cannot run, so main skips steps 2 and 3,
   never asks for the OpenAI approval, and goes straight to the `b-reviewer`
   fallback. Exit 2 means a broken `B_AGENTIC_CODEX_COMPANION` override and is
   reported as a refusal. The probe cannot tell whether you are signed in or have
   quota left; those failures still surface as exit 4 from the real run at step 3.
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
2. Early preflight: `node ~/.claude/b-agentic/hooks/b-codex-guard.mjs --check
[--base <ref>]` refuses when a likely-secret path is tracked, staged, or
   untracked-and-not-ignored, when a submodule or embedded repository hides
   paths, when an untracked non-ignored symlink exists (the plugin follows it
   and would send its target; stage, ignore, or remove it), when a `--base` range
   (merge-base..HEAD and every commit inside it) touches a likely-secret path
   or a submodule, or when the repository has no standing approval. Approve once per repository with `--approve` after
   the user agrees to send it to Codex (OpenAI); `--revoke` withdraws it. The
   guard hook asks for a native confirmation of any Bash command that records
   the approval, points `B_AGENTIC_STATE_DIR` at another store, or writes
   `codex-approved-repos.json` (a tripwire, not a boundary).
3. Run the gate with the wrapper, from the repository, with nothing editing:
   `node ~/.claude/b-agentic/bin/b-codex-review.mjs --scope working-tree --round
<n> --focus-file <path>` (or `--base <ref>` instead of `--scope working-tree`
   for committed changes since that ref; `--include-ignored <path>` as at step
   1; `--kind native` is refused because its output has no verdict contract).
   The wrapper reruns the secret and approval gate, resolves a `--base` once and
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
choose it after a refused (exit 2) or void (exit 3) Codex run or when the
repository is not approved for Codex. A refusal or void run never falls back on
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
   `NEEDS FIXES` rounds.

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
`b-path-guard` hook applies the exact path rules to the file tools (including the
`*.env.example` allowance that deny rules cannot express). Hooks:
`b-path-guard` runs before file tools; `b-codex-guard` is a tripwire on Bash for direct calls to the Codex plugin (see [Review gate](#review-gate)); `b-verify-gate` tracks
edits and, when the main session edited a non-prose file after its last non-inspection shell
command, blocks the first stop once with the verify and review reminder (which also asks the agent to map each confirmed `AC-n` criterion to its check result or a stated gap).
`b-spec-context` is a `SessionStart` hook matched on `compact` only: after compaction it lists, as plain facts, the paths of up to five `docs/specs/*.md`
files whose first 40 lines carry a `Status: approved` line, newest first, in at most 2,000 characters. It injects no file content, never writes, skips symlinks,
likely-secret names, and unusual file names, sets no `onFailure`, and prints nothing (exit 0) when `docs/specs/` is absent, no spec is approved, or anything fails.
Claude Code also fires it when a subagent compacts and sends no `agent_id` to tell the two apart; this is accepted because the output is a short pointer.
Whether the pointer reaches the model after a live `/compact` is not covered by the offline probe (Claude Code issue #15174 reported it missing), so confirm it by hand.
`b-run-context` is a second `SessionStart` hook, matched on `startup|resume|clear|compact`: when `.b-agentic/active` names a run whose `state.json` is not finished, it prints one line with the run id and phase. It is a pointer only (an explicit `/b-flow resume` is the only way a run continues), reads with `O_NOFOLLOW`, never writes, sets no `onFailure`, and prints nothing on any error. Claude Code drops `SessionStart` context intermittently for `startup` and `fork` sources (issues #10373 and #93458), so the pointer is best effort; the run files are the record.
The file-tool
guard sets `onFailure: "block"` (Claude Code 2.1.295 or later), so a guard that crashes, times out, or
cannot start blocks the call, and malformed input still fails open by design. To recover from a
guard that fails closed (for example a missing `node` or hook script), repair or reinstall: Bash is
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
installs nor verifies the sandbox, and whether it leaves the Codex review gate and the Node
hooks working is unverified: after enabling it, run
`node ~/.claude/b-agentic/bin/b-codex-review.mjs --available` and one review round. The
kernel additionally
requires approval for other destructive, privileged, ambiguous, protected, or
external/shared actions.

## MCP and readiness

`claude/configs/mcp.base.json` configures CodeGraph, Context7, Brave Search,
Firecrawl, Playwright, Notion, shadcn, and the optional Excalidraw and draw.io entries
(installed only when selected, see the install options). Tools are addressed as
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
(`tests/hooks/hooks-probe.sh`), the snapshot CLI probe
(`tests/snapshot/cli-probe.sh`), the status line probe
(`tests/statusline/statusline-probe.sh`), and the runtime instruction parity check
(`tooling/validate/runtime_parity.py`). `--release` (CI) adds the sandbox installer
probe (`tests/install/claude-install-probe.sh`) and the RTK readiness check. None
needs Claude Code, credentials, or a network.

`skills/` and `references/` hold canonical workflow guidance; `claude/` holds
generated specialists and settings plus the hooks, CLIs, and MCP templates;
`tooling/generate/`, `tooling/install/`, and `tooling/validate/` own
generation, lifecycle, and static checks; `tests/` covers behavior, hooks,
snapshots, and the installer. See the [ADR-001 design record](docs/decisions/ADR-001-b-agentic-design-record.md).

## `b-flow` runs

`/b-flow <goal>` runs one request from clarified spec to commit in the main session ([ADR-009](docs/decisions/ADR-009-b-flow-automatic-run.md)). Clarification and one approval round (spec and `AC-n`, commit consent, branch target, Codex or `b-reviewer`) are the only user interaction; then it implements, verifies, reviews, fixes in-scope blockers, runs QA, and commits under the recorded consent. It never pushes or opens a PR, and it stops and asks after 3 failed verifies, 3 consecutive `NEEDS FIXES`, or 3 consecutive `QA FAIL`, on a path outside the approved scope, or on a question the approval did not answer.

Run files are untracked, under `.b-agentic/runs/<yyyymmdd-slug>/` at the worktree root (`.b-agentic/.gitignore` is `*`): `spec.md` (the approval; its sha256 is recorded), `plan.md`, `qa.md`, `followups.md`, `state.json` (progress only), and `lock`. `claude/bin/b-state.mjs` is the only writer of state and fails closed: it validates the schema, refuses a symlinked folder, a changed spec, a held lock, or a step whose evidence belongs to another candidate fingerprint (for example `advance commit` without consent or a current QA PASS). `/b-flow resume` runs `b-state.mjs check --takeover`, which re-verifies the repository, branch, spec hash, `HEAD`, and candidate fingerprint; a changed tree voids review and QA evidence and returns the run to `verify`. A `/clear` changes the session id, so a resumed run takes the lock over. State holds no file contents, diffs, command output, or secrets, and is untrusted input to every reader.

The four markdown artifacts have one writer too ([ADR-010](docs/decisions/ADR-010-run-artifact-cli.md)): `python3 -I -B ~/.claude/b-agentic/bin/b_run.py write <spec|plan|qa|followups>` reads JSON on stdin, validates it against `b-agentic/references/artifacts.yaml` (field grammar, enums, limits, one example per kind) and the cross-artifact rules (contiguous `AC-n` and `S-n`, evidence needs a command or a source, plan checks cover every automated command, plan paths inside the spec scope, QA rows matching the spec, no dropped follow-up ids), checks the artifact's phase and the run lock, renders canonical markdown, and records its sha256 and data in `artifacts.json`. `validate` re-renders and compares bytes and refuses unknown files in the run folder; `scope-check` compares changed git paths with the spec scope; `handoff review|qa` renders the review and QA packets. `b-path-guard` refuses native `Edit`, `Write`, and `NotebookEdit` on any `.b-agentic` path, a Bash write is detected rather than prevented, and `b-state` requires valid artifacts, matching spec and plan hashes, approved check commands, and a `qa.md` rewritten in the current QA round before it advances or records.
