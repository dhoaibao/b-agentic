#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="$(mktemp -d /tmp/b-agentic-smoke.XXXXXX)"

cleanup() {
	rm -rf "$WORK_DIR"
}

trap cleanup EXIT

source "$ROOT_DIR/tests/smoke/lib.sh"

# Release URLs that intentionally point nowhere: manifest-only uninstall paths
# must complete without any fetch, and an accidental download fails loudly.
MISSING_RELEASE_URL="file:///nonexistent/b-agentic-release/b-agentic.tar.gz"
MISSING_CHECKSUM_URL="file:///nonexistent/b-agentic-release/b-agentic.tar.gz.sha256"

run_manifest_only_corrupted_manifest_case() {
	local sandbox_corrupt="$WORK_DIR/manifest-only-corrupt"

	mkdir -p "$sandbox_corrupt/home/Documents/b-owned" "$sandbox_corrupt/home/.pi/agent/b-agentic"
	printf 'sentinel\n' >"$sandbox_corrupt/home/Documents/b-owned/file.txt"
	cat >"$sandbox_corrupt/home/.pi/agent/b-agentic/install.json" <<EOF
{"runtime":"pi","paths":{"skills":"$sandbox_corrupt/home/Documents","kernel":"$sandbox_corrupt/home/.pi/agent/AGENTS.md"},"skills":["b-owned"],"agents":[]}
EOF

	local rc=0
	set +e
	HOME="$sandbox_corrupt/home" \
		B_AGENTIC_RELEASE_URL="$MISSING_RELEASE_URL" B_AGENTIC_CHECKSUM_URL="$MISSING_CHECKSUM_URL" \
		B_AGENTIC_DIR="$sandbox_corrupt/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" --uninstall >"$sandbox_corrupt/uninstall.log" 2>&1
	rc=$?
	set -e

	[ "$rc" -ne 0 ] || fail "corrupt manifest-only uninstall without helper should fail safely"
	assert_contains "$sandbox_corrupt/uninstall.log" "requires $sandbox_corrupt/home/.pi/agent/b-agentic/tooling/install/manifest_uninstall.py"
	assert_file "$sandbox_corrupt/home/Documents/b-owned/file.txt"
	assert_no_path "$sandbox_corrupt/source"
}

run_manifest_only_custom_paths_case() {
	local sandbox_custom="$WORK_DIR/manifest-only-custom-paths"
	local manifest_path skill_dir kernel_path snapshot_path skill_snapshot_dir

	mkdir -p "$sandbox_custom/home/custom-meta/skills/b-plan" "$sandbox_custom/home/custom-skills/b-plan" "$sandbox_custom/home/custom-kernel"
	manifest_path="$sandbox_custom/home/custom-meta/install.json"
	skill_dir="$sandbox_custom/home/custom-skills/b-plan"
	skill_snapshot_dir="$sandbox_custom/home/custom-meta/skills/b-plan"
	kernel_path="$sandbox_custom/home/custom-kernel/AGENTS.md"
	snapshot_path="$sandbox_custom/home/custom-meta/AGENTS.md"

	printf 'Generated from skills/registry.yaml\n' >"$skill_dir/SKILL.md"
	printf 'Generated from skills/registry.yaml\n' >"$skill_snapshot_dir/SKILL.md"
	printf '<!-- b-agentic-managed -->\ncustom kernel\n' >"$kernel_path"
	printf '<!-- b-agentic-managed -->\ncustom kernel\n' >"$snapshot_path"
	cat >"$manifest_path" <<EOF
{"runtime":"pi","paths":{"skills":"$sandbox_custom/home/custom-skills","kernel":"$kernel_path"},"skills":["b-plan"],"agents":[]}
EOF

	HOME="$sandbox_custom/home" python3 "$ROOT_DIR/tooling/install/manifest_uninstall.py" "$manifest_path" >"$sandbox_custom/uninstall.log" 2>&1

	assert_contains "$sandbox_custom/uninstall.log" 'Manifest-only uninstall complete for pi'
	assert_no_path "$skill_dir"
	assert_no_path "$kernel_path"
	assert_no_path "$sandbox_custom/home/custom-meta"

	# macOS resolves /tmp through /private/tmp. A HOME spelling through that
	# symlink must remain trusted while symlinks below HOME are still rejected.
	local alias_home="$sandbox_custom/home-alias"
	local alias_manifest="$alias_home/.pi/agent/b-agentic/install.json"
	mkdir -p "$sandbox_custom/home/.pi/agent/b-agentic"
	ln -s "$sandbox_custom/home" "$alias_home"
	printf '%s\n' '{"runtime":"pi","paths":{},"skills":[]}' >"$alias_manifest"
	HOME="$alias_home" python3 "$ROOT_DIR/tooling/install/manifest_uninstall.py" "$alias_manifest" >"$sandbox_custom/alias-uninstall.log" 2>&1
	assert_contains "$sandbox_custom/alias-uninstall.log" 'Manifest-only uninstall complete for pi'
	assert_no_path "$sandbox_custom/home/.pi/agent/b-agentic"

	# A symlink below HOME must remain untrusted even if it resolves to HOME.
	local nested_symlink_home="$sandbox_custom/nested-symlink-home"
	local nested_symlink_manifest="$nested_symlink_home/.pi/agent/b-agentic/install.json"
	local rc=0
	mkdir -p "$nested_symlink_home/agent/b-agentic"
	ln -s "$nested_symlink_home" "$nested_symlink_home/.pi"
	printf '%s\n' '{"runtime":"pi","paths":{},"skills":[]}' >"$nested_symlink_manifest"
	set +e
	HOME="$nested_symlink_home" python3 "$ROOT_DIR/tooling/install/manifest_uninstall.py" "$nested_symlink_manifest" >"$sandbox_custom/nested-symlink-uninstall.log" 2>&1
	rc=$?
	set -e
	[ "$rc" -ne 0 ] || fail "manifest-only uninstall accepted a symlink below HOME"
	assert_contains "$sandbox_custom/nested-symlink-uninstall.log" 'preserving symlinked manifest:'
	assert_file "$nested_symlink_home/agent/b-agentic/install.json"
}

run_manifest_only_mcp_symlink_preservation_case() {
	local sandbox="$WORK_DIR/manifest-only-mcp-symlink"
	local managed='{"mcpServers":{"managed":{"command":"synthetic"}},"unrelated":{"preserve":true}}'
	local template='{"mcpServers":{"managed":{"command":"synthetic"}}}'
	local case_name home home_alias metadata mcp_path target manifest_path

	for case_name in external-target in-home-target; do
		home="$sandbox/$case_name/home"
		metadata="$home/.pi/agent/b-agentic"
		mcp_path="$home/.pi/agent/mcp.json"
		if [ "$case_name" = external-target ]; then
			target="$sandbox/$case_name/outside-target.json"
		else
			target="$home/user-owned-target.json"
		fi
		mkdir -p "$metadata/templates" "$(dirname "$target")"
		printf '%s\n' "$managed" >"$target"
		cp "$target" "$target.before"
		ln -s "$target" "$mcp_path"
		printf '%s\n' "$template" >"$metadata/templates/mcp.user.template.json"
		manifest_path="$metadata/install.json"
		printf '%s\n' '{"runtime":"pi","paths":{},"skills":[],"mcpAction":"write","backups":{}}' >"$manifest_path"

		HOME="$home" python3 "$ROOT_DIR/tooling/install/manifest_uninstall.py" "$manifest_path" >"$sandbox/$case_name.log" 2>&1
		assert_equal_files "$target" "$target.before"
		[ -L "$mcp_path" ] || fail "expected manifest-only uninstall to preserve symlinked mcp.json"
		assert_contains "$sandbox/$case_name.log" 'preserving symlinked mcp.json'
	done

	# An explicit outside manifest path must safely fall back to the confined default.
	home="$sandbox/invalid-fallback/home"
	metadata="$home/.pi/agent/b-agentic"
	mcp_path="$home/.pi/agent/mcp.json"
	mkdir -p "$metadata/templates"
	printf '%s\n' "$managed" >"$mcp_path"
	printf '%s\n' "$template" >"$metadata/templates/mcp.user.template.json"
	manifest_path="$metadata/install.json"
	printf '%s\n' "{\"runtime\":\"pi\",\"paths\":{\"mcpConfig\":\"$sandbox/outside-mcp.json\"},\"skills\":[],\"mcpAction\":\"write\",\"backups\":{}}" >"$manifest_path"
	HOME="$home" python3 "$ROOT_DIR/tooling/install/manifest_uninstall.py" "$manifest_path" >"$sandbox/invalid-fallback.log" 2>&1
	assert_contains "$sandbox/invalid-fallback.log" 'ignoring manifest path outside home for mcpConfig'
	assert_contains "$mcp_path" '"unrelated"'
	assert_not_contains "$mcp_path" '"managed"'

	# A symlinked HOME spelling must also clean the canonical default fallback.
	home="$sandbox/invalid-fallback-alias/home"
	home_alias="$sandbox/invalid-fallback-alias/home-alias"
	metadata="$home/.pi/agent/b-agentic"
	mcp_path="$home/.pi/agent/mcp.json"
	mkdir -p "$metadata/templates"
	ln -s "$home" "$home_alias"
	printf '%s\n' "$managed" >"$mcp_path"
	printf '%s\n' "$template" >"$metadata/templates/mcp.user.template.json"
	manifest_path="$home_alias/.pi/agent/b-agentic/install.json"
	printf '%s\n' "{\"runtime\":\"pi\",\"paths\":{\"mcpConfig\":\"$sandbox/outside-mcp.json\"},\"skills\":[],\"mcpAction\":\"write\",\"backups\":{}}" >"$manifest_path"
	HOME="$home_alias" python3 "$ROOT_DIR/tooling/install/manifest_uninstall.py" "$manifest_path" >"$sandbox/invalid-fallback-alias.log" 2>&1
	assert_contains "$sandbox/invalid-fallback-alias.log" 'ignoring manifest path outside home for mcpConfig'
	assert_contains "$mcp_path" '"unrelated"'
	assert_not_contains "$mcp_path" '"managed"'

	# An explicit path through a symlinked ancestor escaping HOME must not be followed.
	home="$sandbox/ancestor-escape/home"
	metadata="$home/.pi/agent/b-agentic"
	mcp_path="$home/.pi/agent/mcp.json"
	target="$sandbox/ancestor-escape/outside-config/mcp.json"
	mkdir -p "$metadata/templates" "$(dirname "$target")"
	printf '%s\n' "$managed" >"$mcp_path"
	printf '%s\n' "$managed" >"$target"
	cp "$target" "$target.before"
	ln -s "$sandbox/ancestor-escape/outside-config" "$home/config-link"
	printf '%s\n' "$template" >"$metadata/templates/mcp.user.template.json"
	manifest_path="$metadata/install.json"
	printf '%s\n' "{\"runtime\":\"pi\",\"paths\":{\"mcpConfig\":\"$home/config-link/mcp.json\"},\"skills\":[],\"mcpAction\":\"write\",\"backups\":{}}" >"$manifest_path"
	HOME="$home" python3 "$ROOT_DIR/tooling/install/manifest_uninstall.py" "$manifest_path" >"$sandbox/ancestor-escape.log" 2>&1
	assert_equal_files "$target" "$target.before"
	assert_contains "$sandbox/ancestor-escape.log" 'ignoring manifest path outside home for mcpConfig'
	assert_contains "$mcp_path" '"unrelated"'
	assert_not_contains "$mcp_path" '"managed"'

	# A template symlink must not be followed before cleanup reads it.
	home="$sandbox/template-symlink/home"
	metadata="$home/.pi/agent/b-agentic"
	mcp_path="$home/.pi/agent/mcp.json"
	mkdir -p "$metadata/templates"
	printf '%s\n' "$managed" >"$mcp_path"
	cp "$mcp_path" "$mcp_path.before"
	printf '%s\n' "$template" >"$sandbox/template-target.json"
	ln -s "$sandbox/template-target.json" "$metadata/templates/mcp.user.template.json"
	manifest_path="$metadata/install.json"
	printf '%s\n' '{"runtime":"pi","paths":{},"skills":[],"mcpAction":"write","backups":{}}' >"$manifest_path"
	HOME="$home" python3 "$ROOT_DIR/tooling/install/manifest_uninstall.py" "$manifest_path" >"$sandbox/template-symlink.log" 2>&1
	assert_equal_files "$mcp_path" "$mcp_path.before"
	assert_contains "$sandbox/template-symlink.log" 'preserving symlinked mcp.json template'
}

run_manifest_only_modified_skill_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/manifest-only-modified-skill"
	local skill_path="$sandbox/home/.pi/agent/skills/b-plan/SKILL.md"

	expect_install_status 0 "$sandbox" "$release_fixture"
	printf '\npost-install skill modification\n' >>"$skill_path"
	rm -rf "$sandbox/source"
	HOME="$sandbox/home" \
		B_AGENTIC_RELEASE_URL="$MISSING_RELEASE_URL" B_AGENTIC_CHECKSUM_URL="$MISSING_CHECKSUM_URL" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" --uninstall >"$sandbox/uninstall.log" 2>&1

	assert_contains "$sandbox/uninstall.log" 'Manifest-only uninstall complete for pi'
	assert_contains "$skill_path" 'post-install skill modification'
}

run_manifest_only_merged_config_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/manifest-only-merged-config"
	local mcp_path manifest_path

	mkdir -p "$sandbox/home/.pi/agent"
	mcp_path="$sandbox/home/.pi/agent/mcp.json"

	cat >"$mcp_path" <<EOF
{"mcpServers":{"user-server":{"command":"user-server-cmd"}}}
EOF

	expect_install_status 0 "$sandbox" "$release_fixture"

	assert_contains "$mcp_path" '"user-server"'
	assert_contains "$mcp_path" '"codegraph"'
	assert_not_contains "$mcp_path" '"serena"'
	assert_not_contains "$mcp_path" '"linear"'
	assert_not_contains "$mcp_path" '"mobbin"'
	assert_json_value "$mcp_path" "data['settings']['requestTimeoutMs'] == 30000"
	assert_json_value "$sandbox/home/.pi/agent/b-agentic/install.json" "data['capabilityContractVersion'] == 2"
	assert_json_value "$sandbox/home/.pi/agent/b-agentic/install.json" "data['capabilities']['contractVersion'] == 2"
	assert_json_value "$sandbox/home/.pi/agent/b-agentic/install.json" "data['capabilities']['states']['package.pi-mcp-adapter']['state'] == 'ready'"
	assert_not_contains "$sandbox/home/.pi/agent/b-agentic/install.json" 'package.pi-lsp'
	assert_json_value "$sandbox/home/.pi/agent/b-agentic/install.json" "data['capabilities']['states']['extension.b-agentic-status']['state'] == 'ready'"
	assert_json_value "$sandbox/home/.pi/agent/b-agentic/install.json" "data['paths']['capabilityContract'].endswith('/references/capabilities.yaml')"

	python3 - "$mcp_path" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data.setdefault('settings', {})['requestTimeoutMs'] = 12345
path.write_text(json.dumps(data) + '\n')
PY
expect_install_status 0 "$sandbox" "$release_fixture"
assert_json_value "$mcp_path" "data['settings']['requestTimeoutMs'] == 12345"

	manifest_path="$sandbox/home/.pi/agent/b-agentic/install.json"
	assert_file "$manifest_path"

	rm -rf "$sandbox/source"
	HOME="$sandbox/home" \
		B_AGENTIC_RELEASE_URL="$MISSING_RELEASE_URL" B_AGENTIC_CHECKSUM_URL="$MISSING_CHECKSUM_URL" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" --uninstall >"$sandbox/uninstall.log" 2>&1

	assert_contains "$sandbox/uninstall.log" 'Manifest-only uninstall complete for pi'
	assert_contains "$mcp_path" '"user-server"'
	assert_not_contains "$mcp_path" '"codegraph"'
	assert_not_contains "$mcp_path" '"linear"'
}

