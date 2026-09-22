#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/b-agentic-opencode-smoke.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { printf 'smoke-install.sh: %s\n' "$*" >&2; exit 1; }
assert_file() { [ -f "$1" ] || fail "expected file: $1"; }
assert_no_path() { [ ! -e "$1" ] || fail "unexpected path: $1"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "expected $2 in $1"; }
assert_not_contains() { ! grep -Fq -- "$2" "$1" || fail "did not expect $2 in $1"; }
assert_json() {
  python3 - "$1" "$2" <<'PY' || fail "JSON assertion failed: $1"
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text())
assert eval(sys.argv[2], {'data': data})
PY
}

make_source() {
  local destination="$1"
  mkdir -p "$destination"
  cp -R "$ROOT_DIR"/. "$destination"/
  rm -rf "$destination/.git" "$destination/node_modules"
}

make_bin() {
  local directory="$1"
  mkdir -p "$directory"
  for command in rtk codegraph bunx; do
    cat >"$directory/$command" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$directory/$command"
  done
  cat >"$directory/opencode" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/opencode.log"
exit 0
EOF
  chmod +x "$directory/opencode"
  cat >"$directory/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$(dirname "$0")/curl.log"
printf '%s\n' ':'
EOF
  chmod +x "$directory/curl"
}

run_install() {
  local sandbox="$1"
  shift
  HOME="$sandbox/home" \
    PATH="$sandbox/bin:$PATH" \
    B_AGENTIC_DIR="$sandbox/source" \
    B_AGENTIC_REPO="$sandbox/source" \
    bash "$ROOT_DIR/install.sh" "$@"
}

run_install_without_curl() {
  local sandbox="$1"
  shift
  cat >"$sandbox/no-curl.bash" <<'EOF'
command() {
  if [ "${1:-}" = "-v" ] && [ "${2:-}" = "curl" ]; then
    return 1
  fi
  builtin command "$@"
}
EOF
  HOME="$sandbox/home" \
    PATH="$sandbox/bin:$PATH" \
    BASH_ENV="$sandbox/no-curl.bash" \
    B_AGENTIC_DIR="$sandbox/source" \
    B_AGENTIC_REPO="$sandbox/source" \
    bash "$ROOT_DIR/install.sh" "$@"
}

run_install_without_opencode() {
  local sandbox="$1"
  shift
  cat >"$sandbox/no-opencode.bash" <<'EOF'
command() {
  if [ "${1:-}" = "-v" ] && [ "${2:-}" = "opencode" ]; then
    return 1
  fi
  builtin command "$@"
}
EOF
  HOME="$sandbox/home" \
    PATH="$sandbox/bin:$PATH" \
    BASH_ENV="$sandbox/no-opencode.bash" \
    B_AGENTIC_DIR="$sandbox/source" \
    B_AGENTIC_REPO="$sandbox/source" \
    bash "$ROOT_DIR/install.sh" "$@"
}

sandbox="$WORK_DIR/primary"
mkdir -p "$sandbox/home/.config/opencode" "$sandbox/home/.pi/agent/b-agentic"
make_source "$sandbox/source"
make_bin "$sandbox/bin"
printf '%s\n' '{"custom": true, "mcp": {"servers": {"user_server": {"type": "remote", "url": "https://example.invalid/mcp"}}}}' >"$sandbox/home/.config/opencode/opencode.json"
printf '%s\n' '{"legacy": true}' >"$sandbox/home/.pi/agent/b-agentic/install.json"
run_install "$sandbox" >"$sandbox/install.log" 2>&1

