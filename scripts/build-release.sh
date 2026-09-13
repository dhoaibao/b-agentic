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
# Every adapter ships its manifest so the installer can gate a selection with
# an accurate shipped/deferred answer; only shipped adapters ship a payload.
adapter_manifests=("$ROOT"/adapters/*/manifest.yaml)
[ -e "${adapter_manifests[0]}" ] || fail "missing adapter manifests under adapters/"
for manifest in "${adapter_manifests[@]}"; do
	host="$(basename "$(dirname "$manifest")")"
	python3 - "$manifest" "$host" <<'PY' || fail "invalid adapter manifest: adapters/$host/manifest.yaml"
import json
import sys

manifest_path, host = sys.argv[1:3]
data = json.loads(open(manifest_path).read())
if data.get("host") != host:
    raise SystemExit(f"host {data.get('host')!r} does not match directory {host!r}")
if data.get("status") not in {"shipped", "deferred"}:
    raise SystemExit(f"unknown status {data.get('status')!r}")
if not isinstance(data.get("display_name"), str) or not data["display_name"]:
    raise SystemExit("missing display_name")
payload = data.get("payload")
if not isinstance(payload, list) or not all(isinstance(entry, str) for entry in payload):
    raise SystemExit("payload must be a list of strings")
if data.get("status") == "shipped" and not payload:
    raise SystemExit("a shipped adapter must declare a payload")
PY
	while IFS= read -r payload_dir; do
		[ -n "$payload_dir" ] || continue
		[ -d "$ROOT/adapters/$host/$payload_dir" ] || fail "missing adapters/$host/$payload_dir directory"
	done < <(python3 -c 'import json,sys;print("\n".join(json.load(open(sys.argv[1]))["payload"]))' "$manifest")
done
for payload_file in adapters.sh common.sh json_cleanup.py jsonc.py manifest_uninstall.py toml_block.py; do
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
mkdir -p "$tmp/adapters" "$tmp/tooling/install"
for manifest in "${adapter_manifests[@]}"; do
	host="$(basename "$(dirname "$manifest")")"
	mkdir -p "$tmp/adapters/$host"
	cp "$manifest" "$tmp/adapters/$host/manifest.yaml"
	while IFS= read -r payload_dir; do
		[ -n "$payload_dir" ] || continue
		cp -R "$ROOT/adapters/$host/$payload_dir" "$tmp/adapters/$host/$payload_dir"
	done < <(python3 -c 'import json,sys;print("\n".join(json.load(open(sys.argv[1]))["payload"]))' "$manifest")
done
for payload_file in adapters.sh common.sh json_cleanup.py jsonc.py manifest_uninstall.py toml_block.py; do
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