run_user_owned_serena_preservation_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/user-owned-serena-preservation"
	local mcp_path="$sandbox/home/.pi/agent/mcp.json"
	local serena_path="$sandbox/home/.local/bin/serena"
	local serena_log="$sandbox/serena-invocations.log"
	local project_dir="$sandbox/project"
	local serena_state="$project_dir/.serena/user-state.txt"
	local serena_state_snapshot="$sandbox/serena-state.snapshot"
	local smoke_path

	mkdir -p "$(dirname "$mcp_path")" "$(dirname "$serena_path")" "$(dirname "$serena_state")"
	cat >"$mcp_path" <<'EOF'
{
  "mcpServers": {
    "serena": {
      "command": "user-owned-serena",
      "args": ["--custom"],
      "env": {"USER_SETTING": "keep-me"},
      "lifecycle": "eager"
    }
  },
  "settings": {"serenaPreference": "keep-me"}
}
EOF
	cat >"$serena_path" <<'EOF'
#!/usr/bin/env bash
printf 'serena invoked\n' >>"${SERENA_INVOCATION_LOG:?}"
EOF
	chmod +x "$serena_path"
	printf 'user-owned Serena project state\n' >"$serena_state"
	cp "$serena_state" "$serena_state_snapshot"
	smoke_path="$(smoke_runtime_cli_path "$sandbox")"

	(
		cd "$project_dir"
		HOME="$sandbox/home" \
		PATH="$sandbox/home/.local/bin:$smoke_path" \
		SERENA_INVOCATION_LOG="$serena_log" \
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N bash "$ROOT_DIR/install.sh" >"$sandbox/install.log" 2>&1
	)
	assert_json_value "$mcp_path" "data['mcpServers']['serena'] == {'command': 'user-owned-serena', 'args': ['--custom'], 'env': {'USER_SETTING': 'keep-me'}, 'lifecycle': 'eager'}"
	assert_json_value "$mcp_path" "data['settings']['serenaPreference'] == 'keep-me'"
	assert_equal_files "$serena_state" "$serena_state_snapshot"
	[ -x "$serena_path" ] || fail "existing Serena executable was removed during install"
	assert_no_path "$serena_log"

	(
		cd "$project_dir"
		HOME="$sandbox/home" \
		PATH="$sandbox/home/.local/bin:$smoke_path" \
		SERENA_INVOCATION_LOG="$serena_log" \
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N bash "$ROOT_DIR/install.sh" --update >"$sandbox/update.log" 2>&1
	)
	assert_json_value "$mcp_path" "data['mcpServers']['serena'] == {'command': 'user-owned-serena', 'args': ['--custom'], 'env': {'USER_SETTING': 'keep-me'}, 'lifecycle': 'eager'}"
	assert_json_value "$mcp_path" "data['settings']['serenaPreference'] == 'keep-me'"
	assert_equal_files "$serena_state" "$serena_state_snapshot"
	[ -x "$serena_path" ] || fail "existing Serena executable was removed during update"
	assert_no_path "$serena_log"
}

run_user_owned_retired_mcp_preservation_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/user-owned-retired-mcp-preservation"
	local mcp_path="$sandbox/home/.pi/agent/mcp.json"
	local install_log="$sandbox/install.log"
	local before_path="$sandbox/before.json"

	mkdir -p "$(dirname "$mcp_path")"
	cat >"$mcp_path" <<'EOF'
{
  "settings": {
    "directTools": true,
    "linearPreference": "keep-linear",
    "mobbinPreference": {"enabled": false, "region": "keep-mobbin"}
  },
  "mcpServers": {
    "linear": {
      "url": "https://example.invalid/custom-linear",
      "auth": "oauth",
      "oauth": {"scope": "write", "team": "keep-team"},
      "includeTools": ["list_issues"],
      "lifecycle": "eager",
      "custom": {"nested": ["keep", 42]}
    },
    "mobbin": {
      "command": "custom-mobbin",
      "args": ["--keep"],
      "env": {"MOBBIN_USER_SETTING": "keep-me"},
      "lifecycle": "eager",
      "custom": {"nested": {"keep": true}}
    }
  }
}
EOF
	cp "$mcp_path" "$before_path"

	for mode in install update; do
		# Bash 3 treats an empty array expansion as unset under set -u.
		if [ "$mode" = update ]; then
			set -- --update
		else
			set --
		fi
		HOME="$sandbox/home" \
		PATH="$(smoke_runtime_cli_path "$sandbox")" \
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" "$@" >"$install_log" 2>&1

		python3 - "$mcp_path" "$before_path" <<'PY'
import json
import sys
from pathlib import Path

actual = json.loads(Path(sys.argv[1]).read_text())
before = json.loads(Path(sys.argv[2]).read_text())
assert actual['mcpServers']['linear'] == before['mcpServers']['linear']
assert actual['mcpServers']['mobbin'] == before['mcpServers']['mobbin']
for key, value in before['settings'].items():
    assert actual['settings'][key] == value
assert actual['settings']['directTools'] is True
PY
	done

	assert_not_contains "$install_log" 'linear:'
	assert_not_contains "$install_log" 'mobbin:'
}

run_manifest_only_extension_restore_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/manifest-only-extension restore"
	local extension_path="$sandbox/home/.pi/agent/extensions/b-agentic-permissions.ts"
	local worker_path="$sandbox/home/.pi/agent/extensions/b-agentic-status.ts"
	local support_path="$sandbox/home/.pi/agent/extensions/b-agentic-support/shell.ts"

	mkdir -p "$(dirname "$extension_path")" "$(dirname "$support_path")"
	printf 'user-owned permission extension\n' >"$extension_path"
	printf 'user-owned status extension\n' >"$worker_path"
	printf 'user-owned shell support\n' >"$support_path"
	expect_install_status 0 "$sandbox" "$release_fixture"
	assert_not_contains "$extension_path" 'user-owned permission extension'
	rm "$extension_path"
	expect_install_status 0 "$sandbox" "$release_fixture"

	rm -rf "$sandbox/source"
	HOME="$sandbox/home" \
		B_AGENTIC_RELEASE_URL="$MISSING_RELEASE_URL" B_AGENTIC_CHECKSUM_URL="$MISSING_CHECKSUM_URL" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" --uninstall >"$sandbox/uninstall.log" 2>&1

	assert_contains "$sandbox/uninstall.log" 'Manifest-only uninstall complete for pi'
	assert_contains "$extension_path" 'user-owned permission extension'
	assert_contains "$worker_path" 'user-owned status extension'
	assert_contains "$support_path" 'user-owned shell support'
}

run_legacy_consult_extension_removal_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/legacy-consult-extension-removal"
	local extensions_dir="$sandbox/home/.pi/agent/extensions"
	local snapshots_dir="$sandbox/home/.pi/agent/b-agentic/extensions"
	local old_extension="$extensions_dir/b-agentic-consult.ts"
	local old_role_extension="$extensions_dir/b-agentic-consultant.ts"
	local old_support="$extensions_dir/b-agentic-support/consult.ts"
	local old_extension_snapshot="$snapshots_dir/b-agentic-consult.ts"
	local old_role_extension_snapshot="$snapshots_dir/b-agentic-consultant.ts"
	local old_support_snapshot="$snapshots_dir/b-agentic-support/consult.ts"
	local old_architect="$extensions_dir/b-agentic-planner.ts"
	local old_executor="$extensions_dir/b-agentic-worker.ts"
	local old_notify="$extensions_dir/b-agentic-planner-notify.ts"
	local old_v3_role="$extensions_dir/b-agentic-role.ts"
	local old_v3_architect="$extensions_dir/b-agentic-architect.ts"
	local old_v3_executor="$extensions_dir/b-agentic-executor.ts"
	local old_v3_executor_notify="$extensions_dir/b-agentic-executor-notify.ts"
	local old_v3_role_snapshot="$snapshots_dir/b-agentic-role.ts"
	local old_v3_architect_snapshot="$snapshots_dir/b-agentic-architect.ts"
	local old_v3_executor_snapshot="$snapshots_dir/b-agentic-executor.ts"
	local old_v3_executor_notify_snapshot="$snapshots_dir/b-agentic-executor-notify.ts"
	local old_architect_snapshot="$snapshots_dir/b-agentic-planner.ts"
	local old_executor_snapshot="$snapshots_dir/b-agentic-worker.ts"
	local old_notify_snapshot="$snapshots_dir/b-agentic-planner-notify.ts"
	local user_extension="$extensions_dir/user-owned-extension.ts"
	local user_extension_snapshot="$sandbox/user-owned-extension.snapshot"
	local mcp_path="$sandbox/home/.pi/agent/mcp.json"

	mkdir -p "$extensions_dir" "$(dirname "$mcp_path")"
	printf 'user-owned extension\n' >"$user_extension"
	cp "$user_extension" "$user_extension_snapshot"
	cat >"$mcp_path" <<'EOF'
{"mcpServers":{"user-server":{"command":"user-server-cmd"}}}
EOF

	expect_install_status 0 "$sandbox" "$release_fixture"
	assert_no_path "$old_extension"
	assert_no_path "$old_role_extension"
	assert_no_path "$old_support"
	assert_no_path "$old_architect"
	assert_no_path "$old_executor"
	assert_no_path "$old_notify"
	assert_no_path "$old_v3_role"
	assert_no_path "$old_v3_architect"
	assert_no_path "$old_v3_executor"
	assert_no_path "$old_v3_executor_notify"
	mkdir -p "$(dirname "$old_support")" "$(dirname "$old_support_snapshot")"
	printf 'legacy managed consultant tool\n' >"$old_extension"
	printf 'legacy managed consultant role\n' >"$old_role_extension"
	printf 'legacy managed support\n' >"$old_support"
	cp "$old_extension" "$old_extension_snapshot"
	cp "$old_role_extension" "$old_role_extension_snapshot"
	cp "$old_support" "$old_support_snapshot"
	printf 'legacy managed architect profile\n' >"$old_architect"
	printf 'legacy managed executor profile\n' >"$old_executor"
	printf 'legacy managed executor notification\n' >"$old_notify"
	cp "$old_architect" "$old_architect_snapshot"
	cp "$old_executor" "$old_executor_snapshot"
	cp "$old_notify" "$old_notify_snapshot"
	printf 'retired v3 role selection extension\n' >"$old_v3_role"
	printf 'retired v3 architect profile\n' >"$old_v3_architect"
	printf 'retired v3 executor profile\n' >"$old_v3_executor"
	printf 'retired v3 executor notification\n' >"$old_v3_executor_notify"
	mkdir -p "$(dirname "$old_v3_role_snapshot")"
	cp "$old_v3_role" "$old_v3_role_snapshot"
	cp "$old_v3_architect" "$old_v3_architect_snapshot"
	cp "$old_v3_executor" "$old_v3_executor_snapshot"
	cp "$old_v3_executor_notify" "$old_v3_executor_notify_snapshot"
	expect_install_status 0 "$sandbox" "$release_fixture" --update
	assert_no_path "$old_extension"
	assert_no_path "$old_extension_snapshot"
	assert_no_path "$old_role_extension"
	assert_no_path "$old_role_extension_snapshot"
	assert_no_path "$old_support"
	assert_no_path "$old_support_snapshot"
	assert_no_path "$old_architect"
	assert_no_path "$old_architect_snapshot"
	assert_no_path "$old_executor"
	assert_no_path "$old_executor_snapshot"
	assert_no_path "$old_notify"
	assert_no_path "$old_notify_snapshot"
	assert_no_path "$old_v3_role"
	assert_no_path "$old_v3_role_snapshot"
	assert_no_path "$old_v3_architect"
	assert_no_path "$old_v3_architect_snapshot"
	assert_no_path "$old_v3_executor"
	assert_no_path "$old_v3_executor_snapshot"
	assert_no_path "$old_v3_executor_notify"
	assert_no_path "$old_v3_executor_notify_snapshot"

	printf 'legacy managed executor profile\n' >"$old_executor"
	cp "$old_executor" "$old_executor_snapshot"
	printf 'user-modified executor profile\n' >"$old_executor"
	expect_install_status 0 "$sandbox" "$release_fixture" --update
	assert_file "$old_executor"
	assert_file "$old_executor_snapshot"
	assert_contains "$old_executor" 'user-modified executor profile'

	printf 'legacy managed consultant support\n' >"$old_support"
	cp "$old_support" "$old_support_snapshot"
	printf 'user-modified consultant support\n' >"$old_support"
	expect_install_status 0 "$sandbox" "$release_fixture" --update
	assert_file "$old_support"
	assert_file "$old_support_snapshot"
	assert_contains "$old_support" 'user-modified consultant support'
	assert_equal_files "$user_extension" "$user_extension_snapshot"
	assert_contains "$mcp_path" 'user-server'

	expect_install_status 0 "$sandbox" "$release_fixture" --uninstall
	assert_file "$old_support"
	assert_contains "$old_support" 'user-modified consultant support'
	assert_no_path "$old_support_snapshot"
	assert_equal_files "$user_extension" "$user_extension_snapshot"
	assert_contains "$mcp_path" 'user-server'
}

run_manifest_only_extension_symlink_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/manifest-only-extension-symlink"
	local extension_path="$sandbox/home/.pi/agent/extensions/b-agentic-permissions.ts"
	local target_path="$sandbox/target.ts"

	mkdir -p "$(dirname "$extension_path")"
	printf 'user-owned permission extension\n' >"$extension_path"
	expect_install_status 0 "$sandbox" "$release_fixture"
	cp "$extension_path" "$target_path"
	rm "$extension_path"
	ln -s "$target_path" "$extension_path"

	rm -rf "$sandbox/source"
	HOME="$sandbox/home" \
		B_AGENTIC_RELEASE_URL="$MISSING_RELEASE_URL" B_AGENTIC_CHECKSUM_URL="$MISSING_CHECKSUM_URL" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" --uninstall >"$sandbox/uninstall.log" 2>&1

	assert_contains "$sandbox/uninstall.log" 'preserving symlinked Pi permission extension'
	[ -L "$extension_path" ] || fail "expected manifest-only uninstall to preserve symlinked extension"
	assert_contains "$target_path" 'tool_call'
	assert_not_contains "$target_path" 'user-owned permission extension'
}

run_post_install_mcp_modification_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/post-install-mcp-modification"
	local mcp_path manifest_path

	mkdir -p "$sandbox/home/.pi/agent"
	mcp_path="$sandbox/home/.pi/agent/mcp.json"

	cat >"$mcp_path" <<EOF
{"mcpServers":{"user-server":{"command":"user-server-cmd"}}}
EOF

	expect_install_status 0 "$sandbox" "$release_fixture"

	assert_contains "$mcp_path" '"user-server"'
	assert_contains "$mcp_path" '"codegraph"'

	python3 - "$mcp_path" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data.setdefault('mcpServers', {})['codegraph']['USER_SETTING'] = 'keep-me'
path.write_text(json.dumps(data, indent=2) + '\n')
PY

	manifest_path="$sandbox/home/.pi/agent/b-agentic/install.json"
	assert_file "$manifest_path"

	rm -rf "$sandbox/source"
	HOME="$sandbox/home" \
		B_AGENTIC_RELEASE_URL="$MISSING_RELEASE_URL" B_AGENTIC_CHECKSUM_URL="$MISSING_CHECKSUM_URL" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" --uninstall >"$sandbox/uninstall.log" 2>&1

	assert_contains "$sandbox/uninstall.log" 'Manifest-only uninstall complete for pi'
	assert_contains "$mcp_path" '"user-server"'
	assert_contains "$mcp_path" '"codegraph"'
	assert_contains "$mcp_path" '"USER_SETTING"'
	assert_contains "$mcp_path" 'keep-me'
	assert_json_value "$mcp_path" "data['mcpServers']['codegraph'] == {'USER_SETTING': 'keep-me'}"
}

