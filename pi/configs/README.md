# Pi configuration ownership

`settings.base.json`, `subagents.base.json`, `magic-context.base.json`, and
`mcp.base.json` are canonical checked-in templates;
`permission.user.template.json` is generated from
`references/mcp_operations.yaml` by `tooling/generate/registry_sync.py`.

| Source | Installed path (default agent directory `~/.pi/agent`) | Owner |
| --- | --- | --- |
| `settings.base.json` | `settings.json` | Pi, seven unpinned packages, native compaction off by default, and Dracula only when no theme is selected |
| `subagents.base.json` | `subagents.json` | `pi-subagents` excludes Magic Context from children; existing user exclusions are retained |
| `magic-context.base.json` | `~/.config/cortexkit/magic-context.jsonc` (or `$XDG_CONFIG_HOME/cortexkit/`) | Shared CortexKit defaults: enabled with local embeddings; historian falls back to the live Pi model |
| `mcp.base.json` | `mcp.json` | `pi-mcp-adapter`; seven lazy servers with policy-aligned direct-tool lists, no stored credentials |
| `permission.user.template.json` | `extensions/pi-permission-system/config.json` | `@gotgenes/pi-permission-system`; known tool and path policy |
| `../themes/dracula.json` | `themes/dracula.json` | Bundled [Dracula theme](https://draculatheme.com/pi-coding-agent); checked-in MIT license in `../themes/LICENSE` |
| `../agents/b-*.md` | `agents/b-*.md` | Four specialist profiles and child policies |
| `../prompts/b-*.md` | `prompts/b-*.md` | Fifteen explicit `/b-*` routes |

`install.sh` merges without replacing user-owned keys, snapshots the managed
assets, backs up existing configs, and records ownership in
`b-agentic/install.json`. The MCP template adds missing per-server direct-tool
lists; existing user-owned lists remain unchanged. Non-direct operations are
available through the approval-gated proxy. An existing Dracula theme file, a
modified file, or a symlink remains user-owned. `--sync` refreshes an unchanged
managed theme from the checked-in source; uninstall removes only an unchanged
managed copy.
`--sync` refreshes local assets; `--update` asks Pi to update itself and the
installed extensions. Bare npm package names track the latest available
release. Status and doctor commands do not open network/auth/browser sessions
or read credential values. Configuration presence is not live usability.
