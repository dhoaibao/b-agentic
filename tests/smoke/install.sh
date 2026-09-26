#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Keep runner-level XDG configuration from escaping the per-case HOME sandboxes.
unset B_AGENTIC_PI_DIR PI_CODING_AGENT_DIR XDG_CONFIG_HOME
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/b-agentic-pi-smoke.XXXXXX")"
WORK_DIR="$(cd "$WORK_DIR" && pwd -P)"
pids=()
cleanup() {
  local pid
  # Never remove a sandbox while another smoke group is still using it.
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || :; done
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() { printf 'smoke-install.sh: %s\n' "$*" >&2; exit 1; }
assert_file() { [ -f "$1" ] || fail "expected file: $1"; }
assert_no_path() { [ ! -e "$1" ] || fail "unexpected path: $1"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "expected $2 in $1"; }
assert_json() {
  python3 - "$1" "$2" <<'PY' || fail "JSON assertion failed: $1"
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text())
assert eval(sys.argv[2], {'data': data})
PY
}

make_source() {
  local destination="$1" directory
  mkdir -p "$destination"
  cp "$ROOT_DIR/install.sh" "$destination/"
  for directory in pi skills references tooling; do
    cp -R "$ROOT_DIR/$directory" "$destination/"
  done
}

make_bin() {
  local directory="$1"
  mkdir -p "$directory"
cat >"$directory/pi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/pi.log"
if [ "${PI_MOCK_FAIL_REMOVE:-0}" = 1 ] && [ "$1" = remove ]; then exit 1; fi
if [ "${PI_MOCK_FAIL_LIST:-0}" = 1 ] && [ "$1" = list ]; then exit 1; fi
if [ "$1" = list ]; then
  python3 - "$PI_CODING_AGENT_DIR" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
print('User packages:')
for package in json.loads((root / 'settings.json').read_text()).get('packages', []):
    print('  ' + package)
    cache = root / 'npm/node_modules' / package.removeprefix('npm:')
    if cache.is_dir():
        print('    ' + str(cache))
PY
  exit $?
fi
if [ "${PI_MOCK_FAIL_INSTALL:-0}" = 1 ] && [ "$1" = install ]; then exit 1; fi
if [ "${PI_MOCK_PARTIAL_INSTALL:-0}" = 1 ] && [ "$1" = install ]; then
  python3 - "$PI_CODING_AGENT_DIR/b-agentic/install.json" "$2" <<'PY' || exit 1
import json, sys
from pathlib import Path
manifest = json.loads(Path(sys.argv[1]).read_text())
assert manifest['packageState'] == 'partial' and manifest['failedPackage'] == sys.argv[2]
PY
  mkdir -p "$PI_CODING_AGENT_DIR/npm/node_modules/@gotgenes/pi-subagents"
  printf '{"version":"1.0.0"}\n' >"$PI_CODING_AGENT_DIR/npm/node_modules/@gotgenes/pi-subagents/package.json"
  exit 1
fi
if [ "$1" = install ]; then
  mkdir -p "$PI_CODING_AGENT_DIR/npm/node_modules/${2#npm:}"
  touch "$PI_CODING_AGENT_DIR/npm/node_modules/${2#npm:}/extension.js"
fi
if [ "$1" = update ] && [ "$2" = --extensions ] &&
   [ -d "$PI_CODING_AGENT_DIR/npm/node_modules/user-extension" ]; then
  touch "$PI_CODING_AGENT_DIR/npm/node_modules/user-extension/.updated"
fi
EOF
  chmod +x "$directory/pi"
}

run_install() {
  local sandbox="$1"
  shift
  HOME="$sandbox/home" PATH="$sandbox/bin:$PATH" \
    B_AGENTIC_DIR="$sandbox/source" B_AGENTIC_REPO="$sandbox/source" \
    bash "$ROOT_DIR/install.sh" "$@"
}

