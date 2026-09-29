#!/bin/bash
# Development helper: copy this checkout into the Omarchy shell plugin
# directory. The shell's file watcher doesn't follow symlinks, so a copy is
# needed for hot reload.
set -euo pipefail

src="$(cd "$(dirname "$0")/.." && pwd)"
dest="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/vleeuwenmenno.omasoloist"

mkdir -p "$dest"
rsync -a --delete --delay-updates --exclude .git --exclude __pycache__ --exclude /scripts/dev-sync.sh "$src/" "$dest/"
echo "Copied to $dest"
