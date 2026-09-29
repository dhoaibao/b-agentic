# Pi configuration ownership

`settings.base.json`, `subagents.base.json`, `magic-context.base.json`, and
`mcp.base.json` are canonical checked-in templates;
`permission.user.template.json` is generated from
`references/mcp_operations.yaml` by `tooling/generate/registry_sync.py`.

| Source | Installed path (default agent directory `~/.pi/agent`) | Owner |
| --- | --- | --- |
| `settings.base.json` | `settings.json` | Pi, nine unpinned packages, native compaction off by default, and Dracula only when no theme is selected |
| `subagents.base.json` | `subagents.json` | `pi-subagents` excludes Magic Context from children; existing user exclusions are retained |
| `magic-context.base.json` | `~/.config/cortexkit/magic-context.jsonc` (or `$XDG_CONFIG_HOME/cortexkit/`) | Shared CortexKit defaults: enabled with local embeddings; historian falls back to the live Pi model |
| `mcp.base.json` | `mcp-adapter.json` | `pi-mcp-adapter`; seven lazy servers with policy-aligned direct-tool lists, no stored credentials |
| `mcp.clickup.json` | `mcp-adapter.json` | Optional ClickUp stdio server (`@1.9.0`), added only after install opt-in; uses environment references for its personal API token and team ID |
| `permission.user.template.json` | `extensions/pi-permission-system/config.json` | `@gotgenes/pi-permission-system`; known tool and path policy |
| `../themes/dracula.json` | `themes/dracula.json` | Bundled [Dracula theme](https://draculatheme.com/pi-coding-agent); checked-in MIT license in `../themes/LICENSE` |
| `../agents/b-*.md` | `agents/b-*.md` | Four generated specialist profiles (tool allowlists; global permission policy applies, no per-agent block) |
| `../prompts/b-*.md` | `prompts/b-*.md` | Sixteen generated explicit `/b-*` routes |

`install.sh` merges without replacing user-owned keys, snapshots the managed
assets, backs up existing configs, and records ownership in
`b-agentic/install.json`. It asks once whether to add the optional ClickUp MCP
when no choice is recorded; non-interactive first installs or upgrades leave it
out unless `B_AGENTIC_CLICKUP_MCP=yes` is set. Later install and sync runs
preserve the recorded choice; uninstall and reinstall to change it. The MCP
template adds missing per-server
direct-tool lists; existing user-owned lists remain unchanged. Existing `mcp.json` files are
left untouched; the installer does not migrate them to `mcp-adapter.json`.
For an existing b-agentic install recorded against `mcp.json`, install,
`--sync`, and `--update` refuse to proceed. Uninstall first, then install again;
copy any user-owned MCP entries you still need into `mcp-adapter.json`.
Only then update the adapter to 3.x (`install.sh --update`) if an older 2.x copy
is installed; 2.x does not read the new filename. Until removed, legacy entries
in `mcp.json` may be loaded by Pi's built-in MCP
support rather than the adapter. Non-direct operations are available through
the approval-gated proxy. An existing Dracula theme file, a modified file, or a
symlink remains user-owned. `--sync` refreshes an unchanged managed theme from
the checked-in source; uninstall removes only an unchanged
managed copy.
`--sync` refreshes local assets; `--update` asks Pi to update itself and the
installed extensions. Bare npm package names track the latest available
release. Status and doctor commands do not open network/auth/browser sessions
or read credential values. Configuration presence is not live usability.
