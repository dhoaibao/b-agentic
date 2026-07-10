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
kernel = root / 'runtimes/cursor/kernel.md'
settings = root / 'runtimes/cursor/configs/settings.template.json'
mcp = root / 'runtimes/cursor/configs/mcp.user.template.json'

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
    if data.get('version') != 1:
        errors.append(f'{settings}: version must be 1')
    if not isinstance(data.get('editor'), dict) or 'vimMode' not in data['editor']:
        errors.append(f'{settings}: editor.vimMode field must exist')
    if data.get('approvalMode') != 'allowlist':
        errors.append(f'{settings}: approvalMode must be "allowlist"')
    permissions = data.get('permissions', {})
    allow = permissions.get('allow', [])
    deny = permissions.get('deny', [])
    prompted_bash_commands = [
        'git commit *',
        'git push *',
        'git pull *',
        'git revert *',
        'npm install *',
        'pnpm install *',
        'yarn install *',
        'bun install *',
        'cargo install *',
        'go install *',
    ]
    denied_bash_commands = [
        'git reset --hard *',
        'git clean -f *',
        'git push --force *',
        'git push --force-with-lease *',
        'git branch -D *',
    ]

    def shell_patterns(commands):
        patterns = []
        for command in commands:
            patterns.append(f'Shell({command})')
            patterns.append(f'Shell(rtk {command})')
        return patterns

    if any('firecrawl_monitor' in item for item in allow):
        errors.append(f'{settings}: Firecrawl monitor mutation tools must not be allowlisted')
    if any(item in allow for item in ['Mcp(firecrawl:*)', 'Mcp(playwright:*)']):
        errors.append(f'{settings}: Firecrawl/Playwright server wildcards must not be allowlisted')
    for forbidden in [
        'Mcp(firecrawl:firecrawl_agent)',
        'Mcp(firecrawl:firecrawl_crawl)',
        'Mcp(firecrawl:firecrawl_interact)',
        'Mcp(firecrawl:firecrawl_parse)',
        'Mcp(firecrawl:firecrawl_search_feedback)',
        'Mcp(firecrawl:firecrawl_feedback)',
        'Mcp(playwright:browser_click)',
        'Mcp(playwright:browser_type)',
    ]:
        if forbidden in allow:
            errors.append(f'{settings}: gated MCP tool {forbidden!r} must not be allowlisted')
    for required in [
        'Mcp(firecrawl:firecrawl_search)',
        'Mcp(firecrawl:firecrawl_scrape)',
        'Mcp(playwright:browser_snapshot)',
        'Mcp(playwright:browser_navigate)',
    ]:
        if required not in allow:
            errors.append(f'{settings}: missing allowlisted read-only tool {required!r}')
    for prohibited in shell_patterns(prompted_bash_commands):
        if prohibited in allow:
            errors.append(f'{settings}: prompted command {prohibited!r} must not be in allowlist')
    for required in shell_patterns(denied_bash_commands):
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
print('Cursor runtime validation passed.')
PY
