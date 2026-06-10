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

kernel_path = root / 'runtimes' / 'kilo-code' / 'kernel.md'
kernel = kernel_path.read_text() if kernel_path.exists() else ''
kilo_readme = (root / 'runtimes' / 'kilo-code' / 'configs' / 'README.md').read_text() if (root / 'runtimes' / 'kilo-code' / 'configs' / 'README.md').exists() else ''
contract_index = (root / 'references' / 'contract' / 'index.md').read_text() if (root / 'references' / 'contract' / 'index.md').exists() else ''
maintainer = (root / 'CLAUDE.md').read_text() if (root / 'CLAUDE.md').exists() else ''
kilo_install = (root / 'runtimes' / 'kilo-code' / 'scripts' / 'install.sh').read_text() if (root / 'runtimes' / 'kilo-code' / 'scripts' / 'install.sh').exists() else ''
agents_dir = root / 'runtimes' / 'kilo-code' / 'agents'
runtime_registry_path = root / 'runtimes' / 'registry.yaml'

try:
    runtime_registry = json.loads(runtime_registry_path.read_text())
except Exception as exc:
    runtime_registry = {}
    errors.append(f'{runtime_registry_path}: invalid JSON-compatible YAML registry: {exc}')

kilo_runtime = None
for runtime in runtime_registry.get('runtimes', []):
    if isinstance(runtime, dict) and runtime.get('name') == 'kilo-code':
        kilo_runtime = runtime
        break

if not kernel_path.exists():
    errors.append('runtimes/kilo-code/kernel.md: missing')
if '<!-- b-agentic-managed -->' not in kernel:
    errors.append('runtimes/kilo-code/kernel.md: missing b-agentic managed marker')
for marker in ['Runtime Kernel', 'AGENTS.md', 'runtime.md', 'safety-tools.md', 'output.md', 'decisions.md']:
    if marker not in kernel:
        errors.append(f'runtimes/kilo-code/kernel.md: missing kernel marker {marker!r}')
if 'Reference gate:' in kernel:
    errors.append("runtimes/kilo-code/kernel.md: stale 'Reference gate:' terminology; use the runtime kernel contract list")

if 'Kilo Code' not in maintainer:
    errors.append('CLAUDE.md: must mention Kilo Code as a supported runtime')

if not isinstance(kilo_runtime, dict):
    errors.append('runtimes/registry.yaml: missing kilo-code runtime entry')
else:
    command_wrappers = kilo_runtime.get('command_wrappers')
    if not isinstance(command_wrappers, dict) or command_wrappers.get('supported') is not False:
        errors.append('runtimes/registry.yaml: kilo-code must declare unsupported command wrappers')

for required in [
    '~/.config/kilo/b-agentic',
    '/tmp/kilo-code/b-agentic',
]:
    if required not in contract_index:
        errors.append(f'references/contract/index.md: missing Kilo Code-native marker {required!r}')

for required in ['SKILLS_DST', 'KERNEL_DST', 'METADATA_DIR', 'runtime_main', 'KILO_JSONC_DST', 'install_mcp_config']:
    if required not in kilo_install:
        errors.append(f'runtimes/kilo-code/scripts/install.sh: missing Kilo Code installer marker {required!r}')

if not agents_dir.exists():
    errors.append('runtimes/kilo-code/agents: missing Kilo Code agent profile source directory')
else:
    expected_agents = {'b-explore', 'b-research', 'b-review', 'b-verify'}
    agent_names = {path.stem for path in agents_dir.glob('*.md')}
    if agent_names != expected_agents:
        errors.append(f'runtimes/kilo-code/agents: expected {sorted(expected_agents)}, found {sorted(agent_names)}')
for required in ['AGENTS_SRC', 'AGENTS_DST', 'install_managed_profiles', 'uninstall_managed_profiles', 'report_item "agents"']:
    if required not in kilo_install:
        errors.append(f'runtimes/kilo-code/scripts/install.sh: missing Kilo Code agent profile marker {required!r}')

mcp_template_path = root / 'runtimes' / 'kilo-code' / 'configs' / 'mcp.user.template.json'
if not mcp_template_path.exists():
    errors.append('runtimes/kilo-code/configs/mcp.user.template.json: missing MCP template')

if 'Kilo Code Runtime Layout' not in kilo_readme:
    errors.append('runtimes/kilo-code/configs/README.md: missing title')
if 'mcp.user.template.json' not in kilo_readme:
    errors.append('runtimes/kilo-code/configs/README.md: missing mcp.user.template.json reference')
if 'runtime-neutral' not in kilo_readme:
    errors.append('runtimes/kilo-code/configs/README.md: must state that shared skills/contracts stay runtime-neutral')
if '~/.config/kilo/skills/' not in kilo_readme:
    errors.append('runtimes/kilo-code/configs/README.md: must document the Kilo Code skills install root')
for required in ['Optional subagent profiles', '~/.config/kilo/agents/', 'User-owned or modified profiles are preserved']:
    if required not in kilo_readme:
        errors.append(f'runtimes/kilo-code/configs/README.md: missing governance marker {required!r}')
for required in [
    'Continuation and resume guarantees',
    'does not provide native phase-to-phase automation',
    'operator-issued skill invocations',
]:
    if required not in kilo_readme:
        errors.append(f'runtimes/kilo-code/configs/README.md: missing continuation/card marker {required!r}')

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)

print('Kilo Code runtime validation passed.')
PY