config="$sandbox/home/.config/opencode/opencode.json"
metadata="$sandbox/home/.config/opencode/b-agentic"
assert_file "$sandbox/home/.config/opencode/AGENTS.md"
assert_file "$sandbox/home/.config/opencode/skills/b-plan/SKILL.md"
assert_no_path "$sandbox/home/.config/opencode/skills/b-plan/prompt.md"
assert_file "$sandbox/home/.config/opencode/agents/b-planner.md"
assert_file "$sandbox/home/.config/opencode/commands/b-plan.md"
assert_file "$metadata/install.json"
assert_json "$metadata/install.json" "data['runtime'] == 'opencode'"
assert_json "$config" "data['custom'] is True and data['mcp']['servers']['user_server']['url'] == 'https://example.invalid/mcp' and data['mcp']['servers']['context7']['type'] == 'remote' and data['experimental']['subagent_depth'] == 1 and data['plugins'] == ['@cortexkit/opencode-magic-context'] and data['compaction'] == {'auto': False}"
assert_json "$config" "all(any(rule == {'action': 'read', 'resource': path, 'effect': 'deny'} for rule in data['permissions']) for path in ('*credentials.*', '**/*credentials.*', '*secrets.*', '**/*secrets.*')) and any(rule == {'action': 'edit', 'resource': '*', 'effect': 'allow'} for rule in data['permissions']) and any(rule == {'action': 'shell', 'resource': 'git push*', 'effect': 'deny'} for rule in data['permissions']) and any(rule == {'action': 'firecrawl_*', 'resource': '*', 'effect': 'ask'} for rule in data['permissions']) and any(rule == {'action': 'context7_resolve_library_id', 'resource': '*', 'effect': 'allow'} for rule in data['permissions']) and all(data['mcp']['servers'][name]['timeout'] == {'startup': 30000, 'catalog': 30000} for name in ('codegraph', 'context7', 'brave_search', 'firecrawl', 'playwright', 'mobbin', 'shadcn'))"
python3 "$ROOT_DIR/tooling/validate/mcp_doctor.py" --config "$config" --allow-degraded >"$sandbox/doctor.log"
assert_contains "$sandbox/doctor.log" "config: $config"
assert_contains "$sandbox/bin/opencode.log" 'upgrade'
assert_no_path "$sandbox/bin/curl.log"
assert_contains "$sandbox/install.log" '[9/9] Writing install manifest'
assert_contains "$sandbox/install.log" 'A previous Pi b-agentic install remains'
assert_file "$sandbox/home/.pi/agent/b-agentic/install.json"

printf '\n' >>"$sandbox/source/references/capabilities.yaml"
python3 - "$metadata/install.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data['skills'] = []
path.write_text(json.dumps(data) + '\n')
PY
run_install "$sandbox" --sync >"$sandbox/sync.log" 2>&1
assert_contains "$sandbox/sync.log" '[8/8] Writing install manifest'
cmp "$sandbox/source/references/capabilities.yaml" "$metadata/references/capabilities.yaml"
cmp "$sandbox/source/opencode/configs/opencode.user.template.json" "$metadata/templates/opencode.user.template.json"
assert_json "$metadata/install.json" "'b-plan' in data['skills']"
assert_file "$sandbox/home/.config/opencode/agents/b-planner.md"
printf '\nmodified\n' >>"$sandbox/home/.config/opencode/agents/b-planner.md"
run_install "$sandbox" --sync >"$sandbox/modified-sync.log" 2>&1
assert_contains "$sandbox/modified-sync.log" 'preserving modified OpenCode subagent'
assert_contains "$sandbox/home/.config/opencode/agents/b-planner.md" modified
run_install "$sandbox" --uninstall >"$sandbox/uninstall.log" 2>&1
assert_no_path "$sandbox/home/.config/opencode/skills/b-plan"
assert_no_path "$sandbox/home/.config/opencode/agents/b-researcher.md"
assert_file "$sandbox/home/.config/opencode/agents/b-planner.md"
assert_file "$sandbox/home/.config/opencode/b-agentic/install.json"
assert_json "$config" "data == {'custom': True, 'mcp': {'servers': {'user_server': {'type': 'remote', 'url': 'https://example.invalid/mcp'}}}}"

# A symlinked profile is preserved with its metadata for a future safe cleanup.
symlinked="$WORK_DIR/symlinked"
mkdir -p "$symlinked/home/.config/opencode/agents" "$symlinked/user"
make_source "$symlinked/source"
make_bin "$symlinked/bin"
printf '%s\n' 'user-owned agent' >"$symlinked/user/b-planner.md"
ln -s "$symlinked/user/b-planner.md" "$symlinked/home/.config/opencode/agents/b-planner.md"
run_install "$symlinked" >"$symlinked/install.log" 2>&1
run_install "$symlinked" --uninstall >"$symlinked/uninstall.log" 2>&1
[ -L "$symlinked/home/.config/opencode/agents/b-planner.md" ] || fail 'expected symlinked agent to be preserved'
assert_file "$symlinked/home/.config/opencode/b-agentic/install.json"

