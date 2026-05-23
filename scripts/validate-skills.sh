#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

python3 - <<'PY'
from pathlib import Path
import json
import re
import sys
import subprocess

root = Path('.')
errors = []

skill_paths = sorted(root.glob('skills/*/SKILL.md'))
skill_names = [path.parent.name for path in skill_paths]
allowed_frontmatter = {
    'name',
    'description',
    'when_to_use',
    'argument-hint',
    'arguments',
    'user-invocable',
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
            errors.append(f'{path}: unsupported skill frontmatter key {key!r}')

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

    if 'allowed-tools:' in frontmatter:
        errors.append(f'{path}: allowed-tools grants permissions and requires explicit maintainer review before use')

    for section in required_sections:
        if section not in body:
            errors.append(f'{path}: missing required section {section!r}')

    if 'handoff envelope' in text.lower() or '[handoff]' in text:
        if 'contract/09-output' not in text:
            errors.append(f'{path}: emits handoff envelope but missing contract/09-output reference')

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
    ]
    for needle in forbidden:
        if needle in text:
            errors.append(f'{path}: stale pattern {needle!r}')

    if 'references/b-agentic/contract/' in text and '${CLAUDE_SKILL_DIR}/references/b-agentic/contract/' not in text:
        errors.append(f'{path}: contract read gates must use ${{CLAUDE_SKILL_DIR}} support path')

    if 'performance-checklist.md' in text and '${CLAUDE_SKILL_DIR}/references/b-agentic/performance-checklist.md' not in text:
        errors.append(f'{path}: performance checklist read gates must use ${{CLAUDE_SKILL_DIR}} support path')

    if 'Read `reference.md` before' in text or re.search(r'Read\s+`?reference\.md`?', text):
        errors.append(f'{path}: local reference.md read gates must use ${{CLAUDE_SKILL_DIR}}/reference.md')

    if re.search(r'Read §\d+', text):
        errors.append(f'{path}: read gates must name the reference file, not only a section number')

    if 'Graceful degradation:' in text:
        errors.append(f'{path}: graceful degradation rules are centralized in the kernel; skills must not restate them')

    skill_reference = path.parent / 'reference.md'
    if skill_reference.exists() and 'reference.md' not in text:
        errors.append(f'{path}: existing reference.md is not discoverable from SKILL.md')

routing_path = root / 'references' / 'contract' / '01-routing.md'
if not routing_path.exists():
    errors.append('references/contract/01-routing.md: missing contract routing source')
else:
    routing_text = routing_path.read_text()
    referenced_skills = set(re.findall(r'`/(b-[a-z][a-z0-9-]*)`', routing_text))
    skill_dirs = set(skill_names)
    for name in sorted(referenced_skills - skill_dirs):
        errors.append(f'references/contract/01-routing.md: references /{name} but no skills/{name}/ directory exists')

readme = (root / 'README.md').read_text() if (root / 'README.md').exists() else ''
reference = (root / 'REFERENCE.md').read_text() if (root / 'REFERENCE.md').exists() else ''
maintainer_path = root / 'CLAUDE.md'
maintainer = maintainer_path.read_text() if maintainer_path.exists() else ''

kernel_path = root / 'runtimes' / 'claude-code' / 'kernel.md'
kernel = kernel_path.read_text() if kernel_path.exists() else ''
contract_index_path = root / 'references' / 'contract' / 'index.md'
contract_index = contract_index_path.read_text() if contract_index_path.exists() else ''
install_sh = (root / 'install.sh').read_text() if (root / 'install.sh').exists() else ''

contract_version_match = re.search(r'This runtime contract version is `([0-9]{4}-[0-9]{2}-[0-9]{2})`', kernel)
contract_version = contract_version_match.group(1) if contract_version_match else None

if not kernel_path.exists():
    errors.append('runtimes/claude-code/kernel.md: missing Claude Code kernel source')
for runtime_dir in sorted((root / 'runtimes').glob('*/')):
    if not (runtime_dir / 'kernel.md').exists():
        errors.append(f'{runtime_dir}: runtime adapter missing kernel.md')

for doc_path, doc_text in [('README.md', readme), ('REFERENCE.md', reference)]:
    if not doc_text:
        errors.append(f'{doc_path}: missing or empty')
        continue
    if '11-skill' not in doc_text and '11 skills' not in doc_text:
        errors.append(f'{doc_path}: missing explicit 11-skill claim')
    for name in skill_names:
        if name not in doc_text:
            errors.append(f'{doc_path}: missing skill name {name}')

if 'One Command' not in readme or 'skillsSynced' not in readme:
    errors.append('README.md: missing one-command install/output documentation')

if contract_version:
    for plan_path in sorted((root / '.b-agentic' / 'b-plan').glob('*.md')):
        plan_text = plan_path.read_text()
        plan_version_match = re.search(r'^contract_version:\s*(\S+)', plan_text, re.MULTILINE)
        if plan_version_match:
            plan_version = plan_version_match.group(1)
            if plan_version != contract_version:
                errors.append(f'{plan_path}: contract_version {plan_version!r} does not match kernel contract version {contract_version!r}')
else:
    errors.append('runtimes/claude-code/kernel.md: unable to extract contract version')

secret_literal_patterns = [
    re.compile(r'fc-[A-Za-z0-9_-]{8,}'),
    re.compile(r'YOUR[_-]?API[_-]?KEY', re.IGNORECASE),
    re.compile(r'your-api-key', re.IGNORECASE),
]

