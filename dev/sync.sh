#!/bin/bash

# Development sync: copy this checkout into the Omarchy plugins folder
# (the shell rejects symlinked plugins) and enable it in the bar.
#
#   dev/sync.sh            copy + enable
#   dev/sync.sh --copy     copy only (run `omarchy restart shell` after QML changes)

set -euo pipefail

cd "$(dirname "$0")/.."
ID=$(jq -r .id manifest.json)
TARGET="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$ID"

omarchy plugin validate .

mkdir -p "$TARGET"
rsync -a --delete \
  --exclude .git --exclude tests --exclude dev --exclude .gitignore \
  ./ "$TARGET/"
echo "Copied to $TARGET"

if [[ ${1:-} != --copy ]]; then
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  omarchy plugin enable "$ID"
fi
