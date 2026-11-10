# ADR-001: b-agentic design record

- Status: Accepted
- Date: 2026-08-11
- Supersedes: none

Refinements update this record in place. A reversed decision gets a new ADR
with `Supersedes: ADR-001`, and the superseded area is noted here.

Superseded in part by [ADR-002](ADR-002-dual-runtime-support.md): the
single-runtime statement in Context, the `~/.claude`-only boundary under
"Product boundary and architecture", the second-runtime non-goal under
Consequences, and the Anthropic-models-only statement under "Workflow and skill
design" (OpenCode specialists pin `opencode_model`).

Superseded in part by [ADR-006](ADR-006-retire-clickup-integration.md): the
ClickUp MCP server, skill, and `b-clickup-guard` hook described below are
history; they were removed.

OpenCode was replaced by Codex in [ADR-004](ADR-004-codex-runtime.md) and restored, with Codex removed, in [ADR-005](ADR-005-opencode-restored.md).

Superseded in part by [ADR-003](ADR-003-subagent-review-gate.md): the Codex
review gate (the plugin, the `b-codex-review` wrapper, the `b-codex-verdict`
mapper, the `b-codex-guard` hook that checked direct plugin calls, and the
approval flow they enforced) described in Context, under
"Workflow and skill design", "Safety and approval design", and "Verification and
change discipline", and the Codex prerequisite and plugin-command printing under
"Installation, configuration, and lifecycle". `b-review` now runs in the read-only
`b-reviewer` subagent, which makes five specialists; those passages are kept as
history.

## Context

b-agentic supports one runtime, Claude Code. It ships an always-loaded kernel,
canonical skills, named read-only specialists, managed MCP configuration,
hooks and small CLIs, and a merge-safe installer. Codex, through the
`openai/codex-plugin-cc` plugin, is the independent changed-code reviewer. The
earlier Pi runtime was removed from this repository (its last commit is
`ac38e4a`); an already installed copy keeps working, but nothing here generates,
installs, or tests it.

Evidence: [`references/kernel.template.md`](../../references/kernel.template.md),
[`skills/registry.yaml`](../../skills/registry.yaml), and
[`claude/configs/settings.template.json`](../../claude/configs/settings.template.json).

## Decision

Each area below states what was decided and the evidence that backs it; accepted
residual risks are recorded with the area they belong to.

### Product boundary and architecture

Global assets install under `~/.claude` only: the managed hooks, agents, and
instructions refer to that path, so the installer refuses a different
`CLAUDE_CONFIG_DIR`. Project guidance remains in repository
`AGENTS.md` and `CLAUDE.md`. Canonical policy and skill sources live in
`references/` and `skills/`; the registry generator renders each skill file
(a skill is also its `/b-<name>` command), the five specialist profiles, the
kernel's generated blocks, and the settings template (permissions, hooks, and the status line).
Skills install as bare `~/.claude/skills/b-*`, not as a namespaced plugin.
The kernel lives in a marked block of `~/.claude/CLAUDE.md`. The installer owns
only what its manifest records, and never writes under `~/.pi`.

Evidence: [`install.sh`](../../install.sh),
[`tooling/install/claude_install.py`](../../tooling/install/claude_install.py), and
[`tooling/generate/registry_sync.py`](../../tooling/generate/registry_sync.py).

### Workflow and skill design

The kernel selects one skill at a time. Claude Code discovers skill
descriptors and runs a skill as `/b-<name>`. Skills marked
`routing.explicit_request` route only on an explicit user request but stay
model-invocable (no `disable-model-invocation`).
Worktree mutation, user interaction, verification, and reporting stay in the
main session. b-agentic generates five named read-only specialists for the
`Agent` tool: `b-planner`, `b-researcher`, `b-debugger`, `b-auditor`, and `b-reviewer`. Each
child reads its named skill, has a tool allowlist without `Edit`, `Write`,
`NotebookEdit`, or nested delegation, and returns the skill's own output
format. Read-only shell behavior is instructed, not enforced by a child-specific
permission policy.
Delegated skills never run in the main session, including for quick lookups:
the generator writes a `Delegation boundary` (with the parent-owned evidence
handoff and `$ARGUMENTS`) into each delegated skill file, and the kernel repeats
the rule. An unavailable subagent is reported, not replaced by self-execution.
Claude Code starts subagents in the background by default (fork mode is on
unless `CLAUDE_CODE_FORK_SUBAGENT=0`), so work that gates action waits for the
completion notification; work the main session continues without is independent
and read-only. `b-review` is a main-session skill: it freezes the candidate,
runs the Codex gate, and classifies the result. `b-qa` is an optional
main-session acceptance gate after review: it compares the candidate with the
review fingerprint, maps each acceptance criterion to fresh evidence, and ends
with a QA verdict without committing or pushing. It has no specialist, because
Codex already gives review independence, children are read-only and cannot drive
main-session-only browser or dev-server work, and unbounded orchestration is a
non-goal. On Claude Code, specialists run
on Anthropic models only (`opus`, `sonnet`, or `haiku`), so the earlier Gemini
research model is gone.

