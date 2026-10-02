#!/usr/bin/env bash
# Sandbox test: install and --sync remove managed assets that the source no
# longer ships (renamed or removed skills, prompts, agents, extensions) while
# preserving modified, symlinked, user-owned, and unsafe-named files.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Keep runner-level configuration from escaping the per-case HOME sandbox.
unset B_AGENTIC_PI_DIR PI_CODING_AGENT_DIR XDG_CONFIG_HOME B_AGENTIC_DRY_RUN B_AGENTIC_UNINSTALL \
  B_AGENTIC_FORCE B_AGENTIC_REPLACE_MEMORY B_AGENTIC_REF
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/b-agentic-prune.XXXXXX")"
WORK_DIR="$(cd "$WORK_DIR" && pwd -P)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { printf 'prune-retired.sh: %s\n' "$*" >&2; exit 1; }
assert_file() { [ -f "$1" ] || fail "expected file: $1"; }
assert_no_path() { [ ! -e "$1" ] && [ ! -L "$1" ] || fail "unexpected path: $1"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "expected $2 in $1"; }
assert_json() {
  python3 - "$1" "$2" <<'PY' || fail "JSON assertion failed: $1 :: $2"
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text())
assert eval(sys.argv[2], {'data': data})
PY
}

make_bin() {
  mkdir -p "$1"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$1/pi"
  chmod +x "$1/pi"
}

add_retirable() {
  local source="$1"
  mkdir -p "$source/skills/b-old"
  sed 's/^name: .*/name: b-old/' "$source/skills/b-plan/SKILL.md" >"$source/skills/b-old/SKILL.md"
  for kind in agents prompts; do
    printf '# b-old %s\n' "$kind" >"$source/pi/$kind/b-old.md"
  done
  printf '// b-old extension\n' >"$source/pi/extensions/b-old.ts"
}

remove_retirable() {
  local source="$1"
  rm -rf "$source/skills/b-old" "$source/pi/agents/b-old.md" "$source/pi/prompts/b-old.md" "$source/pi/extensions/b-old.ts"
}

# new_case <name>: sandbox with a source copy that still ships the b-old assets.
new_case() {
  local sandbox="$WORK_DIR/$1" directory
  mkdir -p "$sandbox/home" "$sandbox/source"
  cp "$ROOT_DIR/install.sh" "$sandbox/source/"
  for directory in pi skills references tooling; do
    cp -R "$ROOT_DIR/$directory" "$sandbox/source/"
  done
  make_bin "$sandbox/bin"
  add_retirable "$sandbox/source"
  printf '%s' "$sandbox"
}

run_install() {
  local sandbox="$1"
  shift
  HOME="$sandbox/home" PATH="$sandbox/bin:$PATH" \
    B_AGENTIC_DIR="$sandbox/source" B_AGENTIC_REPO="$sandbox/source" \
    B_AGENTIC_CLICKUP_MCP=N \
    bash "$ROOT_DIR/install.sh" "$@"
}

install_then_retire() {
  local sandbox="$1"
  run_install "$sandbox" >"$sandbox/install.log" 2>&1 || { cat "$sandbox/install.log" >&2; fail "initial install failed: $sandbox"; }
  local agent="$sandbox/home/.pi/agent"
  assert_file "$agent/skills/b-old/SKILL.md"
  assert_file "$agent/prompts/b-old.md"
  assert_file "$agent/agents/b-old.md"
  assert_file "$agent/extensions/b-old.ts"
  assert_json "$agent/b-agentic/install.json" "'b-old' in data['skills'] and 'b-old' in data['commands'] and 'b-old' in data['extensions']"
  # The manifest tracks agents from a fixed list, so record b-old as an earlier
  # release that shipped it would have.
  python3 - "$agent/b-agentic/install.json" <<'PYAGENT'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data['agents'] = sorted(set(data['agents']) | {'b-old'})
path.write_text(json.dumps(data, indent=2) + '\n')
PYAGENT
  remove_retirable "$sandbox/source"
}

sync() { run_install "$1" --sync >"$1/${2:-sync}.log" 2>&1 || { cat "$1/${2:-sync}.log" >&2; fail "sync failed: $1"; }; }

# 1. Unmodified retired assets are removed with their snapshots, and the
#    manifest stops listing them; shipped assets stay.
case1="$(new_case unmodified)"
agent="$case1/home/.pi/agent"
install_then_retire "$case1"
sync "$case1"
assert_no_path "$agent/skills/b-old"
assert_no_path "$agent/prompts/b-old.md"
assert_no_path "$agent/agents/b-old.md"
assert_no_path "$agent/extensions/b-old.ts"
assert_no_path "$agent/b-agentic/skills/b-old"
assert_no_path "$agent/b-agentic/prompts/b-old.md"
assert_no_path "$agent/b-agentic/agents/b-old.md"
assert_no_path "$agent/b-agentic/extensions/b-old.ts"
assert_file "$agent/skills/b-plan/SKILL.md"
assert_file "$agent/prompts/b-plan.md"
assert_json "$agent/b-agentic/install.json" "'b-old' not in data['skills'] and 'b-old' not in data['commands'] and 'b-old' not in data['agents'] and 'b-old' not in data['extensions'] and 'b-plan' in data['skills'] and 'b-plan' in data['commands']"

# 9. Uninstall after pruning still succeeds and removes the managed metadata.
run_install "$case1" --uninstall >"$case1/uninstall.log" 2>&1
assert_no_path "$agent/b-agentic"
assert_no_path "$agent/skills/b-plan"

