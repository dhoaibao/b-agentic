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
    allowed_bash_commands = ['git diff *', 'git status *', 'git log *', 'rg *', 'fd *', 'fdfind *', 'jq *']
    prompted_bash_commands = ['git commit *', 'git push *', 'git pull *', 'git revert *', 'npm install *', 'pnpm install *', 'yarn install *', 'bun install *', 'cargo install *', 'go install *']
    denied_bash_commands = ['git reset --hard *', 'git clean -f *', 'git push --force *', 'git push --force-with-lease *', 'git branch -D *', 'rm *']

    def with_rtk(commands):
        expanded = []
        for command in commands:
            expanded.append(command)
            expanded.append(f'rtk {command}')
        return expanded

    def key_positions(keys):
        positions = {}
        for index, key in enumerate(bash_rules):
            if key in keys and key not in positions:
                positions[key] = index
        return positions

    if bash_rules.get('*') != 'ask':
        errors.append(f'{config}: bash default must remain ask')
    for command in with_rtk(allowed_bash_commands):
        if bash_rules.get(command) != 'allow':
            errors.append(f'{config}: missing allowed bash rule {command!r}')
    for command in with_rtk(prompted_bash_commands):
        if bash_rules.get(command) != 'ask':
            errors.append(f'{config}: missing prompted bash rule {command!r}')
    for command in with_rtk(denied_bash_commands):
        if bash_rules.get(command) != 'deny':
            errors.append(f'{config}: missing denied bash rule {command!r}')
    positions = key_positions(with_rtk(['git push --force *', 'git push --force-with-lease *', 'git push *']))
    precedence_pairs = [
        ('git push --force *', 'git push *'),
        ('git push --force-with-lease *', 'git push *'),
        ('rtk git push --force *', 'rtk git push *'),
        ('rtk git push --force-with-lease *', 'rtk git push *'),
    ]
    for specific, general in precedence_pairs:
        if specific in positions and general in positions and positions[specific] > positions[general]:
            errors.append(f'{config}: specific bash rule {specific!r} must appear before general rule {general!r}')

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