# Each group has its own sandboxes. Keep lifecycle steps within a group ordered,
# but run independent groups concurrently to shorten the release gate.
(
# Unsafe shared-config locations fail before the installer touches Pi or assets.
for case_name in outside symlink; do
  unsafe="$WORK_DIR/unsafe-$case_name"
  mkdir -p "$unsafe/home"
  make_source "$unsafe/source"
  make_bin "$unsafe/bin"
  if [ "$case_name" = outside ]; then
    config_home="$unsafe/outside-home"
  else
    mkdir -p "$unsafe/elsewhere"
    ln -s "$unsafe/elsewhere" "$unsafe/home/linked-config"
    config_home="$unsafe/home/linked-config"
  fi
  if XDG_CONFIG_HOME="$config_home" run_install "$unsafe" >"$unsafe/install.log" 2>&1; then
    fail "accepted unsafe Magic Context $case_name path"
  fi
  assert_contains "$unsafe/install.log" 'Magic Context config must be a non-symlinked path under HOME'
  assert_no_path "$unsafe/bin/pi.log"
  assert_no_path "$unsafe/home/.pi/agent/b-agentic"
  assert_no_path "$unsafe/home/.pi/agent/settings.json"
done

# A corrupt prior manifest is rejected before any Pi or shared-config changes.
malformed="$WORK_DIR/malformed-manifest"
mkdir -p "$malformed/home/.pi/agent/b-agentic" "$malformed/home/.config/cortexkit"
make_source "$malformed/source"
make_bin "$malformed/bin"
printf '%s\n' '{invalid json' >"$malformed/home/.pi/agent/b-agentic/install.json"
printf '%s\n' '{"custom":true}' >"$malformed/home/.config/cortexkit/magic-context.jsonc"
if run_install "$malformed" >"$malformed/install.log" 2>&1; then
  fail 'accepted malformed Pi install manifest'
fi
assert_contains "$malformed/install.log" 'unreadable Pi install manifest'
assert_no_path "$malformed/bin/pi.log"
assert_no_path "$malformed/home/.pi/agent/settings.json"
assert_json "$malformed/home/.config/cortexkit/magic-context.jsonc" "data=={'custom': True}"

# Existing user-owned ask rules stay intact, while newly appended deny rules
# take precedence when the Pi permission extension matches the last rule.
legacy_policy="$WORK_DIR/legacy-permission-policy"
mkdir -p "$legacy_policy/home/.pi/agent/extensions/pi-permission-system"
make_source "$legacy_policy/source"
make_bin "$legacy_policy/bin"
printf '%s\n' '{"permission":{"bash":{"sudo *":"ask","docker system prune*":"ask","user-tool *":"allow"}}}' >"$legacy_policy/home/.pi/agent/extensions/pi-permission-system/config.json"
run_install "$legacy_policy" >"$legacy_policy/install.log" 2>&1
assert_json "$legacy_policy/home/.pi/agent/extensions/pi-permission-system/config.json" "data['permission']['bash']['sudo *']=='ask' and data['permission']['bash']['docker system prune*']=='ask' and data['permission']['bash']['user-tool *']=='allow' and list(data['permission']['bash']).index('sudo*') > list(data['permission']['bash']).index('sudo *') and list(data['permission']['bash']).index('docker system prun*') > list(data['permission']['bash']).index('docker system prune*') and data['permission']['external_directory_write']=='deny'"

# A manifest-write failure on sync must restore this run's pre-merge file,
# even when the original manifest says b-agentic created it.
rollback="$WORK_DIR/manifest-rollback"
mkdir -p "$rollback/home"
make_source "$rollback/source"
make_bin "$rollback/bin"
run_install "$rollback" >"$rollback/install.log" 2>&1
printf '%s\n' '{"enabled":true,"embedding":{"provider":"local"},"userNote":"retain me"}' >"$rollback/home/.config/cortexkit/magic-context.jsonc"
python3 - "$rollback/home/.pi/agent/b-agentic/install.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
manifest = json.loads(path.read_text())
manifest['backups'] = 'invalid'
path.write_text(json.dumps(manifest))
PY
if run_install "$rollback" --sync >"$rollback/sync.log" 2>&1; then
  fail 'expected malformed backup metadata to abort manifest write'
fi
assert_contains "$rollback/sync.log" 'failed to write Pi install manifest'
assert_json "$rollback/home/.config/cortexkit/magic-context.jsonc" "data['userNote']=='retain me' and data['embedding']['provider']=='local'"

# A later config-merge failure must not touch the shared CortexKit config
# before ownership can be recorded. Retry and clean up through both paths.
for removal in source manifest; do
  interrupted_magic="$WORK_DIR/interrupted-magic-$removal"
  mkdir -p "$interrupted_magic/home/.pi/agent" "$interrupted_magic/home/.config/cortexkit"
  make_source "$interrupted_magic/source"
  make_bin "$interrupted_magic/bin"
  printf '%s\n' '{"custom":true}' >"$interrupted_magic/home/.config/cortexkit/magic-context.jsonc"
  printf '%s\n' '{invalid json' >"$interrupted_magic/home/.pi/agent/mcp.json"
  if run_install "$interrupted_magic" >"$interrupted_magic/failed.log" 2>&1; then
    fail 'expected invalid MCP config to abort installation'
  fi
  assert_json "$interrupted_magic/home/.config/cortexkit/magic-context.jsonc" "data=={'custom': True}"
  printf '%s\n' '{}' >"$interrupted_magic/home/.pi/agent/mcp.json"
  run_install "$interrupted_magic" >"$interrupted_magic/retry.log" 2>&1
  assert_json "$interrupted_magic/home/.config/cortexkit/magic-context.jsonc" "data['custom'] is True and data['enabled'] is True"
  if [ "$removal" = manifest ]; then
    rm -rf "$interrupted_magic/source"
    HOME="$interrupted_magic/home" PATH="$interrupted_magic/bin:$PATH" B_AGENTIC_DIR="$interrupted_magic/missing" \
      bash "$ROOT_DIR/install.sh" --uninstall >"$interrupted_magic/uninstall.log" 2>&1
  else
    run_install "$interrupted_magic" --uninstall >"$interrupted_magic/uninstall.log" 2>&1
  fi
  assert_json "$interrupted_magic/home/.config/cortexkit/magic-context.jsonc" "data=={'custom': True}"
done
) & pids+=("$!")

