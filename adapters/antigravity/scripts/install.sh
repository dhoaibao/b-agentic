# Sourced by install.sh — do not run directly.
# shellcheck shell=bash
# Variables below are shared with the sourced installer core.
# shellcheck disable=SC2034
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	echo "error: this script is sourced by install.sh" >&2
	exit 1
fi

# Antigravity adapter: declarative configuration only.
#
# Paths come from docs/hosts.md: the global instruction file is
# ~/.gemini/GEMINI.md, global skills live in ~/.gemini/config/skills, global
# MCP servers in ~/.gemini/config/mcp_config.json, and CLI permissions in
# ~/.gemini/antigravity-cli/settings.json.
#
# The 12,000-character cap that references/kernel.antigravity.md is measured
# against is Antigravity's per-rules-file limit; tooling/validate/suite_audit.py
# enforces it for every rendered kernel.

RUNTIME_NAME="antigravity"
RUNTIME_DISPLAY="Antigravity"
GEMINI_HOME="${B_AGENTIC_GEMINI_HOME:-$HOME/.gemini}"
METADATA_DIR="$GEMINI_HOME/config/b-agentic"
BACKUPS_DIR="$METADATA_DIR/backups"
SKILLS_DST="$GEMINI_HOME/config/skills"
SKILLS_SNAPSHOT_DST="$METADATA_DIR/skills"
KERNEL_DST="$GEMINI_HOME/GEMINI.md"
KERNEL_SNAPSHOT_DST="$METADATA_DIR/GEMINI.md"
REFERENCES_DST="$METADATA_DIR/references"
TEMPLATES_DST="$METADATA_DIR/templates"
MANIFEST_DST="$METADATA_DIR/install.json"
MCP_CONFIG_DST="${B_AGENTIC_ANTIGRAVITY_MCP_JSON:-$GEMINI_HOME/config/mcp_config.json}"
SETTINGS_DST="${B_AGENTIC_ANTIGRAVITY_SETTINGS_JSON:-$GEMINI_HOME/antigravity-cli/settings.json}"

DECLARATIVE_CONFIGS=(
	"mcpConfig|$MCP_CONFIG_DST|mcp_config.template.json|Antigravity MCP config"
	"permissionsConfig|$SETTINGS_DST|settings.template.json|Antigravity permissions"
)

antigravity_set_source_dirs() {
	TEMPLATES_SRC="$SOURCE_DIR/adapters/antigravity/configs"
	KERNEL_SRC="$SOURCE_DIR/references/kernel.antigravity.md"
}

antigravity_validate_source() {
	antigravity_set_source_dirs
	[ -f "$KERNEL_SRC" ] || die "missing rendered Antigravity kernel: $KERNEL_SRC"
	[ -d "$TEMPLATES_SRC" ] || die "missing Antigravity config directory: $TEMPLATES_SRC"
	[ -f "$TEMPLATES_SRC/mcp_config.template.json" ] || die "missing Antigravity MCP template: $TEMPLATES_SRC/mcp_config.template.json"
	[ -f "$TEMPLATES_SRC/settings.template.json" ] || die "missing Antigravity permissions template: $TEMPLATES_SRC/settings.template.json"
}

antigravity_install() {
	declarative_install_common
}

antigravity_sync() {
	declarative_sync_common
}

antigravity_update() {
	declarative_install_common
}

antigravity_uninstall() {
	declarative_uninstall_common
}
