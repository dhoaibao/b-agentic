#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

python3 - <<'PY'
from pathlib import Path
import json
import re
import sys

root = Path('.')
errors = []

skill_paths = sorted(root.glob('skills/*/SKILL.md'))
skill_names = [path.parent.name for path in skill_paths]
expected_manual_only = {
    'b-orchestrate',
    'b-plan',
    'b-implement',
    'b-refactor',
    'b-debug',
    'b-test',
    'b-browser',
}
allowed_frontmatter = {
    'name',
    'description',
    'when_to_use',
    'argument-hint',
    'arguments',
    'disable-model-invocation',
    'user-invocable',
    'allowed-tools',
    'model',
    'effort',
    'context',
    'agent',
    'hooks',
    'paths',
    'shell',
}
required_sections = [
    '## When to use',
    '## When NOT to use',
    '## Tools required',
    '## Steps',
    '## Rules',
]

if len(skill_paths) != 11:
    errors.append(f'skills/: expected 11 SKILL.md files, found {len(skill_paths)}')

if (root / 'commands').exists() and any((root / 'commands').glob('*.md')):
    errors.append('commands/: Claude-native runtime should not ship command wrappers; skills create /b-* commands')

def frontmatter_parts(path: Path):
    text = path.read_text()
    if not text.startswith('---\n'):
        errors.append(f'{path}: missing YAML frontmatter start')
        return '', text
    parts = text.split('---', 2)
    if len(parts) < 3:
        errors.append(f'{path}: missing YAML frontmatter close')
        return '', text
    return parts[1], parts[2]

def top_level_keys(frontmatter: str):
    return re.findall(r'^([A-Za-z0-9_-]+):', frontmatter, re.MULTILINE)

for path in skill_paths:
    name = path.parent.name
    text = path.read_text()
    frontmatter, body = frontmatter_parts(path)

    for key in top_level_keys(frontmatter):
        if key not in allowed_frontmatter:
            errors.append(f'{path}: unsupported Claude skill frontmatter key {key!r}')

    name_match = re.search(r'^name:\s*(\S+)\s*$', frontmatter, re.MULTILINE)
    if not name_match:
        errors.append(f'{path}: missing frontmatter name')
    elif name_match.group(1) != name:
        errors.append(f'{path}: frontmatter name {name_match.group(1)!r} does not match directory {name!r}')

    desc_match = re.search(
        r'^description:\s*>\s*\n(?P<desc>(?:\s+.*\n)+?)(?=^[A-Za-z0-9_-]+:|^---)',
        frontmatter + '---',
        re.MULTILINE,
    )
    if not desc_match:
        errors.append(f'{path}: missing block description')
    else:
        desc = ' '.join(line.strip() for line in desc_match.group('desc').splitlines())
        word_count = len(desc.split())
        if word_count > 80:
            errors.append(f'{path}: description has {word_count} words, expected <=80')

    has_disable = bool(re.search(r'^disable-model-invocation:\s*true\s*$', frontmatter, re.MULTILINE))
    if name in expected_manual_only and not has_disable:
        errors.append(f'{path}: mutating/coordinating skill must be manual-only with disable-model-invocation: true')
    if name not in expected_manual_only and has_disable:
        errors.append(f'{path}: read-only/clarification skill should not be manual-only without documented reason')

    if 'allowed-tools:' in frontmatter:
        errors.append(f'{path}: allowed-tools grants permissions and requires explicit maintainer review before use')

    for section in required_sections:
        if section not in body:
            errors.append(f'{path}: missing required section {section!r}')

    if 'status block' not in text and 'status or handoff' not in text:
        errors.append(f'{path}: missing status block reference')

    handoff_indicators = ['hand off to', 'handoff', 'hands off to']
    if any(h in text.lower() for h in handoff_indicators):
        has_handoff_ref = (
            '[handoff]' in text
            or 'handoff envelope' in text
            or '§9' in text
        )
        if not has_handoff_ref:
            errors.append(f'{path}: mentions handoff but missing [handoff] block, handoff envelope, or §9 reference')

    if '## Output format' in body:
        output_fmt_start = body.index('## Output format')
        next_heading = body.find('\n## ', output_fmt_start + 1)
        output_section = body[output_fmt_start:next_heading] if next_heading != -1 else body[output_fmt_start:]
        output_lines = [l.strip() for l in output_section.splitlines()[1:] if l.strip()]
        if len(output_lines) < 2:
            errors.append(f'{path}: Output format section has fewer than 2 non-empty lines')
    else:
        errors.append(f'{path}: missing ## Output format section')

    forbidden = [
        'compatibility: opencode',
        'metadata:',
        'suite: b-agentic',
        'active `AGENTS.md` runtime kernel',
        'global/AGENTS.md',
        '~/.config/opencode',
        '/tmp/opencode',
    ]
    for needle in forbidden:
        if needle in text:
            errors.append(f'{path}: stale OpenCode/runtime pattern {needle!r}')

    if 'references/b-agentic/runtime-contract.md' in text and '${CLAUDE_SKILL_DIR}/references/b-agentic/runtime-contract.md' not in text:
        errors.append(f'{path}: runtime contract read gates must use ${{CLAUDE_SKILL_DIR}} support path')

    if 'performance-checklist.md' in text and '${CLAUDE_SKILL_DIR}/references/b-agentic/performance-checklist.md' not in text:
        errors.append(f'{path}: performance checklist read gates must use ${{CLAUDE_SKILL_DIR}} support path')

    if 'Read `reference.md` before' in text or re.search(r'Read\s+`?reference\.md`?', text):
        errors.append(f'{path}: local reference.md read gates must use ${{CLAUDE_SKILL_DIR}}/reference.md')

    if re.search(r'Read §\d+', text):
        errors.append(f'{path}: read gates must name the reference file, not only a section number')

    if 'Graceful degradation:' in text and '${CLAUDE_SKILL_DIR}/references/b-agentic/runtime-contract.md` §4' not in text:
        errors.append(f'{path}: tool fallback must explicitly read runtime contract §4 from skill support files')

    skill_reference = path.parent / 'reference.md'
    if skill_reference.exists() and 'reference.md' not in text:
        errors.append(f'{path}: existing reference.md is not discoverable from SKILL.md')