(
sandbox="$WORK_DIR/primary"
mkdir -p "$sandbox/home/.pi/agent"
make_source "$sandbox/source"
make_bin "$sandbox/bin"
printf '%s\n' '{"custom":true,"theme":"light","packages":["npm:user-extension"],"compaction":{"enabled":false}}' >"$sandbox/home/.pi/agent/settings.json"
printf '%s\n' '{"maxConcurrent":2,"excludedExtensionPackages":["npm:user-extension"]}' >"$sandbox/home/.pi/agent/subagents.json"
mkdir -p "$sandbox/home/.config/cortexkit"
printf '%s\n' '{"historian":{"pi":{"model":"anthropic/claude-haiku-4-5"}},"custom":true}' >"$sandbox/home/.config/cortexkit/magic-context.jsonc"
printf '%s\n' '{"mcpServers":{"user_server":{"url":"https://example.invalid/mcp","directTools":["custom_tool"]}}}' >"$sandbox/home/.pi/agent/mcp.json"
if run_install "$sandbox" --runtime=pi >"$sandbox/invalid-arg.log" 2>&1; then
  fail 'accepted removed runtime selection flag'
fi
assert_contains "$sandbox/invalid-arg.log" 'unknown argument: --runtime=pi'
run_install "$sandbox" >"$sandbox/install.log" 2>&1

agent="$sandbox/home/.pi/agent"
metadata="$agent/b-agentic"
assert_file "$agent/AGENTS.md"
assert_file "$agent/themes/dracula.json"
assert_json "$agent/themes/dracula.json" "data['name']=='dracula' and data['colors']['accent']=='purple'"
assert_file "$metadata/themes/LICENSE"
assert_file "$metadata/themes/LICENSE.snapshot"
assert_file "$agent/skills/b-plan/SKILL.md"
assert_file "$agent/agents/b-planner.md"
assert_file "$agent/prompts/b-plan.md"
assert_file "$agent/extensions/pi-permission-system/config.json"
assert_file "$metadata/install.json"
assert_json "$metadata/install.json" "data['runtime']=='pi' and data['themeAction']=='write' and data['subagentsAction']=='merge' and data['paths']['subagents']=='$agent/subagents.json' and data['backups']['subagents']!='none' and len(data['agents'])==4 and len(data['skills'])==15 and len(data['commands'])==15"
assert_json "$agent/subagents.json" "data=={'maxConcurrent':2,'excludedExtensionPackages':['npm:@cortexkit/pi-magic-context','npm:user-extension']}"
assert_json "$sandbox/home/.config/cortexkit/magic-context.jsonc" "data['custom'] is True and data['enabled'] is True and data['embedding']['provider']=='local' and data['historian']['pi']['model']=='anthropic/claude-haiku-4-5'"
assert_json "$agent/settings.json" "'npm:@cortexkit/pi-magic-context' in data['packages'] and 'npm:pi-antigravity' in data['packages'] and data['custom'] is True and data['theme']=='light' and data['packages'][0]=='npm:@gotgenes/pi-subagents' and 'npm:user-extension' in data['packages'] and data['compaction']=={'enabled': False}"
assert_json "$agent/mcp.json" "len(data['mcpServers'])==8 and data['mcpServers']['user_server']['url']=='https://example.invalid/mcp' and data['mcpServers']['user_server']['directTools']==['custom_tool']"
assert_json "$agent/mcp.json" "sum(len(server['directTools']) for name, server in data['mcpServers'].items() if name!='user_server')==44"
assert_json "$agent/mcp.json" "'browser_snapshot' in data['mcpServers']['playwright']['directTools'] and 'browser_click' not in data['mcpServers']['playwright']['directTools']"
assert_json "$agent/extensions/pi-permission-system/config.json" "data['permission']['path']['*.env']=='deny' and data['permission']['mcp']['*']=='ask' and data['permissionReviewLog'] is False"
assert_json "$agent/extensions/pi-permission-system/config.json" "all(data['permission'][name]=='allow' for name in ('ctx_search', 'ctx_expand', 'ctx_memory', 'ctx_note', 'ctx_reduce', 'todowrite')) and data['permission']['*']=='ask'"
assert_contains "$sandbox/bin/pi.log" 'update --self'
assert_contains "$sandbox/bin/pi.log" 'list --no-approve'
assert_contains "$sandbox/bin/pi.log" 'install npm:@gotgenes/pi-subagents --no-approve'
assert_contains "$sandbox/bin/pi.log" 'install npm:@cortexkit/pi-magic-context --no-approve'
assert_contains "$sandbox/bin/pi.log" 'install npm:pi-antigravity --no-approve'
if grep -Fq 'update --extensions --no-approve' "$sandbox/bin/pi.log"; then
  fail 'fresh install unexpectedly updated Pi extensions'
fi

printf '\n' >>"$sandbox/source/references/capabilities.yaml"
run_install "$sandbox" --sync >"$sandbox/sync.log" 2>&1
cmp "$sandbox/source/references/capabilities.yaml" "$metadata/references/capabilities.yaml"
printf '\nmodified\n' >>"$agent/agents/b-planner.md"
run_install "$sandbox" --sync >"$sandbox/modified-sync.log" 2>&1
assert_contains "$sandbox/modified-sync.log" 'preserving modified or user-owned Pi specialist'
assert_contains "$agent/agents/b-planner.md" modified
python3 - "$agent/subagents.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data['excludedExtensionPackages'].append('npm:added-by-user')
path.write_text(json.dumps(data))
PY
run_install "$sandbox" --uninstall >"$sandbox/uninstall.log" 2>&1
assert_no_path "$agent/skills/b-plan"
assert_no_path "$agent/prompts/b-plan.md"
assert_file "$agent/agents/b-planner.md"
assert_file "$metadata/install.json"
assert_json "$sandbox/home/.config/cortexkit/magic-context.jsonc" "data=={'historian': {'pi': {'model': 'anthropic/claude-haiku-4-5'}}, 'custom': True}"
assert_json "$agent/settings.json" "data == {'custom': True, 'theme': 'light', 'packages': ['npm:user-extension'], 'compaction': {'enabled': False}}"
assert_json "$agent/subagents.json" "data=={'maxConcurrent':2,'excludedExtensionPackages':['npm:user-extension','npm:added-by-user']}"
assert_no_path "$agent/themes/dracula.json"
assert_json "$agent/mcp.json" "data == {'mcpServers': {'user_server': {'url': 'https://example.invalid/mcp', 'directTools': ['custom_tool']}}}"

# A failed package removal must retain both ownership evidence and the
# settings declaration so a later uninstall can retry.
retry="$WORK_DIR/retry"
mkdir -p "$retry/home"
make_source "$retry/source"
make_bin "$retry/bin"
run_install "$retry" >"$retry/install.log" 2>&1
assert_json "$retry/home/.pi/agent/settings.json" "data['theme']=='dracula' and data['compaction']=={'enabled': False}"
assert_json "$retry/home/.pi/agent/subagents.json" "data=={'excludedExtensionPackages':['npm:@cortexkit/pi-magic-context']}"
assert_json "$retry/home/.config/cortexkit/magic-context.jsonc" "data=={'enabled': True, 'embedding': {'provider': 'local'}}"
PI_MOCK_FAIL_REMOVE=1 run_install "$retry" --uninstall >"$retry/failed-uninstall.log" 2>&1
assert_contains "$retry/failed-uninstall.log" 'could not remove npm:@gotgenes/pi-subagents'
assert_file "$retry/home/.pi/agent/b-agentic/install.json"
assert_json "$retry/home/.pi/agent/settings.json" "'npm:@gotgenes/pi-subagents' in data['packages']"
run_install "$retry" --uninstall >"$retry/retry-uninstall.log" 2>&1
assert_no_path "$retry/home/.pi/agent/b-agentic/install.json"
assert_no_path "$retry/home/.pi/agent/settings.json"
assert_no_path "$retry/home/.pi/agent/subagents.json"
assert_no_path "$retry/home/.config/cortexkit/magic-context.jsonc"
assert_no_path "$retry/home/.pi/agent/themes/dracula.json"

plain="$WORK_DIR/plain-sync"
mkdir -p "$plain/home"
make_source "$plain/source"
make_bin "$plain/bin"
run_install "$plain" >"$plain/install.log" 2>&1
rm "$plain/home/.pi/agent/subagents.json"
run_install "$plain" --sync >"$plain/sync.log" 2>&1
assert_json "$plain/home/.pi/agent/subagents.json" "data['excludedExtensionPackages']==['npm:@cortexkit/pi-magic-context']"
assert_json "$plain/home/.pi/agent/b-agentic/install.json" "data['themeAction']=='replace'"
[ "$(grep -Fc 'install npm:@gotgenes/pi-subagents --no-approve' "$plain/bin/pi.log")" -eq 1 ] ||
  fail 'completed sync reinstalled a Pi extension'
assert_contains "$plain/bin/pi.log" 'update --extensions --no-approve'
run_install "$plain" --uninstall >"$plain/uninstall.log" 2>&1
assert_no_path "$plain/home/.pi/agent/AGENTS.md"
assert_no_path "$plain/home/.pi/agent/themes/dracula.json"
assert_no_path "$plain/home/.pi/agent/b-agentic/install.json"
assert_no_path "$plain/home/.pi/agent/subagents.json"
assert_no_path "$plain/home/.config/cortexkit/magic-context.jsonc"

# Sync upgrades older installs without a subagents entry, preserving the
# original user list so uninstall can remove only the new exclusion.
upgrade="$WORK_DIR/upgrade-subagents"
mkdir -p "$upgrade/home/.pi/agent"
make_source "$upgrade/source"
make_bin "$upgrade/bin"
printf '%s\n' '{"excludedExtensionPackages":["npm:user-extension"],"maxConcurrent":2}' >"$upgrade/home/.pi/agent/subagents.json"
run_install "$upgrade" >"$upgrade/install.log" 2>&1
python3 - "$upgrade/home/.pi/agent/b-agentic/install.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data.pop('subagentsAction')
data['paths'].pop('subagents')
data['backups'].pop('subagents')
path.write_text(json.dumps(data))
PY
printf '%s\n' '{"excludedExtensionPackages":["npm:user-extension"],"maxConcurrent":2}' >"$upgrade/home/.pi/agent/subagents.json"
run_install "$upgrade" --sync >"$upgrade/sync.log" 2>&1
assert_json "$upgrade/home/.pi/agent/subagents.json" "data['excludedExtensionPackages']==['npm:@cortexkit/pi-magic-context','npm:user-extension']"
run_install "$upgrade" --uninstall >"$upgrade/uninstall.log" 2>&1
assert_json "$upgrade/home/.pi/agent/subagents.json" "data=={'excludedExtensionPackages':['npm:user-extension'],'maxConcurrent':2}"

# An old manifest has no claim on a user-created subagents file during uninstall.
legacy="$WORK_DIR/legacy-subagents"
mkdir -p "$legacy/home"
make_source "$legacy/source"
make_bin "$legacy/bin"
run_install "$legacy" >"$legacy/install.log" 2>&1
python3 - "$legacy/home/.pi/agent/b-agentic/install.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data.pop('subagentsAction')
data['paths'].pop('subagents')
data['backups'].pop('subagents')
path.write_text(json.dumps(data))
PY
printf '%s\n' '{"excludedExtensionPackages":["npm:user-extension"]}' >"$legacy/home/.pi/agent/subagents.json"
run_install "$legacy" --uninstall >"$legacy/uninstall.log" 2>&1
assert_json "$legacy/home/.pi/agent/subagents.json" "data=={'excludedExtensionPackages':['npm:user-extension']}"
assert_no_path "$legacy/home/.pi/agent/b-agentic/install.json"

# Pre-existing listed packages are updated rather than installed again.
existing="$WORK_DIR/existing-package"
mkdir -p "$existing/home/.pi/agent/npm/node_modules/@gotgenes/pi-subagents" \
  "$existing/home/.pi/agent/npm/node_modules/user-extension"
make_source "$existing/source"
make_bin "$existing/bin"
printf '%s\n' '{"packages":["npm:@gotgenes/pi-subagents","npm:user-extension"],"compaction":{"enabled":true}}' >"$existing/home/.pi/agent/settings.json"
run_install "$existing" >"$existing/install.log" 2>&1
assert_contains "$existing/bin/pi.log" 'update --extensions --no-approve'
assert_contains "$existing/install.log" 'Pi native compaction remains enabled in user settings'
assert_json "$existing/home/.pi/agent/settings.json" "data['compaction']=={'enabled': True}"
assert_file "$existing/home/.pi/agent/npm/node_modules/user-extension/.updated"
if grep -Fq 'install npm:@gotgenes/pi-subagents --no-approve' "$existing/bin/pi.log"; then
  fail 'pre-existing Pi extension was reinstalled'
fi

# A failed list must not silently fall back to reinstalling packages.
list_failure="$WORK_DIR/list-failure"
mkdir -p "$list_failure/home"
make_source "$list_failure/source"
make_bin "$list_failure/bin"
if PI_MOCK_FAIL_LIST=1 run_install "$list_failure" >"$list_failure/install.log" 2>&1; then
  fail 'expected Pi list failure to abort installation'
fi
assert_json "$list_failure/home/.pi/agent/b-agentic/install.json" "data['packageState']=='pending'"
if grep -Fq 'install npm:' "$list_failure/bin/pi.log"; then
  fail 'Pi list failure fell back to reinstalling packages'
fi

) & pids+=("$!")

