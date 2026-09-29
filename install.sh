#!/bin/bash
# Copy the plugin into the Omarchy shell plugin directory. The shell's file
# watcher does not follow symlinks, so a copy is needed for hot reload.
set -euo pipefail

src="$(cd "$(dirname "$0")" && pwd)"
dest="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/vleeuwenmenno.omasoloist"

mkdir -p "$dest"
rsync -a --delete --delay-updates --exclude .git --exclude install.sh --exclude __pycache__ "$src/" "$dest/"
echo "Installed to $dest"