# Managed plugins union ahead of user plugins and are removed on uninstall.
plugins="$WORK_DIR/plugins"
mkdir -p "$plugins/home/.config/opencode"
make_source "$plugins/source"
make_bin "$plugins/bin"
printf '%s\n' '{"plugins": ["user-plugin"], "compaction": {"keep": {"tokens": 30000}}}' >"$plugins/home/.config/opencode/opencode.json"
run_install "$plugins" >"$plugins/install.log" 2>&1
plugins_config="$plugins/home/.config/opencode/opencode.json"
assert_json "$plugins_config" "data['plugins'] == ['@cortexkit/opencode-magic-context', 'user-plugin'] and data['compaction'] == {'keep': {'tokens': 30000}, 'auto': False}"
run_install "$plugins" --uninstall >"$plugins/uninstall.log" 2>&1
assert_json "$plugins_config" "data == {'plugins': ['user-plugin'], 'compaction': {'keep': {'tokens': 30000}}}"

# Existing managed server launch arrays remain user-owned and survive uninstall.
conflict="$WORK_DIR/conflict"
mkdir -p "$conflict/home/.config/opencode"
make_source "$conflict/source"
make_bin "$conflict/bin"
printf '%s\n' '{"mcp": {"servers": {"firecrawl": {"type": "local", "command": ["npx", "firecrawl-mcp"], "environment": {"FIRECRAWL_API_KEY": "{env:FIRECRAWL_API_KEY}"}}}}}' >"$conflict/home/.config/opencode/opencode.json"
run_install "$conflict" >"$conflict/install.log" 2>&1
conflict_config="$conflict/home/.config/opencode/opencode.json"
assert_json "$conflict_config" "data['mcp']['servers']['firecrawl']['command'] == ['npx', 'firecrawl-mcp']"
run_install "$conflict" --uninstall >"$conflict/uninstall.log" 2>&1
assert_no_path "$conflict/home/.config/opencode/skills/b-plan"
assert_json "$conflict_config" "data == {'mcp': {'servers': {'firecrawl': {'type': 'local', 'command': ['npx', 'firecrawl-mcp'], 'environment': {'FIRECRAWL_API_KEY': '{env:FIRECRAWL_API_KEY}'}}}}}"

# Existing v2 permission rules remain authoritative while managed defaults are added.
permissions="$WORK_DIR/permissions"
mkdir -p "$permissions/home/.config/opencode"
make_source "$permissions/source"
make_bin "$permissions/bin"
printf '%s\n' '{"permissions": [{"action": "shell", "resource": "git status*", "effect": "deny"}]}' >"$permissions/home/.config/opencode/opencode.json"
run_install "$permissions" >"$permissions/install.log" 2>&1
permissions_config="$permissions/home/.config/opencode/opencode.json"
assert_json "$permissions_config" "data['permissions'][-1] == {'action': 'shell', 'resource': 'git status*', 'effect': 'deny'} and any(rule == {'action': 'shell', 'resource': 'git push*', 'effect': 'deny'} for rule in data['permissions'])"
# A broad user rule remains authoritative because OpenCode evaluates the last match.
broad_permissions="$WORK_DIR/broad-permissions"
mkdir -p "$broad_permissions/home/.config/opencode"
make_source "$broad_permissions/source"
make_bin "$broad_permissions/bin"
printf '%s\n' '{"permissions": [{"action": "shell", "resource": "*", "effect": "allow"}]}' >"$broad_permissions/home/.config/opencode/opencode.json"
run_install "$broad_permissions" >"$broad_permissions/install.log" 2>&1
assert_json "$broad_permissions/home/.config/opencode/opencode.json" "data['permissions'][-1] == {'action': 'shell', 'resource': '*', 'effect': 'allow'}"
run_install "$broad_permissions" --sync >"$broad_permissions/sync.log" 2>&1
assert_json "$broad_permissions/home/.config/opencode/opencode.json" "data['permissions'][-1] == {'action': 'shell', 'resource': '*', 'effect': 'allow'}"
python3 - "$permissions/source/opencode/configs/opencode.user.template.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data['permissions'].append({'action': 'shell', 'resource': 'git fetch*', 'effect': 'deny'})
path.write_text(json.dumps(data) + '\n')
PY
run_install "$permissions" --sync >"$permissions/sync.log" 2>&1
assert_json "$permissions_config" "(lambda rules: next(i for i, rule in enumerate(rules) if rule == {'action': 'shell', 'resource': '*', 'effect': 'allow'}) < next(i for i, rule in enumerate(rules) if rule == {'action': 'shell', 'resource': 'git fetch*', 'effect': 'deny'}) < next(i for i, rule in enumerate(rules) if rule == {'action': 'shell', 'resource': 'git status*', 'effect': 'deny'}))(data['permissions'])"
assert_json "$permissions_config" "sum(rule == {'action': 'shell', 'resource': 'git push*', 'effect': 'deny'} for rule in data['permissions']) == 1 and sum(rule == {'action': 'shell', 'resource': 'git fetch*', 'effect': 'deny'} for rule in data['permissions']) == 1"
run_install "$permissions" --uninstall >"$permissions/uninstall.log" 2>&1
assert_json "$permissions_config" "data == {'permissions': [{'action': 'shell', 'resource': 'git status*', 'effect': 'deny'}]}"

