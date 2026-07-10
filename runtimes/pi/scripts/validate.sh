#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"

python3 - <<'PY'
from pathlib import Path
import json
import re
import sys

root = Path('.')
errors = []
kernel = root / 'runtimes/pi/kernel.md'
mcp = root / 'runtimes/pi/configs/mcp.user.template.json'
extension = root / 'runtimes/pi/extensions/b-agentic-permissions.ts'
readme = root / 'runtimes/pi/configs/README.md'

for path in [kernel, mcp, extension, readme]:
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
        elif servers[server].get('lifecycle') != 'lazy':
            errors.append(f'{mcp}: {server} must use lifecycle lazy by default')
    settings = data.get('settings', {})
    if settings.get('directTools') not in (False, None):
        errors.append(f'{mcp}: default directTools must be false (proxy tool default)')

if extension.exists():
    text = extension.read_text()
    for marker in [
        'tool_call',
        '["git", "commit"]',
        '["git", "push"]',
        '["git", "pull"]',
        '["git", "revert"]',
        '["npm", "install"]',
        '["rm", "-rf"]',
        '["git", "reset", "--hard"]',
        '["git", "clean", "-f"]',
        '["git", "push", "--force"]',
        '["git", "branch", "-D"]',
        '["docker", "system", "prune"]',
        '["docker", "volume", "rm"]',
        'rtk',
        'hasUI',
        'fail-closed',
        '.env',
        'splitShellSegments',
        'stripWrappers',
        'isMcpOrCustomTool',
        'isInterpreterOpaque',
        'commandDecision',
        '__test__',
        '"grep"',
        '"find"',
        '"ls"',
    ]:
        if marker not in text:
            errors.append(f'{extension}: missing policy marker {marker!r}')
    if 'return { block: true' not in text and 'block: true' not in text:
        errors.append(f'{extension}: must be able to block tool calls')
    if 'custom/MCP tool' not in text and 'MCP' not in text:
        errors.append(f'{extension}: must gate MCP/custom tools')
    if 'Blocked' not in text or 'protected path' not in text:
        errors.append(f'{extension}: must block protected paths')
    # read must share protected-path handling with write/edit
    if 'event.toolName === "read"' not in text and 'toolName === "read"' not in text:
        # Accept combined write/edit/read branch
        if not re.search(r'toolName === "write".*toolName === "edit".*toolName === "read"', text, re.DOTALL):
            if 'read' not in text or 'isProtectedPath' not in text:
                errors.append(f'{extension}: must apply protected-path policy to read')

if readme.exists():
    text = readme.read_text()
    for marker in ['pi-mcp-adapter@2.11.0', 'extensions/b-agentic-permissions.ts', 'mcp.json']:
        if marker not in text:
            errors.append(f'{readme}: missing {marker!r}')

if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print('Pi runtime validation passed.')
PY
