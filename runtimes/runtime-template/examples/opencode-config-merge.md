# OpenCode JSON Config Merge Example

This example shows how OpenCode merges b-agentic's MCP config into the user's existing `opencode.json`.

## Key Concepts

- **Merge, don't overwrite**: Preserve user's custom MCP servers and settings
- **Use `jq` or Python**: JSON manipulation in shell requires a structured approach
- **Environment variable placeholders**: API keys use `{env:VAR_NAME}` syntax in OpenCode

## Example: MCP Config Merge Function

```bash
install_mcp_config() {
  local template="$TEMPLATES_SRC/mcp.user.template.json"
  local dst="$MCP_CONFIG_DST"
  local tmp
  tmp="$(mktemp)"

  # Start with template as base
  cp "$template" "$tmp"

  # If user already has opencode.json, merge their custom servers
  if [ -f "$dst" ]; then
    python3 - "$tmp" "$dst" <<'PY'
import json
import sys
from pathlib import Path

template_path = Path(sys.argv[1])
user_path = Path(sys.argv[2])

template = json.loads(template_path.read_text())
user = json.loads(user_path.read_text())

# Preserve user's non-MCP keys
result = {k: v for k, v in user.items() if k != "mcp"}

# Merge MCP servers: template servers win, user custom servers preserved
result["mcp"] = user.get("mcp", {})
for name, server in template.get("mcp", {}).items():
    result["mcp"][name] = server

template_path.write_text(json.dumps(result, indent=2) + "\n")
PY
  fi

  # Ensure destination directory exists
  mkdir -p "$(dirname "$dst")"
  
  # Use install_triplet to handle backup/merge logic
  if [ -f "$dst" ]; then
    cp "$dst" "${dst}.backup"
  fi
  mv "$tmp" "$dst"
}
```

## Critical Patterns

1. **Always backup**: Copy existing config before modifying
2. **Preserve unknown keys**: Don't strip user's custom settings
3. **Template servers win**: User shouldn't override b-agentic's managed servers
4. **Handle dry-run**: In dry-run mode, print what would change without modifying files
5. **Report action**: Tell the user whether config was merged, written, or skipped

## OpenCode-Specific Notes

- Config file: `~/.config/opencode/opencode.json`
- MCP key: `mcp` (not `mcpServers` like Claude Code)
- Command format: `["pnpm", "dlx", "package-name", ...]`
- Env placeholders: `"{env:BRAVE_API_KEY}"` (not `"${BRAVE_API_KEY}"`)
- Headers for Context7: use `"headers"` key with `"CONTEXT7_API_KEY": "{env:CONTEXT7_API_KEY}"`