The kernel's "Peer agent messaging" section applies only when the user asks agents
to talk to each other. It adds no other rules and grants no authority: under
`HERDR_ENV=1` the agent uses the `herdr` skill, otherwise `hc --skill` when `hc` is on
`PATH`, and the two cannot message each other.

Evidence: [`references/kernel.template.md`](../../references/kernel.template.md),
[`skills/registry.yaml`](../../skills/registry.yaml),
[`skills/b-qa/prompt.md`](../../skills/b-qa/prompt.md), and
[`claude/agents/b-researcher.md`](../../claude/agents/b-researcher.md).

### Safety and approval design

The generated settings template allows repository-local tools and named
read-only, conditional-read, and trusted-mutation MCP tools, asks before other
classified mutations, uploads, lifecycle, and auth tools, asks before a `git push` that names its remote and branch and before `gh` commands that change reversible GitHub
state (`gh pr create`, `gh auth switch`, `gh release create`, `gh api` with a body or method flag),
and denies named dangerous commands (`git pull`, `git reset --hard`, `git clean -f`,
`git branch -D`, `rm -rf`, destructive, credential, or code-installing `gh` commands such as
`gh pr merge`, `gh repo delete`/`archive`/`edit`, `gh release delete`, `gh extension install`,
`gh alias set`, `gh auth login`/`token`, and `gh api` with a `DELETE`, `PUT`, or `PATCH` method, force, delete,
mirror, all/branches, prune, `main` or `master`, and destination-less (`git push`, `git push origin`) pushes, privilege escalation, bare
shells) plus unambiguous secret files through `Read(path)` and `Edit(path)` rules
(Claude Code warns about and ignores `Write(path)` rules; an `Edit` rule
covers every built-in file-editing tool). Claude Code deny rules cannot carve out `.env.example`, so the `b-path-guard` PreToolUse hook enforces
the exact path rules (`*.env`, `*.env.*`, `*.pem`, `*credentials.*`,
`*secrets.*`, with `*.env.example` allowed) for the file tools, including the glob a search tool is given (Glob's `pattern`, not Grep's content regex). It
checks the names a call carries, not the files a directory search would visit.
Native Linux and macOS Claude Code builds replace `Glob` and `Grep` with `bfs` and
`ugrep` behind Bash, so there the hook never sees a search; those searches rely on
the kernel's secret-file rule and the Claude Code deny rules, which is an accepted
residual risk (`--tools Grep Glob` restores the dedicated tools). Both PreToolUse
guards set `onFailure: "block"` (Claude Code 2.1.295 or later), so a guard that
crashes, times out, or cannot start blocks the call instead of letting it through;
malformed input still fails open by design. If a guard fails closed (for
example `node` or the hook script is missing), repair or reinstall: Bash is not
guarded and still works. How an older client treats the unknown key is
undocumented.
`b-pr` is the only skill that pushes: on an explicit request it pushes the
current non-default branch with an explicit `origin <branch>` destination and
opens a draft PR, and it never forces, pulls, rebases, or merges. To push as an
account that can write to the repository it may run `gh auth switch` between
accounts already logged in, which changes `gh`'s global active account until it
restores the original; each switch asks, and an interrupted run can leave the
switched account active, an accepted residual risk. Its HTTPS push
runs as `git -c ... push`, which the deny rules match only for force and `main` or
`master` pushes; delete, mirror, all-branch, and prune forms there stay at the ask
prompt as an accepted residual risk. Unlike the
earlier policy, the managed rules neither deny nor prompt for outside-project writes
(bare `Edit`, `Write`, and `Bash` allows); the kernel's approval rule is the control,
and any native prompt comes from Claude Code's built-in protected-path checks, the permission mode, or user settings (refined 2026-11-07). Permission rules are not filesystem or process isolation; shell
indirection and MCP arguments the rules cannot see remain residual risks (the
former ClickUp image exception, checked by `b-clickup-guard`, was removed by ADR-006).
Sending a repository to Codex discloses it to OpenAI, and Codex's read-only
sandbox can read every workspace file; Codex has no ignore mechanism. The
`b-review` therefore runs the gate through one wrapper, `b-codex-review`, whose
checks are code rather than model discipline or shell parsing (the approval they
read is covered below). The wrapper
refuses unless no likely-secret path is tracked, staged, or
untracked-and-not-ignored, no submodule or embedded repository hides paths from
the name scan, no untracked symlink would be followed by the plugin, a `--base`
range (merge-base..HEAD and every commit in it) holds no likely-secret path, and
the user approved sending that repository (a standing,
per-repository approval stored in `~/.claude/b-agentic`). It requires exactly one
explicit target (`--scope working-tree` or `--base <ref>`, resolved once and passed
to the plugin as a commit id), refuses an incomplete
snapshot, freezes the candidate before (`f0`) and after (`f1`) the review and
voids it when they differ, and spawns the plugin script with an argument vector
(no shell, so the focus text is one literal argument), always in the foreground
and from the repository root. Native plugin review is not a gate kind because it
has no verdict contract. Ignored secret files, history outside the reviewed range,
and secrets under innocent names remain accepted residual risks.
The `b-codex-guard` Bash hook is a tripwire for accidental direct calls to the
plugin script, not the boundary: a model or user that deliberately obfuscates the
script name (ANSI-C quoting, brace or glob expansion, names built at run time)
is outside what any hook-side shell parser can promise, and that is documented
rather than chased. For plain spellings it refuses a direct review, `task`, or
other disclosing subcommand unless the repository passes the same checks and the
call has the supported form `node <path>/codex-companion.mjs <subcommand>
[args]`; it joins quotes, escapes, and backslash-newline continuations first,
and refuses wrappers, neighbouring commands, expansions, subshells, comments
hiding options, unsafe redirections, and unreadable input that names the script.
Mentioning the script name in an unrelated command (a commit message, a search)
is refused too; use the `Grep` tool where the build has it, or `Read` the file.
The approval is the one input of those checks that a model could still record:
`b-codex-guard --approve` is a plain shell command and the wrapper reads the
store in-process, where no Bash hook sees it. The same hook therefore puts any
Bash command that records the approval, sets `B_AGENTIC_STATE_DIR` for the guard,
wrapper, or plugin, or names the approval store file under `~/.claude/b-agentic`
to the user as a native `ask` prompt, on top of the `AskUserQuestion` that `b-review`
issues first. This is a tripwire, not a boundary: names built at run time,
another interpreter or a script writing the store, and an exported override
still reach it. Closing that would need the approval kept where the model cannot
write; that is not done and is an accepted residual risk.
The plugin's own Stop-hook review gate stays disabled: it reviews the last answer,
not the frozen candidate, and can loop.
Hook matching the plugin's Bash invocation, deny-rule syntax, and exit-code
behavior follow Claude Code's documented contracts but were not exercised
against a live session; the offline hook probe covers only the scripts.

