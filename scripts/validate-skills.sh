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
command_paths = sorted(root.glob('commands/*.md'))
command_names = [path.stem for path in command_paths]
reference_paths = sorted(root.glob('references/*.md'))
reference_names = [path.name for path in reference_paths]

if not skill_paths:
    errors.append('No skills/*/SKILL.md files found')

if not command_paths:
    errors.append('No commands/*.md files found')

if len(command_paths) != len(skill_paths):
    errors.append(f'commands/: expected {len(skill_paths)} wrappers, found {len(command_paths)}')

extra_command_names = sorted(set(command_names) - set(skill_names))
if extra_command_names:
    errors.append(f'commands/: wrappers without matching skill directories: {", ".join(extra_command_names)}')

if not reference_paths:
    errors.append('No references/*.md files found')

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
        r'## Boundary examples',
        r'MCP fallback ladder',
        r'\.opencode/b-e2e/',
        r'git diff HEAD~1 HEAD',
        r'Never trigger destructive git commands',
        r'Note: "⚠️ GitNexus unavailable',
    ]
    for pattern in forbidden_patterns:
        if re.search(pattern, text):
            errors.append(f'{path}: forbidden stale runtime pattern {pattern!r}')

    if 'global/AGENTS.md' in text:
        errors.append(f'{path}: runtime skill files must reference `AGENTS.md`, not `global/AGENTS.md`')

    if name in {'b-research', 'b-test'} and re.search(r'gitnexus', text, re.IGNORECASE):
        errors.append(f'{path}: GitNexus should stay out of this skill workflow')

readme = (root / 'README.md').read_text()
reference = (root / 'REFERENCE.md').read_text()
global_rules = (root / 'global' / 'AGENTS.md').read_text()
runtime_contract_path = root / 'references' / 'runtime-contract.md'
if not runtime_contract_path.exists():
    errors.append('references/runtime-contract.md: missing detailed runtime contract')
    runtime_contract = ''
else:
    runtime_contract = runtime_contract_path.read_text()
root_agents = (root / 'AGENTS.md').read_text()
install_sh = (root / 'install.sh').read_text()

expected_skill_count = len(skill_paths)
for doc_path, doc_text in [('README.md', readme), ('REFERENCE.md', reference)]:
    doc_lower = doc_text.lower()
    count_matches = {int(value) for value in re.findall(r'\b(\d+)\s*[- ]skill\b', doc_lower)}
    count_matches.update(int(value) for value in re.findall(r'\bsuite of\s+(\d+)\s+skills\b', doc_lower))
    if not count_matches:
        errors.append(f'{doc_path}: missing explicit numeric skill-count claim')
    elif expected_skill_count not in count_matches:
        found = ', '.join(str(value) for value in sorted(count_matches))
        errors.append(f'{doc_path}: skill-count claim {found} does not match repo count {expected_skill_count}')

kernel_detail_sections = {
    '§2': ['Detailed plan metadata', 'references/b-skills/runtime-contract.md` §2'],
    '§3': ['Detailed rubrics', 'references/b-skills/runtime-contract.md` §3'],
    '§5': ['Detailed evidence hierarchy', 'references/b-skills/runtime-contract.md` §5'],
    '§6': ['Detailed command risk classes', 'references/b-skills/runtime-contract.md` §6'],
    '§7': ['Detailed scope expansion', 'references/b-skills/runtime-contract.md` §7'],
    '§8': ['Detailed slug algorithm', 'references/b-skills/runtime-contract.md` §8'],
    '§9': ['Detailed status schema', 'references/b-skills/runtime-contract.md` §9'],
    '§10': ['Detailed high-risk gate', 'references/b-skills/runtime-contract.md` §10'],
}
for section, markers in kernel_detail_sections.items():
    if not all(marker in global_rules for marker in markers):
        errors.append(f'global/AGENTS.md: missing kernel-to-contract boundary reference for {section}')

runtime_boundary_sections = [
    '### Kernel/detail split for the shared sections',
    '`§2 Source of truth`',
    '`§3 Definitions and rubrics`',
    '`§5 Evidence standards`',
    '`§6 Safety gates`',
    '`§7 Execution discipline`',
    '`§8 Artifacts`',
    '`§9 Output contract`',
    '`§10 Cross-cutting decisions`',
    '### Non-trivial work',
    '### Small direct request',
    '### Approval-required actions',
    '### Verification ladder',
    '### Skill-exit status block',
    '### Handoff envelope',
]
for required in runtime_boundary_sections:
    if required not in runtime_contract:
        errors.append(f'references/runtime-contract.md: missing canonical boundary section {required!r}')

runtime_boundary_markers = [
    'Requires sequencing.',
    'No remaining design decision',
    'Required fields are `skill`, `state`, `artifacts`, `next`, `blockers`.',
    'Required fields are `source`, `goal`, `decisions`, `assumptions`, `files`, `verification`, `blockers`, `next-skill`.',
]
for required in runtime_boundary_markers:
    if required not in runtime_contract:
        errors.append(f'references/runtime-contract.md: missing canonical boundary marker {required!r}')

kernel_summary_markers = [
    'Use the shared §3 glossary in `references/b-skills/runtime-contract.md`',
    'Use the shared slug, run-id, and artifact conventions from `references/b-skills/runtime-contract.md` §8.',
    'shared `[status]` and `[handoff]` schemas',
]
for required in kernel_summary_markers:
    if required not in global_rules:
        errors.append(f'global/AGENTS.md: missing kernel summary marker {required!r}')