(
# Sync refreshes an unchanged managed theme from the checked-in source.
theme_refresh="$WORK_DIR/theme-refresh"
mkdir -p "$theme_refresh/home"
make_source "$theme_refresh/source"
make_bin "$theme_refresh/bin"
run_install "$theme_refresh" >"$theme_refresh/install.log" 2>&1
python3 - "$theme_refresh/source/pi/themes/dracula.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data['vars']['purple'] = '#c4a0fc'
path.write_text(json.dumps(data, indent=2) + '\n')
PY
run_install "$theme_refresh" --sync >"$theme_refresh/sync.log" 2>&1
assert_json "$theme_refresh/home/.pi/agent/themes/dracula.json" "data['vars']['purple']=='#c4a0fc'"
run_install "$theme_refresh" --uninstall >"$theme_refresh/uninstall.log" 2>&1
assert_no_path "$theme_refresh/home/.pi/agent/themes/dracula.json"

# An existing or modified theme is user-owned; neither sync nor uninstall overwrites it.
user_theme="$WORK_DIR/user-theme"
mkdir -p "$user_theme/home/.pi/agent/themes"
make_source "$user_theme/source"
make_bin "$user_theme/bin"
printf '{"name":"dracula","colors":{"accent":"#ffffff"}}\n' >"$user_theme/home/.pi/agent/themes/dracula.json"
run_install "$user_theme" >"$user_theme/install.log" 2>&1
assert_json "$user_theme/home/.pi/agent/b-agentic/install.json" "data['themeAction']=='preserve'"
run_install "$user_theme" --uninstall >"$user_theme/uninstall.log" 2>&1
assert_json "$user_theme/home/.pi/agent/themes/dracula.json" "data['colors']['accent']=='#ffffff'"

modified_theme="$WORK_DIR/modified-theme"
mkdir -p "$modified_theme/home"
make_source "$modified_theme/source"
make_bin "$modified_theme/bin"
run_install "$modified_theme" >"$modified_theme/install.log" 2>&1
printf '\n' >>"$modified_theme/home/.pi/agent/themes/dracula.json"
run_install "$modified_theme" --sync >"$modified_theme/sync.log" 2>&1
assert_contains "$modified_theme/sync.log" 'preserving modified or user-owned Pi theme'
rm -rf "$modified_theme/source"
HOME="$modified_theme/home" PATH="$modified_theme/bin:$PATH" B_AGENTIC_DIR="$modified_theme/missing" \
  bash "$ROOT_DIR/install.sh" --uninstall >"$modified_theme/uninstall.log" 2>&1
assert_contains "$modified_theme/uninstall.log" 'preserving modified Pi theme'
assert_file "$modified_theme/home/.pi/agent/b-agentic/install.json"
assert_file "$modified_theme/home/.pi/agent/themes/dracula.json"

linked_theme="$WORK_DIR/linked-theme"
mkdir -p "$linked_theme/home/.pi/agent/themes" "$linked_theme/home/user"
make_source "$linked_theme/source"
make_bin "$linked_theme/bin"
printf '%s\n' 'user theme' >"$linked_theme/home/user/dracula.json"
ln -s "$linked_theme/home/user/dracula.json" "$linked_theme/home/.pi/agent/themes/dracula.json"
run_install "$linked_theme" >"$linked_theme/install.log" 2>&1
run_install "$linked_theme" --uninstall >"$linked_theme/uninstall.log" 2>&1
[ -L "$linked_theme/home/.pi/agent/themes/dracula.json" ] || fail 'symlinked Pi theme not preserved'
assert_contains "$linked_theme/home/user/dracula.json" 'user theme'

linked_theme_dir="$WORK_DIR/linked-theme-dir"
mkdir -p "$linked_theme_dir/home/.pi/agent" "$linked_theme_dir/home/user/themes"
make_source "$linked_theme_dir/source"
make_bin "$linked_theme_dir/bin"
ln -s "$linked_theme_dir/home/user/themes" "$linked_theme_dir/home/.pi/agent/themes"
run_install "$linked_theme_dir" >"$linked_theme_dir/install.log" 2>&1
assert_no_path "$linked_theme_dir/home/user/themes/dracula.json"
run_install "$linked_theme_dir" --uninstall >"$linked_theme_dir/uninstall.log" 2>&1
[ -L "$linked_theme_dir/home/.pi/agent/themes" ] || fail 'symlinked Pi theme directory not preserved'

linked_license="$WORK_DIR/linked-license"
mkdir -p "$linked_license/home/.pi/agent/b-agentic/themes" "$linked_license/home/user"
make_source "$linked_license/source"
make_bin "$linked_license/bin"
printf '%s\n' 'user-owned license' >"$linked_license/home/user/LICENSE"
ln -s "$linked_license/home/user/LICENSE" "$linked_license/home/.pi/agent/b-agentic/themes/LICENSE"
if run_install "$linked_license" >"$linked_license/install.log" 2>&1; then
  fail 'accepted symlinked Pi theme license destination'
fi
assert_contains "$linked_license/install.log" 'symlinked Pi theme snapshot or license'
assert_contains "$linked_license/home/user/LICENSE" 'user-owned license'
assert_no_path "$linked_license/home/.pi/agent/themes/dracula.json"

regular_license="$WORK_DIR/regular-license"
mkdir -p "$regular_license/home/.pi/agent/b-agentic/themes"
make_source "$regular_license/source"
make_bin "$regular_license/bin"
printf '%s\n' 'user-owned license' >"$regular_license/home/.pi/agent/b-agentic/themes/LICENSE"
if run_install "$regular_license" >"$regular_license/install.log" 2>&1; then
  fail 'accepted conflicting Pi theme license destination'
fi
assert_contains "$regular_license/install.log" 'preserving modified Pi theme license'
assert_contains "$regular_license/home/.pi/agent/b-agentic/themes/LICENSE" 'user-owned license'
assert_no_path "$regular_license/home/.pi/agent/themes/dracula.json"

edited_license="$WORK_DIR/edited-license"
mkdir -p "$edited_license/home"
make_source "$edited_license/source"
make_bin "$edited_license/bin"
run_install "$edited_license" >"$edited_license/install.log" 2>&1
printf '\nuser edit\n' >>"$edited_license/home/.pi/agent/b-agentic/themes/LICENSE"
if run_install "$edited_license" --sync >"$edited_license/sync.log" 2>&1; then
  fail 'sync overwrote modified Pi theme license'
fi
assert_contains "$edited_license/home/.pi/agent/b-agentic/themes/LICENSE" 'user edit'
assert_file "$edited_license/home/.pi/agent/themes/dracula.json"
rm -rf "$edited_license/source"
HOME="$edited_license/home" PATH="$edited_license/bin:$PATH" B_AGENTIC_DIR="$edited_license/missing" \
  bash "$ROOT_DIR/install.sh" --uninstall >"$edited_license/uninstall.log" 2>&1
assert_contains "$edited_license/uninstall.log" 'preserving modified Pi theme license'
assert_file "$edited_license/home/.pi/agent/b-agentic/install.json"
assert_contains "$edited_license/home/.pi/agent/b-agentic/themes/LICENSE" 'user edit'

edited_kernel="$WORK_DIR/edited-kernel"
mkdir -p "$edited_kernel/home"
make_source "$edited_kernel/source"
make_bin "$edited_kernel/bin"
run_install "$edited_kernel" >"$edited_kernel/install.log" 2>&1
printf '\nuser-edited kernel\n' >>"$edited_kernel/home/.pi/agent/AGENTS.md"
run_install "$edited_kernel" --sync --replace-memory >"$edited_kernel/sync.log" 2>&1
run_install "$edited_kernel" --uninstall >"$edited_kernel/uninstall.log" 2>&1
assert_contains "$edited_kernel/home/.pi/agent/AGENTS.md" 'user-edited kernel'

# An interrupted first install records the original config before attempting
# package installation. A retry must not reclassify managed values as user data.
interrupted="$WORK_DIR/interrupted"
mkdir -p "$interrupted/home/.pi/agent"
make_source "$interrupted/source"
make_bin "$interrupted/bin"
printf '%s\n' '{"custom":true,"packages":["npm:user-extension"]}' >"$interrupted/home/.pi/agent/settings.json"
if PI_MOCK_FAIL_INSTALL=1 run_install "$interrupted" >"$interrupted/failed-install.log" 2>&1; then
  fail 'expected interrupted Pi package install'
fi
assert_json "$interrupted/home/.pi/agent/b-agentic/install.json" "data['packageState']=='partial' and data['failedPackage']=='npm:@gotgenes/pi-subagents' and data['backups']['settings']!='none'"
run_install "$interrupted" --sync >"$interrupted/retry-sync.log" 2>&1
run_install "$interrupted" --uninstall >"$interrupted/uninstall.log" 2>&1
assert_json "$interrupted/home/.pi/agent/settings.json" "data=={'custom':True,'packages':['npm:user-extension']}"
assert_no_path "$interrupted/home/.pi/agent/themes/dracula.json"
assert_no_path "$interrupted/home/.pi/agent/b-agentic/install.json"

partial="$WORK_DIR/partial-package"
mkdir -p "$partial/home"
make_source "$partial/source"
make_bin "$partial/bin"
if PI_MOCK_PARTIAL_INSTALL=1 run_install "$partial" >"$partial/failed-install.log" 2>&1; then
  fail 'expected partial Pi package install failure'
fi
assert_json "$partial/home/.pi/agent/b-agentic/install.json" "data['packageState']=='partial' and data['failedPackage']=='npm:@gotgenes/pi-subagents'"
assert_no_path "$partial/home/.pi/agent/npm/node_modules/@gotgenes/pi-subagents/extension.js"
if PI_MOCK_FAIL_LIST=1 run_install "$partial" --sync >"$partial/failed-retry.log" 2>&1; then
  fail 'expected Pi list failure during partial install recovery'
fi
assert_json "$partial/home/.pi/agent/b-agentic/install.json" "data['packageState']=='partial' and data['failedPackage']=='npm:@gotgenes/pi-subagents'"
run_install "$partial" --sync >"$partial/retry-sync.log" 2>&1
assert_json "$partial/home/.pi/agent/b-agentic/install.json" "data['packageState']=='ready' and 'failedPackage' not in data"
[ "$(grep -Fc 'install npm:@gotgenes/pi-subagents --no-approve' "$partial/bin/pi.log")" -eq 2 ] ||
  fail 'retry did not repair a partial Pi extension installation'
assert_file "$partial/home/.pi/agent/npm/node_modules/@gotgenes/pi-subagents/extension.js"

empty="$WORK_DIR/empty-config"
mkdir -p "$empty/home/.pi/agent/extensions/pi-permission-system"
make_source "$empty/source"
make_bin "$empty/bin"
printf '{}\n' >"$empty/home/.pi/agent/settings.json"
printf '{}\n' >"$empty/home/.pi/agent/mcp.json"
printf '{}\n' >"$empty/home/.pi/agent/extensions/pi-permission-system/config.json"
run_install "$empty" >"$empty/install.log" 2>&1
run_install "$empty" --uninstall >"$empty/uninstall.log" 2>&1
assert_json "$empty/home/.pi/agent/settings.json" "data=={}"
assert_json "$empty/home/.pi/agent/mcp.json" "data=={}"
assert_json "$empty/home/.pi/agent/extensions/pi-permission-system/config.json" "data=={}"

replaced="$WORK_DIR/replaced-kernel"
mkdir -p "$replaced/home/.pi/agent"
make_source "$replaced/source"
make_bin "$replaced/bin"
printf '%s\n' 'original user kernel' >"$replaced/home/.pi/agent/AGENTS.md"
run_install "$replaced" --replace-memory >"$replaced/install.log" 2>&1
run_install "$replaced" --sync >"$replaced/sync.log" 2>&1
run_install "$replaced" --uninstall >"$replaced/uninstall.log" 2>&1
assert_contains "$replaced/home/.pi/agent/AGENTS.md" 'original user kernel'
assert_no_path "$replaced/home/.pi/agent/b-agentic/install.json"

twice="$WORK_DIR/twice-replaced-kernel"
mkdir -p "$twice/home/.pi/agent"
make_source "$twice/source"
make_bin "$twice/bin"
printf '%s\n' 'first user kernel' >"$twice/home/.pi/agent/AGENTS.md"
run_install "$twice" --replace-memory >"$twice/install.log" 2>&1
printf '\nsecond user kernel\n' >>"$twice/home/.pi/agent/AGENTS.md"
run_install "$twice" --sync --replace-memory >"$twice/sync.log" 2>&1
assert_json "$twice/home/.pi/agent/b-agentic/install.json" "len(data['kernelPriorBackups'])==1"
run_install "$twice" --uninstall >"$twice/uninstall.log" 2>&1
assert_contains "$twice/home/.pi/agent/AGENTS.md" 'second user kernel'
assert_file "$twice/home/.pi/agent/b-agentic/install.json"
first_backup="$(python3 - "$twice/home/.pi/agent/b-agentic/install.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['kernelPriorBackups'][0])
PY
)"
assert_contains "$first_backup" 'first user kernel'

) & pids+=("$!")

