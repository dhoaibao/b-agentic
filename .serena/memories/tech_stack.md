# Tech Stack

- Shell installer and runtime scripts are Bash.
- Python 3.11+ is required for structured config, registry sync, validation, and smoke helpers.
- Registry files are JSON-compatible YAML loaded with Python stdlib `json`.
- MCP package commands use `pnpm dlx`; docs call out `pnpm` as an install requirement for MCP entries.
- Runtime targets: Claude Code, OpenCode, Codex CLI.
- Optional installer-managed tools: RTK via remote curl script; Serena via `uv tool install -p 3.13 serena-agent` / `uv tool upgrade serena-agent`.