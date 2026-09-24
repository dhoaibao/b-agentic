#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

python3 - <<'PY'
import json
from pathlib import Path

root = Path.cwd()
registry = json.loads((root / 'skills/registry.yaml').read_text())
settings = json.loads((root / 'pi/configs/settings.base.json').read_text())
mcp = json.loads((root / 'pi/configs/mcp.base.json').read_text())
policy = json.loads((root / 'pi/configs/permission.user.template.json').read_text())
assert len(registry['skills']) == 15
assert len(registry['agents']) == 4
assert len(settings['packages']) == 7
assert 'npm:@cortexkit/pi-magic-context' in settings['packages']
assert json.loads((root / 'pi/configs/magic-context.base.json').read_text()) == {
    'enabled': True, 'embedding': {'provider': 'local'}
}
assert all(name.startswith('npm:') and not name.rsplit('/', 1)[-1].count('@') for name in settings['packages'])
assert settings['compaction']['enabled'] is False
assert len(mcp['mcpServers']) == 7
assert mcp['settings']['scriptMode'] is False
assert mcp['settings']['allowInstall'] is False
assert mcp['settings']['directTools'] is True
assert policy['permissionReviewLog'] is False
assert policy['permission']['mcp']['*'] == 'ask'
assert policy['permission']['path']['*.env'] == 'deny'
assert policy['permission']['external_directory'] == 'ask'
assert policy['permission']['external_directory_write'] == 'deny'
assert policy['permission']['bash']['sudo *'] == 'deny'
assert policy['permission']['bash']['rm -rf *'] == 'deny'
assert policy['permission']['ask_question'] == 'deny'
assert policy['permission']['ask_user_question'] == 'allow'

for name, agent in registry['agents'].items():
    text = (root / 'pi/agents' / f'{name}.md').read_text()
    assert 'Generated from skills/registry.yaml' in text
    assert 'prompt_mode: replace' in text
    assert '\npermission:\n' not in text
    assert 'Remain read-only.' in text
    assert f'model: {agent["model"].split("#", 1)[0]}' in text
    assert 'tools: read, grep, find, ls, bash' in text
    for skill in registry['skills']:
        if skill['execution'].get('agent') == name:
            assert f'`{skill["name"]}`' in text

for skill in registry['skills']:
    name = skill['name']
    prompt = (root / 'pi/prompts' / f'{name}.md').read_text()
    assert f'`{name}`' in prompt or f'skills/{name}/SKILL.md' in prompt
    assert '$ARGUMENTS' in prompt
    assert 'Generated from skills/registry.yaml' in prompt
    assert (root / 'skills' / name / 'SKILL.md').exists()
    if skill['execution']['mode'] == 'subagent':
        assert '`subagent` tool' in prompt and "skill's Output format" in prompt
PY

echo 'Native Pi runtime validation passed.'
