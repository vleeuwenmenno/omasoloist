#!/usr/bin/env python3
"""Spotify Web API helper for the omasoloist bar widget.

Every command prints one JSON object on stdout: {"ok": true, ...} on success
or {"ok": false, "error": "..."} on failure. The widget runs one process per
call, so the helper keeps no state besides the files below.

  ~/.config/omasoloist/config.json   {"clientId": "..."}          (user edited)
  ~/.local/state/omasoloist/token.json  OAuth tokens, mode 0600   (written here)

Login uses the Authorization Code flow with PKCE, so no client secret is
needed or stored.
"""

import base64
import fcntl
import hashlib
import http.server
import json
import os
import re
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

REDIRECT_HOST = "127.0.0.1"
REDIRECT_PORT = 8898
REDIRECT_URI = f"http://{REDIRECT_HOST}:{REDIRECT_PORT}/callback"
AUTH_URL = "https://accounts.spotify.com/authorize"
TOKEN_URL = "https://accounts.spotify.com/api/token"
API_URL = "https://api.spotify.com/v1"
SCOPES = " ".join([
    "user-read-private",
    "user-library-read",
    "user-library-modify",
    "playlist-read-private",
    "playlist-read-collaborative",
    "playlist-modify-private",
    "playlist-modify-public",
    "user-read-playback-state",
    "user-modify-playback-state",
    "user-read-currently-playing",
    "user-read-recently-played",
    "user-top-read",
    "user-follow-read",
    "user-follow-modify",
])
LOGIN_TIMEOUT = 300
PAGE_SIZE = 50

HOME = os.path.expanduser("~")
USER_AGENT = "omasoloist/0.2 (https://github.com/vleeuwenmenno/omasoloist)"
CONFIG_DIR = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config"), "omasoloist")
CACHE_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.join(HOME, ".cache"), "omasoloist")
STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local", "state"), "omasoloist")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")
TOKEN_FILE = os.path.join(STATE_DIR, "token.json")


class HelperError(Exception):
    pass


def read_json(path, fallback):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return fallback


def write_private_json(path, data):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle)
    os.replace(tmp, path)


def client_id():
    value = str(read_json(CONFIG_FILE, {}).get("clientId") or "").strip()
    if not value:
        raise HelperError(f"No Spotify client ID. Add {{\"clientId\": \"...\"}} to {CONFIG_FILE}.")
    return value


