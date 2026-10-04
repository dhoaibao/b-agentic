# Pi configuration ownership

`settings.base.json`, `subagents.base.json`, `magic-context.base.json`, and
`mcp.base.json` are canonical checked-in templates;
`permission.user.template.json` is generated from
`references/mcp_operations.yaml` by `tooling/generate/registry_sync.py`.

| Source | Installed path (default agent directory `~/.pi/agent`) | Owner |
| --- | --- | --- |
| `settings.base.json` | `settings.json` | Pi, nine unpinned packages, `-builtin:mcp` (the adapter owns MCP), native compaction off by default, and Dracula only when no theme is selected |
| `subagents.base.json` | `subagents.json` | `pi-subagents` excludes Magic Context from children; existing user exclusions are retained |
| `magic-context.base.json` | `~/.config/cortexkit/magic-context.jsonc` (or `$XDG_CONFIG_HOME/cortexkit/`) | Shared CortexKit defaults: enabled with local embeddings; historian falls back to the live Pi model |
| `mcp.base.json` | `mcp-adapter.json` | `pi-mcp-adapter`; ten lazy servers (four with fixed direct-tool lists, six search-exposed), no stored credentials |
| `mcp.clickup.json` | `mcp-adapter.json` | Optional ClickUp stdio server (`bunx`, `@1.9.0`), added only after install opt-in; uses environment references for its personal API token and team ID |
| `permission.user.template.json` | `extensions/pi-permission-system/config.json` | `@gotgenes/pi-permission-system`; known tool and path policy |
| `../themes/dracula.json` | `themes/dracula.json` | Bundled [Dracula theme](https://draculatheme.com/pi-coding-agent); checked-in MIT license in `../themes/LICENSE` |
| `../agents/b-*.md` | `agents/b-*.md` | Four generated specialist profiles (tool allowlists; global permission policy applies, no per-agent block) |
| `../prompts/b-*.md` | `prompts/b-*.md` | Seventeen generated explicit `/b-*` routes |
| `../extensions/b-*.ts` | `extensions/b-*.ts` | Managed Pi extensions; `b-sync.ts` provides `/b-sync` (source pull + `install.sh --sync --force`, then reload); `b-verify-gate.ts` adds an advisory one-shot finish-time verify reminder; `b-candidate-snapshot.ts` adds the read-only `b_candidate_snapshot` review-candidate fingerprint tool; `b-input-image-preview.ts` previews image paths in the input above the editor and in a popup (display-only, never touches the editor or submitted text; opt out with `PI_INPUT_IMAGE_PREVIEW=off`); `b-herdr-notify.ts` marks the Herdr pane blocked and shows one Herdr toast when Pi waits on a question or permission prompt (inert outside Herdr and the root TUI session; opt out with `PI_HERDR_NOTIFY=off`) |

`install.sh` merges without replacing user-owned keys, snapshots the managed
assets, backs up existing configs, and records ownership in
`b-agentic/install.json`. It asks once whether to add the optional ClickUp MCP
when no choice is recorded; non-interactive first installs or upgrades leave it
out unless `B_AGENTIC_CLICKUP_MCP=yes` is set. Later install and sync runs
preserve the recorded choice; uninstall and reinstall to change it. The MCP
template adds missing per-server
`directTools` values. Brave Search, Firecrawl, Playwright, Mobbin, Notion, shadcn, and the
optional ClickUp server use `directTools: "search"`: their tools start inactive, so
they cost no prompt tokens, and `mcp({search})` activates matches under the same
`<server>_<tool>` names (about 19K estimated tokens per turn saved; unmeasured).
CodeGraph, Context7, Excalidraw, and draw.io keep short fixed lists. The installer applies
this to an existing install once: it replaces those servers' `directTools` even when
you customised them, saves the previous file under `b-agentic/backups/`, and records
the migrated servers in the manifest (`mcpExposureMigratedServers`), so later syncs keep any list you restore while an optional server enabled later is still migrated.
Specialists list the tools they need by name, which makes those tools active for
them without searching. Existing `mcp.json` files are
left untouched; the installer does not migrate them to `mcp-adapter.json`.
For an existing b-agentic install recorded against `mcp.json`, install,
`--sync`, and `--update` refuse to proceed. Uninstall first, then install again;
copy any user-owned MCP entries you still need into `mcp-adapter.json`.
Only then update the adapter to 3.x (`install.sh --update`) if an older 2.x copy
is installed; 2.x does not read the new filename. Managed settings add `-builtin:mcp`, so Pi's
built-in MCP does not read legacy `mcp.json` entries; uninstall removes that
managed entry (an identical entry a user added after the original install and before an
upgrade first manages it is also removed). Non-direct operations are available through
the approval-gated proxy. An existing Dracula theme file, a modified file, or a
symlink remains user-owned. `--sync` refreshes an unchanged managed theme from
the checked-in source; uninstall removes only an unchanged
managed copy.
`--sync` refreshes local assets; `--update` asks Pi to update itself and the
installed extensions. Bare npm package names track the latest available
release. Status and doctor commands do not open network/auth/browser sessions
or read credential values. Configuration presence is not live usability.

Pi's built-in `codemode` and `tool_search` tools stay off because
`defaultTools` is not set. To opt in to codemode, add `"defaultTools": ["+codemode"]`
to your own settings; nested calls still pass the permission policy, and the
`codemode` tool itself falls under the `*` ask rule.
