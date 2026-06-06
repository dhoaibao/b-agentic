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
    print('Kimi Code CLI runtime validation requires Python 3.11+ (stdlib tomllib).', file=sys.stderr)
    sys.exit(1)

root = Path('.')
errors = []

kernel_path = root / 'runtimes' / 'kimi-code-cli' / 'kernel.md'
kernel = kernel_path.read_text() if kernel_path.exists() else ''
kimi_readme_path = root / 'runtimes' / 'kimi-code-cli' / 'configs' / 'README.md'
kimi_readme = kimi_readme_path.read_text() if kimi_readme_path.exists() else ''
kimi_install_path = root / 'runtimes' / 'kimi-code-cli' / 'scripts' / 'install.sh'
kimi_install = kimi_install_path.read_text() if kimi_install_path.exists() else ''
runtime_registry_path = root / 'runtimes' / 'registry.yaml'
template_path = root / 'runtimes' / 'kimi-code-cli' / 'configs' / 'mcp.user.template.json'
commands_dir = root / 'runtimes' / 'kimi-code-cli' / 'commands'

try:
    runtime_registry = json.loads(runtime_registry_path.read_text())
except Exception as exc:
    runtime_registry = {}
    errors.append(f'{runtime_registry_path}: invalid JSON-compatible YAML registry: {exc}')

kimi_runtime = None
for runtime in runtime_registry.get('runtimes', []):
    if isinstance(runtime, dict) and runtime.get('name') == 'kimi-code-cli':
        kimi_runtime = runtime
        break

if not kernel_path.exists():
    errors.append('runtimes/kimi-code-cli/kernel.md: missing')
if '<!-- b-agentic-managed -->' not in kernel:
    errors.append('runtimes/kimi-code-cli/kernel.md: missing b-agentic managed marker')
for marker in ['Runtime Kernel', 'AGENTS.md', 'runtime.md', 'safety-tools.md', 'output.md', 'decisions.md']:
    if marker not in kernel:
        errors.append(f'runtimes/kimi-code-cli/kernel.md: missing kernel marker {marker!r}')

if not isinstance(kimi_runtime, dict):
    errors.append('runtimes/registry.yaml: missing kimi-code-cli runtime entry')
else:
    expected_paths = {
        'memory_install_path': '~/.kimi-code/AGENTS.md',
        'metadata_root': '~/.kimi-code/b-agentic',
        'skills_install_root': '~/.kimi-code/skills',
        'config_template_dir': 'runtimes/kimi-code-cli/configs',
        'config_schema_family': 'kimi-code',
    }
    for key, expected in expected_paths.items():
        if kimi_runtime.get(key) != expected:
            errors.append(f'runtimes/registry.yaml: kimi-code-cli {key} must be {expected}')
    wrappers = kimi_runtime.get('command_wrappers')
    if not isinstance(wrappers, dict) or wrappers.get('supported') is not False:
        errors.append('runtimes/registry.yaml: kimi-code-cli must declare unsupported command wrappers')
    capabilities = kimi_runtime.get('capabilities', {})
    wrapper_capability = capabilities.get('command_wrappers', {}) if isinstance(capabilities, dict) else {}
    if wrapper_capability.get('support') != 'unsupported':
        errors.append('runtimes/registry.yaml: kimi-code-cli command wrappers capability must be unsupported')

if commands_dir.exists():
    errors.append('runtimes/kimi-code-cli/commands: Kimi adapter must not ship command wrappers')

for required in [
    'KIMI_DIR',
    'KIMI_CODE_HOME',
    'KIMI_CONFIG_DST',
    'MCP_CONFIG_DST',
    'mcpServers',
    'KIMI_MANAGED_BEGIN',
    '[[hooks]]',
    'event = "Stop"',
    'check-runtime.py',
    '--client kimi-code-cli',
    '--event stop',
    'RUNTIME_PRE_ACTION_ENFORCEMENT="advisory-only"',
    'install_hook_checker',
    'install_mcp_config',
    'hooksState',
    'runtime_install_common',
]:
    if required not in kimi_install:
        errors.append(f'runtimes/kimi-code-cli/scripts/install.sh: missing Kimi installer marker {required!r}')

if not template_path.exists():
    errors.append('runtimes/kimi-code-cli/configs/mcp.user.template.json: missing MCP template')
else:
    try:
        template = json.loads(template_path.read_text())
    except Exception as exc:
        errors.append(f'runtimes/kimi-code-cli/configs/mcp.user.template.json: invalid JSON: {exc}')
        template = {}
    servers = template.get('mcpServers', {})
    expected = {'serena', 'context7', 'brave-search', 'firecrawl', 'playwright'}
    if set(servers) != expected:
        errors.append(f'runtimes/kimi-code-cli/configs/mcp.user.template.json: expected default MCP servers {sorted(expected)}, found {sorted(servers)}')
    if servers.get('serena', {}).get('command') != 'serena':
        errors.append('runtimes/kimi-code-cli/configs/mcp.user.template.json: serena must use the installed serena binary')
    if servers.get('serena', {}).get('args') != ['start-mcp-server', '--context', 'kimi-code-cli', '--project-from-cwd']:
        errors.append('runtimes/kimi-code-cli/configs/mcp.user.template.json: serena must use --context kimi-code-cli')
    if servers.get('context7', {}).get('url') != 'https://mcp.context7.com/mcp':
        errors.append('runtimes/kimi-code-cli/configs/mcp.user.template.json: context7 must use the official MCP endpoint')
    if servers.get('brave-search', {}).get('args') != ['dlx', '@brave/brave-search-mcp-server', '--transport', 'stdio']:
        errors.append('runtimes/kimi-code-cli/configs/mcp.user.template.json: brave-search must use pnpm dlx')
    if servers.get('firecrawl', {}).get('args') != ['dlx', 'firecrawl-mcp']:
        errors.append('runtimes/kimi-code-cli/configs/mcp.user.template.json: firecrawl must use pnpm dlx')
    if servers.get('playwright', {}).get('args', [])[-1:] != ['--isolated']:
        errors.append('runtimes/kimi-code-cli/configs/mcp.user.template.json: playwright must use --isolated by default')

if 'Kimi Code CLI Runtime Layout' not in kimi_readme:
    errors.append('runtimes/kimi-code-cli/configs/README.md: missing title')
for needle in [
    '~/.kimi-code/config.toml',
    '~/.kimi-code/skills/',
    '~/.kimi-code/mcp.json',
    'mcp.user.template.json',
    '/skill:<name>',
    'does not install `/b-*` command wrapper files',
    'fail-open',
    'advisory-only',
    '--context kimi-code-cli',
]:
    if needle not in kimi_readme:
        errors.append(f'runtimes/kimi-code-cli/configs/README.md: missing Kimi documentation marker {needle!r}')

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)

print('Kimi Code CLI runtime validation passed.')
PY