readme = (root / 'README.md').read_text() if (root / 'README.md').exists() else ''
reference = (root / 'REFERENCE.md').read_text() if (root / 'REFERENCE.md').exists() else ''
maintainer_path = root / 'CLAUDE.md'
maintainer = maintainer_path.read_text() if maintainer_path.exists() else ''
kernel_path = root / 'global' / 'CLAUDE.md'
kernel = kernel_path.read_text() if kernel_path.exists() else ''
runtime_contract_path = root / 'references' / 'runtime-contract.md'
runtime_contract = runtime_contract_path.read_text() if runtime_contract_path.exists() else ''
install_sh = (root / 'install.sh').read_text() if (root / 'install.sh').exists() else ''
claude_readme = (root / 'claude' / 'README.md').read_text() if (root / 'claude' / 'README.md').exists() else ''

if not kernel_path.exists():
    errors.append('global/CLAUDE.md: missing Claude Code kernel source')
if (root / 'global' / 'AGENTS.md').exists():
    errors.append('global/AGENTS.md: stale OpenCode kernel source should be removed or renamed')
if (root / 'AGENTS.md').exists():
    errors.append('AGENTS.md: stale root maintainer guide should be renamed to CLAUDE.md')
if '<!-- b-agentic-managed -->' not in kernel:
    errors.append('global/CLAUDE.md: missing b-agentic managed marker')
for marker in ['Runtime gate checklist:', 'CLAUDE.md', 'Detailed routing', 'runtime contract §9']:
    if marker not in kernel:
        errors.append(f'global/CLAUDE.md: missing kernel marker {marker!r}')

for doc_path, doc_text in [('README.md', readme), ('REFERENCE.md', reference)]:
    if not doc_text:
        errors.append(f'{doc_path}: missing or empty')
        continue
    if '11-skill' not in doc_text and '11 skills' not in doc_text:
        errors.append(f'{doc_path}: missing explicit 11-skill claim')
    for name in skill_names:
        if name not in doc_text:
            errors.append(f'{doc_path}: missing skill name {name}')
    stale_doc_patterns = [
        'OpenCode as the reference runtime',
        '~/.config/opencode',
        'global/AGENTS.md',
        'commands/<name>.md',
        'commands/*.md',
        'compatibility: opencode',
    ]
    for needle in stale_doc_patterns:
        if needle in doc_text:
            errors.append(f'{doc_path}: stale OpenCode/source-layout phrase {needle!r}')

if 'Claude Code is the reference runtime' not in maintainer:
    errors.append('CLAUDE.md: must state Claude Code is the reference runtime')
for needle in ['compatibility: opencode', 'global/AGENTS.md', 'commands/<name>.md']:
    if needle in maintainer:
        errors.append(f'CLAUDE.md: stale maintainer phrase {needle!r}')

for required in [
    'The active runtime kernel lives in `CLAUDE.md`',
    '${CLAUDE_SKILL_DIR}/references/b-agentic/runtime-contract.md',
    '~/.claude/b-agentic',
    '/tmp/claude-code/b-agentic',
    '### Skill-exit status block',
    '### Handoff envelope',
]:
    if required not in runtime_contract:
        errors.append(f'references/runtime-contract.md: missing Claude-native marker {required!r}')

if 'global/AGENTS.md' in runtime_contract or '~/.config/opencode' in runtime_contract or '/tmp/opencode' in runtime_contract:
    errors.append('references/runtime-contract.md: contains stale active OpenCode path')