# A malformed user permissions value is preserved with an explicit safety warning.
invalid_permissions="$WORK_DIR/invalid-permissions"
mkdir -p "$invalid_permissions/home/.config/opencode"
make_source "$invalid_permissions/source"
make_bin "$invalid_permissions/bin"
printf '%s\n' '{"permissions": {}}' >"$invalid_permissions/home/.config/opencode/opencode.json"
run_install "$invalid_permissions" >"$invalid_permissions/install.log" 2>&1
invalid_permissions_config="$invalid_permissions/home/.config/opencode/opencode.json"
assert_contains "$invalid_permissions/install.log" 'preserving non-array user permissions'
assert_json "$invalid_permissions_config" "data['permissions'] == {}"
run_install "$invalid_permissions" --uninstall >"$invalid_permissions/uninstall.log" 2>&1
assert_json "$invalid_permissions_config" "data == {'permissions': {}}"

# A pre-existing JSONC config remains the single managed config path.
jsonc="$WORK_DIR/jsonc"
mkdir -p "$jsonc/home/.config/opencode"
make_source "$jsonc/source"
make_bin "$jsonc/bin"
printf '%s\n' '// user comment' '{"custom": true}' >"$jsonc/home/.config/opencode/opencode.jsonc"
run_install "$jsonc" >"$jsonc/install.log" 2>&1
jsonc_config="$jsonc/home/.config/opencode/opencode.jsonc"
assert_file "$jsonc_config"
assert_no_path "$jsonc/home/.config/opencode/opencode.json"
assert_json "$jsonc_config" "data['custom'] is True and data['mcp']['servers']['context7']['type'] == 'remote'"
python3 "$ROOT_DIR/tooling/validate/mcp_doctor.py" --home "$jsonc/home" --allow-degraded >"$jsonc/doctor.log"
assert_contains "$jsonc/doctor.log" "config: $jsonc_config"
run_install "$jsonc" --uninstall >"$jsonc/uninstall.log" 2>&1
assert_json "$jsonc_config" "data == {'custom': True}"

# Bootstrap repository and ref inputs reject option-like and remote-helper forms.
invalid="$WORK_DIR/invalid"
mkdir -p "$invalid/home"
make_source "$invalid/source"
make_bin "$invalid/bin"
if HOME="$invalid/home" PATH="$invalid/bin:$PATH" B_AGENTIC_DIR="$invalid/source" B_AGENTIC_REPO='ext::unsafe' bash "$ROOT_DIR/install.sh" --dry-run >"$invalid/repo.log" 2>&1; then
  fail 'expected invalid B_AGENTIC_REPO to fail'
