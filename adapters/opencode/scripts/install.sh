# Sourced by install.sh — do not run directly.
# shellcheck shell=bash
# Variables below are shared with the sourced installer core.
# shellcheck disable=SC2034
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	echo "error: this script is sourced by install.sh" >&2
	exit 1
fi

# OpenCode adapter: declarative configuration only.
#
# Paths come from docs/hosts.md: the global instruction file is
# ~/.config/opencode/AGENTS.md, native skills live in
# ~/.config/opencode/skills, and both the permission object and the MCP
# servers live in the single ~/.config/opencode/opencode.json file.
#
# OpenCode also reads ~/.claude/skills and ~/.agents/skills. This adapter
# writes only its native directory so a machine that also installs the Claude
# Code or Antigravity adapter never gets the same skill twice from two owners;
# see the coexistence note in docs/hosts.md.

RUNTIME_NAME="opencode"
RUNTIME_DISPLAY="OpenCode"
OPENCODE_HOME="${B_AGENTIC_OPENCODE_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}"
METADATA_DIR="$OPENCODE_HOME/b-agentic"
BACKUPS_DIR="$METADATA_DIR/backups"
SKILLS_DST="$OPENCODE_HOME/skills"
SKILLS_SNAPSHOT_DST="$METADATA_DIR/skills"
KERNEL_DST="$OPENCODE_HOME/AGENTS.md"
KERNEL_SNAPSHOT_DST="$METADATA_DIR/AGENTS.md"
REFERENCES_DST="$METADATA_DIR/references"
TEMPLATES_DST="$METADATA_DIR/templates"
MANIFEST_DST="$METADATA_DIR/install.json"
OPENCODE_CONFIG_DST="${B_AGENTIC_OPENCODE_JSON:-$OPENCODE_HOME/opencode.json}"

# One file carries both the permission object and the MCP servers, so it is
# one managed entry: the merge and the uninstall both act on the whole file.
DECLARATIVE_CONFIGS=(
	"opencodeConfig|$OPENCODE_CONFIG_DST|opencode.template.json|OpenCode config"
)

opencode_set_source_dirs() {
	TEMPLATES_SRC="$SOURCE_DIR/adapters/opencode/configs"
	KERNEL_SRC="$SOURCE_DIR/references/kernel.opencode.md"
}

opencode_validate_source() {
	opencode_set_source_dirs
	[ -f "$KERNEL_SRC" ] || die "missing rendered OpenCode kernel: $KERNEL_SRC"
	[ -d "$TEMPLATES_SRC" ] || die "missing OpenCode config directory: $TEMPLATES_SRC"
	[ -f "$TEMPLATES_SRC/opencode.template.json" ] || die "missing OpenCode config template: $TEMPLATES_SRC/opencode.template.json"
}

opencode_install() {
	declarative_install_common
}

opencode_sync() {
	declarative_sync_common
}

opencode_update() {
	declarative_install_common
}

opencode_uninstall() {
	declarative_uninstall_common
}