(
# A symlinked specialist remains user-owned and prevents manifest disposal.
linked="$WORK_DIR/symlinked"
mkdir -p "$linked/home/.pi/agent/agents" "$linked/user"
make_source "$linked/source"
make_bin "$linked/bin"
printf '%s\n' 'user-owned agent' >"$linked/user/b-planner.md"
ln -s "$linked/user/b-planner.md" "$linked/home/.pi/agent/agents/b-planner.md"
run_install "$linked" >"$linked/install.log" 2>&1
run_install "$linked" --uninstall >"$linked/uninstall.log" 2>&1
[ -L "$linked/home/.pi/agent/agents/b-planner.md" ] || fail 'symlinked agent not preserved'
assert_file "$linked/home/.pi/agent/b-agentic/install.json"

# A symlinked kernel cannot be replaced through its target, even when it
# happens to match the prior managed snapshot on a later sync.
linked_kernel="$WORK_DIR/symlinked-kernel"
mkdir -p "$linked_kernel/home/.pi/agent" "$linked_kernel/user"
make_source "$linked_kernel/source"
make_bin "$linked_kernel/bin"
run_install "$linked_kernel" >"$linked_kernel/install.log" 2>&1
mv "$linked_kernel/home/.pi/agent/AGENTS.md" "$linked_kernel/user/AGENTS.md"
ln -s "$linked_kernel/user/AGENTS.md" "$linked_kernel/home/.pi/agent/AGENTS.md"
printf '\n' >>"$linked_kernel/source/references/kernel.template.md"
run_install "$linked_kernel" --sync >"$linked_kernel/sync.log" 2>&1
assert_contains "$linked_kernel/sync.log" 'preserving symlinked kernel'
cmp "$linked_kernel/user/AGENTS.md" "$linked_kernel/home/.pi/agent/b-agentic/AGENTS.md"
run_install "$linked_kernel" --uninstall >"$linked_kernel/uninstall.log" 2>&1
[ -L "$linked_kernel/home/.pi/agent/AGENTS.md" ] || fail 'symlinked kernel not preserved'

# A changed config path or missing backup cannot silently discard user values.
missing="$WORK_DIR/missing-backup"
mkdir -p "$missing/home/.pi/agent"
make_source "$missing/source"
make_bin "$missing/bin"
printf '%s\n' '{"custom":true}' >"$missing/home/.pi/agent/settings.json"
run_install "$missing" >"$missing/install.log" 2>&1
backup="$(python3 - "$missing/home/.pi/agent/b-agentic/install.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['backups']['settings'])
PY
)"
rm -f "$backup"
run_install "$missing" --uninstall >"$missing/uninstall.log" 2>&1
assert_contains "$missing/uninstall.log" 'preserving package cache: original settings backup is missing'
assert_file "$missing/home/.pi/agent/b-agentic/install.json"
rm -rf "$missing/source"
HOME="$missing/home" PATH="$missing/bin:$PATH" B_AGENTIC_DIR="$missing/source" \
  bash "$ROOT_DIR/install.sh" --uninstall >"$missing/manifest-uninstall.log" 2>&1
