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
kernel = root / 'runtimes/claude-code/kernel.md'
settings = root / 'runtimes/claude-code/configs/settings.template.json'
mcp = root / 'runtimes/claude-code/configs/mcp.user.template.json'

for path in [kernel, settings, mcp]:
    if not path.exists():
        errors.append(f'{path}: missing')

if kernel.exists():
    text = kernel.read_text()
    for marker in ['Agent Workflow Kernel', 'Core Rules', 'runtime.md', 'safety-tools.md']:
        if marker not in text:
            errors.append(f'{kernel}: missing {marker!r}')

if settings.exists():
    data = json.loads(settings.read_text())
    if 'hooks' in data or 'statusLine' in data:
        errors.append(f'{settings}: hooks/statusLine are not part of the slim default')
    permissions = data.get('permissions', {})
    allow = data.get('permissions', {}).get('allow', [])
    ask = permissions.get('ask', [])
    deny = permissions.get('deny', [])
    if any('firecrawl_monitor' in item for item in allow):
        errors.append(f'{settings}: Firecrawl monitor mutation tools must not be allowlisted')
    for required in ['Bash(git commit *)', 'Bash(git push *)', 'Bash(git pull *)', 'Bash(git revert *)']:
        if required not in ask:
            errors.append(f'{settings}: missing prompted command {required!r}')
    for required in ['Bash(git reset --hard *)', 'Bash(git clean -f *)', 'Bash(git push --force *)', 'Bash(git push --force-with-lease *)', 'Bash(git branch -D *)']:
        if required not in deny:
            errors.append(f'{settings}: missing denied command {required!r}')

if mcp.exists():
    data = json.loads(mcp.read_text())
    servers = data.get('mcpServers', {})
    for server in ['serena', 'context7', 'codegraph', 'brave-search', 'firecrawl', 'playwright']:
        if server not in servers:
            errors.append(f'{mcp}: missing MCP server {server!r}')

if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print('Claude Code runtime validation passed.')
PY
