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
kernel = root / 'runtimes/kilo-code/kernel.md'
config = root / 'runtimes/kilo-code/configs/mcp.user.template.json'

for path in [kernel, config]:
    if not path.exists():
        errors.append(f'{path}: missing')

if kernel.exists() and 'Core Rules' not in kernel.read_text():
    errors.append(f'{kernel}: missing Core Rules')

if config.exists():
    data = json.loads(config.read_text())
    for server in ['serena', 'context7', 'codegraph', 'brave-search', 'firecrawl', 'playwright']:
        if server not in data.get('mcp', {}):
            errors.append(f'{config}: missing MCP server {server!r}')
    permission = data.get('permission', {})
    bash_rules = permission.get('bash', {}) if isinstance(permission, dict) else {}
    if bash_rules.get('*') != 'ask':
        errors.append(f'{config}: bash default must remain ask')
    skill_rules = permission.get('skill', {}) if isinstance(permission, dict) else {}
    if skill_rules.get('b-*') != 'allow':
        errors.append(f'{config}: managed b-* skills must remain allowed')
    for command in ['git reset --hard *', 'git clean -f *', 'git push --force *', 'git push --force-with-lease *', 'git branch -D *', 'rm *']:
        if bash_rules.get(command) != 'deny':
            errors.append(f'{config}: missing denied bash rule {command!r}')

if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print('Kilo Code runtime validation passed.')
PY
