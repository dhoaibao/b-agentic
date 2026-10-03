#!/usr/bin/env bash
# Sandbox test: the installer moves the large MCP servers to search exposure
# (directTools "search") once per install, backs up the previous file, records
# the migration in the manifest, and leaves unmanaged configuration alone.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
unset B_AGENTIC_PI_DIR PI_CODING_AGENT_DIR XDG_CONFIG_HOME B_AGENTIC_DRY_RUN B_AGENTIC_UNINSTALL \
  B_AGENTIC_FORCE B_AGENTIC_REPLACE_MEMORY B_AGENTIC_REF
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/b-agentic-mcp-search.XXXXXX")"
WORK_DIR="$(cd "$WORK_DIR" && pwd -P)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { printf 'mcp-search-migration.sh: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "expected $2 in $1"; }
assert_not_contains() { ! grep -Fq -- "$2" "$1" || fail "unexpected $2 in $1"; }
assert_json() {
  python3 - "$1" "$2" <<'PY' || fail "JSON assertion failed: $1 :: $2"
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text())
assert eval(sys.argv[2], {'data': data})
PY
}

new_case() {
  local sandbox="$WORK_DIR/$1" directory
  mkdir -p "$sandbox/home" "$sandbox/source" "$sandbox/bin"
  cp "$ROOT_DIR/install.sh" "$sandbox/source/"
  for directory in pi skills references tooling; do
    cp -R "$ROOT_DIR/$directory" "$sandbox/source/"
  done
  printf '#!/usr/bin/env bash\nexit 0\n' >"$sandbox/bin/pi"
  chmod +x "$sandbox/bin/pi"
  # Stub runtime tools so the sandbox never runs the vendor installers.
  for tool in bun rtk codegraph; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$sandbox/bin/$tool"
    chmod +x "$sandbox/bin/$tool"
  done
  mkdir -p "$sandbox/home/.pi/agent"
  printf '%s' "$sandbox"
}

# run_install <sandbox> <clickup yes|no> [installer args...]
run_install() {
  local sandbox="$1" clickup="$2"
  shift 2
  HOME="$sandbox/home" PATH="$sandbox/bin:$PATH" \
    B_AGENTIC_DIR="$sandbox/source" B_AGENTIC_REPO="$sandbox/source" \
    B_AGENTIC_CLICKUP_MCP="$clickup" \
    bash "$ROOT_DIR/install.sh" "$@"
}

install_ok() {
  local sandbox="$1"
  shift
  run_install "$sandbox" "$@" >"$sandbox/last.log" 2>&1 || { cat "$sandbox/last.log" >&2; fail "installer failed: $sandbox"; }
}

# seed_previous <config>: the pre-search-exposure configuration, built from the
# shipped template by restoring explicit allowlists and dropping descriptions.
seed_previous() {
  python3 - "$ROOT_DIR/pi/configs/mcp.base.json" "$1" "$2" <<'PY'
import json, sys
from pathlib import Path
template = json.loads(Path(sys.argv[1]).read_text())
config = {'settings': template['settings'], 'mcpServers': {}}
for name, entry in template['mcpServers'].items():
    entry = {k: v for k, v in entry.items() if k != 'description'}
    if entry['directTools'] == 'search':
        entry['directTools'] = [f'{name}_old_a', f'{name}_old_b']
    config['mcpServers'][name] = entry
extra = json.loads(sys.argv[3]) if sys.argv[3] else {}
config['mcpServers'].update(extra)
Path(sys.argv[2]).write_text(json.dumps(config, indent=2) + '\n')
PY
}

search_ok='all(data["mcpServers"][n]["directTools"] == "search" for n in ["brave_search", "firecrawl", "playwright", "mobbin", "shadcn"])'
direct_ok='isinstance(data["mcpServers"]["context7"]["directTools"], list) and isinstance(data["mcpServers"]["excalidraw"]["directTools"], list) and isinstance(data["mcpServers"]["drawio"]["directTools"], list)'

# M1. A fresh install ships search exposure, descriptions, and records the migration.
case1="$(new_case fresh)"
agent="$case1/home/.pi/agent"
install_ok "$case1" no
assert_json "$agent/mcp-adapter.json" "$search_ok and $direct_ok and 'clickup' not in data['mcpServers']"
assert_json "$agent/mcp-adapter.json" "all(isinstance(s.get('description'), str) for s in data['mcpServers'].values())"
assert_json "$agent/b-agentic/install.json" "data['mcpExposureMigratedServers'] == ['brave_search', 'firecrawl', 'mobbin', 'playwright', 'shadcn']"

