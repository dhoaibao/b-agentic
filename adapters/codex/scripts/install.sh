# Sourced by install.sh — do not run directly.
# shellcheck shell=bash
# Variables below are shared with the sourced installer core.
# shellcheck disable=SC2034
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	echo "error: this script is sourced by install.sh" >&2
	exit 1
fi

# Codex CLI adapter: declarative configuration only.
#
# Paths come from docs/hosts.md: the global instruction file is
# $CODEX_HOME/AGENTS.md (default ~/.codex), skills live in
# ${CODEX_HOME}/skills, and MCP servers plus the approval and sandbox settings
# live in ~/.codex/config.toml. Codex allows config writes only to the user
# config.toml and requires comments and formatting to be preserved, so the
# managed settings go in one delimited block; see tooling/install/toml_block.py.
#
# Two documented capabilities are deliberately NOT delivered:
#   - Starlark execpolicy prefix rules. docs/hosts.md records the syntax but
#     not the discovery path, so the shared deny/ask command patterns are not
#     enforced here. approval_policy = "untrusted" is the accepted downgrade.
#   - PreToolUse hooks (deferred D2a: the hooks.json location is unconfirmed,
#     and a freshly installed hook does nothing until the user trusts it).

RUNTIME_NAME="codex"
RUNTIME_DISPLAY="Codex CLI"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
METADATA_DIR="$CODEX_HOME_DIR/b-agentic"
BACKUPS_DIR="$METADATA_DIR/backups"
SKILLS_DST="$CODEX_HOME_DIR/skills"
SKILLS_SNAPSHOT_DST="$METADATA_DIR/skills"
KERNEL_DST="$CODEX_HOME_DIR/AGENTS.md"
KERNEL_SNAPSHOT_DST="$METADATA_DIR/AGENTS.md"
REFERENCES_DST="$METADATA_DIR/references"
TEMPLATES_DST="$METADATA_DIR/templates"
MANIFEST_DST="$METADATA_DIR/install.json"
CODEX_CONFIG_DST="${B_AGENTIC_CODEX_CONFIG_TOML:-$CODEX_HOME_DIR/config.toml}"
CODEX_CONFIG_TEMPLATE="config.template.toml"

# Codex takes a TOML managed block rather than a JSON merge, so it declares no
# DECLARATIVE_CONFIGS entries and handles its one config file below.
DECLARATIVE_CONFIGS=()

codex_set_source_dirs() {
	TEMPLATES_SRC="$SOURCE_DIR/adapters/codex/configs"
	KERNEL_SRC="$SOURCE_DIR/references/kernel.codex.md"
}

codex_validate_source() {
	codex_set_source_dirs
	[ -f "$KERNEL_SRC" ] || die "missing rendered Codex kernel: $KERNEL_SRC"
	[ -d "$TEMPLATES_SRC" ] || die "missing Codex config directory: $TEMPLATES_SRC"
	[ -f "$TEMPLATES_SRC/$CODEX_CONFIG_TEMPLATE" ] || die "missing Codex config template: $TEMPLATES_SRC/$CODEX_CONFIG_TEMPLATE"
	[ -f "$SOURCE_DIR/tooling/install/toml_block.py" ] || die "missing TOML block helper: $SOURCE_DIR/tooling/install/toml_block.py"
}

codex_install_config() {
	declarative_install_toml_block "$CODEX_CONFIG_DST" "$CODEX_CONFIG_TEMPLATE" "Codex config" codexConfig
}

codex_install() {
	set_install_stage_total 6

	collect_installed_skills INSTALL_SKILL_NAMES
	run_stage "Syncing skills" install_skills || return $?
	run_stage "Syncing references and templates" install_references_and_templates || return $?
	run_install_triplet_stage "Installing kernel" install_kernel "preserve" "pending" "none" \
		INSTALL_MEMORY_ACTION INSTALL_ACTIVATION_STATE INSTALL_MEMORY_BACKUP || return $?
	run_install_triplet_stage "Applying Codex config block" codex_install_config "skip" "none" "none" \
		INSTALL_CODEX_CONFIG_ACTION INSTALL_CODEX_CONFIG_STATE INSTALL_CODEX_CONFIG_BACKUP || return $?
	DECLARATIVE_CONFIG_ACTIONS="codexConfig=$INSTALL_CODEX_CONFIG_ACTION=$INSTALL_CODEX_CONFIG_STATE=$INSTALL_CODEX_CONFIG_BACKUP
"
	DECLARATIVE_CONFIGS=("codexConfig|$CODEX_CONFIG_DST|$CODEX_CONFIG_TEMPLATE|Codex config")
	# toml_block.py refuses to touch a config.toml that already defines a
	# managed key or table; that preserves the user's file but leaves this
	# install without MCP servers, so it must not report a clean result.
	if [ "$INSTALL_CODEX_CONFIG_ACTION" = "skip" ]; then
		DECLARATIVE_CONFIG_SKIPS="Codex config
"
	fi
	run_stage "Installing uninstall helper" install_uninstall_helper || return $?
	run_stage "Writing install manifest" declarative_write_manifest || return $?
	declarative_print_install_report
	installer_summary_log "  execpolicy: shared deny/ask command patterns are not enforced on Codex; see docs/hosts.md"

	if [ "$INSTALL_ACTIVATION_STATE" = "pending" ]; then
		return 2
	fi
}

codex_sync() {
	declarative_sync_common
}

codex_update() {
	codex_install
}

codex_uninstall() {
	require_bin python3
	set_install_stage_total 3
	installer_summary_log "Uninstalling b-agentic from $RUNTIME_DISPLAY"
	local rc=0
	run_stage "Removing managed skills" uninstall_installed_skills || rc=$?
	run_stage "Removing managed kernel" remove_managed_kernel || rc=$?
	run_stage "Removing Codex config block" declarative_uninstall_toml_block "$CODEX_CONFIG_DST" "Codex config" || rc=$?
	finish_uninstall_metadata "$rc" || return $?
	installer_summary_log "Uninstall complete. User-owned $RUNTIME_DISPLAY files were preserved."
}