def post_form(url, fields):
    body = urllib.parse.urlencode(fields).encode()
    request = urllib.request.Request(url, data=body, headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise HelperError(f"Token request failed ({error.code}): {detail}") from None
    except urllib.error.URLError as error:
        raise HelperError(f"Could not reach Spotify: {error.reason}") from None


def store_token(payload, previous=None):
    token = {
        "access_token": payload["access_token"],
        # Spotify may omit a new refresh token on refresh; keep the old one.
        "refresh_token": payload.get("refresh_token") or (previous or {}).get("refresh_token"),
        "expires_at": time.time() + int(payload.get("expires_in", 3600)) - 60,
        "scope": payload.get("scope", ""),
    }
    write_private_json(TOKEN_FILE, token)
    return token


def access_token():
    token = read_json(TOKEN_FILE, None)
    if not token or not token.get("refresh_token"):
        raise HelperError("Not signed in to Spotify.")
    if time.time() < token.get("expires_at", 0):
        return token["access_token"]
    # The widget starts several helpers at once. Spotify rotates the refresh
    # token on every refresh, so only one process may refresh; the others
    # wait on the lock and then use the token it stored.
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    with open(TOKEN_FILE + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        token = read_json(TOKEN_FILE, None) or token
        if time.time() < token.get("expires_at", 0):
            return token["access_token"]
        payload = post_form(TOKEN_URL, {
            "grant_type": "refresh_token",
            "refresh_token": token["refresh_token"],
            "client_id": client_id(),
        })
        return store_token(payload, token)["access_token"]


# GET responses cached on disk, by path prefix (seconds). Anything about live
# playback (/me/player, /me/library/contains) is never cached. Set
# OMASOLOIST_FRESH=1 to bypass reads.
API_CACHE = [
    ("/me/player", 0),
    ("/me/library", 0),
    ("/me/playlists", 300),
    ("/me/tracks", 300),
    ("/me/top/", 6 * 3600),
    ("/me", 3600),
    ("/playlists/", 300),
    ("/albums", 7 * 86400),
    ("/artists", 86400),
    ("/search", 3600),
    ("/tracks/", 7 * 86400),
]


def api_cache_slot(method, path, url):
    if method != "GET" or path.startswith("https://"):
        return None, 0
    for prefix, ttl in API_CACHE:
        if path.startswith(prefix):
            if not ttl:
                return None, 0
            group = prefix.strip("/").replace("/", "_") or "root"
            name = hashlib.sha1(url.encode()).hexdigest() + ".json"
            return os.path.join(CACHE_DIR, "api", group, name), ttl
    return None, 0


def forget_cached(prefix):
    """Drop cached responses for one API_CACHE prefix, e.g. after a like."""
    group = os.path.join(CACHE_DIR, "api", prefix.strip("/").replace("/", "_") or "root")
    for name in os.listdir(group) if os.path.isdir(group) else []:
        try:
            os.remove(os.path.join(group, name))
        except OSError:
            pass


def api(method, path, params=None, body=None, retry=True):
    url = path if path.startswith("https://") else API_URL + path
    if params:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
    slot, ttl = api_cache_slot(method, path, url)
    if slot and not os.environ.get("OMASOLOIST_FRESH"):
        try:
            if time.time() - os.path.getmtime(slot) < ttl:
                with open(slot, encoding="utf-8") as handle:
                    return json.load(handle)
        except (OSError, ValueError):
            pass
    result = api_request(method, path, url, params, body, retry)
    if slot:
        try:
            os.makedirs(os.path.dirname(slot), exist_ok=True)
            with open(slot + ".tmp", "w", encoding="utf-8") as handle:
                json.dump(result, handle)
            os.replace(slot + ".tmp", slot)
        except OSError:
            pass
    return result


def api_request(method, path, url, params, body, retry):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Authorization": "Bearer " + access_token()}
    if data is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            raw = response.read()
            # Player commands answer with an opaque text token, not JSON.
            try:
                return json.loads(raw) if raw else {}
            except ValueError:
                return {}
    except urllib.error.HTTPError as error:
        if error.code == 429 and retry:
            time.sleep(min(int(error.headers.get("Retry-After", "1")), 5))
            return api_request(method, path, url, params, body, retry=False)
        detail = error.read().decode(errors="replace")
        try:
            detail = json.loads(detail)["error"]["message"]
        except (ValueError, KeyError, TypeError):
            pass
        raise HelperError(f"Spotify API {method} {path} failed ({error.code}): {detail}") from None
    except urllib.error.URLError as error:
        raise HelperError(f"Could not reach Spotify: {error.reason}") from None


# ------------------------------------------------------------------ shaping

# Artwork is cached on disk too. pick_image hands out a file:// URL when the
# image is already cached; otherwise it returns the CDN URL and queues the
# image for a detached background download (fetch-images), so the next time
# the widget asks, it gets the local copy.
IMAGE_DIR = os.path.join(CACHE_DIR, "images")
IMAGE_QUEUE = []
IMAGE_MAX_AGE = 60 * 86400


def local_image(url):
    if not url or not url.startswith("https://"):
        return url
    path = os.path.join(IMAGE_DIR, hashlib.sha1(url.encode()).hexdigest())
    if os.path.exists(path):
        return "file://" + path
    IMAGE_QUEUE.append(url)
    return url


def pick_image(images, preferred=300):
    images = [i for i in (images or []) if i and i.get("url")]
    if not images:
        return ""
    # Smallest image at least `preferred` wide, else the largest available.
    sized = sorted(images, key=lambda i: i.get("width") or 0)
    for image in sized:
        if (image.get("width") or 0) >= preferred:
            return local_image(image["url"])
    return local_image(sized[-1]["url"])


def cmd_fetch_images(args):
    """fetch-images <url>...  — download artwork into the cache (runs detached)."""
    os.makedirs(IMAGE_DIR, exist_ok=True)
    fetched = 0
    for url in dict.fromkeys(args):
        if not url.startswith("https://"):
            continue
        path = os.path.join(IMAGE_DIR, hashlib.sha1(url.encode()).hexdigest())
        if os.path.exists(path):
            continue
        try:
            request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(request, timeout=20) as response:
                data = response.read()
        except (urllib.error.URLError, OSError):
            continue
        with open(path + ".tmp", "wb") as handle:
            handle.write(data)
        os.replace(path + ".tmp", path)
        fetched += 1
    # Prune artwork nobody asked for in a while.
    cutoff = time.time() - IMAGE_MAX_AGE
    for name in os.listdir(IMAGE_DIR):
        full = os.path.join(IMAGE_DIR, name)
        try:
            if os.path.getatime(full) < cutoff and os.path.getmtime(full) < cutoff:
                os.remove(full)
        except OSError:
            pass
    return {"fetched": fetched}


def flush_image_queue():
    if not IMAGE_QUEUE:
        return
    urls = list(dict.fromkeys(IMAGE_QUEUE))[:200]
    subprocess.Popen([sys.executable, "-I", os.path.abspath(__file__), "fetch-images"] + urls,
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)


def shape_track(track, added_at=None):
    if not track or not track.get("uri"):
        return None
    album = track.get("album") or {}
    return {
        "uri": track["uri"],
        "name": track.get("name") or "",
        "artists": ", ".join(a.get("name", "") for a in track.get("artists") or [] if a),
        "album": album.get("name") or "",
        "cover": pick_image(album.get("images"), 64),
        "cover_large": pick_image(album.get("images"), 300),
        "album_uri": album.get("uri") or "",
        "release_date": album.get("release_date") or "",
        "artist_uri": ((track.get("artists") or [{}])[0] or {}).get("uri") or "",
        "duration_ms": track.get("duration_ms") or 0,
        "explicit": bool(track.get("explicit")),
        "playable": track.get("is_playable", True) is not False,
        "added_at": added_at or "",
    }


def page(items, total, offset):
    return {"items": items, "total": total, "offset": offset, "next": offset + len(items) < total}


# ------------------------------------------------------------------ commands

def cmd_status(_args):
    config = read_json(CONFIG_FILE, {})
    token = read_json(TOKEN_FILE, None)
    granted = set(((token or {}).get("scope") or "").split())
    return {
        "hasClientId": bool(str(config.get("clientId") or "").strip()),
        "signedIn": bool(token and token.get("refresh_token")),
        # Scopes added in later versions need one more sign-in.
        "missingScopes": sorted(set(SCOPES.split()) - granted) if token else [],
        "configFile": CONFIG_FILE,
        "redirectUri": REDIRECT_URI,
    }


def cmd_set_client_id(args):
    if not args or not args[0].strip():
        raise HelperError("Usage: set-client-id <client id>")
    config = read_json(CONFIG_FILE, {})
    config["clientId"] = args[0].strip()
    os.makedirs(CONFIG_DIR, exist_ok=True)
    with open(CONFIG_FILE, "w", encoding="utf-8") as handle:
        json.dump(config, handle, indent=2)
        handle.write("\n")
    return cmd_status([])


def cmd_login(_args):
    cid = client_id()
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(16)
    result = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            url = urllib.parse.urlparse(self.path)
            if url.path != "/callback":
                self.send_response(404)
                self.end_headers()
                return
            query = urllib.parse.parse_qs(url.query)
            if query.get("state", [""])[0] != state:
                result["error"] = "Login state mismatch; try again."
            elif "error" in query:
                result["error"] = "Spotify login refused: " + query["error"][0]
            else:
                result["code"] = query.get("code", [""])[0]
            ok = "code" in result
            message = ("Signed in to Spotify. You can close this tab." if ok
                       else result.get("error", "Login failed."))
            self.send_response(200 if ok else 400)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(("<!doctype html><meta charset=utf-8><title>omasoloist</title>"
                              "<body style='font:16px system-ui;background:#121212;color:#fff;"
                              "display:grid;place-items:center;height:100vh;margin:0'>"
                              f"<p>{message}</p>").encode())

    try:
        server = http.server.HTTPServer((REDIRECT_HOST, REDIRECT_PORT), Handler)
    except OSError as error:
        raise HelperError(f"Could not listen on {REDIRECT_URI}: {error.strerror}") from None
    server.timeout = 1

    auth = AUTH_URL + "?" + urllib.parse.urlencode({
        "client_id": cid,
        "response_type": "code",
        "redirect_uri": REDIRECT_URI,
        "code_challenge_method": "S256",
        "code_challenge": challenge,
        "scope": SCOPES,
        "state": state,
    })
    subprocess.Popen(["xdg-open", auth], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)

    deadline = time.time() + LOGIN_TIMEOUT
    while not result and time.time() < deadline:
        server.handle_request()
    server.server_close()
    if "error" in result:
        raise HelperError(result["error"])
    if "code" not in result:
        raise HelperError("Login timed out.")

    store_token(post_form(TOKEN_URL, {
        "grant_type": "authorization_code",
        "code": result["code"],
        "redirect_uri": REDIRECT_URI,
        "client_id": cid,
        "code_verifier": verifier,
    }))
    return cmd_status([])


def cmd_logout(_args):
    try:
        os.remove(TOKEN_FILE)
    except FileNotFoundError:
        pass
    return cmd_status([])


def cmd_me(_args):
    me = api("GET", "/me")
    return {"id": me.get("id", ""), "name": me.get("display_name") or me.get("id", ""),
            "image": pick_image(me.get("images"), 64), "product": me.get("product", "")}


def cmd_playlists(args):
    offset = int(args[0]) if args else 0
    data = api("GET", "/me/playlists", {"limit": PAGE_SIZE, "offset": offset})
    items = []
    for playlist in data.get("items") or []:
        if not playlist:
            continue
        # The playlist object's track counter moved from "tracks" to "items".
        counter = playlist.get("items") or playlist.get("tracks") or {}
        items.append({
            "uri": playlist.get("uri", ""),
            "id": playlist.get("id", ""),
            "name": playlist.get("name") or "",
            "owner": (playlist.get("owner") or {}).get("display_name") or "",
            "owner_id": (playlist.get("owner") or {}).get("id") or "",
            "collaborative": bool(playlist.get("collaborative")),
            "cover": pick_image(playlist.get("images"), 64),
            "count": counter.get("total", 0) if isinstance(counter, dict) else 0,
        })
    return page(items, data.get("total", len(items)), offset)


def cmd_liked(args):
    offset = int(args[0]) if args else 0
    data = api("GET", "/me/tracks", {"limit": PAGE_SIZE, "offset": offset})
    items = [shape_track(entry.get("track"), entry.get("added_at"))
             for entry in data.get("items") or [] if entry]
    items = [t for t in items if t]
    return page(items, data.get("total", len(items)), offset)


def cmd_playlist_tracks(args):
    if not args:
        raise HelperError("Usage: playlist-tracks <playlist id> [offset]")
    playlist_id = urllib.parse.quote(args[0], safe="")
    offset = int(args[1]) if len(args) > 1 else 0
    params = {"limit": PAGE_SIZE, "offset": offset}
    # Newer API revisions serve playlist entries from /items; fall back to
    # the older /tracks path when that is all the account can use.
    try:
        data = api("GET", f"/playlists/{playlist_id}/items", params)
    except HelperError as error:
        if "(404)" not in str(error) and "(403)" not in str(error):
            raise
        try:
            data = api("GET", f"/playlists/{playlist_id}/tracks", params)
        except HelperError:
            # Spotify's own editorial/algorithmic playlists (ids "37i9…") are
            # hidden from development-mode apps, but still play fine.
            if args[0].startswith("37i9"):
                raise HelperError("Spotify doesn't let third-party apps list the songs of its own playlists. "
                                  "Press play to listen to it.") from None
            raise
    items = []
    for entry in data.get("items") or []:
        if not entry:
            continue
        track = shape_track(entry.get("item") or entry.get("track"), entry.get("added_at"))
        if track:
            items.append(track)
    result = page(items, data.get("total", len(items)), offset)
    if offset == 0:
        try:
            result["meta"] = shape_playlist(api("GET", f"/playlists/{playlist_id}",
                                                {"fields": "uri,id,name,description,images,owner(display_name,id),collaborative"}))
        except HelperError:
            pass
    return result


def shape_device(device):
    return {
        "id": device.get("id") or "",
        "name": device.get("name") or "",
        "type": device.get("type") or "",
        "active": bool(device.get("is_active")),
        "restricted": bool(device.get("is_restricted")),
        "volume": device.get("volume_percent"),
        "supportsVolume": bool(device.get("supports_volume")),
    }


def cmd_devices(_args):
    devices = api("GET", "/me/player/devices").get("devices") or []
    return {"devices": [shape_device(d) for d in devices]}


def cmd_player(_args):
    """Playback state on whichever device is active, shaped for the widget."""
    data = api("GET", "/me/player", {"additional_types": "episode"})
    if not data or not data.get("device"):
        return {"active": False}
    item = data.get("item") or {}
    album = item.get("album") or {}
    images = album.get("images") or (item.get("images") or [])
    context = data.get("context") or {}
    actions = (data.get("actions") or {}).get("disallows") or {}
    return {
        "active": True,
        "device": shape_device(data["device"]),
        "playing": bool(data.get("is_playing")),
        "progress_ms": data.get("progress_ms") or 0,
        "timestamp": int(time.time() * 1000),
        "shuffle": bool(data.get("shuffle_state")),
        "smart_shuffle": bool(data.get("smart_shuffle")),
        "repeat": data.get("repeat_state") or "off",
        "context_uri": context.get("uri") or "",
        "disallows": sorted(k for k, v in actions.items() if v),
        "item": {
            "uri": item.get("uri") or "",
            "name": item.get("name") or "",
            "artists": ", ".join(a.get("name", "") for a in item.get("artists") or [] if a)
                       or ((item.get("show") or {}).get("name") or ""),
            "artist_uri": ((item.get("artists") or [{}])[0] or {}).get("uri") or "",
            "album_uri": album.get("uri") or "",
            "album": album.get("name") or "",
            "cover": pick_image(images, 300),
            "cover_small": pick_image(images, 64),
            "duration_ms": item.get("duration_ms") or 0,
        } if item else None,
    }


def cmd_queue(_args):
    data = api("GET", "/me/player/queue")
    return {"upcoming": [t for t in (shape_track(i) for i in data.get("queue") or []) if t]}


def cmd_context_name(args):
    """context-name <spotify uri>  — display name of a playlist/album/artist/show."""
    parts = (args[0] if args else "").split(":")
    if len(parts) >= 4 and parts[-1] == "collection":
        return {"name": "Liked Songs"}
    if len(parts) != 3:
        return {"name": ""}
    kind, ident = parts[1], urllib.parse.quote(parts[2], safe="")
    paths = {"playlist": f"/playlists/{ident}", "album": f"/albums/{ident}",
             "artist": f"/artists/{ident}", "show": f"/shows/{ident}"}
    if kind not in paths:
        return {"name": ""}
    params = {"fields": "name"} if kind == "playlist" else None
    return {"name": api("GET", paths[kind], params).get("name") or ""}


def cmd_transfer(args):
    """transfer <device id> [play]"""
    if not args:
        raise HelperError("Usage: transfer <device id> [play]")
    api("PUT", "/me/player", body={"device_ids": [args[0]], "play": len(args) > 1 and args[1] == "play"})
    return {}


def cmd_control(args):
    """control <device id> <action> [value]"""
    if len(args) < 2:
        raise HelperError("Usage: control <device id> <action> [value]")
    device, action = args[0], args[1]
    value = args[2] if len(args) > 2 else ""
    params = {"device_id": device} if device else {}
    if action == "play":
        api("PUT", "/me/player/play", params, json.loads(value) if value else None)
    elif action == "pause":
        api("PUT", "/me/player/pause", params)
    elif action == "next":
        # "next <n>" skips n tracks; the API has no skip-to, so step through.
        for index in range(max(1, int(value or 1))):
            if index:
                time.sleep(0.35)
            api("POST", "/me/player/next", params)
    elif action == "previous":
        api("POST", "/me/player/previous", params)
    elif action == "seek":
        api("PUT", "/me/player/seek", dict(params, position_ms=int(float(value))))
    elif action == "volume":
        api("PUT", "/me/player/volume", dict(params, volume_percent=max(0, min(100, int(float(value))))))
    elif action == "shuffle":
        api("PUT", "/me/player/shuffle", dict(params, state="true" if value == "on" else "false"))
    elif action == "repeat":
        api("PUT", "/me/player/repeat", dict(params, state=value or "off"))
    else:
        raise HelperError(f"Unknown control action: {action}")
    return {}


def shape_album(album):
    if not album or not album.get("uri"):
        return None
    return {"kind": "album", "uri": album["uri"], "id": album.get("id", ""), "name": album.get("name") or "",
            "owner": ", ".join(a.get("name", "") for a in album.get("artists") or [] if a),
            "artist_uri": ((album.get("artists") or [{}])[0] or {}).get("uri") or "",
            "cover": pick_image(album.get("images"), 300), "year": (album.get("release_date") or "")[:4]}


def shape_artist(artist):
    if not artist or not artist.get("uri"):
        return None
    return {"kind": "artist", "uri": artist["uri"], "id": artist.get("id", ""), "name": artist.get("name") or "",
            "owner": "Artist", "cover": pick_image(artist.get("images"), 300)}


def shape_playlist(playlist):
    if not playlist or not playlist.get("uri"):
        return None
    counter = playlist.get("items") or playlist.get("tracks") or {}
    return {"kind": "playlist", "uri": playlist["uri"], "id": playlist.get("id", ""),
            "name": playlist.get("name") or "",
            "owner": (playlist.get("owner") or {}).get("display_name") or "",
            "owner_id": (playlist.get("owner") or {}).get("id") or "",
            "collaborative": bool(playlist.get("collaborative")),
            "description": re.sub(r"<[^>]+>", "", playlist.get("description") or ""),
            "cover": pick_image(playlist.get("images"), 300),
            "count": counter.get("total", 0) if isinstance(counter, dict) else 0}


SEARCH_TYPES = {"track": "tracks", "artist": "artists", "album": "albums", "playlist": "playlists"}


def cmd_search(args):
    """search <query> [type] [offset]

    Without a type: the "All" overview (10 of each). With one of track,
    artist, album or playlist: one page of that type, for the filter chips.
    Development-mode apps get at most 10 results per request.
    """
    query = (args[0] if args else "").strip()
    kind = args[1] if len(args) > 1 else ""
    offset = int(args[2]) if len(args) > 2 else 0
    empty = {"query": query, "tracks": [], "artists": [], "albums": [], "playlists": []}
    if not query:
        return empty
    if kind and kind not in SEARCH_TYPES:
        raise HelperError("Unknown search type: " + kind)
    types = kind or ",".join(SEARCH_TYPES)
    data = api("GET", "/search", {"q": query, "type": types, "limit": 10, "offset": offset})
    shapers = {"tracks": shape_track, "artists": shape_artist, "albums": shape_album, "playlists": shape_playlist}
    result = dict(empty)
    for key, shaper in shapers.items():
        block = data.get(key) or {}
        result[key] = [x for x in (shaper(i) for i in block.get("items") or []) if x]
        if kind and SEARCH_TYPES[kind] == key:
            result["total"] = block.get("total", 0)
            result["next"] = offset + len(block.get("items") or []) < block.get("total", 0)
    return result


def cmd_album_tracks(args):
    if not args:
        raise HelperError("Usage: album-tracks <album id> [offset]")
    album_id = urllib.parse.quote(args[0], safe="")
    offset = int(args[1]) if len(args) > 1 else 0
    album = api("GET", f"/albums/{album_id}")
    data = api("GET", f"/albums/{album_id}/tracks", {"limit": PAGE_SIZE, "offset": offset})
    items = []
    for track in data.get("items") or []:
        if track:
            track = dict(track, album=album)
            shaped = shape_track(track)
            if shaped:
                items.append(shaped)
    # Name and art, for pages opened from a bare URI.
    return dict(page(items, data.get("total", len(items)), offset), meta=shape_album(album))


def artist_overview(artist_id):
    """Monthly listeners, play counts, Spotify bio and related artists.

    The Web API has none of these for development-mode apps, but the public
    open.spotify.com artist page embeds them. Unofficial: None on failure,
    and the caller falls back to Web API data.
    """
    return public_page_entity("artist", artist_id)


def gql_image(visual, preferred=300):
    sources = (visual or {}).get("sources") or []
    return pick_image([{"url": x.get("url"), "width": x.get("width") or 0} for x in sources], preferred)


def cmd_artist(args):
    """artist <id>: header, stats, popular tracks, releases, related artists."""
    if not args:
        raise HelperError("Usage: artist <artist id>")
    artist_id = urllib.parse.quote(args[0], safe="")
    artist = shape_artist(api("GET", f"/artists/{artist_id}")) or {}
    overview = artist_overview(args[0]) or {}

    stats = overview.get("stats") or {}
    profile = overview.get("profile") or {}
    discography = overview.get("discography") or {}
    related = overview.get("relatedContent") or {}

    # Popular: Spotify's own top tracks with play counts, durations from the
    # (cached) single-track endpoint; the bulk /tracks endpoint is 403.
    popular = []
    for entry in (discography.get("topTracks") or {}).get("items") or []:
        uri = ((entry or {}).get("track") or {}).get("uri") or ""
        if not uri.startswith("spotify:track:"):
            continue
        try:
            shaped = shape_track(api("GET", "/tracks/" + uri.split(":")[2]))
        except HelperError:
            shaped = None
        if shaped:
            shaped["playcount"] = int(entry["track"].get("playcount") or 0)
            popular.append(shaped)
    if not popular:
        found = api("GET", "/search", {"q": f'artist:"{artist.get("name", "")}"', "type": "track", "limit": 10})
        for track in (found.get("tracks") or {}).get("items") or []:
            if track and any(a.get("id") == args[0] for a in track.get("artists") or []):
                shaped = shape_track(track)
                if shaped:
                    popular.append(shaped)

    releases = api("GET", f"/artists/{artist_id}/albums", {"limit": 10, "include_groups": "album,single"})
    albums = [x for x in (shape_album(a) for a in releases.get("items") or []) if x]

    popular_releases = []
    for item in (discography.get("popularReleasesAlbums") or {}).get("items") or []:
        uri = item.get("uri") or ""
        if uri.startswith("spotify:album:"):
            popular_releases.append({"kind": "album", "uri": uri, "id": uri.split(":")[2], "name": item.get("name") or "",
                                     "cover": gql_image(item.get("coverArt")),
                                     "year": str((item.get("date") or {}).get("year") or ""),
                                     "owner": (item.get("type") or "").title()})

    related_artists = []
    for item in (related.get("relatedArtists") or {}).get("items") or []:
        uri = item.get("uri") or ""
        if uri.startswith("spotify:artist:"):
            related_artists.append({"kind": "artist", "uri": uri, "id": uri.split(":")[2],
                                    "name": (item.get("profile") or {}).get("name") or "", "owner": "Artist",
                                    "cover": gql_image((item.get("visuals") or {}).get("avatarImage"))})

    featuring = []
    for item in (related.get("featuringV2") or {}).get("items") or []:
        data = (item or {}).get("data") or {}
        uri = data.get("uri") or ""
        images = ((data.get("images") or {}).get("items") or [{}])
        if uri.startswith("spotify:playlist:"):
            featuring.append({"kind": "playlist", "uri": uri, "id": uri.split(":")[2], "name": data.get("name") or "",
                              "owner": "Spotify", "cover": gql_image(images[0] if images else {})})

    return {"artist": artist, "popular": popular[:10], "albums": albums,
            "popularReleases": popular_releases, "related": related_artists, "featuring": featuring,
            "monthlyListeners": int(stats.get("monthlyListeners") or 0),
            "followers": int(stats.get("followers") or 0),
            # The bio carries inline <a href="spotify:…"> links; keep the text.
            "bio": re.sub(r"<[^>]+>", "", (profile.get("biography") or {}).get("text") or "")}


def public_page_entity(kind, ident):
    """The embedded JSON of a public open.spotify.com page (unofficial)."""
    def fetch():
        request = urllib.request.Request(f"https://open.spotify.com/{kind}/{ident}",
                                         headers={"User-Agent": "Mozilla/5.0 (X11; Linux x86_64)",
                                                  "Accept-Language": "en"})
        with urllib.request.urlopen(request, timeout=15) as response:
            html = response.read().decode("utf-8", errors="replace")
        start = html.index(">", html.index('id="initialState"')) + 1
        state = json.loads(base64.b64decode(html[start:html.index("<", start)]))
        return state["entities"]["items"][f"spotify:{kind}:{ident}"]

    try:
        return cached("overview", f"{kind}:{ident}", 86400, fetch)
    except Exception:  # noqa: BLE001 - unofficial source, never fatal
        return None


def cmd_profile(_args):
    """Your profile page: header, top artists/tracks this month, public playlists.

    Follower counts are hidden from development-mode apps; the public
    playlist count and the avatar colour come from the public profile page,
    the following count from /me/following (needs the follow scopes).
    """
    me = api("GET", "/me")
    user_id = me.get("id", "")
    page_data = public_page_entity("user", user_id) or {}
    colors = ((page_data.get("avatar") or {}).get("extractedColors") or {})
    playlists = []
    offset = 0
    while offset < 200:
        chunk = api("GET", "/me/playlists", {"limit": 50, "offset": offset})
        for item in chunk.get("items") or []:
            if item and item.get("public") and (item.get("owner") or {}).get("id") == user_id:
                shaped = shape_playlist(item)
                if shaped:
                    playlists.append(shaped)
        offset += 50
        if offset >= chunk.get("total", 0):
            break
    try:
        following = api("GET", "/me/following", {"type": "artist", "limit": 1})["artists"]["total"]
    except (HelperError, KeyError, TypeError):
        following = -1
    top_artists = [x for x in (shape_artist(a) for a in
                               api("GET", "/me/top/artists", {"limit": 10, "time_range": "short_term"}).get("items") or []) if x]
    top_tracks = [x for x in (shape_track(t) for t in
                              api("GET", "/me/top/tracks", {"limit": 10, "time_range": "short_term"}).get("items") or []) if x]
    return {
        "id": user_id, "name": me.get("display_name") or user_id, "uri": me.get("uri", ""),
        "image": pick_image(me.get("images"), 300),
        "color": (colors.get("colorDark") or {}).get("hex", ""),
        "publicPlaylistCount": ((page_data.get("publicPlaylistsV2") or {}).get("totalCount")) or len(playlists),
        "following": following,
        "topArtists": top_artists, "topTracks": top_tracks, "playlists": playlists,
    }


def cmd_home(_args):
    """Home page: shortcut tiles, recently played albums, top artists/tracks.

    Recently-played entries often carry no context (Soloist doesn't report
    one), so shortcuts come from the library and "recently played" is built
    from the albums of recent tracks.
    """
    recent = api("GET", "/me/player/recently-played", {"limit": 50}).get("items") or []
    seen, recent_albums = set(), []
    for entry in recent:
        album = shape_album((entry.get("track") or {}).get("album"))
        if album and album["uri"] not in seen:
            seen.add(album["uri"])
            recent_albums.append(album)
    playlists = [x for x in (shape_playlist(p) for p in
                             api("GET", "/me/playlists", {"limit": 10}).get("items") or []) if x]
    liked = {"kind": "liked", "uri": "", "name": "Liked Songs", "owner": "Playlist", "cover": ""}
    shortcuts = [liked] + playlists[:5] + recent_albums[:2]
    top_artists = [x for x in (shape_artist(a) for a in
                               api("GET", "/me/top/artists", {"limit": 12}).get("items") or []) if x]
    top_tracks = [x for x in (shape_track(t) for t in
                              api("GET", "/me/top/tracks", {"limit": 12}).get("items") or []) if x]
    return {"shortcuts": shortcuts, "recentAlbums": recent_albums[:12],
            "topArtists": top_artists, "topTracks": top_tracks}


# The older /me/tracks/contains endpoints answer 403 for development-mode
# apps; /me/library takes Spotify URIs instead of ids.

def cmd_liked_contains(args):
    """liked-contains <uri>... -> {"liked": {uri: bool}}

    Works for tracks, albums, playlists and artists. Types are checked
    separately so one refused type (artists need the follow scopes) doesn't
    fail the rest.
    """
    by_type = {}
    for uri in dict.fromkeys(u for u in args if u.startswith("spotify:")):
        by_type.setdefault(uri.split(":")[1], []).append(uri)
    liked = {}
    for uris in by_type.values():
        for start in range(0, len(uris), 40):
            chunk = uris[start:start + 40]
            try:
                answer = api("GET", "/me/library/contains", {"uris": ",".join(chunk)})
            except HelperError:
                continue
            liked.update(zip(chunk, answer if isinstance(answer, list) else []))
    return {"liked": liked}


def cmd_like(args):
    """like <uri> [on|off]"""
    if not args:
        raise HelperError("Usage: like <uri> [on|off]")
    on = len(args) < 2 or args[1] != "off"
    api("PUT" if on else "DELETE", "/me/library", {"uris": args[0]})
    forget_cached("/me/tracks")
    forget_cached("/me/playlists")
    return {"uri": args[0], "liked": on}


def collection_track_uris(uri, limit=50):
    """Track URIs of an album, playlist or Liked Songs, for "Add to queue"."""
    parts = uri.split(":")
    if parts[-1] == "collection":
        return [t["uri"] for t in cmd_liked([])["items"]][:limit]
    if parts[1] == "album":
        return [t["uri"] for t in cmd_album_tracks([parts[2]])["items"]][:limit]
    if parts[1] == "playlist":
        return [t["uri"] for t in cmd_playlist_tracks([parts[2]])["items"]][:limit]
    return [uri] if parts[1] in ("track", "episode") else []


def cmd_add_to_queue(args):
    """add-to-queue <device name> <uri>...  — tracks, or whole albums/playlists."""
    if len(args) < 2:
        raise HelperError("Usage: add-to-queue <device name> <uri>...")
    device = find_device(args[0])
    uris = [u for uri in args[1:] for u in collection_track_uris(uri)]
    for uri in uris:
        api("POST", "/me/player/queue", {"uri": uri, "device_id": device})
    return {"queued": len(uris)}


def cmd_add_to_playlist(args):
    """add-to-playlist <playlist id> <uri>...  — tracks, or whole albums/playlists."""
    if len(args) < 2:
        raise HelperError("Usage: add-to-playlist <playlist id> <uri>...")
    playlist_id = urllib.parse.quote(args[0], safe="")
    uris = [u for uri in args[1:] for u in collection_track_uris(uri, 100)]
    try:
        api("POST", f"/playlists/{playlist_id}/items", body={"uris": uris})
    except HelperError as error:
        if "(404)" not in str(error):
            raise
        api("POST", f"/playlists/{playlist_id}/tracks", body={"uris": uris})
    forget_cached("/playlists/")
    forget_cached("/me/playlists")
    return {"added": len(uris)}


def find_device(name):
    devices = api("GET", "/me/player/devices").get("devices") or []
    for device in devices:
        if device.get("name") == name:
            return device.get("id")
    raise HelperError(f"Spotify doesn't list a device called \"{name}\". Is Soloist signed in?")


def cmd_play(args):
    """play <device name> <json body>  — body as for PUT /me/player/play."""
    if len(args) < 2:
        raise HelperError("Usage: play <device name> <json body>")
    body = json.loads(args[1])
    api("PUT", "/me/player/play", {"device_id": find_device(args[0])}, body)
    return {}


def cmd_replace_queue(args):
    """replace-queue <device name> <json {"uris": [...], "offset": n, "position_ms": ms}>

    The Web API can't edit the queue, but it can start an ad-hoc context from
    a list of tracks. Replaying [current, ...upcoming in the new order] at the
    current position makes Spotify's own queue follow our order on every
    device. Shuffle is turned off first, or Spotify would reshuffle the list.
    """
    if len(args) < 2:
        raise HelperError("Usage: replace-queue <device name> <json>")
    request = json.loads(args[1])
    uris = [u for u in request.get("uris") or [] if isinstance(u, str) and u.startswith("spotify:")]
    if not uris:
        raise HelperError("Nothing to play.")
    device = find_device(args[0])
    try:
        api("PUT", "/me/player/shuffle", {"device_id": device, "state": "false"})
    except HelperError:
        pass
    body = {"uris": uris[:100], "offset": {"position": max(0, int(request.get("offset") or 0))}}
    if request.get("position_ms"):
        body["position_ms"] = max(0, int(request["position_ms"]))
    api("PUT", "/me/player/play", {"device_id": device}, body)
    return {}


# ------------------------------------------------------------ soloist prefs
#
# Soloist has no settings API, but it embeds Spotify's preference engine and
# keeps a per-user key=value file at <data dir>/settings/Users/<id>-user/prefs.
# Soloist rewrites that file itself, so changes are applied with the service
# stopped: stop, write, start.

PREF_KEYS = {
    "audio.play_bitrate_enumeration",
    "audio.play_bitrate_non_metered_enumeration",
    "audio.normalize_v2",
    "audio.crossfade_v2",
    "audio.crossfade.time_v2",
    "audio.gapless_v2",
    "audio.automix",
}


def prefs_file(data_dir):
    users = os.path.join(data_dir, "settings", "Users")
    try:
        entries = sorted(e for e in os.listdir(users) if e.endswith("-user"))
    except OSError:
        entries = []
    if not entries:
        raise HelperError("Soloist has no signed-in user yet; pair it from a Spotify app first.")
    return os.path.join(users, entries[0], "prefs")


def read_prefs(path):
    lines, values = [], {}
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except FileNotFoundError:
        pass
    for line in lines:
        key, sep, value = line.partition("=")
        if sep:
            values[key.strip()] = value.strip()
    return lines, values


def run_quiet(command):
    return subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=30)


def cmd_prefs_get(args):
    """prefs-get <data dir> [service]"""
    data_dir = args[0] if args else os.path.join(HOME, ".local", "share", "soloist")
    service = args[1] if len(args) > 1 else "soloist.service"
    path = prefs_file(data_dir)
    _, values = read_prefs(path)
    about = {"version": "", "expiresInDays": -1}
    try:
        about["version"] = run_quiet(["soloist", "--version"]).stdout.strip().splitlines()[0]
    except (OSError, IndexError, subprocess.SubprocessError):
        pass
    try:
        log = run_quiet(["journalctl", "--user", "-u", service, "-g", "client expires in",
                         "-n", "1", "-o", "cat", "--no-pager"]).stdout
        words = log.split()
        if "in" in words:
            about["expiresInDays"] = int(words[words.index("in") + 1])
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        pass
    return {"file": path, "prefs": {k: v for k, v in values.items() if k in PREF_KEYS}, "about": about}


def cmd_prefs_apply(args):
    """prefs-apply <data dir> <service> <json {key: value|null}>  — null removes a key."""
    if len(args) < 3:
        raise HelperError("Usage: prefs-apply <data dir> <service> <json>")
    data_dir, service, changes = args[0], args[1], json.loads(args[2])
    unknown = set(changes) - PREF_KEYS
    if unknown:
        raise HelperError("Unsupported setting: " + ", ".join(sorted(unknown)))
    path = prefs_file(data_dir)
    was_active = run_quiet(["systemctl", "--user", "is-active", service]).stdout.strip() == "active"
    if was_active:
        run_quiet(["systemctl", "--user", "stop", service])
    try:
        lines, _ = read_prefs(path)
        remaining = dict(changes)
        output = []
        for line in lines:
            key = line.partition("=")[0].strip()
            if key in remaining:
                value = remaining.pop(key)
                if value is not None:
                    output.append(f"{key}={value}")
            else:
                output.append(line)
        output += [f"{k}={v}" for k, v in remaining.items() if v is not None]
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write("\n".join(output) + "\n")
        os.replace(tmp, path)
    finally:
        if was_active:
            run_quiet(["systemctl", "--user", "start", service])
    return cmd_prefs_get([data_dir, service])


# ------------------------------------------------------ lyrics and artist info
#
# Spotify's lyrics and artist bios aren't in the public Web API. Lyrics come
# from LRCLIB (lrclib.net, free, community-run, time-synced) and the "About
# the artist" text from Wikipedia. Only the track title, artist, album and
# duration are sent. Answers are cached on disk.

def cached(kind, key, max_age, fetch):
    digest = hashlib.sha1(key.encode()).hexdigest()
    path = os.path.join(CACHE_DIR, kind, digest + ".json")
    try:
        if time.time() - os.path.getmtime(path) < max_age:
            with open(path, encoding="utf-8") as handle:
                return json.load(handle)
    except (OSError, ValueError):
        pass
    value = fetch()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(value, handle)
    return value


def get_public_json(url, retry=True):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        # LRCLIB answers 502/503 now and then under load; try once more.
        if error.code in (429, 502, 503, 504) and retry:
            time.sleep(1.5)
            return get_public_json(url, retry=False)
        raise HelperError(f"{urllib.parse.urlparse(url).netloc} answered {error.code}") from None
    except urllib.error.URLError as error:
        raise HelperError(f"Could not reach {urllib.parse.urlparse(url).netloc}: {error.reason}") from None


def parse_lrc(text):
    lines = []
    for raw in (text or "").splitlines():
        rest, stamps = raw, []
        while rest.startswith("[") and "]" in rest:
            stamp, rest = rest[1:].split("]", 1)
            try:
                minutes, seconds = stamp.split(":")
                stamps.append(int((int(minutes) * 60 + float(seconds)) * 1000))
            except ValueError:
                break
        for stamp in stamps:
            lines.append({"t": stamp, "text": rest.strip()})
    return sorted(lines, key=lambda line: line["t"])


def cmd_lyrics(args):
    """lyrics <artist> <track> <album> <duration ms>"""
    if len(args) < 2:
        raise HelperError("Usage: lyrics <artist> <track> [album] [duration ms]")
    artist, track = args[0], args[1]
    album = args[2] if len(args) > 2 else ""
    seconds = round(int(args[3]) / 1000) if len(args) > 3 and args[3].isdigit() else 0

    def fetch():
        params = {"artist_name": artist, "track_name": track}
        if album:
            params["album_name"] = album
        if seconds:
            params["duration"] = seconds
        found = get_public_json("https://lrclib.net/api/get?" + urllib.parse.urlencode(params))
        if not found:
            # Fuzzy fallback: first search hit with a matching length.
            hits = get_public_json("https://lrclib.net/api/search?" + urllib.parse.urlencode(
                {"artist_name": artist, "track_name": track})) or []
            found = next((h for h in hits if not seconds or abs((h.get("duration") or 0) - seconds) <= 3), None)
        if not found:
            return {"found": False}
        return {"found": True, "instrumental": bool(found.get("instrumental")),
                "synced": parse_lrc(found.get("syncedLyrics")),
                "plain": found.get("plainLyrics") or "", "source": "LRCLIB"}

    return cached("lyrics", f"{artist}\n{track}\n{album}\n{seconds}", 30 * 86400, fetch)


MUSIC_WORDS = ("band", "musician", "singer", "rapper", "group", "duo", "dj", "producer", "composer",
               "songwriter", "artist", "vocalist", "idol", "orchestra", "project")


def wikipedia_summary(name):
    for title in (name, f"{name} (band)", f"{name} (musician)", f"{name} (singer)", f"{name} (rapper)"):
        page = get_public_json("https://en.wikipedia.org/api/rest_v1/page/summary/"
                               + urllib.parse.quote(title.replace(" ", "_")))
        if not page or page.get("type") != "standard":
            continue
        description = (page.get("description") or "").lower()
        if any(word in description for word in MUSIC_WORDS):
            return page
    return None


def cmd_artist_about(args):
    """artist-about <artist id>: name, image and a Wikipedia summary."""
    if not args:
        raise HelperError("Usage: artist-about <artist id>")
    artist = shape_artist(api("GET", "/artists/" + urllib.parse.quote(args[0], safe=""))) or {}

    def fetch():
        page = wikipedia_summary(artist.get("name", ""))
        if not page:
            return {"bio": "", "url": "", "image": ""}
        return {"bio": page.get("extract") or "",
                "url": ((page.get("content_urls") or {}).get("desktop") or {}).get("page", ""),
                "image": (page.get("originalimage") or page.get("thumbnail") or {}).get("source", "")}

    about = cached("artists", args[0], 7 * 86400, fetch) if artist.get("name") else {}
    return {"artist": artist, **about}


COMMANDS = {
    "status": cmd_status,
    "set-client-id": cmd_set_client_id,
    "login": cmd_login,
    "logout": cmd_logout,
    "me": cmd_me,
    "playlists": cmd_playlists,
    "liked": cmd_liked,
    "playlist-tracks": cmd_playlist_tracks,
    "play": cmd_play,
    "replace-queue": cmd_replace_queue,
    "devices": cmd_devices,
    "player": cmd_player,
    "queue": cmd_queue,
    "context-name": cmd_context_name,
    "search": cmd_search,
    "album-tracks": cmd_album_tracks,
    "home": cmd_home,
    "artist": cmd_artist,
    "profile": cmd_profile,
    "lyrics": cmd_lyrics,
    "liked-contains": cmd_liked_contains,
    "like": cmd_like,
    "add-to-queue": cmd_add_to_queue,
    "add-to-playlist": cmd_add_to_playlist,
    "fetch-images": cmd_fetch_images,
    "artist-about": cmd_artist_about,
    "prefs-get": cmd_prefs_get,
    "prefs-apply": cmd_prefs_apply,
    "transfer": cmd_transfer,
    "control": cmd_control,
}


def main():
    # "--fresh" before the command skips cached API reads (still refreshes
    # the cache), e.g. for the library's refresh button.
    if len(sys.argv) > 1 and sys.argv[1] == "--fresh":
        os.environ["OMASOLOIST_FRESH"] = "1"
        del sys.argv[1]
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print(json.dumps({"ok": False, "error": "Commands: " + ", ".join(COMMANDS)}))
        return 2
    try:
        result = COMMANDS[sys.argv[1]](sys.argv[2:])
    except HelperError as error:
        print(json.dumps({"ok": False, "error": str(error)}))
        return 1
    except Exception as error:  # noqa: BLE001 - always answer the widget in JSON
        print(json.dumps({"ok": False, "error": f"{type(error).__name__}: {error}"}))
        return 1
    print(json.dumps(dict(result, ok=True)))
    sys.stdout.flush()
    flush_image_queue()
    return 0


if __name__ == "__main__":
    sys.exit(main())