The `b-verify-gate` hook is an advisory, one-shot reminder, not a boundary: a
PostToolUse hook tracks non-prose edits made after the last shell command that is
not plain read-only inspection (searches, listings, `git status`/`diff`/`log`; an
ambiguous command still counts as a check; a subagent's command, which carries
an `agent_id`, never does), and
the Stop hook blocks the first stop once (exit 2) with the verify and review
rule, never repeating in the same continuation. It fails open on malformed input
or unusable state. Its per-session state lives in a user-owned `0700` directory
under `~/.claude/b-agentic/` (override `B_AGENTIC_GATE_DIR`, separate from the
Codex approval store's `B_AGENTIC_STATE_DIR`), and state files are opened
without following symlinks.

The `b-spec-context` hook keeps user-approved acceptance criteria reachable
across context compaction without storing state: a `SessionStart` hook matched on
`compact` only lists the paths of up to five `docs/specs/*.md` files whose first
40 lines carry a `Status: approved` line (2,000 characters at most, newest
first), as facts rather than instructions, and never injects file content. It
reads only plain regular files, skips symlinks and likely-secret names, sets no
`onFailure`, and exits 0 silently on any error, so it cannot block startup or
compaction. Claude Code also runs it when a subagent compacts (the payload has
no `agent_id`); that residual risk is accepted because the output is a short
pointer. Per the Claude Code hooks reference (v2.1.322), `SessionStart` output on
`compact` is added to the context, but issue #15174 reported otherwise, so a
live check after `/compact` stays a manual acceptance step.

Evidence: [`tooling/generate/registry_sync.py`](../../tooling/generate/registry_sync.py),
the `b-codex-guard` hook script (removed by [ADR-003](ADR-003-subagent-review-gate.md)),
[`claude/hooks/b-verify-gate.mjs`](../../claude/hooks/b-verify-gate.mjs),
[`claude/hooks/b-spec-context.mjs`](../../claude/hooks/b-spec-context.mjs),
[`claude/hooks/b-path-guard.mjs`](../../claude/hooks/b-path-guard.mjs),
the ClickUp guard (removed by [ADR-006](ADR-006-retire-clickup-integration.md)), and
[`tests/hooks/hooks-probe.sh`](../../tests/hooks/hooks-probe.sh).

### MCP and external-evidence design

The ClickUp integration and related safety-hook decision in this section were
superseded by [ADR-006](ADR-006-retire-clickup-integration.md).

Ten base servers are configured in Claude Code's standard `mcpServers` shape:
seven are always installed, and the optional draw.io, Excalidraw, and TablePro
servers are added only after install opt-in. `references/mcp_operations.yaml`
classifies every known tool, and each class maps to an allow or ask rule on
`mcp__<server>__<tool>`; unclassified tools keep Claude Code's approval prompt.
The retired adapter's lazy and search-exposed modes are gone: Claude Code's
built-in tool search defers large tool sets. Notion workspace reads are
`conditional-read` (calendar and contact reads are `private-read`), not
`read-only`, because every `read-only` tool is granted to all five specialists
and a private workspace must not reach children. Specialists name
their tools in `tools:`; `b-researcher` additionally lists three bounded public
Firecrawl tools classified `conditional-read`. Credentials stay environment
references (`${VAR}`), never stored values. Expansion of those references in
the user-scope MCP file is a documented Claude Code behavior that was not
exercised live. `mcp-doctor` checks only local configuration, launcher, and
variable presence and starts no MCP or browser sessions.
Playwright page-driving tools (`browser_navigate`, `browser_tabs`, `browser_click`,
`browser_type`, `browser_evaluate`, `browser_take_screenshot`, and the other
in-page interaction tools) are `trusted-mutation`, run without a prompt by the
user's decision because browser testing is prompt-heavy; `browser_tabs` `new`
and `browser_navigate` can reach any URL, and `browser_evaluate` runs page-context
JavaScript. `browser_file_upload`, `browser_drop`, and `browser_run_code_unsafe`
stay `external-mutation` because they read local files or run MCP-side code.
The auto-allowed Playwright reads and `browser_take_screenshot` accept a `filename`
that the MCP writes inside the workspace, which no permission rule or hook
sees; b-browser forbids that argument (screenshots only under the approved
evidence root), and the prompt-only enforcement is an accepted residual risk.
Unrestricted navigation also reaches localhost and intranet services, and a
prompt-injected page could steer the auto-allowed click, type, and evaluate
tools there; the isolated headless profile limits stored-credential exposure,
and this is accepted as the user's decision. In OpenCode these tools still ask.

MCP tools fall into nine classes in `references/mcp_operations.yaml`: `read-only`
and `conditional-read` (allowed), `trusted-mutation` (allowed by the user's
decision, main session only), and `local-upload`, `private-read`,
`external-mutation`, `monitor-lifecycle`, `local-mutation`, and `auth` (ask). ClickUp `createTask` and
`updateTask` and the Playwright page-driving tools above are the `trusted-mutation`
tools, run without a prompt by the user's decision (the ClickUp passage that follows is
history, removed by ADR-006). The ClickUp MCP reads and uploads a local image path or
`data:` URI and downloads and re-uploads an external image URL named in task
markdown, and no permission rule sees MCP arguments. The `b-clickup-guard`
PreToolUse hook therefore asks whenever `description` or `append_description`
references an image other than an existing `*.clickup-attachments.com` HTTPS URL.
It matches markdown, reference-style, and `<img>` spellings by pattern, so an
unusual spelling can escape it, and it fails open on malformed input. That a hook
`ask` overrides the `allow` rule was not exercised live, and the `b-clickup`
prompt rule against unapproved image references remains the second layer.

