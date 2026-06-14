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
kernel = root / 'runtimes/droid/kernel.md'
settings = root / 'runtimes/droid/configs/settings.template.json'
mcp = root / 'runtimes/droid/configs/mcp.user.template.json'

for path in [kernel, settings, mcp]:
    if not path.exists():
        errors.append(f'{path}: missing')

if kernel.exists() and 'Core Rules' not in kernel.read_text():
    errors.append(f'{kernel}: missing Core Rules')

if settings.exists():
    data = json.loads(settings.read_text())
    deny = data.get('commandDenylist', [])
    block = data.get('commandBlocklist', [])
    for required in ['git commit', 'git push', 'git pull', 'git revert']:
        if required not in deny:
            errors.append(f'{settings}: missing prompted command {required!r}')
    for required in ['git reset --hard', 'git clean -f', 'git push --force', 'git push --force-with-lease', 'git branch -D']:
        if required not in block:
            errors.append(f'{settings}: missing blocked command {required!r}')

if mcp.exists():
    data = json.loads(mcp.read_text())
    servers = data.get('mcpServers', {})
    for server in ['serena', 'context7', 'brave-search', 'firecrawl', 'playwright']:
        if server not in servers:
            errors.append(f'{mcp}: missing MCP server {server!r}')
    if servers.get('serena', {}).get('args', [None, None, None])[2] != 'ide':
        errors.append(f'{mcp}: serena should use the generic ide context')

if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print('Droid runtime validation passed.')
PY
