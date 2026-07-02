#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"

python3 - <<'PY'
from pathlib import Path
import json
import sys

root = Path('.')
errors = []
kernel = root / 'runtimes/copilot-cli/kernel.md'
mcp = root / 'runtimes/copilot-cli/configs/mcp.user.template.json'

for path in [kernel, mcp]:
    if not path.exists():
        errors.append(f'{path}: missing')

if kernel.exists():
    text = kernel.read_text()
    for marker in ['Agent Workflow Kernel', 'Core Rules', 'runtime.md', 'safety-tools.md', '~/.copilot/b-agentic/references/contract/']:
        if marker not in text:
            errors.append(f'{kernel}: missing {marker!r}')

if mcp.exists():
    data = json.loads(mcp.read_text())
    servers = data.get('mcpServers', {})
    for server in ['serena', 'context7', 'codegraph', 'brave-search', 'firecrawl', 'playwright']:
        if server not in servers:
            errors.append(f'{mcp}: missing MCP server {server!r}')
    context7 = servers.get('context7', {})
    if context7.get('type') != 'http':
         errors.append(f'{mcp}: context7 must use type "http"')
    if context7.get('url') != 'https://mcp.context7.com/mcp':
         errors.append(f'{mcp}: context7 url mismatch')

if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print('GitHub Copilot CLI runtime validation passed.')
PY
