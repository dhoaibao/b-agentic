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
kernel = root / 'runtimes/opencode/kernel.md'
config = root / 'runtimes/opencode/configs/mcp.user.template.json'
commands = root / 'runtimes/opencode/commands'

for path in [kernel, config, commands]:
    if not path.exists():
        errors.append(f'{path}: missing')

if kernel.exists() and 'Core Rules' not in kernel.read_text():
    errors.append(f'{kernel}: missing Core Rules')

if config.exists():
    data = json.loads(config.read_text())
    for server in ['serena', 'context7', 'codegraph', 'brave-search', 'firecrawl', 'playwright']:
        if server not in data.get('mcp', {}):
            errors.append(f'{config}: missing MCP server {server!r}')
    if 'hooks' in data:
        errors.append(f'{config}: hooks are not part of the slim default')
    permission = data.get('permission', {})
    bash_rules = permission.get('bash', {}) if isinstance(permission, dict) else {}
    if bash_rules.get('*') != 'ask':
        errors.append(f'{config}: bash default must remain ask')
    for command in ['git diff *', 'git status *', 'git log *', 'rg *', 'fd *', 'fdfind *', 'jq *', 'rtk git diff *', 'rtk git status *', 'rtk git log *', 'rtk rg *', 'rtk fd *', 'rtk fdfind *', 'rtk jq *']:
        if bash_rules.get(command) != 'allow':
            errors.append(f'{config}: missing allowed bash rule {command!r}')
    for command in ['git reset --hard *', 'git clean -f *', 'git push --force *', 'git push --force-with-lease *', 'git branch -D *', 'rm *']:
        if bash_rules.get(command) != 'deny':
            errors.append(f'{config}: missing denied bash rule {command!r}')

if commands.exists():
    wrappers = {path.stem for path in commands.glob('b-*.md')}
    expected = {path.parent.name for path in (root / 'skills').glob('b-*/prompt.md')}
    if wrappers != expected:
        errors.append(f'{commands}: wrapper set {sorted(wrappers)} must match skills {sorted(expected)}')

if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print('OpenCode runtime validation passed.')
PY
