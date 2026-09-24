# b-agentic operational reference

[Back to the public overview](README.md)

This reference defines the single supported Pi runtime, installation lifecycle,
permission boundary, MCP configuration, and validation.

## Install and lifecycle

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash
```

With Pi already on PATH, install runs `pi update --self`; otherwise it installs
the latest `@earendil-works/pi-coding-agent` through npm. Six bare npm package
names are managed in the Pi agent directory: `@gotgenes/pi-subagents`,
`@gotgenes/pi-permission-system`, `pi-mcp-adapter`,
`@juicesharp/rpiv-ask-user-question`, `@gotgenes/pi-anthropic-auth`, and
`@sreetej510/pi-usage`. None is pinned. The default directory is
`~/.pi/agent`; `B_AGENTIC_PI_DIR` or `PI_CODING_AGENT_DIR` overrides it.
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
preserved by the JSON rewrite. Package declarations union ahead of user
packages. Existing OpenCode configuration and installation are never removed or
updated. See [Pi configuration layout](pi/configs/README.md).

## Kernel and skills

Pi loads the global `AGENTS.md` and discovers native `skills/b-*/SKILL.md`.
The main session reads one skill before acting, or invokes a generated
`/b-<name>` prompt template. `skills/registry.yaml` and `skills/*/prompt.md`
are canonical; `tooling/generate/registry_sync.py` generates the delivery
assets. The four `@gotgenes/pi-subagents` specialist profiles are
`b-planner`, `b-researcher`, `b-debugger`, and `b-reviewer`. Their complete tool
allowlists and per-agent permission rules prohibit worktree writes, user
questions, nested delegation, and mutating MCP tools. The main session owns
those activities, verification, and final reporting. A child result is
evidence, not authorization. Background children run only while the parent Pi
process remains alive; compatible continuations use the extension's `resume`
identifier. Different scope/baseline or required independent review uses a
fresh child. Model IDs and thinking levels come from the registry; missing
provider/model access is reported rather than silently replaced.

Pi native compaction remains enabled by default. There is no DCP or Magic
Context replacement and no `rpiv-todo` dependency. The grouped-choice
`ask_user_question` extension handles material decisions; the native Pi
`ask_question` tool is disabled in the managed permission policy. The
`pi-anthropic-auth` package shapes Anthropic OAuth requests but does not log
users in, grant plan access, or change provider terms. `/usage` reports
provider usage if authenticated; its banked-reset action requires approval.

## Permission boundary

The generated `pi/configs/permission.user.template.json` is a configuration
for `@gotgenes/pi-permission-system`. Main-session local work is allowed,
protected path patterns are denied, named destructive shell commands are
denied, external directories ask, and unknown direct MCP operations ask. The
generic `mcp` proxy asks by default, with metadata operations allowed. Use
read-only named direct tools to avoid proxy approval: the proxy cannot safely
bind an allow rule to the server that will execute it. Skill invocation and
read-only named direct tools are allowed; upload, mutation, monitor, and auth
tools ask. The specialists additionally have complete tool allowlists and
deny-by-default per-agent policies. Extension policy is not a process sandbox:
shell normalization, path-field recognition, and dynamic tool registration
have limits. The kernel requires explicit approval for protected/outside-project
or external/shared actions even when a tool-level rule would allow them.

`tests/pi/permission-probe.sh --setup` installs the current unpinned extensions
in an isolated repo-local profile and runs an offline stub-provider gate for
parent/child writes, protected paths, and dynamic MCP decisions. It does not
prove interactive dialogs, real-provider availability, or production MCP
connectivity. Every changed candidate needs inspected paths and applicable
checks; security, installer, runtime, or multi-subsystem changes require an
independent frozen-snapshot reviewer before normal completion.

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