for name in skill_names:
    for doc_path, doc_text in [('README.md', readme), ('REFERENCE.md', reference)]:
        if name not in doc_text:
            errors.append(f'{doc_path}: missing skill mention {name}')
    if f'remove_skill_if_managed {name}' not in install_sh:
        errors.append(f'install.sh: uninstall missing skill removal for {name}')
    if f'remove_command_if_managed {name}' not in install_sh:
        errors.append(f'install.sh: uninstall missing command removal for {name}')

for name in reference_names:
    for doc_path, doc_text in [('README.md', readme), ('REFERENCE.md', reference)]:
        if name not in doc_text:
            errors.append(f'{doc_path}: missing reference mention {name}')

for ref_path in reference_paths:
    ref_name = ref_path.name
    if ref_name == 'runtime-contract.md':
        continue
    if not any(ref_name in path.read_text() for path in skill_paths):
        errors.append(f'{ref_path}: not referenced by any skill file')

if 'references/b-skills' not in install_sh:
    errors.append('install.sh: missing managed references install path')

if 'sync_directory "$REFERENCES_SRC" "$REFERENCES_DST"' not in install_sh:
    errors.append('install.sh: missing references sync step')

if 'RUNTIME_CONTRACT_DST' not in install_sh:
    errors.append('install.sh: missing runtime contract managed path')

for doc_path, doc_text in [('README.md', readme), ('REFERENCE.md', reference), ('global/AGENTS.md', global_rules), ('references/runtime-contract.md', runtime_contract)]:
    if '.opencode/b-e2e/' in doc_text:
        errors.append(f'{doc_path}: old E2E artifact path still present')

for doc_path, doc_text in [('README.md', readme), ('global/AGENTS.md', global_rules), ('references/runtime-contract.md', runtime_contract)]:
    if 'Opus 4.7' in doc_text:
        errors.append(f'{doc_path}: model-specific reasoning wording should not be present')

if '@modelcontextprotocol/server-sequential-thinking' in install_sh:
    errors.append('install.sh: sequential-thinking should not be bundled in the MCP defaults')

for doc_path, doc_text in [('README.md', readme), ('REFERENCE.md', reference), ('AGENTS.md', root_agents), ('references/runtime-contract.md', runtime_contract)]:
    if 'sequential-thinking' in doc_text:
        errors.append(f'{doc_path}: sequential-thinking should be fully removed from suite docs and maintainer guidance')

for required in ['Radar/hands boundary', 'Evidence standards', 'GitNexus freshness gate', 'Patch discipline', 'Token budget']:
    if required not in runtime_contract:
        errors.append(f'references/runtime-contract.md: missing detailed convention {required!r}')

for required in ['missing expected lines', 'stale context', 'one small hunk']:
    if required not in runtime_contract:
        errors.append(f'references/runtime-contract.md: patch discipline missing phrase {required!r}')

kernel_required = [
    'Runtime Kernel',
    'references/b-skills/runtime-contract.md',
    'Source Of Truth',
    'Tool Priority',
    'Safety',
    '[status]',
    '[handoff]',
]
for required in kernel_required:
    if required not in global_rules:
        errors.append(f'global/AGENTS.md: runtime kernel missing phrase {required!r}')

for doc_path, doc_text in [('REFERENCE.md', reference)]:
    if 'Good triggers' in doc_text or 'Boundary examples' in doc_text:
        errors.append(f'{doc_path}: duplicated trigger examples should stay in README/skills, not reference')

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
    'key Vietnamese + English trigger phrases',
]
for forbidden in root_forbidden:
    if forbidden in root_agents:
        errors.append(f'AGENTS.md: stale maintainer guidance remains: {forbidden!r}')

b_plan = (root / 'skills' / 'b-plan' / 'SKILL.md').read_text()
b_implement = (root / 'skills' / 'b-implement' / 'SKILL.md').read_text()
if 'Update saved-plan checkboxes' in b_implement and '- [ ] **<imperative step title>**' not in b_plan:
    errors.append('skills/b-plan/SKILL.md: saved-plan skeleton must support checkbox-style progress updates used by b-implement')

patch_skill_expectations = {
    'b-implement': 'global patch discipline',
    'b-refactor': 'global patch discipline',
    'b-test': 'global patch discipline',
    'b-debug': 'global patch discipline',
}
for skill_name, required_phrase in patch_skill_expectations.items():
    skill_text = (root / 'skills' / skill_name / 'SKILL.md').read_text()
    if required_phrase not in skill_text:
        errors.append(f'skills/{skill_name}/SKILL.md: missing canonical patch discipline reference {required_phrase!r}')
    for duplicated_phrase in ['missing expected lines', 'stale context recovery']:
        if duplicated_phrase in skill_text:
            errors.append(f'skills/{skill_name}/SKILL.md: duplicated patch protocol phrase {duplicated_phrase!r}')

if 'stable anchors' not in b_plan:
    errors.append('skills/b-plan/SKILL.md: prose/config plans should mention stable anchors for patchable edits')

for required in ['Do not promote to full mode solely', '2-5 bullets']:
    if required not in b_plan:
        errors.append(f'skills/b-plan/SKILL.md: missing low-ceremony planning guard {required!r}')

b_test = (root / 'skills' / 'b-test' / 'SKILL.md').read_text()
for required in ['failing test path', 'verification target']:
    if required not in b_test:
        errors.append(f'skills/b-test/SKILL.md: missing TDD handoff field {required!r}')

for required in ['Daily-use fast path examples', 'trivial happy-path runs']:
    if required not in runtime_contract:
        errors.append(f'references/runtime-contract.md: missing happy-path convention {required!r}')

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