run_ref_install_case() {
	local release_fixture="$1"
	local sandbox_ref="$WORK_DIR/ref-install"
	local sandbox_invalid="$WORK_DIR/ref-install-invalid"
	local install_ref manifest_path rc

	mkdir -p "$sandbox_ref/home" "$sandbox_invalid/home"
	# Pins use the ordinal release-tag scheme the release workflow publishes:
	# $(cat VERSION).N.
	install_ref="$(cat "$ROOT_DIR/VERSION").1"

	expect_install_status 0 "$sandbox_ref" "$release_fixture" --ref="$install_ref"

	manifest_path="$sandbox_ref/home/.pi/agent/b-agentic/install.json"
	assert_file "$manifest_path"
	assert_json_value "$manifest_path" "data['runtime'] == 'pi'"

	rc="$(run_install_status "$sandbox_invalid" "$release_fixture" --ref=--bad)"
	[ "$rc" -ne 0 ] || fail "expected option-looking --ref value to fail safely"
}

run_invalid_skill_payload_case() {
	local release_fixture="$1"
	local sandbox_payload="$WORK_DIR/missing-skill-payload"
	local sandbox_fixture="$WORK_DIR/missing-skill-payload-fixture"
	local sandbox_install="$WORK_DIR/missing-skill-payload-install"

	mkdir -p "$sandbox_payload"
	tar -xzf "$release_fixture/b-agentic.tar.gz" -C "$sandbox_payload"
	rm "$sandbox_payload/skills/b-plan/SKILL.md"
	make_fixture_from_payload "$sandbox_payload" "$sandbox_fixture"

	expect_install_status 1 "$sandbox_install" "$sandbox_fixture"
}

run_release_checksum_mismatch_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/release-checksum-mismatch"
	local fixture="$WORK_DIR/release-checksum-mismatch-fixture"

	mkdir -p "$sandbox/home" "$fixture"
	cp "$release_fixture/b-agentic.tar.gz" "$fixture/b-agentic.tar.gz"
	printf '0000000000000000000000000000000000000000000000000000000000000000  b-agentic.tar.gz\n' >"$fixture/b-agentic.tar.gz.sha256"

	local log="$sandbox/install.log" downloads_before smoke_path
	local case_tmp="$sandbox/tmp"
	mkdir -p "$case_tmp"
	downloads_before="$(temp_download_count "$case_tmp")"
	smoke_path="$(smoke_runtime_cli_path "$sandbox")"
	HOME="$sandbox/home" \
		PATH="$smoke_path" \
		TMPDIR="$case_tmp" \
		B_AGENTIC_RELEASE_URL="file://$fixture/b-agentic.tar.gz" \
		B_AGENTIC_CHECKSUM_URL="file://$fixture/b-agentic.tar.gz.sha256" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" >"$log" 2>&1 && fail "expected checksum mismatch to fail the install"
	assert_contains "$log" 'release checksum mismatch'
	[ "$(temp_download_count "$case_tmp")" -eq "$downloads_before" ] || fail "failed bootstrap leaked a download scratch directory"
}

run_release_unsafe_archive_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/release-unsafe-archive"
	local payload="$WORK_DIR/release-unsafe-archive-payload"
	local fixture rc kind

	mkdir -p "$sandbox/home" "$payload"
	tar -xzf "$release_fixture/b-agentic.tar.gz" -C "$payload"
	ln -s "$payload/install.sh" "$payload/symlink"
	printf 'hidden\n' >"$payload/.hidden"
	cp "$payload/install.sh" "$WORK_DIR/outside-install.sh"

	for kind in absolute dotfile symlink traversal; do
		fixture="$WORK_DIR/release-unsafe-archive-$kind"
		mkdir -p "$fixture"
		case "$kind" in
		absolute)
			# -P keeps the leading slash so the archive carries an absolute member.
			tar -P -czf "$fixture/b-agentic.tar.gz" "$payload/install.sh"
			;;
		dotfile)
			tar -czf "$fixture/b-agentic.tar.gz" -C "$payload" install.sh .hidden
			;;
		symlink)
			tar -czf "$fixture/b-agentic.tar.gz" -C "$payload" symlink
			;;
		traversal)
			# Crafted with python tarfile because tar creation strips leading `..`
			# components; the stored member must keep the traversal sequence.
			python3 - "$fixture/b-agentic.tar.gz" "$WORK_DIR/outside-install.sh" <<'PY'
import sys, tarfile

dest, src = sys.argv[1], sys.argv[2]
with tarfile.open(dest, "w:gz") as tf:
    tf.add(src, arcname="../install.sh")
PY
			;;
		esac
		{
			if command -v sha256sum >/dev/null 2>&1; then
				sha256sum "$fixture/b-agentic.tar.gz"
			else
				shasum -a 256 "$fixture/b-agentic.tar.gz"
			fi
		} | awk '{print $1 "  b-agentic.tar.gz"}' >"$fixture/b-agentic.tar.gz.sha256"
		log="$sandbox/install-$kind.log"
		run_install_capture "$sandbox" "$fixture" "$log" && fail "expected unsafe archive case $kind to fail the install"
		case "$kind" in
		symlink) assert_contains "$log" 'unexpected release archive entry: symlink' ;;
		*) assert_contains "$log" 'unsafe release archive entry' ;;
		esac
		rm -rf "$fixture"
	done
}

run_git_checkout_migration_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/git-checkout-migration"
	local backup install_log

	mkdir -p "$sandbox/home" "$sandbox/source/.git"
	printf 'ref: refs/heads/main\n' >"$sandbox/source/.git/HEAD"
	printf 'user sentinel\n' >"$sandbox/source/user-file.txt"

	install_log="$sandbox/install.log"
	local downloads_before case_tmp
	case_tmp="$sandbox/tmp"
	mkdir -p "$case_tmp"
	downloads_before="$(temp_download_count "$case_tmp")"
	smoke_path="$(smoke_runtime_cli_path "$sandbox")"
	HOME="$sandbox/home" \
		PATH="$smoke_path" \
		TMPDIR="$case_tmp" \
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" \
		B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" >"$install_log" 2>&1 || fail "expected migrated install to succeed"
	[ "$(temp_download_count "$case_tmp")" -eq "$downloads_before" ] || fail "successful bootstrap leaked a download scratch directory"

	backup="$(compgen -G "$sandbox/source.backup.*" | head -1)"
	[ -n "$backup" ] || fail "expected a .backup.<ts> migration directory"
	assert_file "$backup/user-file.txt"
	assert_file "$backup/.git/HEAD"
	assert_contains "$install_log" 'previous b-agentic checkout preserved at:'
	assert_file "$sandbox/source/skills/registry.yaml"
	assert_file "$sandbox/source/VERSION"
	assert_no_path "$sandbox/source/.git"
	assert_no_path "$sandbox/source/user-file.txt"
	assert_no_path "$sandbox/source/docs"
}

run_release_ref_validation_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/release-ref-validation"
	local log ref

	mkdir -p "$sandbox/home"
	for ref in v2026.09.12 v0.1.2 main 1234567 v2026-09-11 v2026.9.11; do
		log="$sandbox/ref-$ref.log"
		run_install_capture "$sandbox" "$release_fixture" "$log" "--ref=$ref" && fail "expected malformed --ref=$ref to fail safely"
		assert_contains "$log" 'must be a vYYYY.MM.DD.N release tag'
	done
}

run_release_ref_url_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/release-ref-url"
	local bin_dir="$sandbox/bin"
	local ref install_log url_log

	# Pins use the ordinal release-tag scheme the release workflow publishes:
	# $(cat VERSION).N.
	ref="$(cat "$ROOT_DIR/VERSION").1"
	mkdir -p "$sandbox/home" "$bin_dir"
	url_log="$sandbox/curl.log"
	install_log="$sandbox/install.log"
	cp "$(command -v curl)" "$bin_dir/.curl-real"
	cat >"$bin_dir/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
selfdir="\$(cd "\$(dirname "\$0")" && pwd)"
for arg in "\$@"; do
	case "\$arg" in
	-*) ;;
	*) printf '%s\n' "\$arg" >>"$url_log" ;;
	esac
done
args=()
saw_release=0
for arg in "\$@"; do
	case "\$arg" in
	https://*/b-agentic.tar.gz.sha256) args+=("file://$release_fixture/b-agentic.tar.gz.sha256"); saw_release=1 ;;
	https://*/b-agentic.tar.gz) args+=("file://$release_fixture/b-agentic.tar.gz"); saw_release=1 ;;
	*) args+=("\$arg") ;;
	esac
done
if [ "\$saw_release" -eq 1 ]; then
	exec "\$selfdir/.curl-real" "\${args[@]}"
fi
# Every non-release URL stays hermetic like the shared smoke curl mock.
printf 'exit 0\n'
EOF
	chmod +x "$bin_dir/curl"

	HOME="$sandbox/home" \
		PATH="$(smoke_path_with_runtime_clis "$sandbox" "$bin_dir")" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" "--ref=$ref" >"$install_log" 2>&1 || fail "expected --ref install via the release download URL to succeed"
	assert_contains "$url_log" "https://github.com/dhoaibao/b-agentic/releases/download/$ref/b-agentic.tar.gz.sha256"
	assert_contains "$url_log" "https://github.com/dhoaibao/b-agentic/releases/download/$ref/b-agentic.tar.gz"
	assert_file "$sandbox/source/VERSION"
}

run_skill_collision_smoke_case() {
	local release_fixture="$1"
	local sandbox_collision="$WORK_DIR/skill-collision"
	local skill_path="$sandbox_collision/home/.pi/agent/skills/b-plan/SKILL.md"
	local manifest_path="$sandbox_collision/home/.pi/agent/b-agentic/install.json"

	mkdir -p "$(dirname "$skill_path")"
	printf 'user-owned b-plan
' >"$skill_path"
	expect_install_status 0 "$sandbox_collision" "$release_fixture"
	assert_file "$manifest_path"
	assert_contains "$skill_path" 'user-owned b-plan'
	assert_json_value "$manifest_path" "'b-plan' not in data['skills']"
}

run_readiness_report_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/readiness-pi"
	local rc=0

	mkdir -p "$sandbox/home"

	set +e
	run_install_with_tty_log "$sandbox" "$release_fixture" "$sandbox/install.log"
	rc=$?
	set -e
	[ "$rc" -eq 0 ] || fail "expected Pi readiness install exit 0, got $rc"
	assert_contains "$sandbox/install.log" 'b-agentic install complete for Pi'
	assert_contains "$sandbox/install.log" 'Readiness:'
	assert_contains "$sandbox/install.log" 'Attention:'
	assert_not_contains "$sandbox/install.log" 'linear:'
	assert_not_contains "$sandbox/install.log" 'mobbin:'
	assert_contains "$sandbox/install.log" 'Next:'
	assert_not_contains "$sandbox/install.log" 'Backups:'
	assert_not_contains "$sandbox/install.log" 'mcp-startup:'
}

run_output_contract_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/output-contract"
	local tty_sandbox="$WORK_DIR/output-contract-tty"
	local dumb_sandbox="$WORK_DIR/output-contract-dumb"
	local failure_sandbox="$WORK_DIR/output-contract-failure"
	local smoke_path rc=0

	mkdir -p "$sandbox/home" "$tty_sandbox/home" "$dumb_sandbox/home" "$failure_sandbox/home"
	smoke_path="$(smoke_runtime_cli_path "$sandbox")"
	set +e
	HOME="$sandbox/home" PATH="$smoke_path" B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N bash "$ROOT_DIR/install.sh" --dry-run >"$sandbox/non-tty.log" 2>&1
	rc=$?
	set -e
	[ "$rc" -eq 0 ] || fail "expected redirected output contract install exit 0, got $rc"
	assert_contains "$sandbox/non-tty.log" '[dry-run] CODEGRAPH_NO_INSTALL_REFRESH=1 codegraph upgrade'
	python3 - "$sandbox/non-tty.log" <<'PY' || fail "redirected installer output contains terminal control data"
from pathlib import Path
import sys
output = Path(sys.argv[1]).read_bytes()
assert b'\r' not in output
assert b'\x1b' not in output
assert b'[1/5] Checking prerequisites\n' in output
assert b'b-agentic install complete for Pi\n' in output
assert output.endswith(b'\n')
PY

	set +e
	TERM=xterm run_install_with_tty_log "$tty_sandbox" "$release_fixture" "$tty_sandbox/install.log" --dry-run
	rc=$?
	set -e
	[ "$rc" -eq 0 ] || fail "expected TTY output contract install exit 0, got $rc"
	python3 - "$tty_sandbox/install.log" <<'PY' || fail "TTY installer output did not render a clean progress line"
from pathlib import Path
import sys
output = Path(sys.argv[1]).read_bytes()
picker_control = b'\x1b[2J\x1b[H'
assert b'\r' in output
assert b'[1/5] [' in output
assert output.count(picker_control) >= 2
assert output.replace(picker_control, b'').find(b'\x1b') == -1
assert b'Selected components:\r\n' in output
assert b'b-agentic install complete for Pi\r\n' in output
assert output.endswith(b'\n')
PY

	set +e
	TERM=dumb run_install_with_tty_log "$dumb_sandbox" "$release_fixture" "$dumb_sandbox/install.log" --dry-run
	rc=$?
	set -e
	[ "$rc" -eq 0 ] || fail "expected TERM=dumb install exit 0, got $rc"
	assert_not_contains "$dumb_sandbox/install.log" '[1/5] ['

	git_payload="$failure_sandbox/broken-payload"
	mkdir -p "$git_payload"
	tar -xzf "$release_fixture/b-agentic.tar.gz" -C "$git_payload"
	rm "$git_payload/skills/b-plan/SKILL.md"
	make_fixture_from_payload "$git_payload" "$failure_sandbox/broken-fixture"
	set +e
	TERM=xterm run_install_with_tty_log "$failure_sandbox" "$failure_sandbox/broken-fixture" "$failure_sandbox/install.log" --dry-run
	rc=$?
	set -e
	[ "$rc" -ne 0 ] || fail "expected TTY failure output contract to fail"
	assert_contains "$failure_sandbox/install.log" 'error:'
}

run_component_picker_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/component-picker"
	local cancel_sandbox="$WORK_DIR/component-picker-cancel"
	local preserve_sandbox="$WORK_DIR/component-picker-preserve"
	local install_log="$sandbox/install.log"
	local cancel_log="$cancel_sandbox/install.log"
	local preserve_log="$preserve_sandbox/rerun.log"
	local mcp_path="$preserve_sandbox/home/.pi/agent/mcp.json"
	local theme_cache="$preserve_sandbox/home/.pi/agent/b-agentic/themes/dracula.json"
	local manifest_path="$preserve_sandbox/home/.pi/agent/b-agentic/install.json"
	local mcp_before="$preserve_sandbox/mcp.before"
	local theme_before="$preserve_sandbox/theme.before"
	local manifest_before="$preserve_sandbox/manifest.before"
	local rc=0

	mkdir -p "$sandbox/home" "$cancel_sandbox/home" "$preserve_sandbox/home"
	assert_picker_key_reader_portability
	set +e
	TERM=xterm B_AGENTIC_TTY_INPUT=$' \e[B \e[B \n' run_install_with_tty_log "$sandbox" "$release_fixture" "$install_log" --dry-run
	rc=$?
	set -e
	[ "$rc" -eq 0 ] || fail "expected component picker dry-run exit 0, got $rc"
	assert_contains "$install_log" 'Select optional components.'
	assert_contains "$install_log" 'Selected components:'
	assert_contains "$install_log" 'MCP support skipped'
	assert_contains "$install_log" 'Pi integrations skipped'
	assert_contains "$install_log" 'Dracula theme skipped'
	assert_contains "$install_log" '[dry-run] curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh'
	assert_not_contains "$install_log" '[dry-run] pi install npm:pi-mcp-adapter'
	assert_not_contains "$install_log" '[dry-run] pi install npm:pi-observational-memory'
	assert_not_contains "$install_log" '[dry-run] git clone --depth 1 https://github.com/dracula/pi-coding-agent.git'

	set +e
	TERM=xterm B_AGENTIC_TTY_INPUT=$'\e' run_install_with_tty_log "$cancel_sandbox" "$release_fixture" "$cancel_log" --dry-run
	rc=$?
	set -e
	[ "$rc" -eq 130 ] || fail "expected Escape to cancel the component picker, got $rc"
	assert_contains "$cancel_log" 'Installation cancelled.'
	assert_no_path "$cancel_sandbox/source"
	assert_no_path "$cancel_sandbox/home/.pi/agent"

	expect_install_status 0 "$preserve_sandbox" "$release_fixture"
	cp "$mcp_path" "$mcp_before"
	cp "$theme_cache" "$theme_before"
	cp "$manifest_path" "$manifest_before"
	set +e
	TERM=xterm B_AGENTIC_TTY_INPUT=$' \e[B \e[B \n' run_install_with_tty_log "$preserve_sandbox" "$release_fixture" "$preserve_log"
	rc=$?
	set -e
	[ "$rc" -eq 0 ] || fail "expected component picker reconcile exit 0, got $rc"
	assert_equal_files "$mcp_path" "$mcp_before"
	assert_equal_files "$theme_cache" "$theme_before"
	python3 - "$manifest_path" "$manifest_before" <<'PY' || fail "component picker changed skipped component manifest state"
