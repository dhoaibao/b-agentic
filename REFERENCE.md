# b-agentic operational reference

[Back to the public overview](README.md)

This reference defines the single supported Pi runtime, installation lifecycle,
permission boundary, MCP configuration, and validation.

## Install and lifecycle

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash
```

With Pi already on PATH, install runs `pi update --self`; otherwise it installs
the latest `@earendil-works/pi-coding-agent` through npm. Seven bare npm package
names are managed in the Pi agent directory: `@gotgenes/pi-subagents`,
`@gotgenes/pi-permission-system`, `pi-mcp-adapter`,
`@juicesharp/rpiv-ask-user-question`, `@gotgenes/pi-anthropic-auth`,
`@sreetej510/pi-usage`, and `@cortexkit/pi-magic-context`. None is pinned. The
default directory is `~/.pi/agent`; `B_AGENTIC_PI_DIR` or `PI_CODING_AGENT_DIR` overrides it.
The override must be an absolute path inside the invoking user's home, so
source-absent manifest uninstall remains confined to the same boundary.

- `--dry-run` prints the planned operations without installing or writing.
- `--sync` refreshes managed assets and merges missing configuration values
  without updating Pi. Install and sync use `pi list` to install missing extensions
  and `pi update --extensions` when any managed extension is already installed.
  This updates all configured packages, including user-owned extensions;
  `--update` updates Pi and installed extensions.
- `--uninstall` removes only unmodified managed assets and managed config
  values; it preserves changed or symlinked files and the metadata needed to
  finish cleanup. Replacing successive user-edited kernels retains older
  backups in managed metadata while restoring the latest edit. Manifest-only
  uninstall works without the source checkout.
- `--replace-memory` expressly replaces a pre-existing global `AGENTS.md`;
  otherwise that user-owned file is preserved. `--preserve-memory` makes the
  default explicit. `--force` permits the normal source refresh path.
- `--ref=<branch-tag-or-commit>` selects a safe checkout ref. `B_AGENTIC_DIR`,
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
union ahead of user entries. Existing OpenCode configuration and installation
are never removed or updated. Magic Context defaults to local embeddings and uses the current Pi
session model for historian work unless the user sets `historian.pi.model` in
`~/.config/cortexkit/magic-context.jsonc` (or `$XDG_CONFIG_HOME/cortexkit/`).
New Pi settings disable native compaction so Magic Context owns context; an
existing explicit compaction setting remains unchanged and is warned about when
still enabled. The shared CortexKit config is merged without replacing existing
values, and uninstall removes only managed values. Magic Context requires
Pi >= 0.74.0; run `/ctx-status` after a new session to verify it loaded.
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
`/b-<name>` prompt template. `skills/registry.yaml` and `skills/*/prompt.md`
are canonical; `tooling/generate/registry_sync.py` generates the delivery
assets. The four `@gotgenes/pi-subagents` specialist profiles are
`b-planner`, `b-researcher`, `b-debugger`, and `b-reviewer`. Their tool lists
omit edit/write, user questions, nested delegation, and mutating direct MCP
tools. Their read-only behavior is instructed, not enforced by a child-specific
permission block: shell access can still mutate state. The main session owns
those activities, verification, and final reporting. A child result is
evidence, not authorization. Background children run only while the parent Pi
process remains alive; compatible continuations use the extension's `resume`
identifier. Different scope/baseline or required independent review uses a
fresh child. Model IDs and thinking levels come from the registry; missing
provider/model access is reported rather than silently replaced.

Magic Context owns main-session context management by default with Pi native
compaction disabled in new settings; existing user compaction preferences remain
authoritative.
There is no DCP or `rpiv-todo` dependency. The grouped-choice
`ask_user_question` extension handles material decisions; the native Pi
`ask_question` tool is disabled in the managed permission policy. The
`pi-anthropic-auth` package shapes Anthropic OAuth requests but does not log
users in, grant plan access, or change provider terms. `/usage` reports
provider usage if authenticated; its banked-reset action requires approval.

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
are lazy. Per-server `directTools` lists eagerly register only the 45 known
allowed operations from `references/mcp_operations.yaml`, below the adapter's
75-tool advisory threshold. Direct names use `<server>_<tool>`; other operations
remain available through the separately gated proxy, where calls ask for
approval. The adapter's script/install tool surfaces are disabled. Credentials
remain environment placeholders; the installer does not collect them. Sync adds
missing per-server lists to existing configurations but preserves user-edited
lists; `/reload` or a restart is needed to pick up changes.

| MCP          | Local prerequisite                           |
| ------------ | -------------------------------------------- |
| CodeGraph    | `codegraph` and an index for graph questions |
| Context7     | `CONTEXT7_API_KEY`                           |
| Brave Search | `bunx`, `BRAVE_API_KEY`                      |
| Firecrawl    | `bunx`, `FIRECRAWL_API_KEY`                  |
| Playwright   | `bunx` (isolated/headless testing)           |
| Mobbin       | approved OAuth/account when requested        |
| shadcn       | `bunx`, project `components.json`            |

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
scripts/smoke-install.sh
scripts/b-agentic-audit.sh
npm run quality
rtk git diff --check
```

`skills/` and `references/` hold canonical workflow guidance;
`pi/` holds generated specialists/prompts and Pi templates/runtime scripts;
`tooling/generate/`, `tooling/install/`, and `tooling/validate/` own generation,
lifecycle, and static checks; `tests/pi/` and `tests/smoke/` cover the local
permission and installer contracts. See the [decision record](docs/decision_design.md).
