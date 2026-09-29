#!/bin/bash
# Install Spotify Soloist (the official headless Spotify Connect client) as a
# systemd user service, the way the omasoloist Omarchy plugin expects it:
# WebSocket API enabled, data in ~/.local/share/soloist, unit soloist.service.
#
# What it writes (nothing outside $HOME, no sudo):
#   $PREFIX/soloist                            the Soloist binary (PREFIX defaults to ~/.local/bin)
#   ~/.config/soloist/api-key                  your Developer API key, mode 0600
#   ~/.local/libexec/soloist-service           wrapper that reads the key and execs soloist
#   ~/.config/systemd/user/soloist.service     the user unit
#
# Run with --help for options. See docs/install-soloist-systemd.md for the
# manual walkthrough of the same steps.
set -euo pipefail

BUILD_URL="https://soloist-builds.spotifycdn.com/soloist_release_%s.tar.gz"
API_KEY_URL="https://developer.spotify.com/dashboard/soloist"
UNIT_NAME="soloist.service"

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"

PREFIX="${PREFIX:-$HOME/.local/bin}"
LIBEXEC_DIR="$HOME/.local/libexec"
KEY_FILE="$XDG_CONFIG_HOME/soloist/api-key"
WRAPPER="$LIBEXEC_DIR/soloist-service"
UNIT_DIR="$XDG_CONFIG_HOME/systemd/user"
UNIT_FILE="$UNIT_DIR/$UNIT_NAME"
DATA_DIR="$XDG_DATA_HOME/soloist"

MODE="install"
FORCE=0
DRY_RUN=0
DEVICE_NAME="${SOLOIST_DEVICE_NAME:-}"

usage() {
  cat <<EOF
Usage: install-soloist.sh [options]

Installs Spotify Soloist as a systemd user service for the omasoloist plugin.

Modes (default: install):
  --update             Download the latest build, replace the binary, restart the service
  --uninstall          Stop and disable the service, remove the binary, wrapper and unit
                       (keeps the API key and the paired session in the data directory)

Options:
  --device-name NAME   Spotify Connect device name (default: this machine's hostname)
  --prefix DIR         Directory for the soloist binary (default: ~/.local/bin, or \$PREFIX)
  --force              Overwrite an existing API key file, wrapper or unit
  --dry-run            Print what would be done without changing anything
  -h, --help           Show this help

Environment:
  SOLOIST_API_KEY      Use this API key instead of prompting for it
  SOLOIST_DEVICE_NAME  Same as --device-name
  PREFIX               Same as --prefix

Get an API key at $API_KEY_URL (Spotify Premium required).
EOF
}

say() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Run a command, or only print it with --dry-run.
run() {
  if (( DRY_RUN )); then
    printf '    would run: %s\n' "$*"
  else
    "$@"
  fi
}

while (( $# > 0 )); do
  case "$1" in
    --update) MODE="update" ;;
    --uninstall) MODE="uninstall" ;;
    --device-name)
      [[ -n ${2:-} ]] || die "--device-name requires a value"
      DEVICE_NAME="$2"
      shift
      ;;
    --device-name=*) DEVICE_NAME="${1#*=}" ;;
    --prefix)
      [[ -n ${2:-} ]] || die "--prefix requires a directory"
      PREFIX="$2"
      shift
      ;;
    --prefix=*) PREFIX="${1#*=}" ;;
    --force) FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

PREFIX="${PREFIX%/}"
BINARY="$PREFIX/soloist"
[[ -n $DEVICE_NAME ]] || DEVICE_NAME="$(uname -n)"

need() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x86_64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7*|armv6l|armhf) echo "arm32" ;;
    *) die "unsupported architecture: $(uname -m) (Soloist ships x86_64, arm64 and arm32)" ;;
  esac
}