import json
import sys
from pathlib import Path

actual = json.loads(Path(sys.argv[1]).read_text())
before = json.loads(Path(sys.argv[2]).read_text())
for key in ('mcpAction', 'mcpState', 'mcpAdapterAction', 'mcpAdapterState', 'themeAction', 'themeState'):
    assert actual.get(key) == before.get(key), key
assert actual['backups'].get('mcpConfig') == before['backups'].get('mcpConfig')
PY
}

# macOS system bash is 3.2 and rejects fractional `read -t` values, which would
# make every arrow key read as a bare Escape and cancel the installer.
assert_picker_key_reader_portability() {
	local fractional_timeouts="" definition="" actual=""

	fractional_timeouts="$(
		grep -REn 'read( +-[A-Za-z]+)* +-t +[0-9]*\.[0-9]+' \
			"$ROOT_DIR/install.sh" "$ROOT_DIR/tooling/install" "$ROOT_DIR/adapters/pi/scripts" || true
	)"
	[ -z "$fractional_timeouts" ] || fail "installer uses a fractional read timeout unsupported by bash 3.2: $fractional_timeouts"

	definition="$(sed -n '/^ui_component_escape_timeout() {$/,/^}$/p' "$ROOT_DIR/install.sh")"
	[ -n "$definition" ] || fail "install.sh does not define ui_component_escape_timeout"

	actual="$(bash -c "$definition"$'\nui_component_escape_timeout 3')"
	[ "$actual" = '1' ] || fail "expected a whole-second escape timeout on bash 3.x, got '$actual'"
	actual="$(bash -c "$definition"$'\nui_component_escape_timeout 5')"
	[ "$actual" = '0.1' ] || fail "expected a fractional escape timeout on bash 4+, got '$actual'"
}

run_optional_shell_tool_case() {
	local release_fixture="$1"
	local output payload
	payload="$WORK_DIR/optional-shell-tool-payload"
	mkdir -p "$payload"
	tar -xzf "$release_fixture/b-agentic.tar.gz" -C "$payload"
	output="$(SOURCE_DIR="$payload" bash -s "$payload" <<'EOF'
set -euo pipefail
dry_run_enabled() { return 1; }
log() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf '%s\n' "$*" >&2; exit 1; }
source "$1/tooling/install/common.sh"
shell_tool_missing_labels() { printf 'rg\n'; }
detect_shell_tool_package_manager() { printf 'apt-get'; }
install_shell_tools
EOF
)"
	assert_contains <(printf '%s\n' "$output") 'Shell tooling hint: sudo apt-get install -y ripgrep fd-find bat eza sd jq'
	assert_not_contains <(printf '%s\n' "$output") 'Install optional shell tooling'
}

run_prompted_mcp_key_pipe_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/prompted-mcp-key-pipe"
	local bin_dir="$sandbox/bin"
	local config_path="$sandbox/mcp.json"
	local environment_log="$sandbox/python-environment.log"
	local real_python

	mkdir -p "$bin_dir"
	real_python="$(command -v python3)"
	cat >"$config_path" <<'EOF'
{"mcpServers":{}}
EOF
	mkdir -p "$WORK_DIR/prompted-mcp-key-pipe-payload"
	tar -xzf "$release_fixture/b-agentic.tar.gz" -C "$WORK_DIR/prompted-mcp-key-pipe-payload"
	cat >"$bin_dir/python3" <<EOF
#!/usr/bin/env bash
while IFS= read -r entry; do
  case "\$entry" in
    CONTEXT7_API_KEY_INPUT=*|BRAVE_API_KEY_INPUT=*|FIRECRAWL_API_KEY_INPUT=*|FIRECRAWL_API_URL_INPUT=*)
      printf 'prompted MCP input leaked into Python environment\n' >> "$environment_log"
      ;;
  esac
done < <(env)
exec "$real_python" "\$@"
EOF
	chmod +x "$bin_dir/python3"

	PATH="$bin_dir:$(smoke_system_path)" \
		SOURCE_DIR="$WORK_DIR/prompted-mcp-key-pipe-payload" \
		MCP_CONFIG_DST="$config_path" \
		MCP_ROOT_KEY="mcpServers" \
		MCP_CONTEXT7_SECTION="headers" \
		MCP_BRAVE_SECTION="env" \
		MCP_FIRECRAWL_SECTION="env" \
		bash -s "$WORK_DIR/prompted-mcp-key-pipe-payload" <<'EOF'
set -euo pipefail
dry_run_enabled() { return 1; }
run_cmd() { "$@"; }
die() { printf '%s\n' "$*" >&2; exit 1; }
source "$1/tooling/install/common.sh"
CONTEXT7_API_KEY_INPUT="test-context7"
BRAVE_API_KEY_INPUT="test-brave"
FIRECRAWL_API_KEY_INPUT="test-firecrawl"
FIRECRAWL_API_URL_INPUT="https://test.firecrawl.dev"
apply_prompted_mcp_keys write none >/dev/null
EOF

	assert_no_path "$environment_log"
	assert_json_value "$config_path" "data['mcpServers']['context7']['headers']['CONTEXT7_API_KEY'] == 'test-context7'"
	assert_json_value "$config_path" "data['mcpServers']['brave-search']['env']['BRAVE_API_KEY'] == 'test-brave'"
	assert_json_value "$config_path" "data['mcpServers']['firecrawl']['env']['FIRECRAWL_API_KEY'] == 'test-firecrawl'"
	assert_json_value "$config_path" "data['mcpServers']['firecrawl']['env']['FIRECRAWL_API_URL'] == 'https://test.firecrawl.dev'"
}

run_playwright_mcp_migration_case() {
	local release_fixture="$1"
	local sandbox_root="$WORK_DIR/playwright-mcp-migration"
	local sandbox mcp_path case_name
	local -a cases=(npx pnpm bunx-versioned bunx-unversioned npx-headless-first bunx-headless-first bunx-isolated-first)

	for case_name in "${cases[@]}"; do
		sandbox="$sandbox_root/$case_name"
		mcp_path="$sandbox/home/.pi/agent/mcp.json"
		mkdir -p "$(dirname "$mcp_path")"
		python3 - "$mcp_path" "$case_name" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
case_name = sys.argv[2]
legacy = {
    "npx": {"command": "npx", "args": ["-y", "@playwright/mcp@latest", "--isolated"]},
    "pnpm": {"command": "pnpm", "args": ["dlx", "@playwright/mcp", "--isolated"]},
    "bunx-versioned": {"command": "bunx", "args": ["@playwright/mcp@latest", "--isolated"]},
    "bunx-unversioned": {"command": "bunx", "args": ["@playwright/mcp", "--isolated"]},
    "npx-headless-first": {"command": "npx", "args": ["-y", "@playwright/mcp@latest", "--headless", "--isolated"]},
    "bunx-headless-first": {"command": "bunx", "args": ["@playwright/mcp", "--headless", "--isolated"]},
    "bunx-isolated-first": {"command": "bunx", "args": ["@playwright/mcp", "--isolated", "--headless"]},
}[case_name]
path.write_text(json.dumps({"mcpServers": {"playwright": legacy}}, indent=2) + "\n")
PY
		expect_install_status 0 "$sandbox" "$release_fixture"
		assert_json_value "$mcp_path" "data['mcpServers']['playwright'] == {'command': 'bunx', 'args': ['@playwright/mcp', '--isolated', '--headless', '--caps=testing'], 'env': {}, 'lifecycle': 'lazy'}"
	done
}

run_mcp_doctor_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/mcp-doctor-pi"
	local bin_dir="$WORK_DIR/mcp-doctor-bin"
	local doctor_log="$WORK_DIR/mcp-doctor.log"
	local invalid_doctor_log="$WORK_DIR/mcp-doctor-invalid.log"
	local config_doctor_log="$WORK_DIR/mcp-doctor-config-keys.log"
	local invalid_suggestions_json="$WORK_DIR/mcp-doctor-invalid-suggestions.json"
	local blocked_suggestions_json="$WORK_DIR/mcp-doctor-blocked-suggestions.json"
	local rc=0
	mkdir -p "$sandbox/home" "$bin_dir"

	set +e
	python3 "$ROOT_DIR/tooling/validate/mcp_doctor.py" \
		--home "$sandbox/home" \
		--allow-degraded \
		--probe-schemas \
		--suggestions-json "$blocked_suggestions_json" >"$WORK_DIR/mcp-doctor-blocked.log" 2>&1
	rc=$?
	set -e
	[ "$rc" -eq 0 ] || fail "expected blocked MCP suggestions to degrade cleanly, got $rc"
	assert_file "$blocked_suggestions_json"
	assert_contains "$blocked_suggestions_json" '"status": "blocked"'
	assert_contains "$blocked_suggestions_json" '"policy_change_applied": false'

	printf '#!/usr/bin/env bash\nexit 0\n' >"$bin_dir/codegraph"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$bin_dir/bunx"
	cat >"$bin_dir/pi" <<'EOF'
#!/usr/bin/env bash
log_dir="$(cd "$(dirname "$0")" && pwd)"
if [ "${1:-}" = "list" ]; then
  [ -f "$log_dir/pi-adapter-installed" ] && printf 'npm:pi-mcp-adapter\n' || true
  [ -f "$log_dir/pi-anthropic-auth-installed" ] && printf 'npm:@gotgenes/pi-anthropic-auth\n' || true
  [ -f "$log_dir/pi-adapter-installed" ] || [ -f "$log_dir/pi-anthropic-auth-installed" ] || printf '(no packages)\n'
  exit 0
fi
if [ "${1:-}" = "install" ]; then
  [ "${2:-}" = "npm:pi-mcp-adapter" ] && : > "$log_dir/pi-adapter-installed"
  [ "${2:-}" = "npm:@gotgenes/pi-anthropic-auth" ] && : > "$log_dir/pi-anthropic-auth-installed"
  exit 0
fi
exit 0
EOF
	chmod +x "$bin_dir/codegraph" "$bin_dir/bunx" "$bin_dir/pi"

	set +e
	HOME="$sandbox/home" \
		PATH="$bin_dir:$(smoke_runtime_cli_path "$sandbox")" \
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" >/dev/null 2>&1
	rc=$?
	set -e
	[ "$rc" -eq 0 ] || fail "expected Pi MCP adapter install exit 0, got $rc"

	set +e
	PATH="$bin_dir:$(smoke_system_path)" \
	CONTEXT7_API_KEY=test-context7 \
	BRAVE_API_KEY=test-brave \
	FIRECRAWL_API_KEY=test-firecrawl \
		python3 "$ROOT_DIR/tooling/validate/mcp_doctor.py" --home "$sandbox/home" >"$doctor_log"
	rc=$?
	set -e
	[ "$rc" -eq 0 ] || fail "expected the fresh managed configuration to pass doctor checks, got $rc"
	assert_not_contains "$doctor_log" 'linear:'
	assert_not_contains "$doctor_log" 'mobbin:'
	assert_contains "$doctor_log" 'mcp-adapter: ready:'
	assert_contains "$doctor_log" 'codegraph: ready:'
	assert_contains "$doctor_log" 'context7: ready:'
	assert_contains "$doctor_log" 'brave-search: ready:'
	assert_contains "$doctor_log" 'firecrawl: ready:'
	assert_contains "$doctor_log" 'playwright: ready:'
	assert_json_value "$sandbox/home/.pi/agent/mcp.json" "data['mcpServers']['playwright']['args'] == ['@playwright/mcp', '--isolated', '--headless', '--caps=testing']"
	assert_contains "$doctor_log" 'schema-probe: not run; live tool inventory is unverified'

	python3 - "$sandbox/home/.pi/agent/mcp.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data['mcpServers']['context7']['headers']['CONTEXT7_API_KEY'] = 'config-context7'
data['mcpServers']['brave-search']['env']['BRAVE_API_KEY'] = 'config-brave'
data['mcpServers']['firecrawl']['env']['FIRECRAWL_API_KEY'] = 'config-firecrawl'
path.write_text(json.dumps(data, indent=2) + '\n')
PY
	env -u CONTEXT7_API_KEY -u BRAVE_API_KEY -u FIRECRAWL_API_KEY \
		PATH="$bin_dir:$(smoke_system_path)" \
		python3 "$ROOT_DIR/tooling/validate/mcp_doctor.py" --home "$sandbox/home" >"$config_doctor_log"
	assert_contains "$config_doctor_log" 'context7: ready:'
	assert_contains "$config_doctor_log" 'brave-search: ready:'
	assert_contains "$config_doctor_log" 'firecrawl: ready:'
	assert_not_contains "$config_doctor_log" 'linear:'
	assert_not_contains "$config_doctor_log" 'mobbin:'

	printf '[]\n' >"$sandbox/home/.pi/agent/mcp.json"
	set +e
	python3 "$ROOT_DIR/tooling/validate/mcp_doctor.py" --home "$sandbox/home" >"$invalid_doctor_log" 2>&1
	rc=$?
	set -e
	[ "$rc" -eq 1 ] || fail "expected malformed Pi MCP config to fail cleanly, got $rc"
	assert_contains "$invalid_doctor_log" 'status: invalid config: config root must be an object'
	assert_not_contains "$invalid_doctor_log" 'Traceback'

	set +e
	python3 "$ROOT_DIR/tooling/validate/mcp_doctor.py" \
		--home "$sandbox/home" \
		--allow-degraded \
		--probe-schemas \
		--suggestions-json "$invalid_suggestions_json" >"$WORK_DIR/mcp-doctor-invalid-suggestions.log" 2>&1
	rc=$?
	set -e
	[ "$rc" -eq 1 ] || fail "expected malformed Pi MCP config to remain blocking with --allow-degraded, got $rc"
	assert_file "$invalid_suggestions_json"
	assert_contains "$invalid_suggestions_json" '"status": "blocked"'
	assert_contains "$invalid_suggestions_json" '"policy_change_applied": false'
}