Optional components: `b-datagrip`, `b-tablepro`, `b-excalidraw`, `b-drawio` and
their MCP servers, routing lines, and `allow` permission rules are declared under
`optional_components` in `skills/registry.yaml`. Generated assets stay complete;
the installers filter them after an explicit choice (checkbox, `--with`/`--without`),
drop skill lines marked `<!-- requires: b-x -->` whose skill is not installed,
record the choice in the manifest, and remove a deselected component's recorded,
unmodified assets on the next sync. `ask` and `deny` rules always ship, so a server
that stays configured keeps its prompts and denials.

The DataGrip MCP server is IDE-managed: the user enables it in DataGrip and
Claude Code connects to it, so b-agentic ships no template and `mcp_doctor`
treats it as optional. It is never `read-only`, because that class feeds every
specialist profile and database metadata and rows must stay in the main session.
Schema metadata tools are `conditional-read`. Tools that return rows or query
history are `private-read` (ask), SQL execution and cancel are
`external-mutation`, and connection create and edit are `auth`. Permission rules
cannot tell a `SELECT` from a write, so every `execute_sql_query` call asks and
the `b-datagrip` prompt carries the read-only, row-limit, single-statement, and
remote-connection guardrails. No hook inspects the SQL: a pattern match cannot
classify data-modifying CTEs, side-effecting functions, or Redis commands, and
hooks fail open. The server enforces no read-only mode, so a read-only database
user remains the hard control. Neither the approval prompt for DataGrip tools nor
DataGrip's `projectPath` handling is exercised by this repository's checks.

