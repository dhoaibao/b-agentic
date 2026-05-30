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
    print('Codex CLI runtime validation requires Python 3.11+ (stdlib tomllib).', file=sys.stderr)
    sys.exit(1)

root = Path('.')
errors = []

kernel_path = root / 'runtimes' / 'codex-cli' / 'kernel.md'
kernel = kernel_path.read_text() if kernel_path.exists() else ''
codex_readme = (root / 'runtimes' / 'codex-cli' / 'configs' / 'README.md').read_text() if (root / 'runtimes' / 'codex-cli' / 'configs' / 'README.md').exists() else ''
contract_index = (root / 'references' / 'contract' / 'index.md').read_text() if (root / 'references' / 'contract' / 'index.md').exists() else ''
maintainer = (root / 'CLAUDE.md').read_text() if (root / 'CLAUDE.md').exists() else ''
codex_install = (root / 'runtimes' / 'codex-cli' / 'scripts' / 'install.sh').read_text() if (root / 'runtimes' / 'codex-cli' / 'scripts' / 'install.sh').exists() else ''
runtime_registry_path = root / 'runtimes' / 'registry.yaml'
template_path = root / 'runtimes' / 'codex-cli' / 'configs' / 'mcp.user.template.toml'

try:
    runtime_registry = json.loads(runtime_registry_path.read_text())
except Exception as exc:
    runtime_registry = {}
    errors.append(f'{runtime_registry_path}: invalid JSON-compatible YAML registry: {exc}')

codex_runtime = None
for runtime in runtime_registry.get('runtimes', []):
    if isinstance(runtime, dict) and runtime.get('name') == 'codex-cli':
        codex_runtime = runtime
        break

if not kernel_path.exists():
    errors.append('runtimes/codex-cli/kernel.md: missing')
if '<!-- b-agentic-managed -->' not in kernel:
    errors.append('runtimes/codex-cli/kernel.md: missing b-agentic managed marker')
for marker in ['Reference checklist:', 'Runtime gate checklist:', 'AGENTS.md', 'Detailed routing', 'runtime contract §9']:
    if marker not in kernel:
        errors.append(f'runtimes/codex-cli/kernel.md: missing kernel marker {marker!r}')

if 'Codex CLI' not in maintainer:
    errors.append('CLAUDE.md: must mention Codex CLI as a supported runtime')

if not isinstance(codex_runtime, dict):
    errors.append('runtimes/registry.yaml: missing codex-cli runtime entry')
else:
    if codex_runtime.get('memory_install_path') != '~/.codex/AGENTS.md':
        errors.append('runtimes/registry.yaml: codex-cli memory_install_path must be ~/.codex/AGENTS.md')
    if codex_runtime.get('skills_install_root') != '~/.codex/skills':
        errors.append('runtimes/registry.yaml: codex-cli skills_install_root must be ~/.codex/skills')
    wrappers = codex_runtime.get('command_wrappers')
    if not isinstance(wrappers, dict) or wrappers.get('supported') is not False:
        errors.append('runtimes/registry.yaml: codex-cli must declare unsupported command wrappers')

for required in [
    '~/.codex/b-agentic',
    '/tmp/codex-cli/b-agentic',
]:
    if required not in contract_index:
        errors.append(f'references/contract/index.md: missing Codex marker {required!r}')

for required in [
    'CODEX_DIR',
    'CODEX_CONFIG_DST',
    'skills.config',
    'mcp_servers',
    '[features]',
    'hooks = true',
    '[[hooks.SessionStart]]',
    '[[hooks.PreToolUse]]',
    '[[hooks.Stop]]',
    'serena-hooks activate --client=codex',
    'serena-hooks remind --client=codex',
    'serena-hooks cleanup --client=codex',
    '# BEGIN b-agentic managed config',
    'runtime_main',
]:
    if required not in codex_install:
        errors.append(f'runtimes/codex-cli/scripts/install.sh: missing Codex installer marker {required!r}')

if not template_path.exists():
    errors.append('runtimes/codex-cli/configs/mcp.user.template.toml: missing MCP template')
else:
    try:
        template = tomllib.loads(template_path.read_text())
    except tomllib.TOMLDecodeError as exc:
        errors.append(f'runtimes/codex-cli/configs/mcp.user.template.toml: invalid TOML: {exc}')
        template = {}

    servers = template.get('mcp_servers', {})
    expected = {'serena', 'context7', 'brave-search', 'firecrawl', 'playwright'}
    if set(servers) != expected:
        errors.append(f'runtimes/codex-cli/configs/mcp.user.template.toml: expected default MCP servers {sorted(expected)}, found {sorted(servers)}')
    if servers.get('serena', {}).get('command') != 'serena':
        errors.append('runtimes/codex-cli/configs/mcp.user.template.toml: serena must use the installed serena binary')
    if servers.get('serena', {}).get('args') != ['start-mcp-server', '--context', 'codex', '--project-from-cwd']:
        errors.append('runtimes/codex-cli/configs/mcp.user.template.toml: serena must use --context codex')
    if servers.get('context7', {}).get('url') != 'https://mcp.context7.com/mcp':
        errors.append('runtimes/codex-cli/configs/mcp.user.template.toml: context7 must use the official MCP endpoint')
    if servers.get('context7', {}).get('env_http_headers', {}).get('CONTEXT7_API_KEY') != 'CONTEXT7_API_KEY':
        errors.append('runtimes/codex-cli/configs/mcp.user.template.toml: context7 must default to env_http_headers forwarding')
    if servers.get('brave-search', {}).get('env_vars') != ['BRAVE_API_KEY']:
        errors.append('runtimes/codex-cli/configs/mcp.user.template.toml: brave-search must default to env_vars forwarding')
    if servers.get('firecrawl', {}).get('env_vars') != ['FIRECRAWL_API_KEY']:
        errors.append('runtimes/codex-cli/configs/mcp.user.template.toml: firecrawl must default to env_vars forwarding')
    if servers.get('playwright', {}).get('args', [])[-1:] != ['--isolated']:
        errors.append('runtimes/codex-cli/configs/mcp.user.template.toml: playwright must use --isolated by default')
if 'Codex CLI Runtime Layout' not in codex_readme:
    errors.append('runtimes/codex-cli/configs/README.md: missing title')
for needle in ['~/.codex/config.toml', '~/.codex/skills/', 'mcp.user.template.toml', 'skills.config', 'runtime-neutral', '--context codex']:
    if needle not in codex_readme:
        errors.append(f'runtimes/codex-cli/configs/README.md: missing Codex documentation marker {needle!r}')

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)

print('Codex CLI runtime validation passed.')
PY