fi
assert_contains "$invalid/repo.log" 'invalid B_AGENTIC_REPO'
if HOME="$invalid/home" PATH="$invalid/bin:$PATH" B_AGENTIC_DIR="$invalid/source" B_AGENTIC_REPO="$invalid/source" bash "$ROOT_DIR/install.sh" --dry-run --ref=-unsafe >"$invalid/ref.log" 2>&1; then
  fail 'expected option-like --ref to fail'
fi
assert_contains "$invalid/ref.log" 'invalid --ref or B_AGENTIC_REF'

# A fresh install exercises automatic config cleanup and manifest-only removal.
clean="$WORK_DIR/clean"
mkdir -p "$clean/home/.config/opencode"
make_source "$clean/source"
make_bin "$clean/bin"
run_install "$clean" >"$clean/install.log" 2>&1
assert_file "$clean/home/.config/opencode/b-agentic/tooling/install/manifest_uninstall.py"
run_install "$clean" --uninstall >"$clean/source-uninstall.log" 2>&1
assert_no_path "$clean/home/.config/opencode/opencode.json"
assert_no_path "$clean/home/.config/opencode/skills/b-plan"
assert_no_path "$clean/home/.config/opencode/b-agentic"
run_install "$clean" >"$clean/reinstall.log" 2>&1
rm -rf "$clean/source"
HOME="$clean/home" PATH="$clean/bin:$PATH" B_AGENTIC_DIR="$clean/missing" bash "$ROOT_DIR/install.sh" --uninstall >"$clean/uninstall.log" 2>&1
assert_contains "$clean/uninstall.log" 'Manifest-only uninstall complete for OpenCode'
assert_no_path "$clean/home/.config/opencode/b-agentic"
assert_no_path "$clean/home/.config/opencode/skills/b-plan"
assert_no_path "$clean/home/.config/opencode/agents/b-planner.md"

# A missing config backup must preserve metadata rather than silently strand values.
missing_backup="$WORK_DIR/missing-backup"
mkdir -p "$missing_backup/home/.config/opencode"
make_source "$missing_backup/source"
make_bin "$missing_backup/bin"
printf '%s\n' '{"custom": true}' >"$missing_backup/home/.config/opencode/opencode.json"
run_install "$missing_backup" >"$missing_backup/install.log" 2>&1
backup_path="$(python3 - "$missing_backup/home/.config/opencode/b-agentic/install.json" <<'PY'
import json, sys
from pathlib import Path
print(json.loads(Path(sys.argv[1]).read_text())['backups']['opencodeConfig'])
PY
)"
rm -f "$backup_path"
run_install "$missing_backup" --uninstall >"$missing_backup/source-uninstall.log" 2>&1
assert_contains "$missing_backup/source-uninstall.log" 'preserving modified opencode.json'
assert_file "$missing_backup/home/.config/opencode/b-agentic/install.json"
assert_file "$missing_backup/home/.config/opencode/opencode.json"
rm -rf "$missing_backup/source"
HOME="$missing_backup/home" PATH="$missing_backup/bin:$PATH" B_AGENTIC_DIR="$missing_backup/missing" bash "$ROOT_DIR/install.sh" --uninstall >"$missing_backup/uninstall.log" 2>&1
assert_contains "$missing_backup/uninstall.log" 'recorded backup is missing'
assert_file "$missing_backup/home/.config/opencode/b-agentic/install.json"
assert_file "$missing_backup/home/.config/opencode/opencode.json"

# Dry runs cannot create a configuration directory.
dry="$WORK_DIR/dry"
mkdir -p "$dry/home"
make_source "$dry/source"
make_bin "$dry/bin"
run_install "$dry" --dry-run >"$dry/log" 2>&1
assert_no_path "$dry/home/.config/opencode"
assert_contains "$dry/log" '[dry-run] opencode upgrade'
assert_no_path "$dry/bin/curl.log"
assert_no_path "$dry/bin/opencode.log"
run_install "$dry" --update --dry-run >"$dry/update.log" 2>&1
assert_contains "$dry/update.log" 'b-agentic update planned: upgrade not run in dry-run.'
assert_no_path "$dry/bin/curl.log"
assert_no_path "$dry/bin/opencode.log"

