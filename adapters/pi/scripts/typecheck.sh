#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
pi_dir=$(cd -- "$script_dir/.." && pwd)
tsc="$pi_dir/node_modules/.bin/tsc"

if [[ ! -x "$tsc" || ! -d "$pi_dir/node_modules/@earendil-works/pi-coding-agent" || ! -d "$pi_dir/node_modules/@types/node" ]]; then
  echo "TypeScript check skipped: install pi dependencies with 'npm install --prefix pi'." >&2
else
  "$tsc" --noEmit --project "$pi_dir/tsconfig.json"
fi

bash "$script_dir/typecheck-preview-markdown.sh"
