#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
unset B_AGENTIC_PI_DIR PI_CODING_AGENT_DIR
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/b-agentic-pi-smoke.XXXXXX")"
WORK_DIR="$(cd "$WORK_DIR" && pwd -P)"
trap 'rm -rf "$WORK_DIR"' EXIT

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
if [ "${PI_MOCK_FAIL_INSTALL:-0}" = 1 ] && [ "$1" = install ]; then exit 1; fi
if [ "${PI_MOCK_PARTIAL_INSTALL:-0}" = 1 ] && [ "$1" = install ]; then
  mkdir -p "$PI_CODING_AGENT_DIR/npm/node_modules/@gotgenes/pi-subagents"
  exit 1
fi
if [ "$1" = install ]; then mkdir -p "$PI_CODING_AGENT_DIR/npm/node_modules/${2#npm:}"; fi
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

sandbox="$WORK_DIR/primary"
mkdir -p "$sandbox/home/.pi/agent" "$sandbox/home/.config/opencode"
make_source "$sandbox/source"
make_bin "$sandbox/bin"
printf '%s\n' 'old runtime belongs to user' >"$sandbox/home/.config/opencode/AGENTS.md"
printf '%s\n' '{"custom":true,"packages":["npm:user-extension"],"compaction":{"enabled":false}}' >"$sandbox/home/.pi/agent/settings.json"
printf '%s\n' '{"mcpServers":{"user_server":{"url":"https://example.invalid/mcp"}}}' >"$sandbox/home/.pi/agent/mcp.json"
run_install "$sandbox" >"$sandbox/install.log" 2>&1

agent="$sandbox/home/.pi/agent"
metadata="$agent/b-agentic"
assert_file "$agent/AGENTS.md"
assert_file "$agent/skills/b-plan/SKILL.md"
assert_file "$agent/agents/b-planner.md"
assert_file "$agent/prompts/b-plan.md"
assert_file "$agent/extensions/pi-permission-system/config.json"
assert_file "$metadata/install.json"
assert_json "$metadata/install.json" "data['runtime']=='pi' and len(data['agents'])==4 and len(data['skills'])==15 and len(data['commands'])==15"
assert_json "$agent/settings.json" "data['custom'] is True and data['packages'][0]=='npm:@gotgenes/pi-subagents' and 'npm:user-extension' in data['packages'] and data['compaction']=={'enabled': False}"
assert_json "$agent/mcp.json" "len(data['mcpServers'])==8 and data['mcpServers']['user_server']['url']=='https://example.invalid/mcp'"
assert_json "$agent/extensions/pi-permission-system/config.json" "data['permission']['path']['*.env']=='deny' and data['permission']['mcp']['*']=='ask' and data['permissionReviewLog'] is False"
assert_contains "$sandbox/bin/pi.log" 'update --self'
assert_contains "$sandbox/bin/pi.log" 'install npm:@gotgenes/pi-subagents --no-approve'
assert_contains "$sandbox/home/.config/opencode/AGENTS.md" 'old runtime belongs to user'

# A failed package removal must retain both ownership evidence and the
# settings declaration so a later uninstall can retry.
retry="$WORK_DIR/retry"
mkdir -p "$retry/home"
make_source "$retry/source"
make_bin "$retry/bin"
run_install "$retry" >"$retry/install.log" 2>&1
PI_MOCK_FAIL_REMOVE=1 run_install "$retry" --uninstall >"$retry/failed-uninstall.log" 2>&1
assert_contains "$retry/failed-uninstall.log" 'could not remove npm:@gotgenes/pi-subagents'
assert_file "$retry/home/.pi/agent/b-agentic/install.json"
assert_json "$retry/home/.pi/agent/settings.json" "'npm:@gotgenes/pi-subagents' in data['packages']"
run_install "$retry" --uninstall >"$retry/retry-uninstall.log" 2>&1
assert_no_path "$retry/home/.pi/agent/b-agentic/install.json"
assert_no_path "$retry/home/.pi/agent/settings.json"

plain="$WORK_DIR/plain-sync"
mkdir -p "$plain/home"
make_source "$plain/source"
make_bin "$plain/bin"
run_install "$plain" >"$plain/install.log" 2>&1
run_install "$plain" --sync >"$plain/sync.log" 2>&1
[ "$(grep -Fc 'install npm:@gotgenes/pi-subagents --no-approve' "$plain/bin/pi.log")" -eq 1 ] ||
  fail 'completed sync reinstalled a Pi extension'
run_install "$plain" --uninstall >"$plain/uninstall.log" 2>&1
assert_no_path "$plain/home/.pi/agent/AGENTS.md"
assert_no_path "$plain/home/.pi/agent/b-agentic/install.json"

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
assert_json "$interrupted/home/.pi/agent/b-agentic/install.json" "data['packageState']=='pending' and data['backups']['settings']!='none'"
run_install "$interrupted" --sync >"$interrupted/retry-sync.log" 2>&1
run_install "$interrupted" --uninstall >"$interrupted/uninstall.log" 2>&1
assert_json "$interrupted/home/.pi/agent/settings.json" "data=={'custom':True,'packages':['npm:user-extension']}"
assert_no_path "$interrupted/home/.pi/agent/b-agentic/install.json"

partial="$WORK_DIR/partial-package"
mkdir -p "$partial/home"
make_source "$partial/source"
make_bin "$partial/bin"
if PI_MOCK_PARTIAL_INSTALL=1 run_install "$partial" >"$partial/failed-install.log" 2>&1; then
  fail 'expected partial Pi package install failure'
fi
run_install "$partial" --sync >"$partial/retry-sync.log" 2>&1
[ "$(grep -Fc 'install npm:@gotgenes/pi-subagents --no-approve' "$partial/bin/pi.log")" -eq 2 ] ||
  fail 'retry skipped partially installed Pi extension'
assert_json "$partial/home/.pi/agent/b-agentic/install.json" "data['packageState']=='ready'"

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

printf '\n' >>"$sandbox/source/references/capabilities.yaml"
run_install "$sandbox" --sync >"$sandbox/sync.log" 2>&1
cmp "$sandbox/source/references/capabilities.yaml" "$metadata/references/capabilities.yaml"
printf '\nmodified\n' >>"$agent/agents/b-planner.md"
run_install "$sandbox" --sync >"$sandbox/modified-sync.log" 2>&1
assert_contains "$sandbox/modified-sync.log" 'preserving modified or user-owned Pi specialist'
assert_contains "$agent/agents/b-planner.md" modified
run_install "$sandbox" --uninstall >"$sandbox/uninstall.log" 2>&1
assert_no_path "$agent/skills/b-plan"
assert_no_path "$agent/prompts/b-plan.md"
assert_file "$agent/agents/b-planner.md"
assert_file "$metadata/install.json"
assert_json "$agent/settings.json" "data == {'custom': True, 'packages': ['npm:user-extension'], 'compaction': {'enabled': False}}"
assert_json "$agent/mcp.json" "data == {'mcpServers': {'user_server': {'url': 'https://example.invalid/mcp'}}}"
assert_contains "$sandbox/home/.config/opencode/AGENTS.md" 'old runtime belongs to user'

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
assert_contains "$clean/bin/pi.log" 'remove npm:@gotgenes/pi-subagents --no-approve'

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
assert_no_path "$dry/bin/pi.log"
run_install "$dry" --update --dry-run >"$dry/update.log" 2>&1
assert_contains "$dry/update.log" '[dry-run] pi update --extensions'
assert_no_path "$dry/bin/pi.log"

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

echo 'Pi installer smoke tests passed.'
