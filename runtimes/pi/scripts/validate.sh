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
        'isTrustedManagedMcpCall',
        'isTrustedManagedTool',
        'MANAGED_MCP_SERVERS',
        'FULLY_TRUSTED_MCP_SERVERS',
        'FIRECRAWL_TRUSTED_TOOLS',
        'PLAYWRIGHT_TRUSTED_TOOLS',
        'firecrawl_search',
        'browser_snapshot',
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
    for server in ['serena', 'codegraph', 'context7', 'brave-search', 'firecrawl', 'playwright']:
        if f'"{server}"' not in text:
            errors.append(f'{extension}: missing managed MCP server {server!r}')
    firecrawl_trusted = re.search(r'FIRECRAWL_TRUSTED_TOOLS = new Set\(\[(.*?)\]\)', text, re.DOTALL)
    if firecrawl_trusted:
        # Exact quoted ids only so firecrawl_agent_status / firecrawl_interact_stop remain allowed.
        for forbidden in [
            '"firecrawl_interact"',
            '"firecrawl_parse"',
            '"firecrawl_search_feedback"',
            '"firecrawl_feedback"',
            '"firecrawl_agent"',
            '"firecrawl_crawl"',
        ]:
            if forbidden in firecrawl_trusted.group(1):
                errors.append(f'{extension}: {forbidden} must not be in FIRECRAWL_TRUSTED_TOOLS')
    playwright_trusted = re.search(r'PLAYWRIGHT_TRUSTED_TOOLS = new Set\(\[(.*?)\]\)', text, re.DOTALL)
    if playwright_trusted and re.search(r'"browser_click"', playwright_trusted.group(1)):
        errors.append(f'{extension}: browser_click must not be in PLAYWRIGHT_TRUSTED_TOOLS')
    if 'explicitServer' not in text or 'fromName' not in text:
        errors.append(f'{extension}: must fail closed on explicit server / tool-name mismatch')
    if 'hasConnect' not in text or 'hasTool' not in text:
        errors.append(f'{extension}: must fail closed on mixed connect/tool MCP selectors')
    if "typeof value.server === \"string\"" not in text or "typeof value.search === \"string\"" not in text:
        errors.append(f'{extension}: connect mixed-selector gate must cover server/search')
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