Evidence: [`references/mcp_operations.yaml`](../../references/mcp_operations.yaml),
[`claude/configs/mcp.base.json`](../../claude/configs/mcp.base.json), and
[`tooling/validate/mcp_doctor.py`](../../tooling/validate/mcp_doctor.py).

### Installation, configuration, and lifecycle

`install.sh` installs from the checkout that contains it, or clones to
`~/.b-agentic-claude` when piped (never `~/.b-agentic`, which keeps serving the
frozen Pi installer). It never runs vendor installers: missing `rtk`,
`codegraph`, `bunx`, and `claude` are reported. The installer copies skills, agents,
hooks, CLIs, and references; replaces the kernel block in the user `CLAUDE.md`; merges
permission rules and hook entries into the user settings file (plus the status
line, only when none is configured) and servers into the user MCP file; and records everything in an install manifest. It parses
every user JSON file before the first write, backs up each file it changes,
keeps files the user modified or that it did not install, refuses a symlinked
managed directory or manifest, writes through (never replaces) a symlinked
config file, and is idempotent. Uninstall removes only recorded, unmodified
assets and entries. The MCP file is `~/.claude.json`; Claude Code rewrites it,
so restart Claude Code after an install. The installer plans every change in
memory and refuses on a structural problem (a malformed or wrongly shaped user
file, duplicate or reversed kernel markers, a symlinked managed directory)
before the first write. That preflight covers every destination the run may
touch, including the backups directory, the manifest, and each managed ancestor
directory, and refuses a symlink or a non-directory in the way. It then records
its intent in the manifest as a `pending` section that sits beside the last
committed ownership, so an interrupted run can be finished by a retry or removed
by an uninstall: both recognize the old and the new state, never arbitrary
modified content. Ownership is never inferred from content: a file, hook,
server, or kernel block identical to the managed one is only ours when a
previous run recorded it, and a modified kernel block or hook is kept. The bootstrap script
honors `--dry-run` before cloning or fetching, runs git with its destination
overrides (`GIT_DIR`, `GIT_WORK_TREE`, `GIT_COMMON_DIR`, and similar) cleared,
and refuses to clone or update when the real worktree, git directory, or common
directory is the home directory or lies under `~/.pi`, resolving symlinks.