assert_contains "$missing/manifest-uninstall.log" 'missing managed template or backup'
assert_file "$missing/home/.pi/agent/b-agentic/install.json"

# A symlinked config and its target are not rewritten on uninstall.
symlink="$WORK_DIR/symlink-config"
mkdir -p "$symlink/home/.pi/agent" "$symlink/user"
make_source "$symlink/source"
make_bin "$symlink/bin"
run_install "$symlink" >"$symlink/install.log" 2>&1
mv "$symlink/home/.pi/agent/mcp.json" "$symlink/user/mcp.json"
ln -s "$symlink/user/mcp.json" "$symlink/home/.pi/agent/mcp.json"
run_install "$symlink" --uninstall >"$symlink/uninstall.log" 2>&1
assert_contains "$symlink/uninstall.log" 'preserving symlinked mcp'
[ -L "$symlink/home/.pi/agent/mcp.json" ] || fail 'symlinked config not preserved'
assert_file "$symlink/home/.pi/agent/b-agentic/install.json"

# An existing symlinked specialist config remains user-owned on install.
linked_subagents="$WORK_DIR/linked-subagents"
mkdir -p "$linked_subagents/home/.pi/agent" "$linked_subagents/user"
make_source "$linked_subagents/source"
make_bin "$linked_subagents/bin"
printf '%s\n' '{"excludedExtensionPackages":["npm:user-extension"]}' >"$linked_subagents/user/subagents.json"
ln -s "$linked_subagents/user/subagents.json" "$linked_subagents/home/.pi/agent/subagents.json"
if run_install "$linked_subagents" >"$linked_subagents/install.log" 2>&1; then
  fail 'accepted symlinked Pi specialist configuration'