run_fresh_dependency_install_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/fresh-dependency-install"
	local bin_dir="$sandbox/smoke-bin"
	local minimal_bin="$sandbox/minimal-bin"
	local install_log="$sandbox/install.log"
	local smoke_path command_path name path_entry
	local -a host_path_entries=()
	local rc=0

	mkdir -p "$sandbox/home" "$minimal_bin"
	smoke_path="$(smoke_runtime_cli_path "$sandbox")"
	IFS=: read -r -a host_path_entries <<<"${PATH:-}"
	for path_entry in "${host_path_entries[@]}"; do
		[ -d "$path_entry" ] || continue
		for command_path in "$path_entry"/*; do
			[ -x "$command_path" ] || continue
			name="${command_path##*/}"
			case "$name" in
				rg | fd | fdfind | bat | batcat | eza | exa | sd | jq | rtk | codegraph) continue ;;
			esac
			[ -e "$minimal_bin/$name" ] && continue
			ln -s "$command_path" "$minimal_bin/$name" 2>/dev/null || true
		done
	done
	smoke_path="$bin_dir:$minimal_bin"
	for name in rtk codegraph rg fd bat eza sd jq; do
		rm -f "$bin_dir/$name"
	done
	cp "$(command -v curl)" "$bin_dir/.curl-real"
	cat >"$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
selfdir="$(cd "$(dirname "$0")" && pwd)"
for arg in "$@"; do
	case "$arg" in
	file://*) exec "$selfdir/.curl-real" "$@" ;;
	esac
done
case "$*" in
  *rtk-ai/rtk*)
    cat <<'SH'
mkdir -p "$HOME/.local/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$HOME/.local/bin/rtk"
chmod +x "$HOME/.local/bin/rtk"
SH
    ;;
  *colbymchenry/codegraph*)
    cat <<'SH'
mkdir -p "$HOME/.local/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$HOME/.local/bin/codegraph"
chmod +x "$HOME/.local/bin/codegraph"
SH
    ;;
  *)
    printf 'exit 0\n'
    ;;
esac
EOF
	chmod +x "$bin_dir/curl"

	set +e
	python3 - "$sandbox" "$release_fixture" "$smoke_path" "$install_log" "$ROOT_DIR/install.sh" <<'PY'
import os, pty, select, sys

sandbox, release_fixture, smoke_path, log_path, install_script = sys.argv[1:6]
env = dict(os.environ)
env["HOME"] = os.path.join(sandbox, "home")
env["PATH"] = smoke_path
env["B_AGENTIC_RELEASE_URL"] = "file://" + release_fixture + "/b-agentic.tar.gz"
env["B_AGENTIC_CHECKSUM_URL"] = "file://" + release_fixture + "/b-agentic.tar.gz.sha256"
env["B_AGENTIC_DIR"] = os.path.join(sandbox, "source")
env["B_AGENTIC_PROMPT_API_KEYS"] = "N"
env["B_AGENTIC_SHELL_RECOMMEND_MANAGER"] = "apt-get"

pid, fd = pty.fork()
if pid == 0:
    os.environ.update(env)
    os.execv("/bin/bash", ["bash", install_script])

os.write(fd, b"\n")
status = None
with open(log_path, "wb") as log:
    while True:
        try:
            result, status = os.waitpid(pid, os.WNOHANG)
            if result:
                break
            ready, _, _ = select.select([fd], [], [], 0.1)
            if ready:
                chunk = os.read(fd, 4096)
                if not chunk:
                    _, status = os.waitpid(pid, 0)
                    break
                log.write(chunk)
                log.flush()
        except (OSError, select.error):
            break

os.close(fd)
if status is None:
    _, status = os.waitpid(pid, 0)
if os.WIFEXITED(status):
    sys.exit(os.WEXITSTATUS(status))
if os.WIFSIGNALED(status):
    sys.exit(128 + os.WTERMSIG(status))
sys.exit(1)
PY
	rc=$?
	set -e
	[ "$rc" -eq 0 ] || fail "expected fresh dependency install exit 0, got $rc"
	for name in rtk codegraph; do
		assert_file "$sandbox/home/.local/bin/$name"
	done
	assert_contains "$install_log" 'Shell tooling hint: sudo apt-get install -y ripgrep fd-find bat eza sd jq'
	assert_contains "$install_log" 'Readiness:'
	assert_not_contains "$install_log" '  codegraph:'
	assert_not_contains "$install_log" '  rtk:'
}

run_existing_tool_upgrade_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/existing-tool-upgrade"
	local bin_dir="$sandbox/bin"
	local upgrade_log="$sandbox/upgrade.log"
	local install_log="$sandbox/install.log"
	local smoke_path
	local rc=0

	mkdir -p "$sandbox/home" "$bin_dir"

	cat >"$bin_dir/rtk" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	cat >"$bin_dir/codegraph" <<EOF
#!/usr/bin/env bash
printf 'codegraph:%s:refresh=%s\n' "\$*" "\${CODEGRAPH_NO_INSTALL_REFRESH:-unset}" >> "$upgrade_log"
exit 0
EOF
	cp "$(command -v curl)" "$bin_dir/.curl-real"
	cat >"$bin_dir/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
selfdir="\$(cd "\$(dirname "\$0")" && pwd)"
for arg in "\$@"; do
	case "\$arg" in
	file://*) exec "\$selfdir/.curl-real" "\$@" ;;
	esac
done
printf '%s\n' 'printf "rtk-upgrade\\n" >> "$upgrade_log"'
EOF
	chmod +x "$bin_dir/rtk" "$bin_dir/codegraph" "$bin_dir/curl"
	smoke_path="$(smoke_path_with_runtime_clis "$sandbox" "$bin_dir")"

	set +e
	python3 - "$sandbox" "$release_fixture" "$smoke_path" "$install_log" "$ROOT_DIR/install.sh" <<'PY'
import os, pty, select, sys

sandbox, release_fixture, smoke_path, log_path, install_script = sys.argv[1:6]
env = dict(os.environ)
env["HOME"] = os.path.join(sandbox, "home")
env["PATH"] = smoke_path
env["B_AGENTIC_RELEASE_URL"] = "file://" + release_fixture + "/b-agentic.tar.gz"
env["B_AGENTIC_CHECKSUM_URL"] = "file://" + release_fixture + "/b-agentic.tar.gz.sha256"
env["B_AGENTIC_DIR"] = os.path.join(sandbox, "source")
env["B_AGENTIC_PROMPT_API_KEYS"] = "N"

pid, fd = pty.fork()
if pid == 0:
    os.environ.update(env)
    os.execv("/bin/bash", ["bash", install_script])

os.write(fd, b"\n")
status = None
with open(log_path, "wb") as log:
    while True:
        try:
            result, status = os.waitpid(pid, os.WNOHANG)
            if result:
                break
            ready, _, _ = select.select([fd], [], [], 0.1)
            if ready:
                chunk = os.read(fd, 4096)
                if not chunk:
                    _, status = os.waitpid(pid, 0)
                    break
                log.write(chunk)
                log.flush()
        except (OSError, select.error):
            break

os.close(fd)
if status is None:
    _, status = os.waitpid(pid, 0)

if os.WIFEXITED(status):
    sys.exit(os.WEXITSTATUS(status))
if os.WIFSIGNALED(status):
    sys.exit(128 + os.WTERMSIG(status))
sys.exit(1)
PY
	rc=$?
	set -e

	[ "$rc" -eq 0 ] || fail "expected existing tool upgrade install exit 0, got $rc"
	assert_contains "$upgrade_log" 'rtk-upgrade'
	assert_contains "$upgrade_log" 'codegraph:upgrade:refresh=1'

	: >"$upgrade_log"
	set +e
	HOME="$sandbox/home" PATH="$smoke_path" \
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N bash "$ROOT_DIR/install.sh" --update >"$sandbox/update.log" 2>&1
	rc=$?
	set -e
	[ "$rc" -eq 0 ] || fail "expected existing tool update exit 0, got $rc"
	assert_contains "$upgrade_log" 'codegraph:upgrade:refresh=1'
	assert_contains "$sandbox/update.log" 'b-agentic update complete for Pi'
	assert_contains "$install_log" '[5/5]'
	assert_contains "$install_log" 'b-agentic install complete for Pi'
	assert_not_contains "$install_log" 'RTK already installed; upgrading'
	assert_not_contains "$install_log" 'CodeGraph already installed; upgrading'
	assert_not_contains "$install_log" 'Install RTK (Rust Token Killer)'
	assert_not_contains "$install_log" 'Install CodeGraph MCP agent'
}

run_existing_tool_default_skip_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/existing-tool-default-skip"
	local bin_dir="$sandbox/bin"
	local upgrade_log="$sandbox/upgrade.log"
	local install_log="$sandbox/install.log"
	local rc=0

	mkdir -p "$sandbox/home" "$bin_dir"

	for tool in rtk codegraph; do
		cat >"$bin_dir/$tool" <<EOF
#!/usr/bin/env bash
printf '%s:%s\n' '$tool' "\$*" >> "$upgrade_log"
exit 0
EOF
		chmod +x "$bin_dir/$tool"
	done

	set +e
	python3 - "$sandbox" "$release_fixture" "$install_log" "$(smoke_path_with_runtime_clis "$sandbox" "$bin_dir")" "$ROOT_DIR/install.sh" <<'PY'
import os, subprocess, sys
sandbox, release_fixture, log_path, smoke_path, install_script = sys.argv[1:6]
env = dict(os.environ)
env["HOME"] = os.path.join(sandbox, "home")
env["PATH"] = smoke_path
env["B_AGENTIC_RELEASE_URL"] = "file://" + release_fixture + "/b-agentic.tar.gz"
env["B_AGENTIC_CHECKSUM_URL"] = "file://" + release_fixture + "/b-agentic.tar.gz.sha256"
env["B_AGENTIC_DIR"] = os.path.join(sandbox, "source")
env["B_AGENTIC_PROMPT_API_KEYS"] = "N"

pid = os.fork()
if pid == 0:
    os.setsid()
    with open(log_path, "wb") as log:
        res = subprocess.run(["bash", install_script], env=env, stdout=log, stderr=log)
        sys.exit(res.returncode)
else:
    _, status = os.waitpid(pid, 0)
    sys.exit(os.WEXITSTATUS(status))
PY
	rc=$?
	set -e

	[ "$rc" -eq 0 ] || fail "expected existing tool reconciliation install exit 0, got $rc"
	assert_not_contains "$install_log" 'skipping upgrade without explicit approval'
}

run_runtime_cli_upgrade_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/runtime-cli-upgrade"
	local bin_dir="$sandbox/bin"
	local upgrade_log="$sandbox/upgrade.log"
	local install_log rc

	mkdir -p "$sandbox/home" "$bin_dir"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$bin_dir/rtk"
	chmod +x "$bin_dir/rtk"

	cat >"$bin_dir/pi" <<EOF
#!/usr/bin/env bash
printf 'pi:%s\n' "\$*" >> "$upgrade_log"
exit 0
EOF
	chmod +x "$bin_dir/pi"

	install_log="$sandbox/install.log"
	rc=0
	set +e
	HOME="$sandbox/home" \
		PATH="$(smoke_path_with_runtime_clis "$sandbox" "$bin_dir")" \
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" >"$install_log" 2>&1
	rc=$?
	set -e

	[ "$rc" -eq 0 ] || fail "expected pi runtime CLI upgrade install exit 0, got $rc"
	assert_contains "$upgrade_log" 'pi:update'
}

run_missing_runtime_cli_install_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/missing-runtime-cli-install"
	local bin_dir="$sandbox/bin"
	local install_log rc required_tool

	mkdir -p "$sandbox/home" "$bin_dir"
	for required_tool in rtk rg fd bat eza sd jq; do
		printf '#!/usr/bin/env bash\nexit 0\n' >"$bin_dir/$required_tool"
		chmod +x "$bin_dir/$required_tool"
	done

	install_log="$sandbox/install.log"
	rc=0
	set +e
	HOME="$sandbox/home" \
		PATH="$bin_dir:$(smoke_system_path)" \
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" --dry-run >"$install_log" 2>&1
	rc=$?
	set -e

	[ "$rc" -eq 0 ] || fail "expected pi missing CLI install dry-run exit 0, got $rc"
	assert_contains "$install_log" '[dry-run] curl -fsSL https://pi.dev/install.sh | sh'
}

run_runtime_cli_default_skip_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/runtime-cli-default-skip"
	local bin_dir="$sandbox/bin"
	local upgrade_log="$sandbox/upgrade.log"
	local install_log="$sandbox/install.log"
	local rc=0

	mkdir -p "$sandbox/home" "$bin_dir"
	for required_tool in rtk rg fd bat eza sd jq; do
		printf '#!/usr/bin/env bash\nexit 0\n' >"$bin_dir/$required_tool"
		chmod +x "$bin_dir/$required_tool"
	done
	cp "$(command -v curl)" "$bin_dir/.curl-real"
	cat >"$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
selfdir="$(cd "$(dirname "$0")" && pwd)"
for arg in "$@"; do
	case "$arg" in
	file://*) exec "$selfdir/.curl-real" "$@" ;;
	esac
done
exit 0
EOF
	chmod +x "$bin_dir/curl"

	set +e
	python3 - "$sandbox" "$release_fixture" "$install_log" "$bin_dir:$(smoke_system_path)" "$ROOT_DIR/install.sh" <<'PY'
import os, subprocess, sys
sandbox, release_fixture, log_path, smoke_path, install_script = sys.argv[1:6]
env = dict(os.environ)
env["HOME"] = os.path.join(sandbox, "home")
env["PATH"] = smoke_path
env["B_AGENTIC_RELEASE_URL"] = "file://" + release_fixture + "/b-agentic.tar.gz"
env["B_AGENTIC_CHECKSUM_URL"] = "file://" + release_fixture + "/b-agentic.tar.gz.sha256"
env["B_AGENTIC_DIR"] = os.path.join(sandbox, "source")
env["B_AGENTIC_PROMPT_API_KEYS"] = "N"

pid = os.fork()
if pid == 0:
    os.setsid()
    with open(log_path, "wb") as log:
        res = subprocess.run(["bash", install_script], env=env, stdout=log, stderr=log)
        sys.exit(res.returncode)
else:
    _, status = os.waitpid(pid, 0)
    sys.exit(os.WEXITSTATUS(status))
PY
	rc=$?
	set -e

	[ "$rc" -le 1 ] || fail "expected runtime CLI default install exit <=1, got $rc"
	assert_no_path "$upgrade_log"
}

run_bun_mcp_package_lifecycle_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/bun-mcp-lifecycle"
	local bun_log="$sandbox/smoke-bin/bun.log"

	mkdir -p "$sandbox/home"
	expect_install_status 0 "$sandbox" "$release_fixture"
	expect_install_status 0 "$sandbox" "$release_fixture" --update

	[ "$(grep -Fc 'bun upgrade' "$bun_log")" -eq 2 ] || fail "expected Bun reconciliation during install and update"
	assert_not_contains "$bun_log" 'bun install --global'
}

