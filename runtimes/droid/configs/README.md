# Droid Config Templates

These templates are merged into user-owned Factory config during install.

- `settings.template.json` targets `~/.factory/settings.json`.
- `mcp.user.template.json` targets `~/.factory/mcp.json`.

Keep secrets out of tracked templates. Droid expands `${VAR}` placeholders in
`mcp.json` at load time.