# Download the current build and install its `soloist` binary to $BINARY.
install_binary() {
  local arch url tmp found
  arch="$(detect_arch)"
  # shellcheck disable=SC2059 # BUILD_URL is our own format string
  url="$(printf "$BUILD_URL" "$arch")"
  say "Downloading Soloist for $arch"
  printf '    %s\n' "$url"
  if (( DRY_RUN )); then
    printf '    would install the soloist binary to %s\n' "$BINARY"
    return
  fi
  need curl
  need tar
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand $tmp now, the variable is local
  trap "rm -rf '$tmp'" EXIT
  curl -fL --proto '=https' --tlsv1.2 --retry 3 -o "$tmp/soloist.tar.gz" "$url"
  mkdir "$tmp/extract"
  tar -xzf "$tmp/soloist.tar.gz" -C "$tmp/extract"
  found="$(find "$tmp/extract" -type f -name soloist | head -n 1)"
  [[ -n $found ]] || die "no 'soloist' binary found in the downloaded archive"
  mkdir -p "$PREFIX"
  # Install next to the target, then rename: a running daemon keeps its old
  # inode and the swap is atomic.
  install -m 0755 "$found" "$BINARY.new"
  mv -f "$BINARY.new" "$BINARY"
  rm -rf "$tmp"
  trap - EXIT
  say "Installed $("$BINARY" --version 2>/dev/null || echo soloist) to $BINARY"
}

# True when $1 may be written: it does not exist yet, or --force was given.
may_write() {
  if [[ -e $1 && $FORCE -eq 0 ]]; then
    warn "$1 already exists; keeping it (use --force to overwrite)"
    return 1
  fi
  return 0
}

write_api_key() {
  local key="${SOLOIST_API_KEY:-}"
  may_write "$KEY_FILE" || return 0
  if (( DRY_RUN )); then
    printf '    would write the API key to %s (mode 0600)\n' "$KEY_FILE"
    return
  fi
  if [[ -z $key ]]; then
    [[ -t 0 ]] || die "no API key: set SOLOIST_API_KEY or run in a terminal"
    printf 'Soloist API key (from %s): ' "$API_KEY_URL"
    read -rs key
    printf '\n'
  fi
  # Strip surrounding whitespace from pasted keys.
  key="$(printf '%s' "$key" | tr -d '[:space:]')"
  [[ -n $key ]] || die "empty API key"
  mkdir -p "$(dirname "$KEY_FILE")"
  chmod 700 "$(dirname "$KEY_FILE")"
  (umask 077 && printf '%s\n' "$key" > "$KEY_FILE")
  chmod 600 "$KEY_FILE"
  say "Wrote API key to $KEY_FILE"
}

write_wrapper() {
  may_write "$WRAPPER" || return 0
  if (( DRY_RUN )); then
    printf '    would write the service wrapper to %s\n' "$WRAPPER"
    return
  fi
  mkdir -p "$LIBEXEC_DIR"
  {
    cat <<'EOF'
#!/bin/bash
# Starts Spotify Soloist for the soloist.service user unit. Written by
# omasoloist's scripts/install-soloist.sh. The API key is read from a
# private file so it never appears in the unit file.
set -euo pipefail

key_file="${XDG_CONFIG_HOME:-$HOME/.config}/soloist/api-key"
[[ -r $key_file ]] || { echo "soloist-service: missing API key file $key_file" >&2; exit 1; }
key="$(tr -d '[:space:]' < "$key_file")"
[[ -n $key ]] || { echo "soloist-service: API key file $key_file is empty" >&2; exit 1; }

EOF
    printf 'binary=%q\n' "$BINARY"
    printf 'device_name=%q\n' "$DEVICE_NAME"
    cat <<'EOF'

# --ws 127.0.0.1:0 enables the WebSocket API on an OS-assigned local port
# (written to <data-dir>/ws.port); the plugin and `soloist ctl` need it.
exec "$binary" \
  --device-name "$device_name" \
  --api-key "$key" \
  --data-dir "${XDG_DATA_HOME:-$HOME/.local/share}/soloist" \
  --ws 127.0.0.1:0
EOF
  } > "$WRAPPER"
  chmod 755 "$WRAPPER"
  say "Wrote wrapper to $WRAPPER (device name: $DEVICE_NAME)"
}

