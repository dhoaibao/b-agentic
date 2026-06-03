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


def command_exposed_skill_names():
    registry_path = root / 'skills' / 'registry.yaml'
    try:
        registry = json.loads(registry_path.read_text())
    except Exception as exc:
        errors.append(f'{registry_path}: invalid JSON-compatible YAML registry: {exc}')
        return set()

    names = set()
    for skill in registry.get('skills', []):
        if not isinstance(skill, dict):
            errors.append('skills/registry.yaml: skill entries must be objects')
            continue
        command = skill.get('command', {})
        if not isinstance(command, dict):
            errors.append(f"skills/registry.yaml: missing command object for {skill.get('name')!r}")
            continue
        if command.get('exposed') is True:
            alias = command.get('alias')
            if not isinstance(alias, str) or not alias:
                errors.append(f"skills/registry.yaml: invalid command alias for {skill.get('name')!r}")
                continue
            names.add(alias)
    return names


skill_names = command_exposed_skill_names()

kernel_path = root / 'runtimes' / 'opencode' / 'kernel.md'
kernel = kernel_path.read_text() if kernel_path.exists() else ''
opencode_readme = (root / 'runtimes' / 'opencode' / 'configs' / 'README.md').read_text() if (root / 'runtimes' / 'opencode' / 'configs' / 'README.md').exists() else ''
contract_index = (root / 'references' / 'contract' / 'index.md').read_text() if (root / 'references' / 'contract' / 'index.md').exists() else ''
maintainer = (root / 'CLAUDE.md').read_text() if (root / 'CLAUDE.md').exists() else ''
opencode_install = (root / 'runtimes' / 'opencode' / 'scripts' / 'install.sh').read_text() if (root / 'runtimes' / 'opencode' / 'scripts' / 'install.sh').exists() else ''
commands_dir = root / 'runtimes' / 'opencode' / 'commands'
runtime_registry_path = root / 'runtimes' / 'registry.yaml'

try:
    runtime_registry = json.loads(runtime_registry_path.read_text())
except Exception as exc:
    runtime_registry = {}
    errors.append(f'{runtime_registry_path}: invalid JSON-compatible YAML registry: {exc}')

opencode_runtime = None
for runtime in runtime_registry.get('runtimes', []):
    if isinstance(runtime, dict) and runtime.get('name') == 'opencode':
        opencode_runtime = runtime
        break

if not kernel_path.exists():
    errors.append('runtimes/opencode/kernel.md: missing')
if '<!-- b-agentic-managed -->' not in kernel:
    errors.append('runtimes/opencode/kernel.md: missing b-agentic managed marker')
for marker in ['Runtime Kernel', 'AGENTS.md', 'runtime.md', 'safety-tools.md', 'output.md', 'decisions.md']:
    if marker not in kernel:
        errors.append(f'runtimes/opencode/kernel.md: missing kernel marker {marker!r}')
if 'Reference gate:' in kernel:
    errors.append("runtimes/opencode/kernel.md: stale 'Reference gate:' terminology; use the runtime kernel contract list")

if 'OpenCode' not in maintainer:
    errors.append('CLAUDE.md: must mention OpenCode as a supported runtime')

if not isinstance(opencode_runtime, dict):
    errors.append('runtimes/registry.yaml: missing opencode runtime entry')
else:
    command_wrappers = opencode_runtime.get('command_wrappers')
    if not isinstance(command_wrappers, dict) or command_wrappers.get('supported') is not True:
        errors.append('runtimes/registry.yaml: opencode must declare supported command wrappers')
    elif command_wrappers.get('source_dir') != 'runtimes/opencode/commands':
        errors.append('runtimes/registry.yaml: opencode command wrapper source_dir must be runtimes/opencode/commands')

for required in [
    '~/.config/opencode/b-agentic',
    '/tmp/opencode/b-agentic',
]:
    if required not in contract_index:
        errors.append(f'references/contract/index.md: missing OpenCode-native marker {required!r}')

for required in ['SKILLS_DST', 'KERNEL_DST', 'METADATA_DIR', 'runtime_main', 'OPENCODE_JSON_DST', 'install_mcp_config']:
    if required not in opencode_install:
        errors.append(f'runtimes/opencode/scripts/install.sh: missing OpenCode installer marker {required!r}')

if not commands_dir.exists():
    errors.append('runtimes/opencode/commands: missing OpenCode command wrapper source directory')
else:
    command_names = {path.stem for path in commands_dir.glob('*.md')}
    missing_commands = sorted(skill_names - command_names)
    extra_commands = sorted(command_names - skill_names)
    if missing_commands or extra_commands:
        errors.append(
            'runtimes/opencode/commands: command wrappers must match skills/ directories '
            f'(missing: {missing_commands}, extra: {extra_commands})'
        )

for required in ['COMMANDS_SRC', 'COMMANDS_DST', 'install_commands', 'report_item "commands"']:
    if required not in opencode_install:
        errors.append(f'runtimes/opencode/scripts/install.sh: missing OpenCode command wrapper marker {required!r}')

mcp_template_path = root / 'runtimes' / 'opencode' / 'configs' / 'mcp.user.template.json'
if not mcp_template_path.exists():
    errors.append('runtimes/opencode/configs/mcp.user.template.json: missing MCP template')

if 'OpenCode Runtime Layout' not in opencode_readme:
    errors.append('runtimes/opencode/configs/README.md: missing title')
if 'mcp.user.template.json' not in opencode_readme:
    errors.append('runtimes/opencode/configs/README.md: missing mcp.user.template.json reference')
if '~/.config/opencode/commands/' not in opencode_readme:
    errors.append('runtimes/opencode/configs/README.md: missing OpenCode command wrapper path documentation')
if 'runtime-neutral' not in opencode_readme:
    errors.append('runtimes/opencode/configs/README.md: must state that shared skills/contracts stay runtime-neutral')
if '~/.config/opencode/skills/' not in opencode_readme:
    errors.append('runtimes/opencode/configs/README.md: must document the OpenCode skills install root')
for required in [
    'Continuation and resume guarantees',
    'does not provide native phase-to-phase automation',
    'operator-issued skill invocations',
]:
    if required not in opencode_readme:
        errors.append(f'runtimes/opencode/configs/README.md: missing continuation/card marker {required!r}')

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)

print('OpenCode runtime validation passed.')
PY
