#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
pi_dir=$(cd -- "$script_dir/.." && pwd)
package_dir="$pi_dir/packages/preview-markdown"
tsc="$pi_dir/node_modules/.bin/tsc"

if [[ ! -x "$tsc" || ! -d "$pi_dir/node_modules/@earendil-works/pi-coding-agent" || ! -d "$pi_dir/node_modules/@earendil-works/pi-tui" ]]; then
  echo "Preview Markdown TypeScript check skipped: install pi dependencies with 'npm install --prefix pi'." >&2
  exit 0
fi

exec "$tsc" --noEmit --project "$package_dir/tsconfig.json"