for json_path in sorted((root / 'runtimes').glob('*/configs/*.json')):
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
        is_opencode = 'opencode' in json_path.parts
        mcp_key = 'mcp' if is_opencode else 'mcpServers'
        servers = data.get(mcp_key)
        if not isinstance(servers, dict) or not servers:
            errors.append(f'{json_path}: missing non-empty {mcp_key} object')
            continue

        expected_user = {'serena', 'context7', 'brave-search', 'firecrawl', 'playwright', 'gitnexus'}

        if is_opencode:
            if 'serena' in servers:
                if servers['serena'].get('command') != ['serena', 'start-mcp-server', '--context', 'ide', '--project-from-cwd']:
                    errors.append(f'{json_path}: serena must use serena start-mcp-server --context ide --project-from-cwd')

            if 'brave-search' in servers:
                env = servers['brave-search'].get('environment', {})
                if env.get('BRAVE_API_KEY') != '{env:BRAVE_API_KEY}':
                    errors.append(f'{json_path}: brave-search must use {{env:BRAVE_API_KEY}} placeholder')
                cmd = servers['brave-search'].get('command', [])
                if not cmd or cmd[0] != 'bunx':
                    errors.append(f'{json_path}: brave-search must use bunx')
                if '@brave/brave-search-mcp-server' not in cmd:
                    errors.append(f'{json_path}: brave-search must use @brave/brave-search-mcp-server')

            if 'firecrawl' in servers:
                env = servers['firecrawl'].get('environment', {})
                if env.get('FIRECRAWL_API_KEY') != '{env:FIRECRAWL_API_KEY}':
                    errors.append(f'{json_path}: firecrawl must use {{env:FIRECRAWL_API_KEY}} placeholder')
                cmd = servers['firecrawl'].get('command', [])
                if not cmd or cmd[0] != 'bunx':
                    errors.append(f'{json_path}: firecrawl must use bunx')
                if 'firecrawl-mcp' not in cmd:
                    errors.append(f'{json_path}: firecrawl must use firecrawl-mcp')

            if 'playwright' in servers:
                cmd = servers['playwright'].get('command', [])
                if not cmd or cmd[0] != 'bunx':
                    errors.append(f'{json_path}: playwright must use bunx')
                if '@playwright/mcp@latest' not in cmd:
                    errors.append(f'{json_path}: playwright must use @playwright/mcp@latest')
                if '--isolated' not in cmd:
                    errors.append(f'{json_path}: playwright must use --isolated by default')

            if 'context7' in servers:
                server = servers['context7']
                if server.get('type') != 'remote' or server.get('url') != 'https://mcp.context7.com/mcp':
                    errors.append(f'{json_path}: context7 must use the official MCP remote endpoint')
                headers = server.get('headers', {})
                if headers.get('CONTEXT7_API_KEY') != '{env:CONTEXT7_API_KEY}':
                    errors.append(f'{json_path}: context7 must use {{env:CONTEXT7_API_KEY}} header placeholder')

            if 'gitnexus' in servers and json_path.name != 'mcp.user.template.json':
                errors.append(f'{json_path}: gitnexus belongs only in the global user config')
            if 'gitnexus' in servers:
                if servers['gitnexus'].get('command') != ['gitnexus', 'mcp']:
                    errors.append(f'{json_path}: gitnexus must use installed gitnexus mcp command')

        else:
            if 'brave-search' in servers:
                env = servers['brave-search'].get('env', {})
                if env.get('BRAVE_API_KEY') != '${BRAVE_API_KEY}':
                    errors.append(f'{json_path}: brave-search must use ${{BRAVE_API_KEY}} placeholder')
                if servers['brave-search'].get('command') != 'bunx':
                    errors.append(f'{json_path}: brave-search must use bunx')
                args = servers['brave-search'].get('args', [])
                if '@brave/brave-search-mcp-server' not in args:
                    errors.append(f'{json_path}: brave-search must use @brave/brave-search-mcp-server')

            if 'firecrawl' in servers:
                env = servers['firecrawl'].get('env', {})
                if env.get('FIRECRAWL_API_KEY') != '${FIRECRAWL_API_KEY}':
                    errors.append(f'{json_path}: firecrawl must use ${{FIRECRAWL_API_KEY}} placeholder')
                if servers['firecrawl'].get('command') != 'bunx':
                    errors.append(f'{json_path}: firecrawl must use bunx')
                if 'firecrawl-mcp' not in servers['firecrawl'].get('args', []):
                    errors.append(f'{json_path}: firecrawl must use firecrawl-mcp')

            if 'playwright' in servers:
                if servers['playwright'].get('command') != 'bunx':
                    errors.append(f'{json_path}: playwright must use bunx')
                args = servers['playwright'].get('args', [])
                if '@playwright/mcp@latest' not in args:
                    errors.append(f'{json_path}: playwright must use @playwright/mcp@latest')
                if '--isolated' not in args:
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
            actual_user = set(servers)
            if actual_user != expected_user:
                errors.append(f'{json_path}: user MCP template must contain all default global servers {sorted(expected_user)}, found {sorted(actual_user)}')

for forbidden in ['--install-project-mcp', '--replace-project-mcp', '--mcp-profile', '--with-playwright', '--with-gitnexus', '.mcp.json']:
    if forbidden in readme:
        errors.append(f'README.md: should not document per-project/options installer path {forbidden!r}')

for forbidden in ['--install-project-mcp', '--replace-project-mcp', '--mcp-profile', '--with-playwright', '--with-gitnexus', 'PROJECT_MCP_DST', 'mcpProfile']:
    if forbidden in install_sh:
        errors.append(f'install.sh: should not expose per-project/options installer path {forbidden!r}')

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)

print(f'Shared skill validation passed ({len(skill_paths)} skills).')
PY

# Run per-runtime validators
exit_code=0
for runtime_script in runtimes/*/scripts/validate.sh; do
  if [ -f "$runtime_script" ]; then
    if ! bash "$runtime_script"; then
      exit_code=1
    fi
  fi
done

exit "$exit_code"
