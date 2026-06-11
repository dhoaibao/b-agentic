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

kernel_path = root / 'runtimes' / 'claude-code' / 'kernel.md'
kernel = kernel_path.read_text() if kernel_path.exists() else ''
claude_readme = (root / 'runtimes' / 'claude-code' / 'configs' / 'README.md').read_text() if (root / 'runtimes' / 'claude-code' / 'configs' / 'README.md').exists() else ''
contract_index = (root / 'references' / 'contract' / 'index.md').read_text() if (root / 'references' / 'contract' / 'index.md').exists() else ''
maintainer = (root / 'CLAUDE.md').read_text() if (root / 'CLAUDE.md').exists() else ''
install_sh = (root / 'install.sh').read_text() if (root / 'install.sh').exists() else ''
claude_install = (root / 'runtimes' / 'claude-code' / 'scripts' / 'install.sh').read_text() if (root / 'runtimes' / 'claude-code' / 'scripts' / 'install.sh').exists() else ''
readme = (root / 'README.md').read_text() if (root / 'README.md').exists() else ''
agents_dir = root / 'runtimes' / 'claude-code' / 'agents'

if (root / 'global' / 'AGENTS.md').exists():
    errors.append('global/AGENTS.md: stale OpenCode kernel source should be removed or renamed')
if (root / 'AGENTS.md').exists():
    errors.append('AGENTS.md: stale root maintainer guide should be renamed to CLAUDE.md')

if not kernel_path.exists():
    errors.append('runtimes/claude-code/kernel.md: missing')
if '<!-- b-agentic-managed -->' not in kernel:
    errors.append('runtimes/claude-code/kernel.md: missing b-agentic managed marker')
for marker in ['Runtime Kernel', 'CLAUDE.md', 'runtime.md', 'safety-tools.md', 'output.md', 'decisions.md']:
    if marker not in kernel:
        errors.append(f'runtimes/claude-code/kernel.md: missing kernel marker {marker!r}')
if 'Reference gate:' in kernel:
    errors.append("runtimes/claude-code/kernel.md: stale 'Reference gate:' terminology; use the runtime kernel contract list")

if 'Claude Code is the reference runtime' not in maintainer:
    errors.append('CLAUDE.md: must state Claude Code is the reference runtime')
for needle in ['compatibility: opencode', 'global/AGENTS.md', 'commands/<name>.md']:
    if needle in maintainer:
        errors.append(f'CLAUDE.md: stale maintainer phrase {needle!r}')

stale_doc_patterns = [
    'OpenCode as the reference runtime',
    'global/AGENTS.md',
    'commands/<name>.md',
    'commands/*.md',
    'compatibility: opencode',
]
for doc_path, doc_text in [('README.md', readme)]:
    if not doc_text:
        continue
    for needle in stale_doc_patterns:
        if needle in doc_text:
            errors.append(f'{doc_path}: stale pattern {needle!r}')

for required in [
    'Slim shared reference snapshot',
    '~/.claude/b-agentic/references/contract/',
    '~/.claude/b-agentic',
    '/tmp/claude-code/b-agentic',
]:
    if required not in contract_index:
        errors.append(f'references/contract/index.md: missing shared or Claude-runtime marker {required!r}')

if 'global/AGENTS.md' in contract_index:
    errors.append('references/contract/index.md: contains stale active OpenCode path global/AGENTS.md')

for required in ['runtimes/$RUNTIME/kernel.md', 'skills', 'shared references support sync']:
    if required not in install_sh:
        errors.append(f'install.sh: missing shared installer marker {required!r}')

if 'references/b-agentic' in install_sh:
    errors.append("install.sh: stale shared reference path 'references/b-agentic'")

for required in ['settingsAction', 'mcpAction', 'CLAUDE_JSON_DST', 'report_item "skills"', 'report_item "agents"', '$HOME/.claude', 'report_item "activation"', 'install_hook_checker']:
    if required not in claude_install:
        errors.append(f'runtimes/claude-code/scripts/install.sh: missing Claude installer marker {required!r}')

settings_template = (root / 'runtimes' / 'claude-code' / 'configs' / 'settings.template.json').read_text()
for required in ['check-runtime.py', '--client claude-code', '--event stop']:
    if required not in settings_template:
        errors.append(f'runtimes/claude-code/configs/settings.template.json: missing hook checker marker {required!r}')

if not agents_dir.exists():
    errors.append('runtimes/claude-code/agents: missing Claude agent profile source directory')
else:
    expected_agents = {'b-explore', 'b-research', 'b-review', 'b-verify'}
    agent_names = {path.stem for path in agents_dir.glob('*.md')}
    if agent_names != expected_agents:
        errors.append(f'runtimes/claude-code/agents: expected {sorted(expected_agents)}, found {sorted(agent_names)}')
for required in ['AGENTS_SRC', 'AGENTS_DST', 'install_managed_profiles', 'uninstall_managed_profiles']:
    if required not in claude_install:
        errors.append(f'runtimes/claude-code/scripts/install.sh: missing Claude agent profile marker {required!r}')

if 'Global MCP Setup' not in claude_readme or '~/.claude.json' not in claude_readme:
    errors.append('runtimes/claude-code/configs/README.md: missing global MCP setup documentation')
for required in [
    'Continuation and resume guarantees',
    'does not provide native phase-to-phase automation',
    'operator-issued skill invocations',
]:
    if required not in claude_readme:
        errors.append(f'runtimes/claude-code/configs/README.md: missing continuation/card marker {required!r}')
for required in ['Optional subagent profiles', 'Governance assets', '~/.claude/agents/']:
    if required not in claude_readme:
        errors.append(f'runtimes/claude-code/configs/README.md: missing governance marker {required!r}')

for forbidden in ['--install-project-mcp', '--replace-project-mcp', '--mcp-profile', '--with-playwright', '.mcp.json']:
    if forbidden in claude_readme:
        errors.append(f'runtimes/claude-code/configs/README.md: should not document per-project/options installer path {forbidden!r}')

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)

print('Claude Code runtime validation passed.')
PY