fi
assert_contains "$linked_subagents/install.log" 'preserving symlinked subagents configuration'
assert_json "$linked_subagents/user/subagents.json" "data=={'excludedExtensionPackages':['npm:user-extension']}"

# Manifest-only uninstall requires no source checkout.
clean="$WORK_DIR/clean"
mkdir -p "$clean/home"
make_source "$clean/source"
make_bin "$clean/bin"
run_install "$clean" >"$clean/install.log" 2>&1
run_install "$clean" --sync >"$clean/sync.log" 2>&1
[ "$(grep -Fc 'install npm:@gotgenes/pi-subagents --no-approve' "$clean/bin/pi.log")" -eq 1 ] ||
  fail 'manifest-only fixture reinstalled a Pi extension during sync'
assert_no_path "$clean/home/.pi/agent/b-agentic/backups/AGENTS.md.bak"
rm -rf "$clean/source"
HOME="$clean/home" PATH="$clean/bin:$PATH" B_AGENTIC_DIR="$clean/missing" \
  bash "$ROOT_DIR/install.sh" --uninstall --dry-run >"$clean/dry-uninstall.log" 2>&1
assert_contains "$clean/dry-uninstall.log" 'Manifest-only uninstall preview for Pi'
assert_file "$clean/home/.pi/agent/skills/b-plan/SKILL.md"
assert_file "$clean/home/.pi/agent/settings.json"
assert_file "$clean/home/.pi/agent/subagents.json"
assert_file "$clean/home/.config/cortexkit/magic-context.jsonc"
assert_file "$clean/home/.pi/agent/themes/dracula.json"
assert_file "$clean/home/.pi/agent/b-agentic/install.json"
if grep -Fq 'remove npm:' "$clean/bin/pi.log"; then fail 'dry-run removed a Pi package'; fi
HOME="$clean/home" PATH="$clean/bin:$PATH" B_AGENTIC_DIR="$clean/missing" PI_MOCK_FAIL_REMOVE=1 \
  bash "$ROOT_DIR/install.sh" --uninstall >"$clean/failed-uninstall.log" 2>&1
assert_contains "$clean/failed-uninstall.log" 'could not remove managed package'
assert_file "$clean/home/.pi/agent/b-agentic/install.json"
assert_json "$clean/home/.pi/agent/settings.json" "'npm:@gotgenes/pi-subagents' in data['packages']"
HOME="$clean/home" PATH="$clean/bin:$PATH" B_AGENTIC_DIR="$clean/missing" \
  bash "$ROOT_DIR/install.sh" --uninstall >"$clean/uninstall.log" 2>&1
assert_contains "$clean/uninstall.log" 'Manifest-only uninstall complete for Pi'
assert_no_path "$clean/home/.pi/agent/skills/b-plan"
assert_no_path "$clean/home/.pi/agent/agents/b-planner.md"
assert_no_path "$clean/home/.pi/agent/AGENTS.md"
assert_no_path "$clean/home/.pi/agent/themes/dracula.json"
assert_no_path "$clean/home/.pi/agent/subagents.json"
assert_contains "$clean/bin/pi.log" 'remove npm:@gotgenes/pi-subagents --no-approve'
assert_no_path "$clean/home/.config/cortexkit/magic-context.jsonc"

edited_orphan="$WORK_DIR/edited-orphan-kernel"
mkdir -p "$edited_orphan/home"
make_source "$edited_orphan/source"
make_bin "$edited_orphan/bin"
run_install "$edited_orphan" >"$edited_orphan/install.log" 2>&1
printf '\nuser-edited orphan kernel\n' >>"$edited_orphan/home/.pi/agent/AGENTS.md"
run_install "$edited_orphan" --sync --replace-memory >"$edited_orphan/sync.log" 2>&1
rm -rf "$edited_orphan/source"
HOME="$edited_orphan/home" PATH="$edited_orphan/bin:$PATH" B_AGENTIC_DIR="$edited_orphan/missing" \
  bash "$ROOT_DIR/install.sh" --uninstall >"$edited_orphan/uninstall.log" 2>&1
assert_contains "$edited_orphan/home/.pi/agent/AGENTS.md" 'user-edited orphan kernel'

dangling="$WORK_DIR/dangling-kernel"
mkdir -p "$dangling/home" "$dangling/user"
make_source "$dangling/source"
make_bin "$dangling/bin"
run_install "$dangling" >"$dangling/install.log" 2>&1
rm "$dangling/home/.pi/agent/AGENTS.md"
ln -s "$dangling/user/missing.md" "$dangling/home/.pi/agent/AGENTS.md"
rm -rf "$dangling/source"
HOME="$dangling/home" PATH="$dangling/bin:$PATH" B_AGENTIC_DIR="$dangling/missing" \
  bash "$ROOT_DIR/install.sh" --uninstall >"$dangling/uninstall.log" 2>&1
[ -L "$dangling/home/.pi/agent/AGENTS.md" ] || fail 'dangling user kernel symlink removed'
assert_file "$dangling/home/.pi/agent/b-agentic/install.json"

# Source-absent removal must restore the pre-install settings and user kernel,
# including when the first package install was interrupted.
orphan="$WORK_DIR/orphan-interrupted"
mkdir -p "$orphan/home/.pi/agent"
make_source "$orphan/source"
make_bin "$orphan/bin"
printf '%s\n' '{"custom":true}' >"$orphan/home/.pi/agent/settings.json"
printf '%s\n' 'orphan original kernel' >"$orphan/home/.pi/agent/AGENTS.md"
if PI_MOCK_FAIL_INSTALL=1 run_install "$orphan" --replace-memory >"$orphan/failed-install.log" 2>&1; then
  fail 'expected interrupted manifest-only fixture install'
