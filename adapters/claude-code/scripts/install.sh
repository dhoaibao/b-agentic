# Sourced by install.sh — do not run directly.
# shellcheck shell=bash
# Variables below are shared with the sourced installer core.
# shellcheck disable=SC2034
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	echo "error: this script is sourced by install.sh" >&2
	exit 1
fi

# Claude Code adapter: declarative configuration only.
#
# Paths come from docs/hosts.md: CLAUDE.md is the personal instruction file,
# skills live under ~/.claude/skills, personal MCP servers belong in
# ~/.claude.json rather than a project .mcp.json, and permissions live in
# ~/.claude/settings.json. No hook scripts ship (docs/decision_design.md).

RUNTIME_NAME="claude-code"
RUNTIME_DISPLAY="Claude Code"
CLAUDE_HOME="${B_AGENTIC_CLAUDE_HOME:-$HOME/.claude}"
METADATA_DIR="$CLAUDE_HOME/b-agentic"
BACKUPS_DIR="$METADATA_DIR/backups"
SKILLS_DST="$CLAUDE_HOME/skills"
SKILLS_SNAPSHOT_DST="$METADATA_DIR/skills"
KERNEL_DST="$CLAUDE_HOME/CLAUDE.md"
KERNEL_SNAPSHOT_DST="$METADATA_DIR/CLAUDE.md"
REFERENCES_DST="$METADATA_DIR/references"
TEMPLATES_DST="$METADATA_DIR/templates"
MANIFEST_DST="$METADATA_DIR/install.json"
MCP_CONFIG_DST="${B_AGENTIC_CLAUDE_MCP_JSON:-$HOME/.claude.json}"
SETTINGS_DST="${B_AGENTIC_CLAUDE_SETTINGS_JSON:-$CLAUDE_HOME/settings.json}"

DECLARATIVE_CONFIGS=(
	"mcpConfig|$MCP_CONFIG_DST|mcp.template.json|Claude Code MCP config"
	"permissionsConfig|$SETTINGS_DST|settings.template.json|Claude Code permissions"
)

claude_code_set_source_dirs() {
	TEMPLATES_SRC="$SOURCE_DIR/adapters/claude-code/configs"
	KERNEL_SRC="$SOURCE_DIR/references/kernel.claude-code.md"
}

claude_code_validate_source() {
	claude_code_set_source_dirs
	[ -f "$KERNEL_SRC" ] || die "missing rendered Claude Code kernel: $KERNEL_SRC"
	[ -d "$TEMPLATES_SRC" ] || die "missing Claude Code config directory: $TEMPLATES_SRC"
	[ -f "$TEMPLATES_SRC/mcp.template.json" ] || die "missing Claude Code MCP template: $TEMPLATES_SRC/mcp.template.json"
	[ -f "$TEMPLATES_SRC/settings.template.json" ] || die "missing Claude Code permissions template: $TEMPLATES_SRC/settings.template.json"
}

claude_code_install() {
	declarative_install_common
}

claude_code_sync() {
	declarative_sync_common
}

# Claude Code ships no managed packages or extensions, so an update is exactly
# a reinstall of the declarative assets.
claude_code_update() {
	declarative_install_common
}

claude_code_uninstall() {
	declarative_uninstall_common
}
