# Installing Spotify Soloist as a systemd user service

The omasoloist plugin controls [Spotify Soloist](https://developer.spotify.com/documentation/soloist),
Spotify's official headless Spotify Connect client. Soloist has to run in the
background with its WebSocket API enabled. This guide sets it up as a systemd
user service called `soloist.service`, which is what the plugin expects by
default.

OmaSoloist does not install Soloist for you. Soloist is Spotify's software,
downloaded from Spotify, so you set it up yourself with the steps below and
stay in control of which build you run.

## Prerequisites

- **Spotify Premium.** Soloist does not work with free accounts.
- **A Soloist Developer API key.** Sign in at the
  [Spotify Developer Dashboard](https://developer.spotify.com/dashboard) and
  open **Spotify Soloist API Key**
  ([developer.spotify.com/dashboard/soloist](https://developer.spotify.com/dashboard/soloist)).
  This key is separate from the Web API app Client ID used for the plugin's
  library and search features.
- **PipeWire or another sound server** running in your user session (Omarchy
  ships PipeWire).
- `curl`, `tar` and `sha256sum`.

## 1. Download the binary

Soloist is distributed as a tarball per architecture:

| Machine (`uname -m`) | Archive |
|----------------------|---------|
| `x86_64`             | `soloist_release_x86_64.tar.gz` |
| `aarch64`            | `soloist_release_arm64.tar.gz` |
| `armv7l`             | `soloist_release_arm32.tar.gz` |

The archive contains the `soloist` binary plus a changelog and license file.
Install the binary to `~/.local/bin` (on Omarchy this directory is already on
your `PATH`, which matters: the plugin runs `soloist ctl` from `PATH`):

```bash
arch=x86_64   # or arm64 / arm32
tmp=$(mktemp -d)
curl -fL --proto '=https' --tlsv1.2 -o "$tmp/soloist.tar.gz" \
  "https://soloist-builds.spotifycdn.com/soloist_release_$arch.tar.gz"
tar -xzf "$tmp/soloist.tar.gz" -C "$tmp"
```

### Check what you downloaded

Spotify publishes one moving "latest" archive per architecture, with no
versioned download links and no checksum files, so there is nothing
official to compare against. Before installing, look at what you got and
keep a record:

```bash
"$tmp/soloist" --version          # e.g. soloist 1.3.8.51 build … (20260918) …
sha256sum "$tmp/soloist.tar.gz" "$tmp/soloist"
```

The version line includes the build date; a build older than about 90 days
won't start (see [Updating](#updating)). Save the version and checksums
somewhere if you want to tell later whether the binary changed:

```bash
mkdir -p ~/.local/share/soloist
{ date -u +%FT%TZ; "$tmp/soloist" --version; sha256sum "$tmp/soloist.tar.gz" "$tmp/soloist"; } \
  >> ~/.local/share/soloist/installed-builds.log
```

Then install it and clean up:

```bash
install -Dm755 "$tmp/soloist" ~/.local/bin/soloist
rm -rf "$tmp"
soloist --version
```

## 2. Store the API key

Soloist needs the key on every start (`-k/--api-key`). Keep it in a private
file instead of the unit file:

```bash
mkdir -p ~/.config/soloist
chmod 700 ~/.config/soloist
read -rsp 'Soloist API key: ' key && echo
(umask 077 && printf '%s\n' "$key" > ~/.config/soloist/api-key)
unset key
```

## 3. Create the wrapper script

The unit starts this wrapper, which reads the key and replaces itself with
Soloist. Save it as `~/.local/libexec/soloist-service`:

```bash
#!/bin/bash
set -euo pipefail

key_file="${XDG_CONFIG_HOME:-$HOME/.config}/soloist/api-key"
key="$(tr -d '[:space:]' < "$key_file")"

exec "$HOME/.local/bin/soloist" \
  --device-name "$(uname -n)" \
  --api-key "$key" \
  --data-dir "${XDG_DATA_HOME:-$HOME/.local/share}/soloist" \
  --ws 127.0.0.1:0
```

```bash
chmod 755 ~/.local/libexec/soloist-service
```

About the flags:

- `--device-name` is the name you see in Spotify's device picker. Change it to
  anything you like.
- `--data-dir` is set explicitly. Without it, systemd's `$STATE_DIRECTORY`
  (if you add `StateDirectory=` to the unit) would take priority, and the
  plugin looks in `~/.local/share/soloist` by default.
- `--ws 127.0.0.1:0` enables the WebSocket API on a local, OS-assigned port.
  Soloist writes the port to `<data-dir>/ws.port`, and `soloist ctl` and the
  plugin find it there. **The plugin does not work without it.**

Other useful options (see `soloist --help`): `--pipewire-device <node>` to
route audio to one PipeWire sink, `--initial-volume <0-100>` (default 40),
`--cache-size <MB>`, `--verbose`.

### Where the API key is visible

Soloist only accepts the key as a command-line argument (`-k/--api-key`);
it has no environment variable or key-file option. So while it runs, the key
is part of its process arguments:

- **Your own programs** can read it, but they can read the key file too, so
  that adds nothing.
- **Other user accounts on the same machine** can see process arguments in
  `/proc` by default. On a single-user laptop that's nobody. On a shared
  machine, hide other users' processes by mounting `/proc` with
  `hidepid=invisible`, for example with this line in `/etc/fstab`
  (needs root, takes effect after a reboot or remount):

  ```
  proc  /proc  proc  defaults,hidepid=invisible  0  0
  ```

The key only lets a Soloist device sign in with your developer account.
If it leaks, revoke it on the
[Soloist API Key](https://developer.spotify.com/dashboard/soloist) page and
put the new one in `~/.config/soloist/api-key`.

## 4. Create the user unit

Save as `~/.config/systemd/user/soloist.service`:

```ini
[Unit]
Description=Spotify Soloist (official headless Spotify Connect client)
Documentation=https://developer.spotify.com/documentation/soloist
Wants=sound.target network-online.target
After=sound.target network-online.target

[Service]
ExecStart=%h/.local/libexec/soloist-service
Restart=on-failure
RestartSec=12
# Exit code 10 = this build has expired. Restarting won't help.
RestartPreventExitStatus=10

[Install]
WantedBy=default.target
```

`RestartPreventExitStatus=10` stops systemd from restarting an expired build
every 12 seconds forever (see [Updating](#updating)).

## 5. Enable and start

```bash
systemctl --user daemon-reload
systemctl --user enable --now soloist.service
```

## 6. Pair (log in)

Soloist has no username or password. You log it in from another Spotify app,
once:

1. Open Spotify on your phone, desktop or the web player, on the same network.
2. Open the device picker (**Connect to a device**).
3. Pick the device named after your machine (or your `--device-name`).

The session is saved in the data directory and restored on every restart. To
pair again later (for example with a different account), stop the service
and run `soloist --pair` with the same `--device-name`, `--api-key` and
`--data-dir` flags, then start the service again.

## 7. Verify

```bash
soloist ctl status
```

Expected output looks like:

```
soloist: running (pid 12345)
  ws: listening on 127.0.0.1:36121
  logged in: yes
  active device: yes
```

`soloist ctl now` shows the current track; `soloist ctl --help` lists the
other control commands.

## Updating

**Soloist builds expire 90 days after their build date.** An expired build
exits with code 10 and the service stops. Update by repeating step 1
(download, check, install over the old binary) and restarting:

```bash
systemctl --user restart soloist.service
```

A reminder in your calendar every couple of months saves a surprise.

## Uninstalling

```bash
systemctl --user disable --now soloist.service
rm ~/.config/systemd/user/soloist.service ~/.local/libexec/soloist-service ~/.local/bin/soloist
systemctl --user daemon-reload
```

The API key (`~/.config/soloist/api-key`) and the session
(`~/.local/share/soloist`) are left in place; remove them if you want.

## Troubleshooting

Start with the logs:

```bash
journalctl --user -u soloist.service -f
systemctl --user status soloist.service
```

**`logged in: no`.** The daemon runs but has not been paired, or the stored
session was lost. Pick the device in a Spotify app's device picker (step 6).
If it does not appear, check that the other device is on the same network
and that the service is running.

**API key rejected.** Check the key file contains only the key
(`wc -c ~/.config/soloist/api-key`), that it is the key from the *Soloist API
Key* dashboard page (not a Web API Client ID), and that the account behind it
has Premium.

**Service stopped with exit code 10.** The build expired. See
[Updating](#updating). Afterwards `systemctl --user reset-failed soloist.service`
clears the failed state if needed.

**Plugin stays on "Connecting…" while the service is running.** The
WebSocket API is probably not enabled. `soloist ctl status` should show a `ws:` line;
if it doesn't, add `--ws 127.0.0.1:0` to the wrapper and restart. Also check
that Soloist and the plugin use the same data directory: the plugin reads
`~/.local/share/soloist` unless you set `dataDir` in its `shell.json` entry.

**Plugin shows "Set up Soloist".** Either the shell cannot find `soloist` on
its `PATH`, or systemd does not know the unit. Check with
`systemctl --user status soloist.service`. Put the binary in `~/.local/bin`
(or another directory on the shell's `PATH`) and run `omarchy restart shell`.

**Different unit name.** If your unit is not called `soloist.service`, set
`serviceName` in the plugin's `shell.json` entry.

**No sound, or sound on the wrong output.** Soloist plays through your user
session's sound server, so the unit must run as your user (it does, with
`systemctl --user`). Check it shows up with `wpctl status` while playing. To
pin it to one output, find the sink's node name or ID in `wpctl status` and add
`--pipewire-device <node>` to the wrapper. `omarchy restart audio` helps when
PipeWire itself is stuck.
