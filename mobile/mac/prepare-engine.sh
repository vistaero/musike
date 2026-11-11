#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
node_bin="${MUSIKE_NODE:-$(command -v node || true)}"
if [ -z "$node_bin" ] || ! "$node_bin" --version >/dev/null 2>&1 || [ ! -f "$root/web/node_modules/vite/bin/vite.js" ]; then
  echo "error: Install Node.js and the workspace dependencies before building Musike for Mac." >&2
  exit 1
fi
cd "$root/web"
"$node_bin" node_modules/vite/bin/vite.js build --mode mac
destination="$root/mobile/mac/App/Mac/public"
rm -rf "$destination"
mkdir -p "$destination"
cp -R dist-mac/. "$destination/"
