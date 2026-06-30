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
kernel = root / 'runtimes/antigravity-cli/kernel.md'
settings = root / 'runtimes/antigravity-cli/configs/settings.template.json'
mcp = root / 'runtimes/antigravity-cli/configs/mcp.user.template.json'

for path in [kernel, settings, mcp]:
    if not path.exists():
        errors.append(f'{path}: missing')

if kernel.exists():
    text = kernel.read_text()
    for marker in ['Agent Workflow Kernel', 'Core Rules', 'runtime.md', 'safety-tools.md', '~/.gemini/antigravity-cli/b-agentic/references/contract/']:
        if marker not in text:
            errors.append(f'{kernel}: missing {marker!r}')

if settings.exists():
    data = json.loads(settings.read_text())
    if 'hooks' in data or 'statusLine' in data:
        errors.append(f'{settings}: hooks/statusLine are not part of the slim default')
    permissions = data.get('permissions', {})
    allow = permissions.get('allow', [])
    ask = permissions.get('ask', [])
    deny = permissions.get('deny', [])
    prompted_bash_commands = [
        'command(git commit.*)',
        'command(git push.*)',
        'command(git pull.*)',
        'command(git revert.*)',
        'command(npm install.*)',
        'command(pnpm install.*)',
        'command(yarn install.*)',
        'command(bun install.*)',
        'command(cargo install.*)',
        'command(go install.*)',
    ]
    denied_bash_commands = [
        'command(git reset --hard.*)',
        'command(git clean -f.*)',
        'command(git push --force.*)',
        'command(git push --force-with-lease.*)',
        'command(git branch -D.*)',
    ]

    def bash_patterns(commands):
        patterns = []
        for command in commands:
            patterns.append(command)
            target = command[len('command('):-1]
            patterns.append(f'command(rtk {target})')
        return patterns

    if any('firecrawl_monitor' in item for item in allow):
        errors.append(f'{settings}: Firecrawl monitor mutation tools must not be allowlisted')
    for required in bash_patterns(prompted_bash_commands):
        if required not in ask:
            errors.append(f'{settings}: missing prompted command {required!r}')
    for required in bash_patterns(denied_bash_commands):
        if required not in deny:
            errors.append(f'{settings}: missing denied command {required!r}')

if mcp.exists():
    data = json.loads(mcp.read_text())
    servers = data.get('mcpServers', {})
    for server in ['serena', 'context7', 'codegraph', 'brave-search', 'firecrawl', 'playwright']:
        if server not in servers:
            errors.append(f'{mcp}: missing MCP server {server!r}')
    context7 = servers.get('context7', {})
    if context7.get('type') != 'remote':
        errors.append(f'{mcp}: context7 must use type "remote"')
    if 'url' in context7 or 'httpUrl' in context7:
        errors.append(f'{mcp}: context7 must use serverUrl, not url or httpUrl')
    if context7.get('serverUrl') != 'https://mcp.context7.com/mcp':
        errors.append(f'{mcp}: context7 serverUrl mismatch')

if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print('Antigravity CLI runtime validation passed.')
PY
