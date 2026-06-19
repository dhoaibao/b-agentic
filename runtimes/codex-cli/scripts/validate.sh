#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"

python3 - <<'PY'
import ast
from pathlib import Path
import json
import re
import sys

try:
    import tomllib
except ModuleNotFoundError:
    print('Codex CLI runtime validation requires Python 3.11+.', file=sys.stderr)
    sys.exit(1)

root = Path('.')
errors = []
kernel = root / 'runtimes/codex-cli/kernel.md'
template = root / 'runtimes/codex-cli/configs/mcp.user.template.toml'
rules = root / 'runtimes/codex-cli/rules/b-agentic.rules'

for path in [kernel, template, rules]:
    if not path.exists():
        errors.append(f'{path}: missing')

if kernel.exists() and 'Core Rules' not in kernel.read_text():
    errors.append(f'{kernel}: missing Core Rules')

if template.exists():
    data = tomllib.loads(template.read_text())
    for server in ['serena', 'context7', 'codegraph', 'brave-search', 'firecrawl', 'playwright']:
        if server not in data.get('mcp_servers', {}):
            errors.append(f'{template}: missing MCP server {server!r}')
    if 'hooks' in data or 'features' in data:
        errors.append(f'{template}: hooks are not part of the slim default')

if rules.exists():
    text = rules.read_text()
    expected_rules = {
        ('git', 'reset', '--hard'): 'forbidden',
        ('git', 'clean', '-f'): 'forbidden',
        ('git', 'push', '--force'): 'forbidden',
        ('git', 'push', '--force-with-lease'): 'forbidden',
        ('git', 'branch', '-D'): 'forbidden',
        ('docker', 'system', 'prune'): 'forbidden',
        ('docker', 'volume', 'rm'): 'forbidden',
        ('git', 'commit'): 'prompt',
        ('git', 'push'): 'prompt',
        ('git', 'pull'): 'prompt',
        ('git', 'revert'): 'prompt',
        ('npm', 'install'): 'prompt',
        ('pnpm', 'install'): 'prompt',
        ('yarn', 'install'): 'prompt',
        ('bun', 'install'): 'prompt',
        ('rm', '-rf'): 'prompt',
        ('pip', 'install'): 'prompt',
        ('poetry', 'add'): 'prompt',
        ('cargo', 'add'): 'prompt',
        ('go', 'get'): 'prompt',
    }
    block_pattern = re.compile(
        r'prefix_rule\(\s*pattern = (\[[^\]]*\])\s*,\s*decision = "(prompt|forbidden)"\s*,',
        re.MULTILINE,
    )
    parsed_rules = {}
    rule_order = {}
    for index, match in enumerate(block_pattern.finditer(text)):
        pattern = tuple(ast.literal_eval(match.group(1)))
        decision = match.group(2)
        if pattern in parsed_rules and parsed_rules[pattern] != decision:
            errors.append(f'{rules}: conflicting decisions for pattern {pattern!r}')
        parsed_rules[pattern] = decision
        rule_order.setdefault(pattern, index)

    for pattern, decision in expected_rules.items():
        for actual_pattern in (pattern, ('rtk', *pattern)):
            actual_decision = parsed_rules.get(actual_pattern)
            if actual_decision != decision:
                errors.append(
                    f'{rules}: expected pattern {actual_pattern!r} to use decision {decision!r}, found {actual_decision!r}'
                )

    precedence_pairs = [
        (('git', 'push', '--force'), ('git', 'push')),
        (('git', 'push', '--force-with-lease'), ('git', 'push')),
        (('rtk', 'git', 'push', '--force'), ('rtk', 'git', 'push')),
        (('rtk', 'git', 'push', '--force-with-lease'), ('rtk', 'git', 'push')),
    ]
    for specific, general in precedence_pairs:
        if specific in rule_order and general in rule_order and rule_order[specific] > rule_order[general]:
            errors.append(f'{rules}: specific rule {specific!r} must appear before general rule {general!r}')

if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print('Codex CLI runtime validation passed.')
PY
