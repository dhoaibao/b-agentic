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
kernel = root / 'runtimes/kimi-code-cli/kernel.md'
mcp = root / 'runtimes/kimi-code-cli/configs/mcp.user.template.json'
config = root / 'runtimes/kimi-code-cli/configs/config.template.toml'

for path in [kernel, mcp, config]:
    if not path.exists():
        errors.append(f'{path}: missing')

if kernel.exists():
    text = kernel.read_text()
    for marker in ['Agent Workflow Kernel', 'Core Rules', 'runtime.md', 'safety-tools.md']:
        if marker not in text:
            errors.append(f'{kernel}: missing {marker!r}')

if mcp.exists():
    data = json.loads(mcp.read_text())
    servers = data.get('mcpServers', {})
    for server in ['serena', 'context7', 'codegraph', 'brave-search', 'firecrawl', 'playwright']:
        if server not in servers:
            errors.append(f'{mcp}: missing MCP server {server!r}')
    serena = servers.get('serena', {})
    if serena.get('command') != 'serena' or serena.get('args')[:4] != ['start-mcp-server', '--context', 'ide', '--project-from-cwd']:
        errors.append(f'{mcp}: Serena MCP must launch with --context ide')
    if 'mcp' in data:
        errors.append(f'{mcp}: Kimi MCP config must use mcpServers, not mcp')

if config.exists():
    try:
        import tomllib
    except ModuleNotFoundError:
        errors.append('Kimi runtime validation requires Python 3.11+.')
    else:
        data = tomllib.loads(config.read_text())
        rules = data.get('permission', {}).get('rules', [])
        patterns = [rule.get('pattern') for rule in rules if isinstance(rule, dict)]
        for required in [
            'Bash(git commit*)',
            'Bash(git push*)',
            'Bash(git pull*)',
            'Bash(git revert*)',
            'Bash(git reset --hard*)',
            'Bash(git clean -f*)',
            'Bash(git push --force*)',
            'Bash(git branch -D*)',
        ]:
            if required not in patterns:
                errors.append(f'{config}: missing permission rule {required!r}')

if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print('Kimi Code CLI runtime validation passed.')
PY