write_unit() {
  may_write "$UNIT_FILE" || return 0
  if (( DRY_RUN )); then
    printf '    would write the user unit to %s\n' "$UNIT_FILE"
    return
  fi
  mkdir -p "$UNIT_DIR"
  cat > "$UNIT_FILE" <<'EOF'
[Unit]
Description=Spotify Soloist (official headless Spotify Connect client)
Documentation=https://developer.spotify.com/documentation/soloist
Wants=sound.target network-online.target
After=sound.target network-online.target

[Service]
ExecStart=%h/.local/libexec/soloist-service
Restart=on-failure
RestartSec=12
# Exit code 10 means this Soloist build has expired (builds last 90 days).
# Restarting cannot fix that, so stop instead of looping; run
# `install-soloist.sh --update` to get a fresh build.
RestartPreventExitStatus=10

[Install]
WantedBy=default.target
EOF
  say "Wrote unit to $UNIT_FILE"
}

warn_path() {
  local on_path
  on_path="$(command -v soloist 2>/dev/null || true)"
  if [[ -z $on_path ]]; then
    warn "$PREFIX is not on your PATH; the plugin runs 'soloist ctl' and needs it there"
  elif [[ $on_path != "$BINARY" ]]; then
    warn "'soloist' on your PATH is $on_path, not $BINARY; the plugin will use that one"
  fi
}

print_pairing() {
  cat <<EOF

Soloist is running as "$DEVICE_NAME". To log in (one time only):
  1. Open Spotify on your phone, desktop or web player, on the same network.
  2. Open the device picker (Connect to a device) and choose "$DEVICE_NAME".
  3. Check: soloist ctl status   (should show "logged in: yes")

The session is stored in $DATA_DIR and restored on restart.
Logs: journalctl --user -u $UNIT_NAME -f
Soloist builds expire after 90 days; update with: $0 --update
EOF
}

do_install() {
  need systemctl
  if [[ -e $BINARY && $FORCE -eq 0 ]]; then
    say "Soloist binary already at $BINARY; keeping it (use --update or --force to replace)"
  else
    install_binary
  fi
  write_api_key
  write_wrapper
  write_unit
  say "Enabling and starting $UNIT_NAME"
  run systemctl --user daemon-reload
  run systemctl --user enable --now "$UNIT_NAME"
  # A rerun with --force rewrote the files; pick them up.
  if (( FORCE )); then run systemctl --user restart "$UNIT_NAME"; fi
  (( DRY_RUN )) || warn_path
  print_pairing
}

do_update() {
  need systemctl
  install_binary
  say "Restarting $UNIT_NAME"
  # try-restart only restarts a running unit; a unit stopped by an expired
  # build (exit 10) is failed, so reset and start it too.
  run systemctl --user reset-failed "$UNIT_NAME" 2>/dev/null || true
  if systemctl --user is-enabled --quiet "$UNIT_NAME" 2>/dev/null; then
    run systemctl --user restart "$UNIT_NAME"
  else
    warn "$UNIT_NAME is not enabled; run this script without --update to set it up"
  fi
}

do_uninstall() {
  need systemctl
  say "Stopping and disabling $UNIT_NAME"
  run systemctl --user disable --now "$UNIT_NAME" 2>/dev/null || true
  local file
  for file in "$UNIT_FILE" "$WRAPPER" "$BINARY"; do
    if [[ -e $file ]]; then
      say "Removing $file"
      run rm -f "$file"
    fi
  done
  run systemctl --user daemon-reload
  cat <<EOF

Kept (remove by hand if you no longer need them):
  $KEY_FILE   your API key
  $DATA_DIR   paired session and Soloist settings
EOF
}

(( DRY_RUN )) && say "Dry run: nothing will be changed"
case "$MODE" in
  install) do_install ;;
  update) do_update ;;
  uninstall) do_uninstall ;;
esac