# M2. An upgrade moves the managed large servers to search once, keeps customised
#     direct servers and unmanaged servers, and backs up the previous file.
case2="$(new_case upgrade)"
agent="$case2/home/.pi/agent"
seed_previous "$agent/mcp-adapter.json" '{"custom": {"command": "my-server", "directTools": ["custom_a"]}}'
python3 - "$agent/mcp-adapter.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data['mcpServers']['codegraph']['directTools'] = ['codegraph_explore', 'codegraph_extra']
path.write_text(json.dumps(data, indent=2) + '\n')
PY
cp "$agent/mcp-adapter.json" "$case2/previous.json"
install_ok "$case2" no
assert_json "$agent/mcp-adapter.json" "$search_ok"
assert_json "$agent/mcp-adapter.json" "data['mcpServers']['codegraph']['directTools'] == ['codegraph_explore', 'codegraph_extra']"
assert_json "$agent/mcp-adapter.json" "data['mcpServers']['custom'] == {'command': 'my-server', 'directTools': ['custom_a']}"
assert_contains "$case2/last.log" 'migrating mcpServers.brave_search.directTools'
assert_contains "$case2/last.log" 'previous mcp configuration saved to'
backup="$(find "$agent/b-agentic/backups" -name "mcp-adapter.json.bak-*" -print -quit)"
cmp -s "$backup" "$case2/previous.json" || fail 'backup does not hold the previous configuration'
assert_json "$agent/b-agentic/install.json" "data['mcpExposureMigratedServers'] == ['brave_search', 'firecrawl', 'mobbin', 'playwright', 'shadcn']"

# M3. Syncing again is idempotent, and a list the user restores afterwards is kept.
cp "$agent/mcp-adapter.json" "$case2/after-first.json"
install_ok "$case2" no --sync
cmp -s "$agent/mcp-adapter.json" "$case2/after-first.json" || fail 'second sync changed the configuration'
assert_not_contains "$case2/last.log" 'migrating'
python3 - "$agent/mcp-adapter.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data['mcpServers']['brave_search']['directTools'] = ['brave_web_search']
path.write_text(json.dumps(data, indent=2) + '\n')
PY
install_ok "$case2" no --sync
assert_json "$agent/mcp-adapter.json" "data['mcpServers']['brave_search']['directTools'] == ['brave_web_search']"

# M4. The optional ClickUp server follows the template, and an entry that only
#     differs by the exposure metadata does not block enabling it.
case4="$(new_case clickup-fresh)"
agent="$case4/home/.pi/agent"
install_ok "$case4" yes
assert_json "$agent/mcp-adapter.json" "data['mcpServers']['clickup']['directTools'] == 'search'"
case4b="$(new_case clickup-upgrade)"
agent="$case4b/home/.pi/agent"
python3 - "$ROOT_DIR/pi/configs/mcp.clickup.json" "$ROOT_DIR/pi/configs/mcp.base.json" "$agent/mcp-adapter.json" <<'PY'
import json, sys
from pathlib import Path
clickup = json.loads(Path(sys.argv[1]).read_text())['mcpServers']['clickup']
clickup = {k: v for k, v in clickup.items() if k != 'description'}
clickup['directTools'] = ['getTaskById', 'searchTasks']
Path(sys.argv[3]).write_text(json.dumps({'mcpServers': {'clickup': clickup}}, indent=2) + '\n')
PY
install_ok "$case4b" yes
assert_json "$agent/mcp-adapter.json" "data['mcpServers']['clickup']['directTools'] == 'search'"

# M5. A same-named server with its own transport migrates its exposure but keeps its transport.
case5="$(new_case own-transport)"
agent="$case5/home/.pi/agent"
seed_previous "$agent/mcp-adapter.json" ''
python3 - "$agent/mcp-adapter.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data['mcpServers']['brave_search'] = {'command': 'my-brave', 'args': ['--x'], 'directTools': ['brave_web_search']}
path.write_text(json.dumps(data, indent=2) + '\n')
PY
install_ok "$case5" no
assert_json "$agent/mcp-adapter.json" "data['mcpServers']['brave_search']['directTools'] == 'search' and data['mcpServers']['brave_search']['command'] == 'my-brave'"
assert_contains "$case5/last.log" 'preserving user transport for MCP server brave_search'

# M6. A dry run reports the migration and writes nothing.
case6="$(new_case dry-run)"
agent="$case6/home/.pi/agent"
seed_previous "$agent/mcp-adapter.json" ''
cp "$agent/mcp-adapter.json" "$case6/before.json"
install_ok "$case6" no --dry-run
cmp -s "$agent/mcp-adapter.json" "$case6/before.json" || fail 'dry run changed the configuration'
assert_contains "$case6/last.log" 'would migrate MCP servers to directTools "search"'
[ ! -e "$agent/b-agentic/install.json" ] || fail 'dry run wrote a manifest'

# M6b. With ClickUp opted in and customised, the dry run reports its overwrite too.
case6b="$(new_case dry-run-clickup)"
agent="$case6b/home/.pi/agent"
seed_previous "$agent/mcp-adapter.json" ''
python3 - "$ROOT_DIR/pi/configs/mcp.clickup.json" "$agent/mcp-adapter.json" <<'PY'
import json, sys
from pathlib import Path
clickup = json.loads(Path(sys.argv[1]).read_text())['mcpServers']['clickup']
clickup = {k: v for k, v in clickup.items() if k != 'description'}
clickup['directTools'] = ['clickup_getTaskById']
path = Path(sys.argv[2])
data = json.loads(path.read_text())
data['mcpServers']['clickup'] = clickup
path.write_text(json.dumps(data, indent=2) + '\n')
PY
install_ok "$case6b" yes --dry-run
assert_contains "$case6b/last.log" '["mcpServers","clickup","directTools"]'

