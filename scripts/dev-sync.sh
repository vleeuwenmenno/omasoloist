#!/bin/bash
# Development helper: copy this checkout into the Omarchy shell plugin
# directory. The shell's file watcher doesn't follow symlinks, so a copy is
# needed for hot reload.
set -euo pipefail

src="$(cd "$(dirname "$0")/.." && pwd)"
dest="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/vleeuwenmenno.omasoloist"

if [[ -L "$dest" || ( -e "$dest" && "$src" -ef "$dest" ) ]]; then
  echo "Destination is a symlink or this checkout; use make update instead." >&2
  exit 1
fi

mkdir -p "$dest"
rsync -a --delete --delay-updates --exclude .git --exclude __pycache__ --exclude /scripts/dev-sync.sh "$src/" "$dest/"
echo "Copied to $dest"
