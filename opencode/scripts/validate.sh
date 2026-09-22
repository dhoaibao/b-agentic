#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

[ -d opencode/agents ] || { echo 'missing OpenCode agents' >&2; exit 1; }
[ -d opencode/commands ] || { echo 'missing generated OpenCode commands' >&2; exit 1; }
[ -f opencode/configs/opencode.base.json ] || { echo 'missing OpenCode base config' >&2; exit 1; }
[ -f opencode/configs/opencode.user.template.json ] || { echo 'missing generated OpenCode config template' >&2; exit 1; }
[ ! -d pi ] || { echo 'retired Pi runtime directory is present' >&2; exit 1; }

python3 - <<'PY'
import json
from pathlib import Path

root = Path.cwd()
registry = json.loads((root / 'skills/registry.yaml').read_text())
agent_marker = 'Managed by b-agentic'
assert agent_marker in (root / 'opencode/scripts/install.sh').read_text()
bound_skills = {}
for skill in registry['skills']:
    execution = skill['execution']
    if execution['mode'] == 'subagent':
        bound_skills.setdefault(execution['agent'], []).append(skill['name'])
config = json.loads((root / 'opencode/configs/opencode.user.template.json').read_text())
assert 'autoupdate' not in config
assert config['experimental']['subagent_depth'] == 1
servers = config['mcp']['servers']
assert isinstance(servers, dict) and servers
for entry in servers.values():
    assert entry['disabled'] is False and entry['codemode'] is False
    assert entry['timeout'] == {'startup': 30000, 'catalog': 30000}

rules = config['permissions']
assert isinstance(rules, list) and rules

def effect(action, resource='*'):
    matches = [rule['effect'] for rule in rules if rule['action'] == action and rule['resource'] == resource]
    assert matches
    return matches[-1]

assert effect('edit') == 'allow'
assert effect('shell', 'git push*') == 'deny'
assert effect('shell', 'git pull*') == 'deny'
assert effect('shell', 'curl * | bash*') == 'ask'
assert effect('context7_resolve_library_id') == 'allow'
for server in ('codegraph', 'context7', 'brave_search', 'firecrawl', 'playwright', 'mobbin', 'shadcn'):
    assert effect(f'{server}_*') == 'ask'
for name, skill_names in bound_skills.items():
    text = (root / 'opencode/agents' / f'{name}.md').read_text()
    assert 'mode: subagent' in text and 'permissions:' in text
    assert 'Generated from skills/registry.yaml' in text
    assert agent_marker in text
    for action in ('edit', 'subagent', 'question'):
        assert f'action: {action}\n    resource: "*"\n    effect: deny' in text
    actions = {line.split(': ', 1)[1] for line in text.splitlines() if line.strip().startswith('- action: ')}
    assert actions == {'edit', 'subagent', 'question'}
    for skill_name in skill_names:
        assert f'`{skill_name}`' in text
    assert "Load and execute the named skill" in text
    assert "Return that named skill's own Output format" in text

for path in (root / 'opencode/commands').glob('b-*.md'):
    lines = path.read_text().splitlines()
    assert lines[0] == '---' and lines[1].startswith('description: ')
    assert isinstance(json.loads(lines[1].removeprefix('description: ')), str)
    assert 'Generated from skills/registry.yaml' in path.read_text()
    skill_name = path.stem
    skill = next(item for item in registry['skills'] if item['name'] == skill_name)
    if skill['execution']['mode'] == 'subagent':
        text = path.read_text()
        assert f"Load and execute the `{skill_name}` skill" in text
        assert f"Return the `{skill_name}` skill's own Output format" in text
PY

echo 'Native OpenCode v2 runtime validation passed.'
