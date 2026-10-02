#!/bin/bash
# Link this checkout into the user's Omarchy plugins, preserving any install.
set -euo pipefail

src="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
config="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy"
plugin_id="vleeuwenmenno.omasoloist"
dest="$config/plugins/$plugin_id"

if [[ -L "$dest" && "$(readlink -f -- "$dest")" == "$src" ]]; then
  printf 'Already linked: %s -> %s\n' "$dest" "$src"
  exit 0
fi

# Moving a checkout that is already installed in place would break its path.
if [[ -e "$dest" && "$(realpath -- "$dest")" == "$src" ]]; then
  printf 'Checkout already lives at %s; clone elsewhere before linking.\n' "$dest" >&2
  exit 1
fi

mkdir -p -- "$(dirname -- "$dest")"
backup=""
if [[ -e "$dest" || -L "$dest" ]]; then
  backup_root="$config/plugin-backups"
  mkdir -p -- "$backup_root"
  backup="$(mktemp -d -- "$backup_root/$plugin_id.$(date +%Y%m%d-%H%M%S).XXXXXX")"
  mv -T -- "$dest" "$backup/$plugin_id"
  printf 'Previous install parked at %s\n' "$backup/$plugin_id"
fi

if ! ln -sT -- "$src" "$dest"; then
  if [[ -n "$backup" ]]; then
    mv -T -- "$backup/$plugin_id" "$dest"
    rmdir -- "$backup"
  fi
  exit 1
fi
printf 'Linked: %s -> %s\n' "$dest" "$src"