# Missing curl does not block an upgrade when OpenCode is already installed,
# and a failed vendor installer must not block local asset setup.
missing_curl="$WORK_DIR/missing-curl"
mkdir -p "$missing_curl/home"
make_source "$missing_curl/source"
make_bin "$missing_curl/bin"
run_install_without_curl "$missing_curl" >"$missing_curl/install.log" 2>&1
assert_contains "$missing_curl/install.log" "Upgrading OpenCode CLI with 'opencode upgrade'"
assert_contains "$missing_curl/install.log" '[9/9] Writing install manifest'
assert_file "$missing_curl/home/.config/opencode/AGENTS.md"
assert_no_path "$missing_curl/bin/curl.log"

# Missing curl still warns when OpenCode is not installed yet.
missing_curl_fresh="$WORK_DIR/missing-curl-fresh"
mkdir -p "$missing_curl_fresh/home"
make_source "$missing_curl_fresh/source"
make_bin "$missing_curl_fresh/bin"
rm -f "$missing_curl_fresh/bin/opencode"
cat >"$missing_curl_fresh/no-cli.bash" <<'EOF'
command() {
  if [ "${1:-}" = "-v" ] && { [ "${2:-}" = "curl" ] || [ "${2:-}" = "opencode" ]; }; then
    return 1
  fi
  builtin command "$@"
}
EOF
HOME="$missing_curl_fresh/home" \
  PATH="$missing_curl_fresh/bin:$PATH" \
  BASH_ENV="$missing_curl_fresh/no-cli.bash" \
  B_AGENTIC_DIR="$missing_curl_fresh/source" \
  B_AGENTIC_REPO="$missing_curl_fresh/source" \
  bash "$ROOT_DIR/install.sh" >"$missing_curl_fresh/install.log" 2>&1
assert_contains "$missing_curl_fresh/install.log" 'curl is required to install the current OpenCode CLI; skipping OpenCode installation'
assert_contains "$missing_curl_fresh/install.log" '[9/9] Writing install manifest'
assert_file "$missing_curl_fresh/home/.config/opencode/AGENTS.md"

failed_upgrade="$WORK_DIR/failed-upgrade"
mkdir -p "$failed_upgrade/home"
make_source "$failed_upgrade/source"
make_bin "$failed_upgrade/bin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$failed_upgrade/bin/opencode"
chmod +x "$failed_upgrade/bin/opencode"
run_install "$failed_upgrade" >"$failed_upgrade/install.log" 2>&1
assert_contains "$failed_upgrade/install.log" 'OpenCode CLI upgrade failed; upgrade it manually, then rerun with --update'
assert_contains "$failed_upgrade/install.log" '[9/9] Writing install manifest'
assert_file "$failed_upgrade/home/.config/opencode/AGENTS.md"
assert_no_path "$failed_upgrade/bin/curl.log"
run_install "$failed_upgrade" --update >"$failed_upgrade/update.log" 2>&1
assert_contains "$failed_upgrade/update.log" 'b-agentic update skipped: OpenCode CLI upgrade failed.'

# A fresh install without OpenCode on PATH still uses the curl installer.
fresh_install="$WORK_DIR/fresh-install"
mkdir -p "$fresh_install/home"
make_source "$fresh_install/source"
make_bin "$fresh_install/bin"
rm -f "$fresh_install/bin/opencode"
run_install_without_opencode "$fresh_install" >"$fresh_install/install.log" 2>&1
assert_contains "$fresh_install/bin/curl.log" '-fsSL https://opencode.ai/v2/install'
assert_not_contains "$fresh_install/bin/curl.log" 'opencode-ai@'
assert_contains "$fresh_install/install.log" '[9/9] Writing install manifest'

# A successful vendor installer with no discoverable CLI reports the PATH gap.
missing_path="$WORK_DIR/missing-path"
mkdir -p "$missing_path/home"
make_source "$missing_path/source"
make_bin "$missing_path/bin"
rm -f "$missing_path/bin/opencode"
run_install_without_opencode "$missing_path" >"$missing_path/install.log" 2>&1
assert_contains "$missing_path/install.log" "OpenCode CLI installed but 'opencode' is not on PATH"
assert_contains "$missing_path/install.log" '[9/9] Writing install manifest'
assert_file "$missing_path/home/.config/opencode/AGENTS.md"

echo 'OpenCode installer smoke tests passed.'