for required in ['settingsAction', 'mcpAction', 'CLAUDE_JSON_DST', 'skillsSynced']:
    if required not in install_sh:
        errors.append(f'install.sh: missing global one-command installer marker {required!r}')

for required in ['$HOME/.claude', 'global/CLAUDE.md', 'skills', 'references/b-agentic', 'activationState']:
    if required not in install_sh:
        errors.append(f'install.sh: missing Claude installer marker {required!r}')
if '~/.config/opencode' in install_sh or 'opencode.json' in install_sh:
    errors.append('install.sh: contains stale OpenCode install target')

user_mcp_template = root / 'claude' / 'mcp.user.template.json'
if not user_mcp_template.exists():
    errors.append(f'{user_mcp_template}: missing global MCP user template')

secret_literal_patterns = [
    re.compile(r'fc-[A-Za-z0-9_-]{8,}'),
    re.compile(r'YOUR[_-]?API[_-]?KEY', re.IGNORECASE),
    re.compile(r'your-api-key', re.IGNORECASE),
]

for json_path in sorted((root / 'claude').glob('*.json')):
    try:
        data = json.loads(json_path.read_text())
    except Exception as exc:
        errors.append(f'{json_path}: invalid JSON: {exc}')
        continue

    text = json_path.read_text()
    for pattern in secret_literal_patterns:
        if pattern.search(text):
            errors.append(f'{json_path}: contains secret-looking placeholder/literal {pattern.pattern!r}')

    if json_path.name.startswith('mcp.'):
        servers = data.get('mcpServers')
        if not isinstance(servers, dict) or not servers:
            errors.append(f'{json_path}: missing non-empty mcpServers object')
            continue

        if 'brave-search' in servers:
            env = servers['brave-search'].get('env', {})
            if env.get('BRAVE_API_KEY') != '${BRAVE_API_KEY}':
                errors.append(f'{json_path}: brave-search must use ${{BRAVE_API_KEY}} placeholder')
            args = servers['brave-search'].get('args', [])
            if '@brave/brave-search-mcp-server' not in args:
                errors.append(f'{json_path}: brave-search must use @brave/brave-search-mcp-server')

        if 'firecrawl' in servers:
            env = servers['firecrawl'].get('env', {})
            if env.get('FIRECRAWL_API_KEY') != '${FIRECRAWL_API_KEY}':
                errors.append(f'{json_path}: firecrawl must use ${{FIRECRAWL_API_KEY}} placeholder')

        if 'playwright' in servers and '--isolated' not in servers['playwright'].get('args', []):
            errors.append(f'{json_path}: playwright must use --isolated by default')

        if 'context7' in servers:
            server = servers['context7']
            if server.get('type') != 'http' or server.get('url') != 'https://mcp.context7.com/mcp':
                errors.append(f'{json_path}: context7 must use the official MCP HTTP endpoint')
            headers = server.get('headers', {})
            if headers.get('CONTEXT7_API_KEY') != '${CONTEXT7_API_KEY:-}':
                errors.append(f'{json_path}: context7 must use ${{CONTEXT7_API_KEY:-}} optional header placeholder')

        if 'gitnexus' in servers and json_path.name != 'mcp.user.template.json':
            errors.append(f'{json_path}: gitnexus belongs only in the global user config')
        if 'gitnexus' in servers:
            gitnexus = servers['gitnexus']
            if gitnexus.get('command') != 'gitnexus' or gitnexus.get('args') != ['mcp']:
                errors.append(f'{json_path}: gitnexus must use installed gitnexus mcp command')

        if json_path.name == 'mcp.user.template.json':
            expected_user = {'serena', 'context7', 'brave-search', 'firecrawl', 'playwright', 'gitnexus'}
            actual_user = set(servers)
            if actual_user != expected_user:
                errors.append(f'{json_path}: user MCP template must contain all default global servers {sorted(expected_user)}, found {sorted(actual_user)}')

for forbidden in ['--install-project-mcp', '--replace-project-mcp', '--mcp-profile', '--with-playwright', '--with-gitnexus', '.mcp.json']:
    if forbidden in readme:
        errors.append(f'README.md: should not document per-project/options installer path {forbidden!r}')
    if forbidden in claude_readme:
        errors.append(f'claude/README.md: should not document per-project/options installer path {forbidden!r}')

for forbidden in ['--install-project-mcp', '--replace-project-mcp', '--mcp-profile', '--with-playwright', '--with-gitnexus', 'PROJECT_MCP_DST', 'mcpProfile']:
    if forbidden in install_sh:
        errors.append(f'install.sh: should not expose per-project/options installer path {forbidden!r}')

if 'One Command' not in readme or 'skillsSynced' not in readme:
    errors.append('README.md: missing one-command install/output documentation')

if 'Global MCP Setup' not in claude_readme or '~/.claude.json' not in claude_readme:
    errors.append('claude/README.md: missing global MCP setup documentation')

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)

print(f'Skill validation passed ({len(skill_paths)} skills).')
PY
