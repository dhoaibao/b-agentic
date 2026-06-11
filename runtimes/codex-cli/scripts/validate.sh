#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"

python3 - <<'PY'
from pathlib import Path
import json
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
    for server in ['serena', 'context7', 'brave-search', 'firecrawl', 'playwright']:
        if server not in data.get('mcp_servers', {}):
            errors.append(f'{template}: missing MCP server {server!r}')
    if 'hooks' in data or 'features' in data:
        errors.append(f'{template}: hooks are not part of the slim default')

if rules.exists():
    text = rules.read_text()
    for marker in ['git", "reset", "--hard', 'git", "clean", "-f', 'git", "push", "--force', 'decision = "prompt"']:
        if marker not in text:
            errors.append(f'{rules}: missing command governance marker {marker!r}')

if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print('Codex CLI runtime validation passed.')
PY
