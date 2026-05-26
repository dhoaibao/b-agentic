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

kernel_path = root / 'runtimes' / 'kimi-cli' / 'kernel.md'
kernel = kernel_path.read_text() if kernel_path.exists() else ''
runtime_readme_path = root / 'runtimes' / 'kimi-cli' / 'configs' / 'README.md'
runtime_readme = runtime_readme_path.read_text() if runtime_readme_path.exists() else ''
maintainer = (root / 'CLAUDE.md').read_text() if (root / 'CLAUDE.md').exists() else ''
kimi_install = (root / 'runtimes' / 'kimi-cli' / 'scripts' / 'install.sh').read_text() if (root / 'runtimes' / 'kimi-cli' / 'scripts' / 'install.sh').exists() else ''
runtime_registry_path = root / 'runtimes' / 'registry.yaml'
settings_template_path = root / 'runtimes' / 'kimi-cli' / 'configs' / 'settings.template.json'
mcp_template_path = root / 'runtimes' / 'kimi-cli' / 'configs' / 'mcp_config.template.json'

try:
    runtime_registry = json.loads(runtime_registry_path.read_text())
except Exception as exc:
    runtime_registry = {}
    errors.append(f'{runtime_registry_path}: invalid JSON-compatible YAML registry: {exc}')

runtime = None
for candidate in runtime_registry.get('runtimes', []):
    if isinstance(candidate, dict) and candidate.get('name') == 'kimi-cli':
        runtime = candidate
        break

if not kernel_path.exists():
    errors.append('runtimes/kimi-cli/kernel.md: missing')
if '<!-- b-agentic-managed -->' not in kernel:
    errors.append('runtimes/kimi-cli/kernel.md: missing b-agentic managed marker')
for marker in ['Reference checklist:', 'Runtime gate checklist:', 'AGENTS.md', 'Kimi Code CLI', 'runtime contract §9']:
    if marker not in kernel:
        errors.append(f'runtimes/kimi-cli/kernel.md: missing kernel marker {marker!r}')
if '~/.kimi/b-agentic/references/contract/' not in kernel:
    errors.append('runtimes/kimi-cli/kernel.md: missing Kimi reference path')

if 'Kimi Code CLI' not in maintainer:
    errors.append('CLAUDE.md: must mention Kimi Code CLI as a supported runtime')

if not isinstance(runtime, dict):
    errors.append('runtimes/registry.yaml: missing kimi-cli runtime entry')
else:
    expected = {
        'memory_install_path': '~/.kimi/AGENTS.md',
        'metadata_root': '~/.kimi/b-agentic',
        'skills_install_root': '~/.kimi/skills',
        'config_schema_family': 'kimi-mcp-json',
    }
    for key, value in expected.items():
        if runtime.get(key) != value:
            errors.append(f'runtimes/registry.yaml: kimi-cli {key} must be {value}')
    command_wrappers = runtime.get('command_wrappers')
    if not isinstance(command_wrappers, dict) or command_wrappers.get('supported') is not False:
        errors.append('runtimes/registry.yaml: kimi-cli must not declare command wrappers')
    elif command_wrappers.get('source_dir') is not None or command_wrappers.get('install_root') is not None:
        errors.append('runtimes/registry.yaml: kimi-cli command wrapper paths must be null')

for required in [
    'KIMI_DIR',
    'MCP_CONFIG_DST',
    'mcp_config.template.json',
    'install_mcp_config',
    'runtime_main',
    'report_item "mcp"',
]:
    if required not in kimi_install:
        errors.append(f'runtimes/kimi-cli/scripts/install.sh: missing Kimi installer marker {required!r}')

if not settings_template_path.exists():
    errors.append('runtimes/kimi-cli/configs/settings.template.json: missing settings template')
else:
    try:
        settings = json.loads(settings_template_path.read_text())
    except Exception as exc:
        errors.append(f'runtimes/kimi-cli/configs/settings.template.json: invalid JSON: {exc}')
        settings = None
    if settings != {}:
        errors.append('runtimes/kimi-cli/configs/settings.template.json: settings template must be empty object')

if not mcp_template_path.exists():
    errors.append('runtimes/kimi-cli/configs/mcp_config.template.json: missing MCP config template')
else:
    try:
        template = json.loads(mcp_template_path.read_text())
    except Exception as exc:
        errors.append(f'runtimes/kimi-cli/configs/mcp_config.template.json: invalid JSON: {exc}')
        template = {}
    servers = template.get('mcpServers', {})
    expected_servers = {'serena', 'context7', 'brave-search', 'firecrawl', 'playwright', 'gitnexus'}
    if set(servers) != expected_servers:
        errors.append(f'runtimes/kimi-cli/configs/mcp_config.template.json: expected default MCP servers {sorted(expected_servers)}, found {sorted(servers)}')
    context7 = servers.get('context7', {})
    if context7.get('serverUrl') != 'https://mcp.context7.com/mcp':
        errors.append('runtimes/kimi-cli/configs/mcp_config.template.json: context7 must use serverUrl')
    if 'httpUrl' in context7:
        errors.append('runtimes/kimi-cli/configs/mcp_config.template.json: context7 must not use httpUrl')
    if context7.get('headers', {}).get('CONTEXT7_API_KEY') != '$CONTEXT7_API_KEY':
        errors.append('runtimes/kimi-cli/configs/mcp_config.template.json: context7 must use $CONTEXT7_API_KEY header placeholder')
    if servers.get('playwright', {}).get('args', [])[-1:] != ['--isolated']:
        errors.append('runtimes/kimi-cli/configs/mcp_config.template.json: playwright must use --isolated by default')

if 'Kimi Code CLI Runtime Layout' not in runtime_readme:
    errors.append('runtimes/kimi-cli/configs/README.md: missing title')
for needle in [
    '~/.kimi/mcp.json',
    '~/.kimi/skills/',
    'mcp_config.template.json',
    'serverUrl',
    'runtime-neutral',
    'native skill loader',
    'config.toml',
]:
    if needle not in runtime_readme:
        errors.append(f'runtimes/kimi-cli/configs/README.md: missing Kimi documentation marker {needle!r}')

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)

print('Kimi Code CLI runtime validation passed.')
PY
