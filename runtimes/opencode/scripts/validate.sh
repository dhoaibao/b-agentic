#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"

python3 - <<'PY'
from pathlib import Path
import re
import sys

root = Path('.')
errors = []


def command_exposed_skill_names():
    names = set()
    for path in root.glob('skills/*/SKILL.md'):
        text = path.read_text()
        frontmatter = ''
        if text.startswith('---\n'):
            parts = text.split('---', 2)
            if len(parts) >= 3:
                frontmatter = parts[1]

        if re.search(r'^user-invocable:\s*false\s*$', frontmatter, re.MULTILINE):
            continue

        names.add(path.parent.name)
    return names


skill_names = command_exposed_skill_names()

kernel_path = root / 'runtimes' / 'opencode' / 'kernel.md'
kernel = kernel_path.read_text() if kernel_path.exists() else ''
opencode_readme = (root / 'runtimes' / 'opencode' / 'configs' / 'README.md').read_text() if (root / 'runtimes' / 'opencode' / 'configs' / 'README.md').exists() else ''
contract_index = (root / 'references' / 'contract' / 'index.md').read_text() if (root / 'references' / 'contract' / 'index.md').exists() else ''
maintainer = (root / 'CLAUDE.md').read_text() if (root / 'CLAUDE.md').exists() else ''
opencode_install = (root / 'runtimes' / 'opencode' / 'scripts' / 'install.sh').read_text() if (root / 'runtimes' / 'opencode' / 'scripts' / 'install.sh').exists() else ''
commands_dir = root / 'runtimes' / 'opencode' / 'commands'

if not kernel_path.exists():
    errors.append('runtimes/opencode/kernel.md: missing')
if '<!-- b-agentic-managed -->' not in kernel:
    errors.append('runtimes/opencode/kernel.md: missing b-agentic managed marker')
for marker in ['Reference checklist:', 'Runtime gate checklist:', 'AGENTS.md', 'Detailed routing', 'runtime contract §9']:
    if marker not in kernel:
        errors.append(f'runtimes/opencode/kernel.md: missing kernel marker {marker!r}')
if 'Reference gate:' in kernel:
    errors.append("runtimes/opencode/kernel.md: stale 'Reference gate:' terminology; use 'Reference checklist:'")

if 'OpenCode' not in maintainer:
    errors.append('CLAUDE.md: must mention OpenCode as a supported runtime')

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

for required in ['COMMANDS_SRC', 'COMMANDS_DST', 'install_commands', 'commandsSynced']:
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
if '${CLAUDE_SKILL_DIR}' not in opencode_readme or 'only intentional shared bridge marker' not in opencode_readme:
    errors.append('runtimes/opencode/configs/README.md: must keep the shared bridge-marker constraint explicit')

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)

print('OpenCode runtime validation passed.')
PY