run_pi_package_lifecycle_preservation_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/pi-package-lifecycle-preservation"
	local install_log="$sandbox/install.log"
	local package_log="$sandbox/smoke-bin/pi-install.log"
	local project_dir="$sandbox/project"
	local global_lsp_config="$sandbox/home/.pi/agent/lsp.json"
	local project_lsp_config="$project_dir/.pi/lsp.json"
	local global_lsp_snapshot="$sandbox/global-lsp.snapshot"
	local project_lsp_snapshot="$sandbox/project-lsp.snapshot"
	local ask_package_count todo_package_count smoke_path
	local rc=0

	mkdir -p "$sandbox/home/.pi/agent" "$project_dir/.pi"
	cat >"$global_lsp_config" <<'EOF'
{
  "servers": {
    "global-user": {"command": "user-global-lsp", "args": ["--keep"]}
  }
}
EOF
	cat >"$project_lsp_config" <<'EOF'
{
  "servers": {
    "project-user": {"command": "user-project-lsp", "args": ["--keep"]}
  }
}
EOF
	cp "$global_lsp_config" "$global_lsp_snapshot"
	cp "$project_lsp_config" "$project_lsp_snapshot"
	smoke_path="$(smoke_runtime_cli_path "$sandbox")"
	: >"$sandbox/smoke-bin/pi-ask-user-question-versioned-installed"
	: >"$sandbox/smoke-bin/pi-lsp-ranged-installed"
	: >"$sandbox/smoke-bin/pi-todo-versioned-installed"
	set +e
	(
		cd "$project_dir"
		HOME="$sandbox/home" PATH="$smoke_path" \
			B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" B_AGENTIC_DIR="$sandbox/source" \
			B_AGENTIC_PROMPT_API_KEYS=N bash "$ROOT_DIR/install.sh" --dry-run >"$install_log" 2>&1
	)
	rc=$?
	set -e
	[ "$rc" -eq 0 ] || fail "expected optional Pi package dry-run exit 0, got $rc"
	assert_contains "$install_log" '[dry-run] pi install npm:@juicesharp/rpiv-ask-user-question'
	assert_contains "$install_log" '[dry-run] pi install npm:@juicesharp/rpiv-todo'
	assert_not_contains "$install_log" 'npm:@narumitw/pi-lsp'
	assert_not_contains "$install_log" 'npm:@juicesharp/rpiv-ask-user-question@'
	assert_not_contains "$install_log" 'npm:@juicesharp/rpiv-todo@'
	assert_no_path "$sandbox/smoke-bin/pi-ask-user-question-installed"
	assert_no_path "$sandbox/smoke-bin/pi-todo-installed"
	assert_file "$sandbox/smoke-bin/pi-ask-user-question-versioned-installed"
	assert_file "$sandbox/smoke-bin/pi-lsp-ranged-installed"
	assert_file "$sandbox/smoke-bin/pi-todo-versioned-installed"
	assert_equal_files "$global_lsp_config" "$global_lsp_snapshot"
	assert_equal_files "$project_lsp_config" "$project_lsp_snapshot"

	expect_install_status_in_cwd 0 "$project_dir" "$sandbox" "$release_fixture"
	assert_contains "$package_log" 'npm:@juicesharp/rpiv-ask-user-question'
	assert_contains "$package_log" 'npm:@juicesharp/rpiv-todo'
	assert_not_contains "$package_log" 'npm:@narumitw/pi-lsp'
	assert_not_contains "$package_log" 'npm:@juicesharp/rpiv-ask-user-question@'
	assert_not_contains "$package_log" 'npm:@juicesharp/rpiv-todo@'
	assert_file "$sandbox/smoke-bin/pi-ask-user-question-installed"
	assert_file "$sandbox/smoke-bin/pi-lsp-ranged-installed"
	assert_file "$sandbox/smoke-bin/pi-todo-installed"
	assert_no_path "$sandbox/smoke-bin/pi-ask-user-question-versioned-installed"
	assert_no_path "$sandbox/smoke-bin/pi-todo-versioned-installed"
	assert_equal_files "$global_lsp_config" "$global_lsp_snapshot"
	assert_equal_files "$project_lsp_config" "$project_lsp_snapshot"
	assert_contains "$sandbox/home/.pi/agent/b-agentic/install.json" '"piAskUserQuestionAction": "install"'
	assert_contains "$sandbox/home/.pi/agent/b-agentic/install.json" '"piAskUserQuestionState": "ready"'
	assert_contains "$sandbox/home/.pi/agent/b-agentic/install.json" '"piTodoAction": "install"'
	assert_contains "$sandbox/home/.pi/agent/b-agentic/install.json" '"piTodoState": "ready"'
	assert_not_contains "$sandbox/home/.pi/agent/b-agentic/install.json" 'piLsp'
	assert_not_contains "$sandbox/home/.pi/agent/b-agentic/install.json" 'package.pi-lsp'
	assert_json_value "$sandbox/home/.pi/agent/b-agentic/install.json" "data['capabilities']['states']['package.pi-todo']['action'] == 'install'"
	assert_json_value "$sandbox/home/.pi/agent/b-agentic/install.json" "data['capabilities']['states']['package.pi-todo']['state'] == 'ready'"
	ask_package_count="$(grep -Fc 'npm:@juicesharp/rpiv-ask-user-question' "$package_log")"
	todo_package_count="$(grep -Fc 'npm:@juicesharp/rpiv-todo' "$package_log")"
	[ "$ask_package_count" -eq 1 ] || fail "expected initial ask-user-question install exactly once"
	[ "$todo_package_count" -eq 1 ] || fail "expected initial pi-todo install exactly once"
	assert_contains "$install_log" 'update --extensions'

	expect_install_status_in_cwd 0 "$project_dir" "$sandbox" "$release_fixture"
	assert_equal_files "$global_lsp_config" "$global_lsp_snapshot"
	assert_equal_files "$project_lsp_config" "$project_lsp_snapshot"
	expect_install_status_in_cwd 0 "$project_dir" "$sandbox" "$release_fixture" --update
	assert_equal_files "$global_lsp_config" "$global_lsp_snapshot"
	assert_equal_files "$project_lsp_config" "$project_lsp_snapshot"
	assert_file "$sandbox/smoke-bin/pi-lsp-ranged-installed"
	assert_not_contains "$package_log" 'npm:@narumitw/pi-lsp'
	[ "$(grep -Fc 'npm:@juicesharp/rpiv-ask-user-question' "$package_log")" -eq "$ask_package_count" ] || fail "ask-user-question was reinstalled after package detection"
	[ "$(grep -Fc 'npm:@juicesharp/rpiv-todo' "$package_log")" -eq "$todo_package_count" ] || fail "pi-todo was reinstalled after package detection"
	assert_not_contains "$sandbox/home/.pi/agent/b-agentic/install.json" 'piLsp'
	assert_not_contains "$sandbox/home/.pi/agent/b-agentic/install.json" 'package.pi-lsp'
	assert_contains "$sandbox/home/.pi/agent/b-agentic/install.json" '"piTodoAction": "present"'
	assert_contains "$sandbox/home/.pi/agent/b-agentic/install.json" '"piTodoState": "ready"'
	assert_contains "$sandbox/smoke-bin/pi-install.log" 'update --extensions'

	expect_install_status_in_cwd 0 "$project_dir" "$sandbox" "$release_fixture" --uninstall
	assert_equal_files "$global_lsp_config" "$global_lsp_snapshot"
	assert_equal_files "$project_lsp_config" "$project_lsp_snapshot"
	assert_file "$sandbox/smoke-bin/pi-lsp-ranged-installed"
	assert_file "$sandbox/smoke-bin/pi-todo-installed"
	assert_no_path "$sandbox/home/.pi/agent/b-agentic/install.json"
}

run_rule_guard_lifecycle_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/rule-guard-lifecycle"
	local extensions_dir="$sandbox/home/.pi/agent/extensions"
	local snapshots_dir="$sandbox/home/.pi/agent/b-agentic/extensions"
	local rule_guard_path="$extensions_dir/b-agentic-rule-guard.ts"
	local rule_guard_snapshot="$snapshots_dir/b-agentic-rule-guard.ts"
	local permissions_path="$extensions_dir/b-agentic-permissions.ts"
	local user_extension="$extensions_dir/user-owned-extension.ts"
	local user_extension_snapshot="$sandbox/user-owned-extension.snapshot"
	local mcp_path="$sandbox/home/.pi/agent/mcp.json"
	local manifest_path="$sandbox/home/.pi/agent/b-agentic/install.json"

	mkdir -p "$extensions_dir" "$snapshots_dir" "$(dirname "$mcp_path")"
	printf 'user-owned extension\n' >"$user_extension"
	cp "$user_extension" "$user_extension_snapshot"
	cat >"$mcp_path" <<'EOF'
{"mcpServers":{"user-server":{"command":"user-server-cmd"}}}
EOF

	expect_install_status 0 "$sandbox" "$release_fixture"
	assert_no_path "$rule_guard_path"
	assert_no_path "$rule_guard_snapshot"
	assert_file "$permissions_path"
	assert_contains "$permissions_path" 'pi.on("tool_call"'
	assert_equal_files "$user_extension" "$user_extension_snapshot"
	assert_contains "$mcp_path" '"user-server"'
	assert_not_contains "$manifest_path" 'b-agentic-rule-guard.ts'
	assert_not_contains "$sandbox/home/.pi/agent/b-agentic/references/capabilities.yaml" 'b-agentic-rule-guard'

	printf 'legacy managed rule guard\n' >"$rule_guard_path"
	cp "$rule_guard_path" "$rule_guard_snapshot"
	expect_install_status 0 "$sandbox" "$release_fixture" --update
	assert_no_path "$rule_guard_path"
	assert_no_path "$rule_guard_snapshot"
	assert_equal_files "$user_extension" "$user_extension_snapshot"
	assert_contains "$mcp_path" '"user-server"'

	printf 'legacy managed rule guard\n' >"$rule_guard_path"
	cp "$rule_guard_path" "$rule_guard_snapshot"
	printf 'user-modified rule guard\n' >"$rule_guard_path"
	expect_install_status 0 "$sandbox" "$release_fixture" --update
	assert_file "$rule_guard_path"
	assert_file "$rule_guard_snapshot"
	assert_contains "$rule_guard_path" 'user-modified rule guard'
	assert_equal_files "$user_extension" "$user_extension_snapshot"
	assert_contains "$mcp_path" '"user-server"'
	assert_not_contains "$manifest_path" 'b-agentic-rule-guard.ts'

	expect_install_status 0 "$sandbox" "$release_fixture" --uninstall
	assert_file "$rule_guard_path"
	assert_contains "$rule_guard_path" 'user-modified rule guard'
	assert_no_path "$rule_guard_snapshot"
	assert_equal_files "$user_extension" "$user_extension_snapshot"
	assert_contains "$mcp_path" '"user-server"'
	assert_no_path "$manifest_path"
}

run_rule_guard_orphan_snapshot_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/rule-guard-orphan-snapshot"
	local extensions_dir="$sandbox/home/.pi/agent/extensions"
	local snapshots_dir="$sandbox/home/.pi/agent/b-agentic/extensions"
	local rule_guard_path="$extensions_dir/b-agentic-rule-guard.ts"
	local rule_guard_snapshot="$snapshots_dir/b-agentic-rule-guard.ts"

	mkdir -p "$extensions_dir" "$snapshots_dir"
	expect_install_status 0 "$sandbox" "$release_fixture"
	printf 'orphaned managed rule guard snapshot\n' >"$rule_guard_snapshot"
	expect_install_status 0 "$sandbox" "$release_fixture" --update
	assert_no_path "$rule_guard_path"
	assert_no_path "$rule_guard_snapshot"
}

run_rule_guard_manifest_backup_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/rule-guard-manifest-backup"
	local extensions_dir="$sandbox/home/.pi/agent/extensions"
	local snapshots_dir="$sandbox/home/.pi/agent/b-agentic/extensions"
	local backups_dir="$sandbox/home/.pi/agent/b-agentic/backups"
	local rule_guard_path="$extensions_dir/b-agentic-rule-guard.ts"
	local rule_guard_snapshot="$snapshots_dir/b-agentic-rule-guard.ts"
	local original_backup="$backups_dir/b-agentic-rule-guard.ts.bak"
	local original_snapshot="$sandbox/original-rule-guard.snapshot"
	local manifest_path="$sandbox/home/.pi/agent/b-agentic/install.json"

	mkdir -p "$extensions_dir" "$snapshots_dir" "$backups_dir"
	expect_install_status 0 "$sandbox" "$release_fixture"
	printf 'legacy managed rule guard\n' >"$rule_guard_path"
	cp "$rule_guard_path" "$rule_guard_snapshot"
	printf 'user-original rule guard\n' >"$original_backup"
	cp "$original_backup" "$original_snapshot"
	python3 - "$manifest_path" "$rule_guard_path" "$original_backup" <<'PY'
import json
import sys
from pathlib import Path

manifest_path, rule_guard_path, original_backup = map(Path, sys.argv[1:])
data = json.loads(manifest_path.read_text())
data.setdefault('paths', {}).setdefault('extensions', {})['b-agentic-rule-guard.ts'] = str(rule_guard_path)
data.setdefault('backups', {}).setdefault('extensions', {})['b-agentic-rule-guard.ts'] = str(original_backup)
manifest_path.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')
PY

	rm -rf "$sandbox/source"
	HOME="$sandbox/home" \
		B_AGENTIC_RELEASE_URL="$MISSING_RELEASE_URL" B_AGENTIC_CHECKSUM_URL="$MISSING_CHECKSUM_URL" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" --uninstall >"$sandbox/uninstall.log" 2>&1
	assert_equal_files "$rule_guard_path" "$original_snapshot"
	assert_no_path "$rule_guard_snapshot"
	assert_no_path "$original_backup"
	assert_no_path "$manifest_path"
}

run_pi_anthropic_auth_package_lifecycle_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/pi-anthropic-auth-package-lifecycle"
	local install_log="$sandbox/install.log"
	local package_log="$sandbox/smoke-bin/pi-install.log"
	local package_count
	local rc=0

	mkdir -p "$sandbox/home"
	set +e
	HOME="$sandbox/home" PATH="$(smoke_runtime_cli_path "$sandbox")" \
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N bash "$ROOT_DIR/install.sh" --dry-run >"$install_log" 2>&1
	rc=$?
	set -e
	[ "$rc" -eq 0 ] || fail "expected pi-anthropic-auth dry-run exit 0, got $rc"
	assert_contains "$install_log" '[dry-run] pi install npm:@gotgenes/pi-anthropic-auth'
	assert_contains "$install_log" 'anthropic-auth:'
	assert_no_path "$sandbox/smoke-bin/pi-anthropic-auth-installed"

	expect_install_status 0 "$sandbox" "$release_fixture"
	assert_contains "$package_log" 'npm:@gotgenes/pi-anthropic-auth'
	assert_contains "$sandbox/home/.pi/agent/b-agentic/install.json" '"piAnthropicAuthAction": "install"'
	assert_contains "$sandbox/home/.pi/agent/b-agentic/install.json" '"piAnthropicAuthState": "ready"'
	package_count="$(grep -Fc 'npm:@gotgenes/pi-anthropic-auth' "$package_log")"
	[ "$package_count" -eq 1 ] || fail "expected initial pi-anthropic-auth install exactly once"

	expect_install_status 0 "$sandbox" "$release_fixture"
	expect_install_status 0 "$sandbox" "$release_fixture" --update
	[ "$(grep -Fc 'npm:@gotgenes/pi-anthropic-auth' "$package_log")" -eq "$package_count" ] || fail "pi-anthropic-auth was reinstalled after package detection"
	assert_contains "$sandbox/home/.pi/agent/b-agentic/install.json" '"piAnthropicAuthAction": "present"'
	assert_contains "$sandbox/home/.pi/agent/b-agentic/install.json" '"piAnthropicAuthState": "ready"'

	expect_install_status 0 "$sandbox" "$release_fixture" --uninstall
	assert_file "$sandbox/smoke-bin/pi-anthropic-auth-installed"
	assert_no_path "$sandbox/home/.pi/agent/b-agentic/install.json"
}

run_parallel_chain_output_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/parallel-chain-output"
	local install_log="$sandbox/install.log"
	local bin_dir="$sandbox/smoke-bin"
	local rc=0

	mkdir -p "$sandbox/home"
	set +e
	HOME="$sandbox/home" PATH="$(smoke_runtime_cli_path "$sandbox")" \
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N B_AGENTIC_VERBOSE_MOCK=1 bash "$ROOT_DIR/install.sh" >"$install_log" 2>&1
	rc=$?
	set -e
	[ "$rc" -eq 0 ] || fail "expected verbose mocked install exit 0, got $rc"
	assert_not_contains "$install_log" 'dependency routine output'
	assert_not_contains "$install_log" 'bun routine output'
	assert_not_contains "$install_log" 'pi routine output'
	assert_contains "$install_log" 'b-agentic install complete for Pi'
	assert_contains "$install_log" 'warning: mocked actionable warning'

	: >"$bin_dir/fail-codegraph"
	set +e
	HOME="$sandbox/home" PATH="$(smoke_runtime_cli_path "$sandbox")" \
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N B_AGENTIC_VERBOSE_MOCK=1 bash "$ROOT_DIR/install.sh" --update >"$sandbox/failure.log" 2>&1
	rc=$?
	set -e
	[ "$rc" -ne 0 ] || fail "expected forced dependency chain failure"
	assert_contains "$sandbox/failure.log" 'Dependency chain failed: update_tooling'
	assert_contains "$sandbox/failure.log" 'forced codegraph diagnostic'
}