Evidence: [`install.sh`](../../install.sh),
[`tooling/install/claude_install.py`](../../tooling/install/claude_install.py), and
[`tests/install/claude-install-probe.sh`](../../tests/install/claude-install-probe.sh).

### Verification and change discipline

Canonical sources regenerate before static validation. The suite checks
routing, generated assets, capability and MCP policy, decision traceability,
the hooks and verdict mapper, and the snapshot CLI. Release validation adds the
sandbox installer probe. None of it needs Claude Code, Codex, credentials, or a
network; live provider behavior, approval prompts, and the plugin are separate
evidence, not inferred from static checks.
Every candidate gets an inspected diff and applicable checks. Classify the
final change against the task baseline. Independent review is required by
request or for security/privacy/authority, data integrity, externally consumed
contracts, dependencies/runtime configuration, installer or user-config merge
behavior, approval/safety/delegation/review/commit/routing policy, behavior
across independently owned subsystems, or a concrete risk checks do not cover.
Routine skill-prompt wording is not automatically policy. Direct tests/docs and
faithfully regenerated outputs count with their source. A bounded, clear,
verified low-risk change may skip review with its reason reported. Failed
checks or unexpected paths block completion; ambiguous acceptance goes to the
user.
The gate is the plugin's adversarial review, run by `b-codex-review` in the
foreground while nothing edits. Main launches the wrapper as a harness
background command and waits for it, because the harness kills foreground
commands at 10 minutes, before the wrapper's own timeout can void a run. The
focus text carries acceptance, triggers,
and, for a re-review, prior finding IDs, dispositions, and sweep and check
results; the plugin's threads are ephemeral, so every round is fresh. Main
records the candidate fingerprint at the freeze, requires the wrapper's `f0` to
equal it, and recomputes it after the wrapper returns; any difference voids the
review. `b-codex-verdict` maps the plugin's verdict and
severities to a provisional result: `critical` and `high` findings are
provisional blockers unless disproved with evidence, `medium` and `low` are
follow-ups unless they fall in a blocker class, and `needs-attention` without
findings is void. Main owns the final verdict. `NEEDS FIXES` requires an
evidenced blocker (acceptance, correctness, security/data/contract, check,
snapshot, path, or generated-output class); main fixes blockers as a batch, one
whole defect class at a time, and after 3 consecutive `NEEDS FIXES` rounds asks
the user. Protected paths require permission before content is hashed. The
read-only `b-candidate-snapshot` CLI computes the identity for the whole
repository as one fingerprint, lists protected paths and submodules without
hashing or diffing them, excludes git-ignored files unless named with
`--include-ignored`, treats tracked files hidden by index flags (assume-unchanged,
or skip-worktree while present on disk) as incomplete, and refuses when a
repository filter would run a program or the repository is a partial clone. Without the CLI the wrapper cannot run, so
`b-review` blocks instead of hand-hashing.

Evidence: [`scripts/validate-skills.sh`](../../scripts/validate-skills.sh),
[`tooling/validate/behavior.py`](../../tooling/validate/behavior.py),
and [`claude/bin/b-candidate-snapshot.mjs`](../../claude/bin/b-candidate-snapshot.mjs).

## Consequences

Accepted residual risks are recorded with each decision above. The intentional
non-goals follow.

b-agentic does not maintain a second runtime, custom permission engine,
argument-aware MCP gate, or persistent subagent store. It does not ship themes,
TUI widgets beyond the read-only `b-statusline` status line (refined 2026-11-07),
notifications, a self-updating command, or third-party extension
management; Claude Code's own `AskUserQuestion`, todo list, and compaction cover
what those extensions did. The repository does not promise detached background
work, authenticated MCP or Codex readiness from configuration, containment of
Codex's read access, or unbounded orchestration.

Evidence: [`README.md`](../../README.md),
[`REFERENCE.md`](../../REFERENCE.md), and
[`claude/configs/README.md`](../../claude/configs/README.md).
