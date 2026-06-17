# Codex CLI TOML Config Merge Example

This example shows how Codex CLI merges b-agentic's MCP config into the user's existing `config.toml`.

## Key Concepts

- **Managed blocks**: Use `# BEGIN b-agentic managed config` / `# END b-agentic managed config` markers
- **Preserve user content**: Only modify the managed block, leave rest untouched
- **Python 3.11+ required**: Use stdlib `tomllib` for TOML parsing
- **Safe removal**: During uninstall, remove only the managed block

## Example: TOML Config Merge Function

```bash
readonly CODEX_MANAGED_BEGIN="# BEGIN b-agentic managed config"
readonly CODEX_MANAGED_END="# END b-agentic managed config"

install_codex_config() {
  local template="$TEMPLATES_SRC/mcp.user.template.toml"
  local dst="$CODEX_CONFIG_DST"
  
  # Read template content (managed block)
  local managed_content
  managed_content="$(cat "$template")"
  
  # If user config exists, replace or insert managed block
  if [ -f "$dst" ]; then
    python3 - "$dst" "$managed_content" <<'PY'
import sys
from pathlib import Path

dst_path = Path(sys.argv[1])
managed_content = sys.argv[2]
begin = "# BEGIN b-agentic managed config"
end = "# END b-agentic managed config"

text = dst_path.read_text()

# Remove existing managed block if present
if begin in text and end in text:
    prefix, remainder = text.split(begin, 1)
    _managed, suffix = remainder.split(end, 1)
    text = prefix + suffix

# Append new managed block at end
text = text.rstrip() + "\n\n" + begin + "\n" + managed_content + "\n" + end + "\n"
dst_path.write_text(text)
PY
  else
    # No existing config: write managed block with markers
    {
      echo "$CODEX_MANAGED_BEGIN"
      cat "$template"
      echo "$CODEX_MANAGED_END"
    } > "$dst"
  fi
}

remove_codex_managed_block() {
  local path="$1"
  [ -f "$path" ] || return 0
  
  python3 - "$path" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
begin = "# BEGIN b-agentic managed config"
end = "# END b-agentic managed config"

text = path.read_text()
if begin not in text:
    sys.exit(0)
if end not in text:
    print(f"warning: preserving modified Codex config: {path}", file=sys.stderr)
    sys.exit(0)

prefix, remainder = text.split(begin, 1)
_managed, suffix = remainder.split(end, 1)
cleaned = (prefix + suffix).strip()

if cleaned:
    path.write_text(cleaned + "\n")
else:
    path.unlink()
PY
}
```

## Critical Patterns

1. **Use markers**: Always wrap managed content in BEGIN/END comments
2. **Idempotent updates**: Removing then re-adding prevents duplication
3. **Preserve user content**: Only touch the managed block
4. **Safe uninstall**: If markers are missing, warn and preserve file
5. **Handle empty file**: If removing the block leaves nothing, delete the file

## Codex CLI-Specific Notes

- Config file: `~/.codex/config.toml`
- Uses TOML format (not JSON)
- Agents use `.toml` extension (not `.md`)
- Rules use `.rules` extension
- Requires Python 3.11+ for stdlib `tomllib`
- Commands in config: `command = ["pnpm", "dlx", "package", ...]`
- Env vars: `env = { BRAVE_API_KEY = "BRAVE_API_KEY" }` (value equals the env var name for env binding)
- HTTP headers: `http_headers = { CONTEXT7_API_KEY = "CONTEXT7_API_KEY" }` (value equals the env var name for env binding)
