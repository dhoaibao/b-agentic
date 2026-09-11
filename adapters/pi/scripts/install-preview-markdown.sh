#!/usr/bin/env bash
set -euo pipefail

readonly REPOSITORY="dhoaibao/b-agentic"
readonly SOURCE_PATH="adapters/pi/packages/preview-markdown/extensions/b-agentic-preview-markdown.ts"

if [ "$#" -ne 1 ]; then
	printf 'usage: %s vX.Y.Z\n' "${BASH_SOURCE[0]}" >&2
	exit 1
fi

VERSION="$1"
if [[ ! "$VERSION" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
	printf 'error: invalid version ref %s; expected vX.Y.Z\n' "$VERSION" >&2
	exit 1
fi
readonly VERSION
readonly SOURCE_URL="https://raw.githubusercontent.com/${REPOSITORY}/${VERSION}/${SOURCE_PATH}"

if [ -z "${HOME:-}" ]; then
	printf '%s\n' 'error: HOME must be set' >&2
	exit 1
fi

require_command() {
	command -v "$1" >/dev/null 2>&1 || {
		printf 'error: required command not found: %s\n' "$1" >&2
		exit 1
	}
}

for command in curl grep install mktemp mv; do
	require_command "$command"
done

readonly PI_AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
readonly EXTENSIONS_DIR="$PI_AGENT_DIR/extensions"
readonly TARGET_PATH="$EXTENSIONS_DIR/b-agentic-preview-markdown.ts"

tmp_download=""
tmp_install=""
cleanup() {
	[ -z "$tmp_download" ] || rm -f "$tmp_download"
	[ -z "$tmp_install" ] || rm -f "$tmp_install"
}
trap cleanup EXIT

tmp_download="$(mktemp "${TMPDIR:-/tmp}/b-agentic-preview-markdown.download.XXXXXX")"
printf 'Downloading the version-pinned Markdown preview extension...\n' >&2
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
	--output "$tmp_download" "$SOURCE_URL"

if [ ! -s "$tmp_download" ] || \
	! grep -Fq 'name: "preview_markdown"' "$tmp_download" || \
	! grep -Fq 'registerShortcut("ctrl+shift+m"' "$tmp_download" || \
	! grep -Fq 'export default function' "$tmp_download"; then
	printf 'error: downloaded file failed the Markdown preview extension validation\n' >&2
	exit 1
fi

mkdir -p "$EXTENSIONS_DIR"
tmp_install="$(mktemp "$EXTENSIONS_DIR/.b-agentic-preview-markdown.ts.XXXXXX")"
install -m 0644 "$tmp_download" "$tmp_install"
mv -f "$tmp_install" "$TARGET_PATH"
tmp_install=""

printf 'Installed %s from %s\n' "$TARGET_PATH" "$SOURCE_URL"
printf '%s\n' 'Run /reload in your current Pi session to load the extension.'
printf '%s\n' 'No AGENTS.md change is required: the extension self-registers its tool and prompt metadata.'
printf '%s\n' 'Optional: add a local AGENTS.md note if you want to remind future sessions to use preview_markdown.'
