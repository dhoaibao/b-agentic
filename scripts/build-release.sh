#!/usr/bin/env bash
# build-release.sh - Build the checksum-verified b-agentic release bundle.
#
# Stages the release payload allowlist (the only paths install.sh reads when
# installing) and emits a gzipped tarball plus a SHA-256 checksum file:
#
#   scripts/build-release.sh [OUT_DIR]   # default: dist/
#
# The bundle never contains docs, tests, generators, validators, CI
# configuration, or dependency trees: no installed asset references them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
OUT_DIR="${1:-$ROOT/dist}"
OUT_DIR="${OUT_DIR%/}"
VERSION_FILE="$ROOT/VERSION"

fail() {
	printf 'build-release: %s\n' "$*" >&2
	exit 1
}

[ -f "$VERSION_FILE" ] || fail "missing VERSION"
VERSION="$(awk 'NF {print $1; exit}' "$VERSION_FILE")"
[ -n "$VERSION" ] || fail "VERSION is empty"
[ -f "$ROOT/install.sh" ] || fail "missing install.sh"
marker="$(sed -n '2p' "$ROOT/install.sh")"
[ "$marker" = "# B_AGENTIC_INSTALLER" ] || fail "install.sh line 2 must be the '# B_AGENTIC_INSTALLER' managed marker"
[ -d "$ROOT/skills" ] || fail "missing skills directory"
[ -d "$ROOT/references" ] || fail "missing references directory"
[ -f "$ROOT/adapters/pi/manifest.yaml" ] || fail "missing adapters/pi/manifest.yaml"
for payload_dir in configs extensions packages scripts; do
	[ -d "$ROOT/adapters/pi/$payload_dir" ] || fail "missing adapters/pi/$payload_dir directory"
done
for payload_file in common.sh json_cleanup.py jsonc.py manifest_uninstall.py; do
	[ -f "$ROOT/tooling/install/$payload_file" ] || fail "missing tooling/install/$payload_file"
done

mkdir -p "$OUT_DIR"
archive="$OUT_DIR/b-agentic.tar.gz"
checksum="$OUT_DIR/b-agentic.tar.gz.sha256"
tmp="$OUT_DIR/.b-agentic-build.$$"
rm -rf "$tmp"
mkdir "$tmp"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

# Stage only the release contract; the staged tree is what ships.
cp "$ROOT/install.sh" "$tmp/install.sh"
cp "$VERSION_FILE" "$tmp/VERSION"
cp -R "$ROOT/skills" "$tmp/skills"
cp -R "$ROOT/references" "$tmp/references"
mkdir -p "$tmp/adapters/pi" "$tmp/tooling/install"
cp "$ROOT/adapters/pi/manifest.yaml" "$tmp/adapters/pi/manifest.yaml"
for payload_dir in configs extensions packages scripts; do
	cp -R "$ROOT/adapters/pi/$payload_dir" "$tmp/adapters/pi/$payload_dir"
done
for payload_file in common.sh json_cleanup.py jsonc.py manifest_uninstall.py; do
	cp "$ROOT/tooling/install/$payload_file" "$tmp/tooling/install/$payload_file"
done

bad_member="$(find "$tmp" -type l -print -quit)"
[ -z "$bad_member" ] || fail "payload contains a symlink: $bad_member"
bad_member="$(find "$tmp" \( -name '__pycache__' -o -name 'node_modules' \) -print -quit)"
[ -z "$bad_member" ] || fail "payload contains generated or dependency trees: $bad_member"

tar -czf "$archive" -C "$tmp" install.sh VERSION skills references adapters tooling
# The checksum names the bare archive so the published .sha256 asset verifies
# in the directory where both release assets are downloaded together.
if command -v sha256sum >/dev/null 2>&1; then
	sha256sum "$archive" | awk '{print $1 "  b-agentic.tar.gz"}' >"$checksum"
elif command -v shasum >/dev/null 2>&1; then
	shasum -a 256 "$archive" | awk '{print $1 "  b-agentic.tar.gz"}' >"$checksum"
else
	fail "sha256sum or shasum is required"
fi
printf 'Built %s (version %s)\n' "$archive" "$VERSION"