run_uninstall_skips_dependency_reconciliation_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/uninstall-skips-dependency-reconciliation"
	local bin_dir="$sandbox/smoke-bin"
	local dependency_log="$sandbox/dependency.log"
	local install_log="$sandbox/uninstall.log"
	local smoke_path rc tool

	mkdir -p "$sandbox/home"
	expect_install_status 0 "$sandbox" "$release_fixture"
	smoke_path="$(smoke_runtime_cli_path "$sandbox")"
	: >"$dependency_log"
	for tool in rtk codegraph bun curl; do
		cat >"$bin_dir/$tool" <<EOF
#!/usr/bin/env bash
printf '%s\\n' '$tool' >> "$dependency_log"
exit 97
EOF
		chmod +x "$bin_dir/$tool"
	done

	set +e
	HOME="$sandbox/home" \
		PATH="$smoke_path" \
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" --uninstall >"$install_log" 2>&1
	rc=$?
	set -e

	[ "$rc" -eq 0 ] || fail "expected uninstall without dependency reconciliation to exit 0, got $rc"
	[ ! -s "$dependency_log" ] || fail "uninstall unexpectedly reconciled dependencies: $dependency_log"
	assert_contains "$install_log" 'Uninstall complete.'
}

run_runtime_cli_prompt_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/runtime-cli-prompt"
	local bin_dir="$sandbox/bin"
	local install_log="$sandbox/install.log"
	local rc=0

	mkdir -p "$sandbox/home" "$bin_dir"
	for required_tool in rtk rg fd bat eza sd jq; do
		printf '#!/usr/bin/env bash\nexit 0\n' >"$bin_dir/$required_tool"
		chmod +x "$bin_dir/$required_tool"
	done

	set +e
	python3 - "$sandbox" "$release_fixture" "$install_log" "$bin_dir:$(smoke_system_path)" "$ROOT_DIR/install.sh" <<'PY'
import os, pty, select, sys

sandbox, release_fixture, log_path, smoke_path, install_script = sys.argv[1:6]
env = dict(os.environ)
env["HOME"] = os.path.join(sandbox, "home")
env["PATH"] = smoke_path
env["B_AGENTIC_RELEASE_URL"] = "file://" + release_fixture + "/b-agentic.tar.gz"
env["B_AGENTIC_CHECKSUM_URL"] = "file://" + release_fixture + "/b-agentic.tar.gz.sha256"
env["B_AGENTIC_DIR"] = os.path.join(sandbox, "source")
env["B_AGENTIC_PROMPT_API_KEYS"] = "N"

pid, fd = pty.fork()
if pid == 0:
    os.environ.update(env)
    os.execv("/bin/bash", ["bash", install_script, "--dry-run"])

os.write(fd, b"y\n")
status = None
with open(log_path, "wb") as log:
    while True:
        try:
            result, status = os.waitpid(pid, os.WNOHANG)
            if result:
                break
            ready, _, _ = select.select([fd], [], [], 0.1)
            if ready:
                chunk = os.read(fd, 4096)
                if not chunk:
                    _, status = os.waitpid(pid, 0)
                    break
                log.write(chunk)
                log.flush()
        except (OSError, select.error):
            break

os.close(fd)
if status is None:
    _, status = os.waitpid(pid, 0)

if os.WIFEXITED(status):
    sys.exit(os.WEXITSTATUS(status))
if os.WIFSIGNALED(status):
    sys.exit(128 + os.WTERMSIG(status))
sys.exit(1)
PY
	rc=$?
	set -e

	[ "$rc" -le 1 ] || fail "expected runtime CLI prompt install exit <=1, got $rc"
	assert_not_contains "$install_log" 'Install the Pi CLI now? [y/N]:'
	assert_contains "$install_log" '[dry-run] curl -fsSL https://pi.dev/install.sh | sh'
}

run_runtime_cli_auto_upgrade_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/runtime-cli-auto-upgrade"
	local bin_dir="$sandbox/bin"
	local install_log="$sandbox/install.log"
	local upgrade_log="$sandbox/upgrade.log"
	local smoke_path
	local rc=0

	mkdir -p "$sandbox/home" "$bin_dir"

	cat >"$bin_dir/pi" <<EOF
#!/usr/bin/env bash
printf 'pi:%s\n' "\$*" >> "$upgrade_log"
exit 0
EOF
	chmod +x "$bin_dir/pi"
	smoke_path="$(smoke_path_with_runtime_clis "$sandbox" "$bin_dir")"

	set +e
	python3 - "$sandbox" "$release_fixture" "$smoke_path" "$install_log" "$ROOT_DIR/install.sh" <<'PY'
import os, pty, select, sys

sandbox, release_fixture, smoke_path, log_path, install_script = sys.argv[1:6]
env = dict(os.environ)
env["HOME"] = os.path.join(sandbox, "home")
env["PATH"] = smoke_path
env["B_AGENTIC_RELEASE_URL"] = "file://" + release_fixture + "/b-agentic.tar.gz"
env["B_AGENTIC_CHECKSUM_URL"] = "file://" + release_fixture + "/b-agentic.tar.gz.sha256"
env["B_AGENTIC_DIR"] = os.path.join(sandbox, "source")
env["B_AGENTIC_PROMPT_API_KEYS"] = "N"

pid, fd = pty.fork()
if pid == 0:
    os.environ.update(env)
    os.execv("/bin/bash", ["bash", install_script])

os.write(fd, b"y\n")
status = None
with open(log_path, "wb") as log:
    while True:
        try:
            result, status = os.waitpid(pid, os.WNOHANG)
            if result:
                break
            ready, _, _ = select.select([fd], [], [], 0.1)
            if ready:
                chunk = os.read(fd, 4096)
                if not chunk:
                    _, status = os.waitpid(pid, 0)
                    break
                log.write(chunk)
                log.flush()
        except (OSError, select.error):
            break

os.close(fd)
if status is None:
    _, status = os.waitpid(pid, 0)

if os.WIFEXITED(status):
    sys.exit(os.WEXITSTATUS(status))
if os.WIFSIGNALED(status):
    sys.exit(128 + os.WTERMSIG(status))
sys.exit(1)
PY
	rc=$?
	set -e

	[ "$rc" -le 1 ] || fail "expected runtime CLI auto-upgrade install exit <=1, got $rc"
	assert_not_contains "$install_log" 'Upgrade the installed Pi CLI now? [y/N]:'
	assert_not_contains "$install_log" 'pi_cli_installed: command not found'
	assert_not_contains "$install_log" 'Install the Pi CLI now? [y/N]:'
	assert_contains "$install_log" '[5/5]'
	assert_contains "$install_log" 'b-agentic install complete for Pi'
	assert_not_contains "$install_log" 'Pi CLI already installed; upgrading with pi update'
	assert_contains "$upgrade_log" 'pi:update'
}

run_runtime_cli_update_failure_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/runtime-cli-update-failure"
	local bin_dir="$sandbox/bin"
	local install_log="$sandbox/install.log"
	local rc=0

	mkdir -p "$sandbox/home" "$bin_dir"
	cat >"$bin_dir/pi" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "update" ] && exit 1
exit 0
EOF
	chmod +x "$bin_dir/pi"

	set +e
	HOME="$sandbox/home" \
		PATH="$(smoke_path_with_runtime_clis "$sandbox" "$bin_dir")" \
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" >"$install_log" 2>&1
	rc=$?
	set -e

	[ "$rc" -ne 0 ] || fail "expected Pi CLI update failure to propagate"
	assert_contains "$install_log" 'Pi CLI install/upgrade failed'
}

run_skill_doctor_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/skill-doctor-pi"
	local doctor_log="$WORK_DIR/skill-doctor.log"
	local expected_skill_count
	local rc=0
	mkdir -p "$sandbox/home"
	expected_skill_count="$(registry_skill_count)"

	expect_install_status 0 "$sandbox" "$release_fixture"
	python3 "$ROOT_DIR/tooling/validate/skill_doctor.py" --home "$sandbox/home" >"$doctor_log"
	assert_contains "$doctor_log" "expected-skills: $expected_skill_count"
	assert_contains "$doctor_log" 'kernel: ready'
	assert_contains "$doctor_log" "skills: ready: $expected_skill_count skills installed"
	assert_contains "$doctor_log" 'content: ready'
	assert_contains "$doctor_log" 'discovery: ready:'
	printf '\nstale managed skill\n' >>"$sandbox/home/.pi/agent/skills/b-plan/SKILL.md"
	set +e
	python3 "$ROOT_DIR/tooling/validate/skill_doctor.py" --home "$sandbox/home" >"$doctor_log"
	rc=$?
	set -e
	[ "$rc" -eq 1 ] || fail "expected skill doctor to fail for stale skill content, got $rc"
	assert_contains "$doctor_log" 'content: stale: skill b-plan'
	printf '%s\n' '<!-- b-agentic-managed -->' >"$sandbox/home/.pi/agent/AGENTS.md"
	set +e
	python3 "$ROOT_DIR/tooling/validate/skill_doctor.py" --home "$sandbox/home" >"$doctor_log"
	rc=$?
	set -e
	[ "$rc" -eq 1 ] || fail "expected skill doctor to fail for stale kernel content, got $rc"
	assert_contains "$doctor_log" 'content: stale: skill b-plan,kernel'
	rm -rf "$sandbox/home/.pi/agent/skills/b-review"
	set +e
	python3 "$ROOT_DIR/tooling/validate/skill_doctor.py" --home "$sandbox/home" >"$doctor_log"
	rc=$?
	set -e
	[ "$rc" -eq 1 ] || fail "expected skill doctor to fail for missing skill, got $rc"
	assert_contains "$doctor_log" 'skills: missing or mismatched: missing b-review'
	assert_contains "$doctor_log" 'discovery: blocked: install complete current skill payload'

}

run_dracula_theme_install_and_update_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/dracula-theme-install-and-update"
	local fixture_repo="$WORK_DIR/dracula-fixture-update"

	make_dracula_fixture "$fixture_repo"
	mkdir -p "$sandbox/tmp"

	HOME="$sandbox/home" \
		TMPDIR="$sandbox/tmp" \
		PATH="$(smoke_runtime_cli_path "$sandbox")" \
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_DRACULA_REPO="$fixture_repo" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" >"$sandbox/install.log" 2>&1

	assert_file "$sandbox/home/.pi/agent/b-agentic/themes/dracula.json"
	[ -L "$sandbox/home/.pi/agent/themes/dracula.json" ] || fail "expected dracula.json to be a symlink"
	assert_equal_files "$sandbox/home/.pi/agent/themes/dracula.json" "$sandbox/home/.pi/agent/b-agentic/themes/dracula.json"
	assert_json_value "$sandbox/home/.pi/agent/b-agentic/install.json" "data['themeAction'] == 'write'"
	assert_json_value "$sandbox/home/.pi/agent/b-agentic/install.json" "data['themeState'] == 'ready'"
	assert_json_value "$sandbox/home/.pi/agent/b-agentic/install.json" "data['paths']['theme'] == '$sandbox/home/.pi/agent/themes/dracula.json'"
	assert_json_value "$sandbox/home/.pi/agent/b-agentic/install.json" "data['paths']['cachedTheme'] == '$sandbox/home/.pi/agent/b-agentic/themes/dracula.json'"

	# Update upstream fixture with new content and verify --update refreshes cached theme and symlink
	cat >"$fixture_repo/dracula.json" <<'EOF'
{
  "name": "Dracula",
  "colors": {
    "background": "#000000",
    "foreground": "#ffffff"
  }
}
EOF
	git -C "$fixture_repo" add dracula.json
	git -C "$fixture_repo" commit -qm 'update theme colors'

	HOME="$sandbox/home" \
		TMPDIR="$sandbox/tmp" \
		PATH="$(smoke_runtime_cli_path "$sandbox")" \
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_DRACULA_REPO="$fixture_repo" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" --update >"$sandbox/update.log" 2>&1

	assert_contains "$sandbox/home/.pi/agent/b-agentic/themes/dracula.json" '"#000000"'
	assert_contains "$sandbox/home/.pi/agent/themes/dracula.json" '"#000000"'

	# Verify --sync does not update Dracula theme
	cat >"$fixture_repo/dracula.json" <<'EOF'
{
  "name": "Dracula",
  "colors": {
    "background": "#111111",
    "foreground": "#eeeeee"
  }
}
EOF
	git -C "$fixture_repo" add dracula.json
	git -C "$fixture_repo" commit -qm 'sync should not pull this'

	HOME="$sandbox/home" \
		TMPDIR="$sandbox/tmp" \
		PATH="$(smoke_runtime_cli_path "$sandbox")" \
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_DRACULA_REPO="$fixture_repo" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" --sync >"$sandbox/sync.log" 2>&1

	assert_contains "$sandbox/home/.pi/agent/b-agentic/themes/dracula.json" '"#000000"'
	assert_not_contains "$sandbox/home/.pi/agent/b-agentic/themes/dracula.json" '"#111111"'

	# Verify temporary clone cleanup on successful run
	local leftover_clones
	leftover_clones="$(find "$sandbox/tmp" -maxdepth 1 -name "b-agentic-dracula.*" 2>/dev/null || true)"
	[ -z "$leftover_clones" ] || fail "temporary clone directories were not cleaned up: $leftover_clones"

	# Verify temporary clone cleanup on failure during copy (e.g. cache parent directory is a regular file)
	local sandbox_fail="$WORK_DIR/dracula-theme-failure-cleanup"
	mkdir -p "$sandbox_fail/tmp" "$sandbox_fail/home/.pi/agent/b-agentic"
	touch "$sandbox_fail/home/.pi/agent/b-agentic/themes"
	local fail_rc=0
	HOME="$sandbox_fail/home" \
		TMPDIR="$sandbox_fail/tmp" \
		PATH="$(smoke_runtime_cli_path "$sandbox_fail")" \
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" \
		B_AGENTIC_DIR="$sandbox_fail/source" \
		B_AGENTIC_DRACULA_REPO="$fixture_repo" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" >"$sandbox_fail/install.log" 2>&1 || fail_rc=$?

	[ "$fail_rc" -ne 0 ] || fail "expected installer to fail when cache destination directory cannot be created"
	assert_contains "$sandbox_fail/install.log" 'failed to cache Dracula theme to'

	local leftover_fail_clones
	leftover_fail_clones="$(find "$sandbox_fail/tmp" -maxdepth 1 -name "b-agentic-dracula.*" 2>/dev/null || true)"
	[ -z "$leftover_fail_clones" ] || fail "temporary clone directory leaked after copy error: $leftover_fail_clones"
}

run_dracula_theme_dry_run_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/dracula-theme-dry-run"

	HOME="$sandbox/home" \
		PATH="$(smoke_runtime_cli_path "$sandbox")" \
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" --dry-run >"$sandbox/dry-run.log" 2>&1

	assert_no_path "$sandbox/home/.pi/agent/themes"
	assert_no_path "$sandbox/home/.pi/agent/b-agentic/themes"
	assert_contains "$sandbox/dry-run.log" '[dry-run] git clone --depth 1'
	assert_contains "$sandbox/dry-run.log" '[dry-run] copy dracula.json ->'
	assert_contains "$sandbox/dry-run.log" '[dry-run] ln -sfn'
}