fi
run_install "$orphan" --sync >"$orphan/retry-sync.log" 2>&1
rm -rf "$orphan/source"
HOME="$orphan/home" PATH="$orphan/bin:$PATH" B_AGENTIC_DIR="$orphan/missing" \
  bash "$ROOT_DIR/install.sh" --uninstall >"$orphan/uninstall.log" 2>&1
assert_json "$orphan/home/.pi/agent/settings.json" "data=={'custom':True}"
assert_no_path "$orphan/home/.pi/agent/themes/dracula.json"
assert_contains "$orphan/home/.pi/agent/AGENTS.md" 'orphan original kernel'
assert_no_path "$orphan/home/.pi/agent/b-agentic/install.json"

twice_orphan="$WORK_DIR/twice-replaced-orphan"
mkdir -p "$twice_orphan/home/.pi/agent"
make_source "$twice_orphan/source"
make_bin "$twice_orphan/bin"
printf '%s\n' 'first orphan kernel' >"$twice_orphan/home/.pi/agent/AGENTS.md"
run_install "$twice_orphan" --replace-memory >"$twice_orphan/install.log" 2>&1
printf '\nsecond orphan kernel\n' >>"$twice_orphan/home/.pi/agent/AGENTS.md"
run_install "$twice_orphan" --sync --replace-memory >"$twice_orphan/sync.log" 2>&1
rm -rf "$twice_orphan/source"
HOME="$twice_orphan/home" PATH="$twice_orphan/bin:$PATH" B_AGENTIC_DIR="$twice_orphan/missing" \
  bash "$ROOT_DIR/install.sh" --uninstall >"$twice_orphan/uninstall.log" 2>&1
assert_contains "$twice_orphan/home/.pi/agent/AGENTS.md" 'second orphan kernel'
assert_file "$twice_orphan/home/.pi/agent/b-agentic/install.json"
orphan_first_backup="$(python3 - "$twice_orphan/home/.pi/agent/b-agentic/install.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['kernelPriorBackups'][0])
PY
)"
assert_contains "$orphan_first_backup" 'first orphan kernel'

empty_orphan="$WORK_DIR/empty-config-orphan"
mkdir -p "$empty_orphan/home/.pi/agent/extensions/pi-permission-system"
make_source "$empty_orphan/source"
make_bin "$empty_orphan/bin"
printf '{}\n' >"$empty_orphan/home/.pi/agent/settings.json"
printf '{}\n' >"$empty_orphan/home/.pi/agent/mcp.json"
printf '{}\n' >"$empty_orphan/home/.pi/agent/extensions/pi-permission-system/config.json"
run_install "$empty_orphan" >"$empty_orphan/install.log" 2>&1
rm -rf "$empty_orphan/source"
HOME="$empty_orphan/home" PATH="$empty_orphan/bin:$PATH" B_AGENTIC_DIR="$empty_orphan/missing" \
  bash "$ROOT_DIR/install.sh" --uninstall >"$empty_orphan/uninstall.log" 2>&1
assert_json "$empty_orphan/home/.pi/agent/settings.json" "data=={}"
assert_json "$empty_orphan/home/.pi/agent/mcp.json" "data=={}"
assert_json "$empty_orphan/home/.pi/agent/extensions/pi-permission-system/config.json" "data=={}"

dry="$WORK_DIR/dry"
mkdir -p "$dry/home"
make_source "$dry/source"
make_bin "$dry/bin"
run_install "$dry" --dry-run >"$dry/log" 2>&1
assert_no_path "$dry/home/.pi/agent"
assert_contains "$dry/log" '[dry-run] pi update --self'
assert_contains "$dry/log" '[dry-run] install Pi theme'
assert_no_path "$dry/bin/pi.log"
run_install "$dry" --update --dry-run >"$dry/update.log" 2>&1
assert_contains "$dry/update.log" '[dry-run] pi update --extensions'
assert_no_path "$dry/bin/pi.log"

# A git-backed source dry-run reports the exact refresh operations: fetch plus
# pull, or fetch plus checkout when a ref is pinned.
gitdry="$WORK_DIR/git-dry"
mkdir -p "$gitdry/home"
make_source "$gitdry/source"
make_bin "$gitdry/bin"
git -C "$gitdry/source" init --quiet
run_install "$gitdry" --dry-run >"$gitdry/log" 2>&1
assert_contains "$gitdry/log" "[dry-run] git -C $gitdry/source fetch --tags --prune"
assert_contains "$gitdry/log" "[dry-run] git -C $gitdry/source pull --ff-only"
run_install "$gitdry" --ref=v1.2.3 --dry-run >"$gitdry/ref.log" 2>&1
assert_contains "$gitdry/ref.log" "[dry-run] git -C $gitdry/source checkout v1.2.3 --"
if grep -Fq 'pull --ff-only' "$gitdry/ref.log"; then fail 'dry-run reported pull for a pinned ref'; fi
assert_no_path "$gitdry/bin/pi.log"

# An override outside HOME is rejected before installation; a home-confined
# override remains removable after the source checkout is lost.
outside="$WORK_DIR/outside-home"
mkdir -p "$outside/home"
make_source "$outside/source"
make_bin "$outside/bin"
if B_AGENTIC_PI_DIR="$outside/agent" run_install "$outside" >"$outside/install.log" 2>&1; then
  fail 'accepted Pi agent directory outside HOME'
fi
assert_contains "$outside/install.log" 'Pi agent directory must be an absolute path under'
assert_no_path "$outside/agent"
rm -rf "$outside/source"
if HOME="$outside/home" PATH="$outside/bin:$PATH" B_AGENTIC_DIR="$outside/missing" B_AGENTIC_PI_DIR="$outside/agent" \
  bash "$ROOT_DIR/install.sh" --uninstall >"$outside/uninstall.log" 2>&1; then
  fail 'accepted outside-HOME manifest-only uninstall'
fi
assert_no_path "$outside/agent"

override="$WORK_DIR/home-override"
mkdir -p "$override/home"
make_source "$override/source"
make_bin "$override/bin"
B_AGENTIC_PI_DIR="$override/home/custom-agent" run_install "$override" >"$override/install.log" 2>&1
assert_file "$override/home/custom-agent/b-agentic/install.json"
rm -rf "$override/source"
HOME="$override/home" PATH="$override/bin:$PATH" B_AGENTIC_DIR="$override/missing" \
  B_AGENTIC_PI_DIR="$override/home/custom-agent" bash "$ROOT_DIR/install.sh" --uninstall >"$override/uninstall.log" 2>&1
assert_no_path "$override/home/custom-agent/b-agentic/install.json"
) & pids+=("$!")

failed=0
for index in "${!pids[@]}"; do
  if ! wait "${pids[$index]}"; then
    printf 'smoke-install.sh: group %s failed\n' "$((index + 1))" >&2
    failed=1
  fi
done
[ "$failed" -eq 0 ] || fail 'one or more installer smoke groups failed'
echo 'Pi installer smoke tests passed.'