# M8. ClickUp enabled after an earlier run without it is still migrated, and a list
#     restored afterwards is kept.
case8="$(new_case clickup-later)"
agent="$case8/home/.pi/agent"
install_ok "$case8" no
python3 - "$ROOT_DIR/pi/configs/mcp.clickup.json" "$agent/mcp-adapter.json" "$agent/b-agentic/install.json" <<'PY'
import json, sys
from pathlib import Path
clickup = json.loads(Path(sys.argv[1]).read_text())['mcpServers']['clickup']
clickup = {k: v for k, v in clickup.items() if k != 'description'}
clickup['directTools'] = ['clickup_getTaskById']
config = Path(sys.argv[2])
data = json.loads(config.read_text())
data['mcpServers']['clickup'] = clickup
config.write_text(json.dumps(data, indent=2) + '\n')
# An install that predates the recorded ClickUp choice.
manifest = Path(sys.argv[3])
record = json.loads(manifest.read_text())
record.pop('clickupMcpEnabled', None)
manifest.write_text(json.dumps(record, indent=2) + '\n')
PY
install_ok "$case8" yes
assert_json "$agent/mcp-adapter.json" "data['mcpServers']['clickup']['directTools'] == 'search'"
assert_json "$agent/b-agentic/install.json" "'clickup' in data['mcpExposureMigratedServers']"
python3 - "$agent/mcp-adapter.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data['mcpServers']['clickup']['directTools'] = ['clickup_getTaskById']
path.write_text(json.dumps(data, indent=2) + '\n')
PY
install_ok "$case8" yes --sync
assert_json "$agent/mcp-adapter.json" "data['mcpServers']['clickup']['directTools'] == ['clickup_getTaskById']"

# M9. The earlier managed ClickUp npx launcher migrates to bunx with or without a
#     recorded opt-in; a customised launcher is preserved.
seed_clickup_entry() {
  python3 - "$ROOT_DIR/pi/configs/mcp.clickup.json" "$1" "$2" <<'PY'
import json, sys
from pathlib import Path
clickup = json.loads(Path(sys.argv[1]).read_text())['mcpServers']['clickup']
clickup = {k: v for k, v in clickup.items() if k != 'description'}
if sys.argv[3] == 'legacy':
    clickup['command'], clickup['args'] = 'npx', ['-y', '@hauptsache.net/clickup-mcp@1.9.0']
else:
    clickup['command'], clickup['args'] = 'my-clickup', ['--x']
Path(sys.argv[2]).write_text(json.dumps({'mcpServers': {'clickup': clickup}}, indent=2) + '\n')
PY
}
bunx_ok="data['mcpServers']['clickup']['command'] == 'bunx' and data['mcpServers']['clickup']['args'] == ['@hauptsache.net/clickup-mcp@1.9.0']"
case9="$(new_case clickup-legacy-new-opt-in)"
agent="$case9/home/.pi/agent"
seed_clickup_entry "$agent/mcp-adapter.json" legacy
install_ok "$case9" yes
assert_json "$agent/mcp-adapter.json" "$bunx_ok"
assert_contains "$case9/last.log" 'launcher from npx to bunx'
case9b="$(new_case clickup-legacy-recorded)"
agent="$case9b/home/.pi/agent"
install_ok "$case9b" yes
seed_clickup_entry "$agent/mcp-adapter.json" legacy
install_ok "$case9b" yes --sync
assert_json "$agent/mcp-adapter.json" "$bunx_ok"
case9c="$(new_case clickup-custom-launcher)"
agent="$case9c/home/.pi/agent"
install_ok "$case9c" yes
seed_clickup_entry "$agent/mcp-adapter.json" custom
install_ok "$case9c" yes --sync
assert_json "$agent/mcp-adapter.json" "data['mcpServers']['clickup']['command'] == 'my-clickup' and data['mcpServers']['clickup']['args'] == ['--x']"

# M7. Uninstall removes the servers b-agentic added and keeps the user's own.
case7="$(new_case uninstall)"
agent="$case7/home/.pi/agent"
printf '%s\n' '{"mcpServers": {"custom": {"command": "my-server", "directTools": ["custom_a"]}}}' >"$agent/mcp-adapter.json"
install_ok "$case7" no
assert_json "$agent/mcp-adapter.json" "$search_ok and 'custom' in data['mcpServers']"
install_ok "$case7" no --uninstall
assert_json "$agent/mcp-adapter.json" "list(data['mcpServers']) == ['custom'] and data['mcpServers']['custom']['directTools'] == ['custom_a']"

printf 'MCP search exposure migration checks passed.\n'
