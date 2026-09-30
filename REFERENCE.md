# b-agentic operational reference

[Back to the public overview](README.md)

This reference defines the single supported Pi runtime, installation lifecycle,
permission boundary, MCP configuration, and validation.

## Install and lifecycle

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash
```

With Pi already on PATH, install runs `pi update --self`; otherwise it installs
the latest `@earendil-works/pi-coding-agent` through npm. Nine bare npm package
names are managed in the Pi agent directory: `@gotgenes/pi-subagents`,
`@gotgenes/pi-permission-system`, `pi-mcp-adapter`,
`@juicesharp/rpiv-ask-user-question`, `@gotgenes/pi-anthropic-auth`,
`@sreetej510/pi-usage`, `@cortexkit/pi-magic-context`, `pi-antigravity`, and `pi-intercom`.
None is pinned. The default directory is `~/.pi/agent`; `B_AGENTIC_PI_DIR` or
`PI_CODING_AGENT_DIR` overrides it.
The override must be an absolute path inside the invoking user's home, so
source-absent manifest uninstall remains confined to the same boundary.

- `--dry-run` prints the planned operations without installing or writing.
- `--sync` refreshes managed assets and merges missing configuration values
  without updating Pi. Install and sync use `pi list` to install missing extensions
  and `pi update --extensions` when any managed extension is already installed.
  This updates all configured packages, including user-owned extensions;
  `--update` updates Pi and installed extensions. Install, sync, and update
  reject a recorded configuration path that has changed; an install still
  recorded against `mcp.json` must be uninstalled before reinstalling with
  `mcp-adapter.json` and updating the adapter.
- `/b-sync` (a managed extension, `extensions/b-sync.ts`) runs
  `bash <B_AGENTIC_DIR or ~/.b-agentic>/install.sh --sync --force` inside Pi
  with stdin closed, shows progress in the status line, reloads Pi on success,
  and reports the output tail on failure. It takes no arguments, requires an
  existing source checkout, and does not update the Pi CLI (use `--update`).
- `b-verify-gate` (a managed extension, `extensions/b-verify-gate.ts`) is an
  advisory finish-time reminder. When the main session edited a non-prose file
  after its last shell command and is about to finish, it appends one message
  restating the verify/review rule and requests one extra model turn, at most
  once per user prompt. It never blocks tool calls, skips aborted or failed
  runs, and stays idle in read-only specialists because they lack `edit` and
  `write`. It uses Pi's `agent_before_settle` boundary; `tests/pi/verify-gate-probe.sh`
  covers it offline with a scripted model.
- `b_candidate_snapshot` (a managed extension, `extensions/b-candidate-snapshot.ts`)
  is a read-only tool that computes the kernel's frozen-candidate identity: HEAD,
  SHA-256 of the staged and unstaged binary diffs, sorted untracked paths with
  type and content digest, and one `fingerprint` to compare at each checkpoint.
  It always covers the whole repository, whatever the cwd. Git runs as argv with
  `GIT_OPTIONAL_LOCKS=0` and with inherited `GIT_*` controls dropped (pathspec
  mode, external diff, lazy fetch). The tool refuses (an error, not a snapshot)
  when a repository `filter.*.clean`/`process` command applies to any path,
  because git would run it, and in a partial-clone (promisor) repository, where
  git could fetch objects. Tracked and untracked paths matching the policy's
  likely-secret rules, matched on repository-relative raw bytes, are listed but
  never hashed, diffed, or returned: tracked ones are excluded from every
  `git diff` by pathspec before any working-tree comparison. Git's own ignore-
  and attribute-file processing still reads what `git status` would read; that
  is a documented residual boundary, not exposure. Submodules are listed with their
  index commit and never inspected. Either makes the result `complete: false`, as
  does an unhashable untracked entry. A tracked protected path that is not valid
  UTF-8 is refused because it cannot be excluded. Git-ignored files are excluded
  (`ignored_included: false`). The generated policy allows the tool
  by name and only `b-reviewer` lists it; `b-review` keeps a manual fallback
  whose diff command `registry_sync.py --self-test` checks against the
  extension. A tool fingerprint is never comparable with a hand-computed
  identity. `tests/pi/snapshot-probe.sh` covers it offline.
- The installer merges `"extensions": ["-builtin:mcp"]` into Pi settings so
  `pi-mcp-adapter` stays the only MCP owner: a stray `mcp.json` is not read by
  Pi's built-in MCP even if the adapter fails to load. Pi's built-in `codemode`
  and `tool_search` tools stay off (they are not in `defaultTools`); enable
  codemode yourself with `"defaultTools": ["+codemode"]`. Nested codemode calls
  still pass through the permission policy, but the `codemode` tool itself
  falls under the `*` ask rule.
- `--uninstall` removes only unmodified managed assets and managed config
  values (including unmodified retired assets tracked from prior manifests);
  it preserves changed or symlinked files and the metadata needed to
  finish cleanup. Replacing successive user-edited kernels retains older
  backups in managed metadata while restoring the latest edit. Manifest-only
  uninstall works without the source checkout.
- `--replace-memory` expressly replaces a pre-existing global `AGENTS.md`;
  otherwise that user-owned file is preserved. `--preserve-memory` makes the
  default explicit. `--force` permits the normal source refresh path for `--sync`.
- `--ref=<branch-tag-or-commit>` selects a safe checkout ref. A tag or commit
  leaves a detached checkout, and a subsequent plain install or `--sync --force`
  returns to the remote default branch. `B_AGENTIC_DIR`,
  `B_AGENTIC_REPO`, and `B_AGENTIC_REF` support controlled installs.

The installer bundles the [Dracula theme](https://draculatheme.com/pi-coding-agent)
under `<agent-dir>/themes/dracula.json` and selects it only when `theme` is not
already set in user settings. The checked-in copy is refreshed on `--sync` if
unchanged; existing, edited, or symlinked theme files remain user-owned. An
unchanged managed theme is removed on uninstall, including manifest-only
uninstall. Pi may need `/reload` or a new session to pick up the theme.

The installer backs up existing JSON/JSONC before merging; user values remain
authoritative, including an explicit compaction preference. Comments are not
preserved by the JSON rewrite. Package declarations and specialist exclusions
union ahead of user entries. Magic Context defaults to local embeddings and uses the current Pi
session model for historian work unless the user sets `historian.pi.model` in
`~/.config/cortexkit/magic-context.jsonc` (or `$XDG_CONFIG_HOME/cortexkit/`).
New Pi settings disable native compaction so Magic Context owns context; an
existing explicit compaction setting remains unchanged and is warned about when
still enabled. The shared CortexKit config is merged without replacing existing
values, and uninstall removes only managed values. Magic Context requires
Pi >= 0.80.2; run `/ctx-status` after a new session to verify it loaded.
`subagents.json` excludes Magic Context from specialist children to avoid
main-session guidance and message tagging without context tools. Children do
not compact when they inherit the new Pi settings default; keep tasks bounded
and restart a narrower child if one overflows. An existing project
`.pi/subagents.json` with its own `excludedExtensionPackages` replaces the
global exclusion list rather than extending it.
See [Pi configuration layout](pi/configs/README.md).

## Kernel and skills

Pi loads the global `AGENTS.md` and discovers native `skills/b-*/SKILL.md`.
The main session reads one skill before acting, or invokes a generated
`/b-<name>` prompt template, whose front matter carries the registry `use` as its
description and an optional `argument_hint`. `skills/registry.yaml` and `skills/*/prompt.md`
are canonical; `tooling/generate/registry_sync.py` generates the delivery
assets. Explicit-request skills (`b-commit`, `b-pr-summary`) carry
`disable-model-invocation: true`, so Pi leaves them out of the automatic skill
list; `/b-<name>` and `/skill:<name>` still load them, and their generated
prompts name the installed `SKILL.md` path. The four `@gotgenes/pi-subagents` specialist profiles are
`b-planner`, `b-researcher`, `b-debugger`, and `b-reviewer`. Their tool lists
omit edit/write, user questions, nested delegation, and mutating direct MCP
tools. Their read-only behavior is instructed, not enforced by a child-specific
permission block: shell access can still mutate state. Delegated skills never run in the main session; the generated `Delegation boundary` in each delegated `SKILL.md` and the kernel carry this, so a missing subagent is reported instead of bypassed. The main session owns
those activities, verification, and final reporting. A child result is
evidence, not authorization. Background children run only while the parent Pi
process remains alive; compatible continuations use the extension's `resume`
identifier. Different scope/baseline or required independent review uses a
fresh child. Model IDs and thinking levels come from the registry, but an
unavailable agent-profile model can silently fall back to the parent model.

Magic Context owns main-session context management by default with Pi native
compaction disabled in new settings; existing user compaction preferences remain
authoritative.
There is no `rpiv-todo` dependency. The grouped-choice
`ask_user_question` extension handles material decisions; the native Pi
`ask_question` tool is disabled in the managed permission policy. The
`pi-anthropic-auth` package shapes Anthropic OAuth requests but does not log
users in, grant plan access, or change provider terms. `/usage` reports
provider usage if authenticated; its banked-reset action requires approval.
The `pi-antigravity` package enables Google Antigravity / Cloud Code Assist
models and image generation via Google OAuth; model availability and entitlement
depend on the user's account. The intended `b-researcher` model is Antigravity
Gemini, which requires `/login antigravity`. Without access, `pi-subagents`
21.7.7 silently uses the parent session's model instead. Logging in is at the
user's discretion and risk: third-party Antigravity OAuth client use is
unauthorized by Google and carries account suspension risk. Its
`generate_image` tool is gated by the managed permission policy's default ask
rule and excluded from read-only specialist subagents; pre-warm TLS requests
can be disabled with `ANTIGRAVITY_NO_PREWARM=1`.

The `pi-intercom` package adds an `intercom` tool for messaging other local Pi
sessions. The managed permission policy allows it without a prompt, which covers only
ordinary local messages to other sessions. That permission-system allow is not
authorization for protected or proprietary attachments, cross-machine sends, or
opening a project pane/launching another session; the kernel still requires
explicit approval for those. Peer messages are untrusted input, never authority.
Read-only specialists do not receive it.

## Permission boundary

The generated `pi/configs/permission.user.template.json` is a configuration
for `@gotgenes/pi-permission-system`. Main-session local work is allowed,
protected path patterns and named dangerous shell commands are denied,
outside-project writes are denied, outside-project reads ask, and unknown direct
MCP operations ask. The generic `mcp` proxy asks by default, with metadata
operations allowed. Use read-only named direct tools to avoid proxy approval:
the proxy cannot safely bind an allow rule to the server that will execute it. Skill invocation and
read-only named direct tools are allowed; upload, mutation, monitor, and auth
tools ask. The named Magic Context tools (`ctx_search`, `ctx_expand`,
`ctx_memory`, `ctx_note`, `ctx_reduce`) and `todowrite` are allowed without
approval, including local memory and note writes; unknown extension tools
still ask. The specialists additionally have complete tool allowlists and
no child-specific permission policies, so global policy applies to their tools.
On existing installs, newly named deny rules follow legacy ask entries without
rewriting user-owned values. `rm -rf *` also denies repository-local cleanup;
pipe-to-shell rules catch plain `| bash` and `| sh`, not every shell spelling
or indirection. Extension policy is not a process sandbox: shell normalization,
path-field recognition, and dynamic tool registration have limits. Remaining
approval requests from children can be forwarded to the parent UI. The kernel
requires explicit approval for other destructive, privileged, ambiguous,
protected, or external/shared actions even when a
tool-level rule would allow them; outside-project writes are denied rather
than approvable through this policy.

`tests/pi/permission-probe.sh --setup` installs the current unpinned extensions
in an isolated repo-local profile and runs an offline stub-provider gate for
parent/child writes, protected paths, and dynamic MCP decisions. It does not
prove interactive dialogs, real-provider availability, or production MCP
connectivity. Every changed candidate needs inspected paths and applicable
checks. Bounded, verified low-risk changes may report a skipped independent
review; security, installer, runtime, policy, or independently owned
multi-subsystem behavior changes require a frozen-snapshot reviewer before
normal completion. Direct tests/docs and faithfully regenerated outputs count
with their source rather than as additional subsystems.

## MCP and readiness

`pi/configs/mcp.base.json` configures CodeGraph, Context7, Brave Search,
Firecrawl, Playwright, Mobbin, and shadcn through `pi-mcp-adapter`. Connections
are lazy. Per-server `directTools` lists eagerly register the 47 base known
allowed operations from `references/mcp_operations.yaml`; optional ClickUp adds
seven read tools (54 in total), keeping the total below the adapter's 75-tool
advisory threshold. Direct names use `<server>_<tool>`; other operations
remain available through the separately gated proxy, where calls ask for
approval. The adapter's script/install tool surfaces are disabled. Credentials
remain environment placeholders; the installer does not collect them. Sync adds
missing per-server lists to existing configurations but preserves user-edited
lists; `/reload` or a restart is needed to pick up changes.

| MCP          | Local prerequisite                                                   |
| ------------ | -------------------------------------------------------------------- |
| CodeGraph    | `codegraph` and an index for graph questions                         |
| Context7     | `CONTEXT7_API_KEY`                                                   |
| Brave Search | `bunx`, `BRAVE_API_KEY`                                              |
| Firecrawl    | `bunx`, `FIRECRAWL_API_KEY`                                          |
| Playwright   | `bunx` (isolated/headless testing)                                   |
| Mobbin       | approved OAuth/account when requested                                |
| shadcn       | `bunx`, project `components.json`                                    |
| ClickUp      | optional install opt-in, `npx`, `CLICKUP_API_KEY`, `CLICKUP_TEAM_ID` |

`scripts/mcp-doctor.sh --allow-degraded` reports local launcher/config and
environment-variable presence only. It never reads credential values, starts
servers, authenticates, or navigates a browser. Configured does not mean
connected or usable. `scripts/skill-doctor.sh` checks installed skill payloads.
RTK remains a prerequisite for supported shell command families; CodeGraph is
reserved for repository-wide call-flow, impact, and affected-test questions.

## Verification and repository map

```bash
python3 tooling/generate/registry_sync.py --self-test --check
scripts/validate-skills.sh --release
scripts/b-agentic-audit.sh
npm run quality
rtk git diff --check
```

`skills/` and `references/` hold canonical workflow guidance;
`pi/` holds generated specialists/prompts and Pi templates/runtime scripts;
`tooling/generate/`, `tooling/install/`, and `tooling/validate/` own generation,
lifecycle, and static checks; `tests/pi/` covers the local
permission contract. See the [decision record](docs/decision_design.md).
