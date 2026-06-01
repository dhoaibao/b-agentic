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

kernel_path = root / 'runtimes' / 'zed' / 'kernel.md'
kernel = kernel_path.read_text() if kernel_path.exists() else ''
runtime_readme_path = root / 'runtimes' / 'zed' / 'configs' / 'README.md'
runtime_readme = runtime_readme_path.read_text() if runtime_readme_path.exists() else ''
maintainer = (root / 'CLAUDE.md').read_text() if (root / 'CLAUDE.md').exists() else ''
zed_install = (root / 'runtimes' / 'zed' / 'scripts' / 'install.sh').read_text() if (root / 'runtimes' / 'zed' / 'scripts' / 'install.sh').exists() else ''
runtime_registry_path = root / 'runtimes' / 'registry.yaml'
mcp_template_path = root / 'runtimes' / 'zed' / 'configs' / 'mcp.user.template.json'

try:
    runtime_registry = json.loads(runtime_registry_path.read_text())
except Exception as exc:
    runtime_registry = {}
    errors.append(f'{runtime_registry_path}: invalid JSON-compatible YAML registry: {exc}')

runtime = None
for candidate in runtime_registry.get('runtimes', []):
    if isinstance(candidate, dict) and candidate.get('name') == 'zed':
        runtime = candidate
        break

if not kernel_path.exists():
    errors.append('runtimes/zed/kernel.md: missing')
if '<!-- b-agentic-managed -->' not in kernel:
    errors.append('runtimes/zed/kernel.md: missing b-agentic managed marker')
for marker in ['Reference checklist:', 'Runtime gate checklist:', 'AGENTS.md', 'Zed', 'runtime contract §9']:
    if marker not in kernel:
        errors.append(f'runtimes/zed/kernel.md: missing kernel marker {marker!r}')
if '~/.agents/b-agentic/references/contract/' not in kernel:
    errors.append('runtimes/zed/kernel.md: missing Zed reference path')
if '~/.agents/b-agentic/references/cards/' not in kernel:
    errors.append('runtimes/zed/kernel.md: missing Zed decision-card path')

if 'Zed' not in maintainer:
    errors.append('CLAUDE.md: must mention Zed as a supported runtime')

if not isinstance(runtime, dict):
    errors.append('runtimes/registry.yaml: missing zed runtime entry')
else:
    expected = {
        'memory_install_path': '~/.config/zed/AGENTS.md',
        'metadata_root': '~/.agents/b-agentic',
        'skills_install_root': '~/.agents/skills',
        'config_schema_family': 'zed-json',
    }
    for key, value in expected.items():
        if runtime.get(key) != value:
            errors.append(f'runtimes/registry.yaml: zed {key} must be {value}')
    command_wrappers = runtime.get('command_wrappers')
    if not isinstance(command_wrappers, dict) or command_wrappers.get('supported') is not False:
        errors.append('runtimes/registry.yaml: zed must not declare command wrappers')
    elif command_wrappers.get('source_dir') is not None or command_wrappers.get('install_root') is not None:
        errors.append('runtimes/registry.yaml: zed command wrapper paths must be null')

for required in [
    'ZED_CONFIG_DIR',
    'MCP_CONFIG_DST',
    'mcp.user.template.json',
    'install_mcp_config',
    'runtime_main',
    'report_item "mcp"',
]:
    if required not in zed_install:
        errors.append(f'runtimes/zed/scripts/install.sh: missing Zed installer marker {required!r}')

if not mcp_template_path.exists():
    errors.append('runtimes/zed/configs/mcp.user.template.json: missing MCP config template')
else:
    try:
        template = json.loads(mcp_template_path.read_text())
    except Exception as exc:
        errors.append(f'runtimes/zed/configs/mcp.user.template.json: invalid JSON: {exc}')
        template = {}
    servers = template.get('context_servers', {})
    expected_servers = {'serena', 'context7', 'brave-search', 'firecrawl', 'playwright'}
    if set(servers) != expected_servers:
        errors.append(f'runtimes/zed/configs/mcp.user.template.json: expected default MCP servers {sorted(expected_servers)}, found {sorted(servers)}')
    context7 = servers.get('context7', {})
    if context7.get('url') != 'https://mcp.context7.com/mcp':
        errors.append('runtimes/zed/configs/mcp.user.template.json: context7 must use url')
    if 'serverUrl' in context7:
        errors.append('runtimes/zed/configs/mcp.user.template.json: context7 must not use serverUrl')
    if context7.get('headers', {}).get('CONTEXT7_API_KEY') != '$CONTEXT7_API_KEY':
        errors.append('runtimes/zed/configs/mcp.user.template.json: context7 must use $CONTEXT7_API_KEY header placeholder')
    if servers.get('playwright', {}).get('args', [])[-1:] != ['--isolated']:
        errors.append('runtimes/zed/configs/mcp.user.template.json: playwright must use --isolated by default')

if 'Zed Runtime Layout' not in runtime_readme:
    errors.append('runtimes/zed/configs/README.md: missing title')
for needle in [
    '~/.config/zed/settings.json',
    '~/.agents/skills/',
    'mcp.user.template.json',
    'url',
    'runtime-neutral',
    'native slash command',
    'Shared decision cards: `~/.agents/b-agentic/references/cards/*.md`',
    'Continuation and resume guarantees',
    'does not provide native phase-to-phase automation',
    'operator-issued skill invocations',
]:
    if needle not in runtime_readme:
        errors.append(f'runtimes/zed/configs/README.md: missing Zed documentation marker {needle!r}')

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)

print('Zed runtime validation passed.')
PY
