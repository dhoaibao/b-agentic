#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/adapters/pi/packages/preview-markdown"
cd "$PACKAGE_DIR"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/b-agentic-preview-package.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

node - "$PACKAGE_DIR/package.json" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const packagePath = process.argv[2];
const manifest = JSON.parse(fs.readFileSync(packagePath, "utf8"));
const expectedExtension = "./extensions/b-agentic-preview-markdown.ts";
const errors = [];

if (manifest.name !== "@dhoaibao/preview-markdown") errors.push("package name must be @dhoaibao/preview-markdown");
if (manifest.publishConfig?.access !== "public") errors.push("publishConfig.access must be public");
if (manifest.repository?.url !== "git+https://github.com/dhoaibao/b-agentic.git") errors.push("repository.url must use the canonical git+https URL");
if (manifest.keywords?.includes("pi-package") !== true) errors.push("keywords must include pi-package");
if (manifest.repository?.directory !== "adapters/pi/packages/preview-markdown") errors.push("repository.directory must identify the package root");
if (JSON.stringify(manifest.pi?.extensions) !== JSON.stringify([expectedExtension])) {
  errors.push("pi.extensions must contain only the canonical preview extension");
}
for (const dependency of ["@earendil-works/pi-coding-agent", "@earendil-works/pi-tui"]) {
  if (manifest.peerDependencies?.[dependency] !== "*") {
    errors.push(`${dependency} must be a * peerDependency`);
  }
}
if (manifest.dependencies && Object.keys(manifest.dependencies).length > 0) {
  errors.push("package must not bundle runtime dependencies");
}
for (const relativePath of ["README.md", "extensions/b-agentic-preview-markdown.ts"]) {
  if (!fs.existsSync(path.join(path.dirname(packagePath), relativePath))) {
    errors.push(`missing package source ${relativePath}`);
  }
}
if (errors.length > 0) {
  console.error(errors.join("\n"));
  process.exit(1);
}
NODE

PACK_JSON="$(npm pack --ignore-scripts --json --pack-destination "$WORK_DIR")"
TARBALL_NAME="$(node -e 'process.stdout.write(JSON.parse(process.argv[1])[0].filename)' "$PACK_JSON")"
TARBALL_PATH="$WORK_DIR/$TARBALL_NAME"

if [[ ! -f "$TARBALL_PATH" ]]; then
  echo "npm pack did not produce $TARBALL_NAME" >&2
  exit 1
fi

tar -tzf "$TARBALL_PATH" | LC_ALL=C sort > "$WORK_DIR/entries.txt"
cat > "$WORK_DIR/expected.txt" <<'EOF'
package/README.md
package/extensions/b-agentic-preview-markdown.ts
package/package.json
EOF

if ! diff -u "$WORK_DIR/expected.txt" "$WORK_DIR/entries.txt"; then
  echo "npm tarball contains unexpected or missing files" >&2
  exit 1
fi

tar -xOf "$TARBALL_PATH" package/package.json > "$WORK_DIR/packed-package.json"
# Compare the packed manifest and verify that its Pi source path is present.
PACKAGE_ENTRIES="$WORK_DIR/entries.txt" node - "$PACKAGE_DIR/package.json" "$WORK_DIR/packed-package.json" <<'NODE'
const fs = require("node:fs");

const source = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const packed = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
if (JSON.stringify(source) !== JSON.stringify(packed)) {
  console.error("packed package.json does not match the source manifest");
  process.exit(1);
}
const extension = packed.pi?.extensions?.[0];
const archivePath = `package/${extension?.replace(/^\.\//, "") ?? ""}`;
const entries = fs.readFileSync(process.env.PACKAGE_ENTRIES, "utf8").split("\n");
if (packed.pi?.extensions?.length !== 1 || !entries.includes(archivePath)) {
  console.error("packed Pi manifest does not discover the canonical extension source");
  process.exit(1);
}
NODE

printf 'Preview Markdown npm package validation passed.\n'
