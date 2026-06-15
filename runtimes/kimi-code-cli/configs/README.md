# Kimi Code CLI Runtime Config

b-agentic installs Kimi Code CLI assets into the Kimi data root.

Default paths:

- Kernel: `~/.kimi-code/AGENTS.md`
- Skills: `~/.kimi-code/skills/`
- Metadata, references, and install manifest: `~/.kimi-code/b-agentic/`
- Runtime config and permission rules: `~/.kimi-code/config.toml`
- User-level MCP config: `~/.kimi-code/mcp.json`

Set `KIMI_CODE_HOME` to install into the same alternate data root that Kimi uses at runtime. Set `B_AGENTIC_KIMI_CODE_DIR` when you need an installer-only override, or `B_AGENTIC_KIMI_MCP_JSON` to target a specific `mcp.json`.

Kimi also supports project-level `.kimi-code/mcp.json` and `.kimi-code/skills/`, but this adapter writes user-level files by default so install and uninstall do not mutate arbitrary repositories.

## Permissions

The adapter appends a managed block to `config.toml` with `[[permission.rules]]` entries. The managed rules deny destructive git, branch, and Docker cleanup commands, and ask before commits, pushes, pulls, reverts, dependency writes, and recursive deletion. Existing user-owned provider, model, and UI settings are preserved outside the managed block.

## MCP

Kimi reads MCP servers from `mcp.json` with a top-level `mcpServers` object. The template in this directory installs the recommended b-agentic MCP entries:

- Serena
- CodeGraph
- Context7
- Brave Search
- Firecrawl
- Playwright

The template does not rely on undocumented environment placeholder expansion. If `--prompt-api-keys` is used, the installer writes provided Context7, Brave Search, and Firecrawl keys into the user-level `mcp.json`; otherwise the runtime can still start non-keyed servers, and `scripts/mcp-doctor.sh --runtime=kimi-code-cli` reports remaining key blockers.

## Skills

Kimi scans `~/.kimi-code/skills/` by default, or `$KIMI_CODE_HOME/skills/` when Kimi is launched with a relocated data root. b-agentic installs directory-form skills with `SKILL.md` files into the Kimi-specific user skill directory.
