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

kernel_path = root / 'runtimes' / 'opencode' / 'kernel.md'
kernel = kernel_path.read_text() if kernel_path.exists() else ''
opencode_readme = (root / 'runtimes' / 'opencode' / 'configs' / 'README.md').read_text() if (root / 'runtimes' / 'opencode' / 'configs' / 'README.md').exists() else ''
contract_index = (root / 'references' / 'contract' / 'index.md').read_text() if (root / 'references' / 'contract' / 'index.md').exists() else ''
maintainer = (root / 'CLAUDE.md').read_text() if (root / 'CLAUDE.md').exists() else ''
opencode_install = (root / 'runtimes' / 'opencode' / 'scripts' / 'install.sh').read_text() if (root / 'runtimes' / 'opencode' / 'scripts' / 'install.sh').exists() else ''

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

for required in ['SKILLS_DST', 'KERNEL_DST', 'METADATA_DIR', 'runtime_main']:
    if required not in opencode_install:
        errors.append(f'runtimes/opencode/scripts/install.sh: missing OpenCode installer marker {required!r}')

if 'OpenCode Runtime Layout' not in opencode_readme:
    errors.append('runtimes/opencode/configs/README.md: missing title')

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)

print('OpenCode runtime validation passed.')
PY
