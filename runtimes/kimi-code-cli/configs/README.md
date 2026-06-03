# Kimi Code CLI Config

b-agentic installs user-scope assets under Kimi Code CLI's default data root:

- Runtime kernel: `~/.kimi-code/b-agentic-kernel.md`
- Managed metadata, references, templates, and helper scripts: `~/.kimi-code/b-agentic/`
- Skills: `~/.kimi-code/skills/`
- Runtime config: `~/.kimi-code/config.toml`
- MCP servers: `~/.kimi-code/mcp.json`

Set `KIMI_CODE_HOME` to relocate Kimi's data root. For tests and one-off installs, `B_AGENTIC_KIMI_CODE_HOME` takes precedence over `KIMI_CODE_HOME`.

## Activation

Kimi Code CLI does not currently document a Claude/Codex-style global memory file. The adapter therefore activates the runtime kernel with a Kimi-native `UserPromptSubmit` hook in `config.toml`.

The hook runs a managed local Python script from `~/.kimi-code/b-agentic/hooks/inject-kernel.py`. It injects `b-agentic-kernel.md` into context once per Kimi session ID, then records a small marker under `~/.kimi-code/b-agentic/hook-state/`.

Hooks are fail-open in Kimi Code CLI. If the hook script cannot run, Kimi continues the session, but the b-agentic kernel may not be present. Restart Kimi after installation so the new hook is loaded.

## MCP

The installer merges `mcp.user.template.json` into `~/.kimi-code/mcp.json` under the `mcpServers` key. Project-level `.kimi-code/mcp.json` entries still take precedence inside Kimi Code CLI.

The template keeps API key values as placeholders. Use `install.sh --runtime=kimi-code-cli --prompt-api-keys` to write prompted values into the user config, or edit `~/.kimi-code/mcp.json` manually.

## Permissions

The managed `config.toml` block adds conservative deny rules for destructive shell patterns and keeps other approval behavior with Kimi's runtime defaults. It does not enable YOLO mode or broad MCP allowlists.

## Uninstall

`install.sh --runtime=kimi-code-cli --uninstall` removes managed skills, the managed kernel when unchanged, the managed `config.toml` block, managed MCP entries when safe, and `~/.kimi-code/b-agentic/`. User-owned Kimi config, sessions, credentials, logs, and project-local `.kimi-code/` files are preserved.