# 8. A plain install (not --sync) prunes through the same path.
case2="$(new_case plain-install)"
agent="$case2/home/.pi/agent"
install_then_retire "$case2"
run_install "$case2" >"$case2/reinstall.log" 2>&1
assert_no_path "$agent/skills/b-old"
assert_no_path "$agent/prompts/b-old.md"
assert_no_path "$agent/b-agentic/skills/b-old"
assert_json "$agent/b-agentic/install.json" "'b-old' not in data['skills'] and 'b-old' not in data['commands']"

# 2/3. Modified and symlinked retired assets are kept, warned about on every
#      run, and stay tracked so uninstall still evaluates them.
case3="$(new_case modified)"
agent="$case3/home/.pi/agent"
install_then_retire "$case3"
printf '\nuser edit\n' >>"$agent/skills/b-old/SKILL.md"
printf '\nuser edit\n' >>"$agent/prompts/b-old.md"
printf 'user target\n' >"$case3/target.ts"
rm -f "$agent/extensions/b-old.ts"
ln -s "$case3/target.ts" "$agent/extensions/b-old.ts"
for run in first second; do
  sync "$case3" "modified-$run"
  assert_contains "$agent/skills/b-old/SKILL.md" 'user edit'
  assert_contains "$agent/prompts/b-old.md" 'user edit'
  [ -L "$agent/extensions/b-old.ts" ] || fail 'symlinked retired extension was replaced'
  assert_contains "$case3/modified-$run.log" 'preserving modified skill'
  assert_contains "$case3/modified-$run.log" 'preserving modified retired Pi prompt'
  assert_contains "$case3/modified-$run.log" 'preserving symlinked retired Pi extension'
  assert_json "$agent/b-agentic/install.json" "'b-old' in data['skills'] and 'b-old' in data['commands'] and 'b-old' in data['extensions']"
done
assert_file "$case3/target.ts"
# The unmodified retired agent is still pruned alongside the kept files.
assert_no_path "$agent/agents/b-old.md"
run_install "$case3" --uninstall >"$case3/uninstall.log" 2>&1
assert_contains "$agent/skills/b-old/SKILL.md" 'user edit'
assert_file "$case3/target.ts"

# 4/5. An unsafe manifest name and a user-owned file without a snapshot are
#      never removed.
case4="$(new_case user-owned)"
agent="$case4/home/.pi/agent"
install_then_retire "$case4"
printf 'sentinel\n' >"$agent/sentinel.md"
printf 'user-owned prompt\n' >"$agent/prompts/b-user.md"
mkdir -p "$agent/skills/b-user"
printf 'user-owned skill\n' >"$agent/skills/b-user/SKILL.md"
python3 - "$agent/b-agentic/install.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data['commands'] += ['../sentinel', 'b-user']
data['skills'] += ['../sentinel', 'b-user']
path.write_text(json.dumps(data, indent=2) + '\n')
PY
sync "$case4"
assert_file "$agent/sentinel.md"
assert_contains "$agent/prompts/b-user.md" 'user-owned prompt'
assert_contains "$agent/skills/b-user/SKILL.md" 'user-owned skill'
assert_no_path "$agent/prompts/b-old.md"

# 7. --dry-run --sync removes nothing and leaves the manifest untouched.
case5="$(new_case dry-run)"
agent="$case5/home/.pi/agent"
install_then_retire "$case5"
cp "$agent/b-agentic/install.json" "$case5/manifest.before"
run_install "$case5" --sync --dry-run >"$case5/dry.log" 2>&1 || { cat "$case5/dry.log" >&2; fail 'dry-run sync failed'; }
assert_file "$agent/skills/b-old/SKILL.md"
assert_file "$agent/prompts/b-old.md"
assert_file "$agent/b-agentic/skills/b-old/SKILL.md"
cmp "$case5/manifest.before" "$agent/b-agentic/install.json" || fail 'dry-run changed the manifest'
assert_contains "$case5/dry.log" '[dry-run] rm'

# 10. A hardcoded specialist the source stops shipping is pruned and dropped
#     from the manifest too.
case6="$(new_case hardcoded-agent)"
agent="$case6/home/.pi/agent"
install_then_retire "$case6"
assert_file "$agent/agents/b-debugger.md"
rm -f "$case6/source/pi/agents/b-debugger.md"
sync "$case6"
assert_no_path "$agent/agents/b-debugger.md"
assert_no_path "$agent/b-agentic/agents/b-debugger.md"
assert_file "$agent/agents/b-planner.md"
assert_json "$agent/b-agentic/install.json" "'b-debugger' not in data['agents'] and 'b-planner' in data['agents']"

# 11. A failed removal keeps the asset, its snapshot, and its manifest entry.
if [ "$(id -u)" -ne 0 ]; then
  case7="$(new_case failed-removal)"
  agent="$case7/home/.pi/agent"
  install_then_retire "$case7"
  chmod a-w "$agent/prompts" "$agent/skills/b-old"
  sync "$case7" failed-removal || true
  chmod u+w "$agent/prompts" "$agent/skills/b-old"
  assert_file "$agent/prompts/b-old.md"
  assert_file "$agent/b-agentic/prompts/b-old.md"
  assert_file "$agent/skills/b-old/SKILL.md"
  assert_file "$agent/b-agentic/skills/b-old/SKILL.md"
  assert_contains "$case7/failed-removal.log" 'failed to remove retired Pi prompt'
  assert_contains "$case7/failed-removal.log" 'failed to remove skill'
  assert_json "$agent/b-agentic/install.json" "'b-old' in data['skills'] and 'b-old' in data['commands']"
fi

printf 'Retired-asset pruning checks passed.\n'
