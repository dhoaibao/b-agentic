#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

python3 - <<'PY'
from pathlib import Path
import re
import sys

root = Path('.')
errors = []

skill_paths = sorted(root.glob('skills/*/SKILL.md'))
skill_names = [path.parent.name for path in skill_paths]

if not skill_paths:
    errors.append('No skills/*/SKILL.md files found')

required_sections = [
    '## When to use',
    '## When NOT to use',
    '## Tools required',
    '## Steps',
    '## Rules',
]

for path in skill_paths:
    text = path.read_text()
    name = path.parent.name

    if not text.startswith('---\n'):
        errors.append(f'{path}: missing YAML frontmatter start')
        continue

    parts = text.split('---', 2)
    if len(parts) < 3:
        errors.append(f'{path}: missing YAML frontmatter close')
        continue

    frontmatter = parts[1]
    body = parts[2]

    name_match = re.search(r'^name:\s*(\S+)\s*$', frontmatter, re.MULTILINE)
    if not name_match:
        errors.append(f'{path}: missing frontmatter name')
    elif name_match.group(1) != name:
        errors.append(f'{path}: frontmatter name {name_match.group(1)!r} does not match directory {name!r}')

    if not re.search(r'^compatibility:\s*opencode\s*$', frontmatter, re.MULTILINE):
        errors.append(f'{path}: compatibility must be opencode')

    if not re.search(r'^\s*suite:\s*b-skills\s*$', frontmatter, re.MULTILINE):
        errors.append(f'{path}: metadata.suite must be b-skills')

    desc_match = re.search(r'^description:\s*>\s*\n(?P<desc>(?:\s+.*\n)+?)(?=^[A-Za-z_-]+:|^metadata:|^---)', frontmatter + '---', re.MULTILINE)
    if not desc_match:
        errors.append(f'{path}: missing block description')
    else:
        desc = ' '.join(line.strip() for line in desc_match.group('desc').splitlines())
        word_count = len(desc.split())
        if word_count > 80:
            errors.append(f'{path}: description has {word_count} words, expected <=80')

    for section in required_sections:
        if section not in body:
            errors.append(f'{path}: missing required section {section!r}')

    command_path = root / 'commands' / f'{name}.md'
    if not command_path.exists():
        errors.append(f'{path}: missing matching command wrapper {command_path}')

    forbidden_patterns = [
        r'`write`',
        r'`edit`',
        r'native `edit`',
        r'manual `edit`',
        r'\.opencode/b-e2e/',
        r'git diff HEAD~1 HEAD',
        r'Never trigger destructive git commands',
        r'Note: "⚠️ GitNexus unavailable',
    ]
    for pattern in forbidden_patterns:
        if re.search(pattern, text):
            errors.append(f'{path}: forbidden stale runtime pattern {pattern!r}')

    if name in {'b-research', 'b-test', 'b-e2e'} and re.search(r'gitnexus', text, re.IGNORECASE):
        errors.append(f'{path}: GitNexus should stay out of this skill workflow')

readme = (root / 'README.md').read_text()
reference = (root / 'REFERENCE.md').read_text()
global_rules = (root / 'global' / 'AGENTS.md').read_text()
root_agents = (root / 'AGENTS.md').read_text()

for name in skill_names:
    for doc_path, doc_text in [('README.md', readme), ('REFERENCE.md', reference)]:
        if name not in doc_text:
            errors.append(f'{doc_path}: missing skill mention {name}')

for doc_path, doc_text in [('README.md', readme), ('REFERENCE.md', reference), ('global/AGENTS.md', global_rules)]:
    if '.opencode/b-e2e/' in doc_text:
        errors.append(f'{doc_path}: old E2E artifact path still present')

for required in ['Radar/hands boundary', 'Evidence standards', 'GitNexus freshness gate']:
    if required not in global_rules:
        errors.append(f'global/AGENTS.md: missing global convention {required!r}')

if 'install.sh' in global_rules:
    errors.append('global/AGENTS.md: runtime global rules should not mention install.sh')

root_required = [
    'optional radar',
    'primary hands',
    'indexed, fresh, and target-aware',
    'only when indexing is safe',
]
for required in root_required:
    if required not in root_agents:
        errors.append(f'AGENTS.md: missing GitNexus/Serena contract phrase {required!r}')

root_forbidden = [
    'Prefer GitNexus first for graph-shaped code tasks when the repo is indexed:',
    'when GitNexus is available and indexed',
    'Note: "⚠️ GitNexus unavailable',
]
for forbidden in root_forbidden:
    if forbidden in root_agents:
        errors.append(f'AGENTS.md: stale GitNexus guidance remains: {forbidden!r}')

stale_reindex_prefix = 'If any GitNexus tool warns the index is stale, run `'
if stale_reindex_prefix in root_agents and '--skip-agents-md' not in root_agents:
    errors.append('AGENTS.md: stale GitNexus reindex guidance remains: missing `--skip-agents-md`')

if errors:
    print('Skill validation failed:', file=sys.stderr)
    for error in errors:
        print(f'- {error}', file=sys.stderr)
    raise SystemExit(1)

print(f'Skill validation passed ({len(skill_paths)} skills).')
PY