run_dracula_theme_collision_case() {
	local release_fixture="$1"
	local sandbox_user_file="$WORK_DIR/dracula-collision-file"
	local sandbox_symlink="$WORK_DIR/dracula-collision-symlink"

	mkdir -p "$sandbox_user_file/home/.pi/agent/themes"
	printf '{"user": "theme"}\n' >"$sandbox_user_file/home/.pi/agent/themes/dracula.json"

	HOME="$sandbox_user_file/home" \
		PATH="$(smoke_runtime_cli_path "$sandbox_user_file")" \
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" \
		B_AGENTIC_DIR="$sandbox_user_file/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" >"$sandbox_user_file/install.log" 2>&1

	assert_contains "$sandbox_user_file/install.log" 'warning: preserving user-owned theme file:'
	[ ! -L "$sandbox_user_file/home/.pi/agent/themes/dracula.json" ] || fail "expected regular file, not symlink"
	assert_contains "$sandbox_user_file/home/.pi/agent/themes/dracula.json" '"user": "theme"'
	assert_file "$sandbox_user_file/home/.pi/agent/b-agentic/themes/dracula.json"

	# Unrelated symlink collision
	mkdir -p "$sandbox_symlink/home/.pi/agent/themes" "$sandbox_symlink/external"
	printf '{"external": "theme"}\n' >"$sandbox_symlink/external/theme.json"
	ln -s "$sandbox_symlink/external/theme.json" "$sandbox_symlink/home/.pi/agent/themes/dracula.json"

	HOME="$sandbox_symlink/home" \
		PATH="$(smoke_runtime_cli_path "$sandbox_symlink")" \
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" \
		B_AGENTIC_DIR="$sandbox_symlink/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" >"$sandbox_symlink/install.log" 2>&1

	assert_contains "$sandbox_symlink/install.log" 'warning: preserving symlinked Pi theme:'
	[ -L "$sandbox_symlink/home/.pi/agent/themes/dracula.json" ] || fail "expected symlink"
	assert_contains "$sandbox_symlink/home/.pi/agent/themes/dracula.json" '"external": "theme"'
}

run_dracula_theme_uninstall_case() {
	local release_fixture="$1"
	local sandbox_std="$WORK_DIR/dracula-uninstall-std"
	local sandbox_user="$WORK_DIR/dracula-uninstall-user"
	local sandbox_manifest_std="$WORK_DIR/dracula-uninstall-manifest-std"
	local sandbox_manifest_user="$WORK_DIR/dracula-uninstall-manifest-user"

	# Standard regular uninstall removes managed symlink
	expect_install_status 0 "$sandbox_std" "$release_fixture"
	assert_file "$sandbox_std/home/.pi/agent/b-agentic/themes/dracula.json"
	[ -L "$sandbox_std/home/.pi/agent/themes/dracula.json" ] || fail "expected symlink"
	expect_install_status 0 "$sandbox_std" "$release_fixture" --uninstall
	assert_no_path "$sandbox_std/home/.pi/agent/themes/dracula.json"
	assert_no_path "$sandbox_std/home/.pi/agent/b-agentic"

	# Standard regular uninstall preserves user modified theme file
	expect_install_status 0 "$sandbox_user" "$release_fixture"
	rm "$sandbox_user/home/.pi/agent/themes/dracula.json"
	printf '{"custom": 1}\n' >"$sandbox_user/home/.pi/agent/themes/dracula.json"
	HOME="$sandbox_user/home" \
		PATH="$(smoke_runtime_cli_path "$sandbox_user")" \
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" \
		B_AGENTIC_DIR="$sandbox_user/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" --uninstall >"$sandbox_user/uninstall.log" 2>&1
	assert_contains "$sandbox_user/uninstall.log" 'preserving modified Pi theme:'
	assert_file "$sandbox_user/home/.pi/agent/themes/dracula.json"
	assert_contains "$sandbox_user/home/.pi/agent/themes/dracula.json" '"custom": 1'

	# Manifest-only uninstall removes managed symlink
	expect_install_status 0 "$sandbox_manifest_std" "$release_fixture"
	rm -rf "$sandbox_manifest_std/source"
	HOME="$sandbox_manifest_std/home" \
		B_AGENTIC_RELEASE_URL="$MISSING_RELEASE_URL" B_AGENTIC_CHECKSUM_URL="$MISSING_CHECKSUM_URL" \
		B_AGENTIC_DIR="$sandbox_manifest_std/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" --uninstall >"$sandbox_manifest_std/uninstall.log" 2>&1
	assert_contains "$sandbox_manifest_std/uninstall.log" 'Manifest-only uninstall complete for pi'
	assert_no_path "$sandbox_manifest_std/home/.pi/agent/themes/dracula.json"
	assert_no_path "$sandbox_manifest_std/home/.pi/agent/b-agentic"

	# Manifest-only uninstall preserves user modified theme file
	expect_install_status 0 "$sandbox_manifest_user" "$release_fixture"
	rm "$sandbox_manifest_user/home/.pi/agent/themes/dracula.json"
	printf '{"custom": 2}\n' >"$sandbox_manifest_user/home/.pi/agent/themes/dracula.json"
	rm -rf "$sandbox_manifest_user/source"
	HOME="$sandbox_manifest_user/home" \
		B_AGENTIC_RELEASE_URL="$MISSING_RELEASE_URL" B_AGENTIC_CHECKSUM_URL="$MISSING_CHECKSUM_URL" \
		B_AGENTIC_DIR="$sandbox_manifest_user/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" --uninstall >"$sandbox_manifest_user/uninstall.log" 2>&1
	assert_contains "$sandbox_manifest_user/uninstall.log" 'preserving modified Pi theme:'
	assert_file "$sandbox_manifest_user/home/.pi/agent/themes/dracula.json"
	assert_contains "$sandbox_manifest_user/home/.pi/agent/themes/dracula.json" '"custom": 2'
}

run_standalone_preview_installer_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/standalone-preview-installer"
	local bin_dir="$sandbox/bin"
	local curl_log="$sandbox/curl.log"
	local target="$sandbox/pi/extensions/b-agentic-preview-markdown.ts"
	local unrelated_extension="$sandbox/pi/extensions/user-extension.ts"
	local config_path="$sandbox/pi/mcp.json"
	local test_version="v9.8.7"
	local rc=0

	mkdir -p "$bin_dir" "$sandbox/tmp" "$(dirname "$target")"
	printf 'old preview extension\n' >"$target"
	printf 'user extension\n' >"$unrelated_extension"
	printf '{"mcpServers":{"user":{"command":"keep-me"}}}\n' >"$config_path"
	cat >"$bin_dir/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
output=""
url=""
while [ "\$#" -gt 0 ]; do
	case "\$1" in
		--output) output="\$2"; shift 2 ;;
		*) url="\$1"; shift ;;
	esac
done
printf '%s\n' "\$url" >>"$curl_log"
[ -n "\$output" ]
cp "$ROOT_DIR/adapters/pi/packages/preview-markdown/extensions/b-agentic-preview-markdown.ts" "\$output"
EOF
	chmod +x "$bin_dir/curl"

	HOME="$sandbox/home" \
		PI_CODING_AGENT_DIR="$sandbox/pi" \
		TMPDIR="$sandbox/tmp" \
		PATH="$bin_dir:$(smoke_system_path)" \
		bash "$ROOT_DIR/adapters/pi/scripts/install-preview-markdown.sh" "$test_version" >"$sandbox/install.log" 2>&1

	assert_equal_files "$target" "$ROOT_DIR/adapters/pi/packages/preview-markdown/extensions/b-agentic-preview-markdown.ts"
	assert_contains "$unrelated_extension" 'user extension'
	assert_contains "$config_path" 'keep-me'
	assert_contains "$curl_log" "https://raw.githubusercontent.com/dhoaibao/b-agentic/$test_version/adapters/pi/packages/preview-markdown/extensions/b-agentic-preview-markdown.ts"
	assert_not_contains "$curl_log" 'b-agentic-permissions.ts'
	assert_contains "$sandbox/install.log" 'Run /reload'
	[ -z "$(find "$sandbox/tmp" -maxdepth 1 -name 'b-agentic-preview-markdown.*' -print -quit)" ] || fail 'standalone preview installer leaked a temporary download'

	printf 'old preview extension\n' >"$target"
	set +e
	HOME="$sandbox/home" \
		PI_CODING_AGENT_DIR="$sandbox/pi" \
		TMPDIR="$sandbox/tmp" \
		PATH="$bin_dir:$(smoke_system_path)" \
		bash "$ROOT_DIR/adapters/pi/scripts/install-preview-markdown.sh" not-a-version >"$sandbox/invalid.log" 2>&1
	rc=$?
	set -e
	[ "$rc" -ne 0 ] || fail 'standalone preview installer accepted an invalid download'
	assert_contains "$sandbox/invalid.log" 'invalid version ref not-a-version'
	assert_contains "$target" 'old preview extension'
	[ "$(wc -l <"$curl_log")" -eq 1 ] || fail 'invalid standalone preview version unexpectedly invoked curl'
	[ -z "$(find "$sandbox/tmp" -maxdepth 1 -name 'b-agentic-preview-markdown.*' -print -quit)" ] || fail 'standalone preview installer leaked a temporary file after validation failure'
}

run_agent_gate_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/agent-gate"
	local install_log="$sandbox/install.log"

	mkdir -p "$sandbox/home"
	# Release payloads ship only the Pi adapter, so a deferred host cannot be
	# resolved at all and must still fail closed before any install plan.
	HOME="$sandbox/home" \
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" --agent codex --dry-run >"$install_log" 2>&1 &&
		fail "deferred agent must not reach the install plan"
	assert_contains "$install_log" "unknown agent 'codex': no adapter manifest at adapters/codex/manifest.yaml"

	HOME="$sandbox/home" \
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" --agent bogus --dry-run >"$install_log" 2>&1 &&
		fail "unknown agent must be rejected"
	assert_contains "$install_log" "unknown agent 'bogus'"
}

run_rtk_latest_dry_run_case() {
	local release_fixture="$1"
	local sandbox="$WORK_DIR/rtk-latest-dry-run"
	local bin_dir="$sandbox/bin"
	local install_log="$sandbox/install.log"
	local rc required_tool

	mkdir -p "$sandbox/home" "$bin_dir"
	for required_tool in rg fd bat eza sd jq; do
		printf '#!/usr/bin/env bash\nexit 0\n' >"$bin_dir/$required_tool"
		chmod +x "$bin_dir/$required_tool"
	done

	set +e
	HOME="$sandbox/home" \
		PATH="$bin_dir:$(smoke_system_path)" \
		B_AGENTIC_RELEASE_URL="file://$release_fixture/b-agentic.tar.gz" B_AGENTIC_CHECKSUM_URL="file://$release_fixture/b-agentic.tar.gz.sha256" \
		B_AGENTIC_DIR="$sandbox/source" \
		B_AGENTIC_PROMPT_API_KEYS=N \
		bash "$ROOT_DIR/install.sh" --dry-run >"$install_log" 2>&1
	rc=$?
	set -e
	[ "$rc" -eq 0 ] || fail "expected dry-run with latest RTK exit 0, got $rc"
	assert_contains "$install_log" '[dry-run] curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh'
}

run_base_smoke_worker() {
	local release_fixture="$1"
	local worker_index="$2"
	shift 2
	local -a cases=("$@")
	local worker_status=0 case_status case_name index

	for ((index = worker_index; index < ${#cases[@]}; index += 2)); do
		case_name="${cases[$index]}"
		printf 'Running %s...\n' "$case_name"
		if ( "$case_name" "$release_fixture" ); then
			:
		else
			case_status=$?
			printf '%s failed with status %s\n' "$case_name" "$case_status"
			[ "$worker_status" -ne 0 ] || worker_status="$case_status"
		fi
	done
	return "$worker_status"
}

run_base_smoke_cases() {
	# This function runs in a background subshell from main. Keep the parent
	# cleanup trap out of it so a completed installer worker cannot delete the
	# shared WORK_DIR while the Pi worker is still running.
	trap - EXIT
	local release_fixture="$1"
	local worker_count=2
	local pool_dir="$WORK_DIR/base-smoke-pool"
	local -a cases=(
		run_standalone_preview_installer_case
		run_agent_gate_case
		run_rtk_latest_dry_run_case
		run_ref_install_case
		run_release_checksum_mismatch_case
		run_release_unsafe_archive_case
		run_git_checkout_migration_case
		run_release_ref_validation_case
		run_release_ref_url_case
		run_manifest_only_corrupted_manifest_case
		run_manifest_only_custom_paths_case
		run_manifest_only_mcp_symlink_preservation_case
		run_manifest_only_modified_skill_case
		run_manifest_only_merged_config_case
		run_user_owned_serena_preservation_case
		run_user_owned_retired_mcp_preservation_case
		run_manifest_only_extension_restore_case
		run_legacy_consult_extension_removal_case
		run_manifest_only_extension_symlink_case
		run_invalid_skill_payload_case
		run_skill_collision_smoke_case
		run_readiness_report_case
		run_output_contract_case
		run_component_picker_case
		run_optional_shell_tool_case
		run_prompted_mcp_key_pipe_case
		run_playwright_mcp_migration_case
		run_mcp_doctor_case
		run_runtime_cli_default_skip_case
		run_runtime_cli_prompt_case
		run_runtime_cli_auto_upgrade_case
		run_runtime_cli_upgrade_case
		run_missing_runtime_cli_install_case
		run_runtime_cli_update_failure_case
		run_existing_tool_upgrade_case
		run_existing_tool_default_skip_case
		run_fresh_dependency_install_case
		run_bun_mcp_package_lifecycle_case
		run_pi_package_lifecycle_preservation_case
		run_rule_guard_lifecycle_case
		run_rule_guard_orphan_snapshot_case
		run_rule_guard_manifest_backup_case
		run_pi_anthropic_auth_package_lifecycle_case
		run_parallel_chain_output_case
		run_uninstall_skips_dependency_reconciliation_case
		run_skill_doctor_case
		run_dracula_theme_install_and_update_case
		run_dracula_theme_dry_run_case
		run_dracula_theme_collision_case
		run_dracula_theme_uninstall_case
	)
	local -a pids=()
	local worker_index status rc=0

	mkdir -p "$pool_dir"
	for ((worker_index = 0; worker_index < worker_count; worker_index++)); do
		run_base_smoke_worker "$release_fixture" "$worker_index" "${cases[@]}" \
			>"$pool_dir/worker-$worker_index.log" 2>&1 &
		pids+=("$!")
	done

	for ((worker_index = 0; worker_index < worker_count; worker_index++)); do
		if wait "${pids[$worker_index]}"; then
			:
		else
			status=$?
			[ "$rc" -ne 0 ] || rc="$status"
		fi
		cat "$pool_dir/worker-$worker_index.log"
	done
	rm -rf "$pool_dir"
	return "$rc"
}

main() {
	local release_fixture="$WORK_DIR/release-fixture"
	local default_dracula_fixture="$WORK_DIR/dracula-default-fixture"

	require_bin git
	require_bin node
	require_bin python3
	make_dracula_fixture "$default_dracula_fixture"
	export B_AGENTIC_DRACULA_REPO="$default_dracula_fixture"
	echo "Building release fixture..."
	make_release_fixture "$release_fixture"
	# shellcheck disable=SC1090
	source "$ROOT_DIR/adapters/pi/tests/smoke.sh"
	declare -F run_pi_smoke_cases >/dev/null || fail "Pi smoke suite did not define run_pi_smoke_cases"
	echo "Running Pi smoke cases..."
	run_pi_smoke_cases "$release_fixture" &
	local pi_smoke_pid=$!

	echo "Running base installer smoke cases with 2 workers..."
	run_base_smoke_cases "$release_fixture" &
	local base_pid=$!

	local base_status
	if wait "$base_pid"; then
		:
	else
		base_status=$?
		wait "$pi_smoke_pid" 2>/dev/null || true
		return "$base_status"
	fi

	local pi_smoke_status
	if wait "$pi_smoke_pid"; then
		:
	else
		pi_smoke_status=$?
		return "$pi_smoke_status"
	fi


	printf 'smoke-install.sh passed\n'
}

main "$@"
