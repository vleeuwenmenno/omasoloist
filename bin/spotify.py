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
from contextlib import contextmanager
import fcntl
import hashlib
import http.server
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
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


class RateLimited(HelperError):
    def __init__(self, message, seconds=0, reason=""):
        super().__init__(message)
        self.seconds = seconds
        self.reason = reason


class ApiError(HelperError):
    def __init__(self, message, status):
        super().__init__(message)
        self.status = status


RESPONSE_META = {}


@contextmanager
def state_lock(name):
    # Locks live outside the cache so clearing it cannot replace a locked inode.
    folder = os.path.join(STATE_DIR, "locks")
    os.makedirs(folder, mode=0o700, exist_ok=True)
    path = os.path.join(folder, hashlib.sha256(name.encode()).hexdigest())
    with open(path, "a", encoding="utf-8") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield


def atomic_write(path, data):
    folder = os.path.dirname(path)
    os.makedirs(folder, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".write-", dir=folder)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def read_json(path, fallback):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return fallback


def write_private_json(path, data):
    atomic_write(path, json.dumps(data).encode())


def cache_epoch(folder, group=""):
    state = read_json(os.path.join(STATE_DIR, "cache-epochs.json"), {})
    return state.get(folder, 0), state.get(folder + ":" + group, 0)


def bump_cache_epoch(folder, group=""):
    path = os.path.join(STATE_DIR, "cache-epochs.json")
    state = read_json(path, {})
    key = folder + ":" + group if group else folder
    state[key] = state.get(key, 0) + 1
    write_private_json(path, state)


def api_session():
    token = read_json(TOKEN_FILE, {}) or {}
    cid = client_id()
    if not token.get("refresh_token") or token.get("client_id", cid) != cid:
        raise HelperError("Not signed in to Spotify.")
    identity = token.get("cache_session") or token["refresh_token"]
    return hashlib.sha256((cid + ":" + identity).encode()).hexdigest()


def client_id():
    value = str(read_json(CONFIG_FILE, {}).get("clientId") or "").strip()
    if not value:
        raise HelperError(f"No Spotify client ID. Add {{\"clientId\": \"...\"}} to {CONFIG_FILE}.")
    return value


# ------------------------------------------------------------ bounded reads
#
# Every network response is read through read_limited, so an oversized or
# endless response fails instead of exhausting memory.

KIB, MIB = 1024, 1024 * 1024
LIMIT_TOKEN = 64 * KIB         # OAuth token responses
LIMIT_API = 8 * MIB            # Spotify Web API JSON (largest pages are ~100-300 KiB)
LIMIT_PUBLIC_JSON = 1 * MIB    # LRCLIB, Wikipedia, GitHub tags
LIMIT_PAGE = 4 * MIB           # public open.spotify.com pages (~200-350 KiB)
LIMIT_IMAGE = 2 * MIB          # artwork (Spotify covers are ~20-300 KiB)
LIMIT_ERROR = 64 * KIB         # error bodies
MAX_IMAGE_SIDE = 4096          # pixels, either dimension


def read_limited(response, limit, what="Response"):
    length = response.headers.get("Content-Length")
    if length and length.isdigit() and int(length) > limit:
        raise HelperError(f"{what} is too large ({int(length) // KIB} KiB, limit {limit // KIB} KiB)")
    chunks, total = [], 0
    while True:
        chunk = response.read(min(64 * KIB, limit + 1 - total))
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
        if total > limit:
            raise HelperError(f"{what} is larger than the {limit // KIB} KiB limit")
    return b"".join(chunks)


def read_error_body(error):
    try:
        return error.read(LIMIT_ERROR).decode(errors="replace")
    except OSError:
        return ""


def post_form(url, fields):
    body = urllib.parse.urlencode(fields).encode()
    request = urllib.request.Request(url, data=body, headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.loads(read_limited(response, LIMIT_TOKEN, "Token response"))
    except urllib.error.HTTPError as error:
        raise HelperError(f"Token request failed ({error.code}): {read_error_body(error)}") from None
    except urllib.error.URLError as error:
        raise HelperError(f"Could not reach Spotify: {error.reason}") from None


def store_token(payload, previous=None):
    token = {
        "access_token": payload["access_token"],
        # Spotify may omit a new refresh token on refresh; keep the old one.
        "refresh_token": payload.get("refresh_token") or (previous or {}).get("refresh_token"),
        "expires_at": time.time() + int(payload.get("expires_in", 3600)) - 60,
        "scope": payload.get("scope", ""),
        "client_id": client_id(),
        # A new login starts a new cache namespace, even with the same client ID.
        # Refreshes retain it, including when upgrading a legacy token file.
        "cache_session": ((previous or {}).get("cache_session")
                          or (previous or {}).get("refresh_token") or secrets.token_hex(16)),
    }
    write_private_json(TOKEN_FILE, token)
    return token


def access_token():
    token = read_json(TOKEN_FILE, None)
    if not token or not token.get("refresh_token"):
        raise HelperError("Not signed in to Spotify.")
    # A token belongs to the app that issued it; a new client ID needs a new sign-in.
    if token.get("client_id", client_id()) != client_id():
        raise HelperError("Not signed in to Spotify.")
    if time.time() < token.get("expires_at", 0):
        return token["access_token"]
    # The widget starts several helpers at once. Spotify rotates the refresh
    # token on every refresh, so only one process may refresh; the others
    # wait on the lock and then use the token it stored.
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    with open(TOKEN_FILE + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        token = read_json(TOKEN_FILE, None)
        if not token or not token.get("refresh_token") or token.get("client_id", client_id()) != client_id():
            raise HelperError("Not signed in to Spotify.")
        if time.time() < token.get("expires_at", 0):
            return token["access_token"]
        payload = post_form(TOKEN_URL, {
            "grant_type": "refresh_token",
            "refresh_token": token["refresh_token"],
            "client_id": client_id(),
        })
        return store_token(payload, token)["access_token"]


# GET responses cached on disk, by path prefix (seconds). Live playback is
# never cached; likes are shared for 30 seconds. Set
# OMASOLOIST_FRESH=1 to bypass reads.
API_CACHE = [
    # The popup and the window both list devices; share one answer.
    ("/me/player/devices", 5),
    ("/me/player/recently-played", 120),
    ("/me/player", 0),
    ("/me/library/contains", 30),
    ("/me/albums", 300),
    ("/me/following", 300),
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


def api_cache_slot(method, path, url, session=None):
    if method != "GET" or path.startswith("https://"):
        return None, 0
    for prefix, ttl in API_CACHE:
        if path.startswith(prefix):
            if not ttl:
                return None, 0
            group = prefix.strip("/").replace("/", "_") or "root"
            name = hashlib.sha1(url.encode()).hexdigest() + ".json"
            return os.path.join(CACHE_DIR, "api", group, session or api_session(), name), ttl
    return None, 0


def forget_cached(prefix):
    """Drop cached responses for one API_CACHE prefix, e.g. after a like."""
    group = os.path.join(CACHE_DIR, "api", prefix.strip("/").replace("/", "_") or "root")
    with state_lock("cache-epochs"):
        bump_cache_epoch("api", prefix.strip("/").replace("/", "_") or "root")
        shutil.rmtree(group, ignore_errors=True)


def api(method, path, params=None, body=None, retry=True):
    requested_at = time.time()
    session = api_session()  # Validate sign-in before serving any cached response.
    if RESPONSE_META.setdefault("session", session) != session:
        raise HelperError("Spotify sign-in changed. Try again.")
    url = path if path.startswith("https://") else API_URL + path
    if params:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(sorted(params.items()))
    slot, ttl = api_cache_slot(method, path, url, session)
    if not slot:
        result = api_request(method, path, url, params, body, retry)
        if api_session() != session:
            raise HelperError("Spotify sign-in changed. Try again.")
        return result
    group = os.path.basename(os.path.dirname(os.path.dirname(slot)))
    # Single-flight includes independent helper processes and Home's threads.
    with state_lock("api-key:" + slot):
        for _attempt in range(2):
            with state_lock("cache-epochs"):
                epoch = cache_epoch("api", group)
                if api_session() != session:
                    raise HelperError("Spotify sign-in changed. Try again.")
                refreshed_while_waiting = False
                try:
                    refreshed_while_waiting = os.path.getmtime(slot) >= requested_at
                except OSError:
                    pass
                if not os.environ.get("OMASOLOIST_FRESH") or refreshed_while_waiting:
                    hit = fresh_json(slot, ttl)
                    if hit is not None:
                        RESPONSE_META["cacheAge"] = max(RESPONSE_META.get("cacheAge", 0),
                                                        max(0, time.time() - os.path.getmtime(slot)))
                        request_stat("cacheHits")
                        return hit
                failure = fresh_json(slot + ".error", 300)
                if failure:
                    request_stat("capabilityHits")
                    raise ApiError(failure["message"], failure["status"])
            try:
                result = api_request(method, path, url, params, body, retry)
            except RateLimited:
                with state_lock("cache-epochs"):
                    if api_session() != session or epoch != cache_epoch("api", group):
                        raise
                    stale = read_json(slot, None)
                if stale is None:
                    raise
                RESPONSE_META["stale"] = True
                RESPONSE_META["limits"] = active_limits()
                request_stat("staleHits")
                return stale
            except ApiError as error:
                # Only remember known editorial-playlist capability failures.
                # Other 403s may be permission or authentication problems.
                if error.status in (403, 404) and path.startswith("/playlists/37i9"):
                    with state_lock("cache-epochs"):
                        if api_session() == session and epoch == cache_epoch("api", group):
                            write_private_json(slot + ".error", {"message": str(error), "status": error.status})
                raise
            with state_lock("cache-epochs"):
                if api_session() != session:
                    raise HelperError("Spotify sign-in changed. Try again.")
                if epoch != cache_epoch("api", group):
                    continue  # A mutation or Clear finished while this read was pending.
                write_private_json(slot, result)
                return result
    raise HelperError("Spotify data changed while loading. Try again.")


def fresh_json(path, ttl):
    try:
        if time.time() - os.path.getmtime(path) < ttl:
            return read_json(path, None)
    except OSError:
        pass
    return None


def request_stat(name):
    with state_lock("request-stats"):
        path = os.path.join(STATE_DIR, "request-stats.json")
        stats = read_json(path, {"since": time.time()})
        stats[name] = stats.get(name, 0) + 1
        write_private_json(path, stats)


# General limits are app-wide. Development quotas belong to the developer
# account, with unpublished buckets that can change. Without a documented
# bucket identifier, stop all Web API requests conservatively. Keep reading
# legacy endpoint wait files so an upgrade never forgets an existing deadline.
def rate_limit_file(path):
    path = path.split("?")[0].removeprefix(API_URL)
    group = next((prefix for prefix, _ttl in API_CACHE if path.startswith(prefix)),
                 "/".join(path.split("/")[:3]))
    return os.path.join(CACHE_DIR, "rate-limited", group.strip("/").replace("/", "_") or "root")


def rate_limit_wait(path):
    files = {rate_limit_file(path), os.path.join(CACHE_DIR, "rate-limited", "global")}
    return max((max(0, limit_record(file).get("deadline", 0) - time.time()) for file in files), default=0)


def limit_record(path):
    value = read_json(path, {})
    if isinstance(value, (int, float)):
        return {"deadline": value, "reason": "", "scope": "endpoint"}
    return value if isinstance(value, dict) else {}


def note_rate_limit(path, seconds, reason=""):
    with state_lock("rate-limits"):
        file = os.path.join(CACHE_DIR, "rate-limited", "global")
        previous = limit_record(file)
        deadline = time.time() + seconds
        if deadline >= previous.get("deadline", 0):
            write_private_json(file, {"deadline": deadline, "scope": "global", "reason": reason,
                                      "endpoint": path.split("?")[0].removeprefix(API_URL)})


def rate_limit_error(seconds, reason=""):
    minutes = max(1, round(seconds / 60))
    wait = f"{minutes // 60} h {minutes % 60} min" if minutes >= 60 else f"{minutes} min"
    return RateLimited(f"Spotify is limiting requests. Trying again in {wait}.", seconds, reason)


# Local pacing limits, not a claim about Spotify's unpublished quota. Reserve
# four requests per window for controls, so browsing cannot consume them all.
REQUEST_WINDOW = 30
REQUEST_LIMIT = 20
CONTROL_RESERVE = 4
REQUEST_INTERVAL = 0.35


@contextmanager
def request_turn(method, path):
    # Hold through the response and 429 recording: no other helper can send a
    # request between Spotify rejecting one and the cooldown being persisted.
    file = os.path.join(STATE_DIR, "request-budget.json")
    while True:
        with state_lock("spotify-request"):
            wait = rate_limit_wait(path)
            if wait > 0:
                raise rate_limit_error(wait)
            now = time.time()
            budget = read_json(file, {})
            starts = [t for t in budget.get("starts", []) if now - REQUEST_WINDOW < t <= now]
            direct_control = method != "GET" and path != "/me/player/queue"
            ceiling = REQUEST_LIMIT if direct_control else REQUEST_LIMIT - CONTROL_RESERVE
            delay = max(0, budget.get("last", 0) + REQUEST_INTERVAL - now)
            if len(starts) >= ceiling:
                delay = max(delay, starts[-ceiling] + REQUEST_WINDOW - now)
            if delay <= 0:
                write_private_json(file, {"last": now, "starts": starts + [now]})
                yield
                return
        # Waiting readers release the lock so controls can use their reserve.
        time.sleep(min(delay, 1))


def api_request(method, path, url, params, body, retry):
    with request_turn(method, path):
        return send_api_request(method, path, url, body)


def send_api_request(method, path, url, body):
    wait = rate_limit_wait(path)
    if wait > 0:
        raise rate_limit_error(wait)
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Authorization": "Bearer " + access_token()}
    if data is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, method=method, headers=headers)
    request_stat("requests")
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            raw = read_limited(response, LIMIT_API, "Spotify API response")
            # Player commands answer with an opaque text token, not JSON.
            try:
                return json.loads(raw) if raw else {}
            except ValueError:
                return {}
    except urllib.error.HTTPError as error:
        if error.code == 429:
            try:
                retry_after = max(1, int(error.headers.get("Retry-After", "30")))
            except ValueError:
                retry_after = 30
            detail = read_error_body(error)
            error.close()
            try:
                reason = json.loads(detail).get("error", {}).get("reason", "")
            except (ValueError, AttributeError):
                reason = ""
            note_rate_limit(path, retry_after, reason)
            request_stat("rateLimited")
            raise rate_limit_error(rate_limit_wait(path), reason) from None
        detail = read_error_body(error)
        try:
            detail = json.loads(detail)["error"]["message"]
        except (ValueError, KeyError, TypeError):
            pass
        error.close()
        raise ApiError(f"Spotify API {method} {path} failed ({error.code}): {detail}", error.code) from None
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


def image_size(data):
    """(format, width, height) from a JPEG, PNG or WebP header, else None.

    Only these formats are cached; the dimensions gate what QML decodes.
    """
    if data[:8] == b"\x89PNG\r\n\x1a\n" and data[12:16] == b"IHDR":
        return "png", int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        kind = data[12:16]
        if kind == b"VP8 " and len(data) >= 30:
            return "webp", int.from_bytes(data[26:28], "little") & 0x3FFF, int.from_bytes(data[28:30], "little") & 0x3FFF
        if kind == b"VP8L" and len(data) >= 25:
            bits = int.from_bytes(data[21:25], "little")
            return "webp", (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
        if kind == b"VP8X" and len(data) >= 30:
            return "webp", int.from_bytes(data[24:27], "little") + 1, int.from_bytes(data[27:30], "little") + 1
        return None
    if data[:2] == b"\xff\xd8":
        i = 2
        while i + 9 < len(data):
            if data[i] != 0xFF:
                return None
            marker = data[i + 1]
            if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
                i += 2
                continue
            length = int.from_bytes(data[i + 2:i + 4], "big")
            # SOF markers carry the frame size.
            if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                return "jpeg", int.from_bytes(data[i + 7:i + 9], "big"), int.from_bytes(data[i + 5:i + 7], "big")
            i += 2 + length
    return None


def acceptable_image(data):
    info = image_size(data)
    return bool(info) and 0 < info[1] <= MAX_IMAGE_SIDE and 0 < info[2] <= MAX_IMAGE_SIDE


# Until an image is cached, QML may load it directly, but only from
# Spotify's image CDNs; anything else waits for the validated cache copy.
DIRECT_IMAGE_HOSTS = ("i.scdn.co", "mosaic.scdn.co", "pickasso.spotifycdn.com",
                      "image-cdn-ak.spotifycdn.com", "image-cdn-fa.spotifycdn.com")


def local_image(url):
    if not url or not url.startswith("https://"):
        return ""
    path = os.path.join(IMAGE_DIR, hashlib.sha1(url.encode()).hexdigest())
    try:
        # Files are only cached after validation; the size check also
        # covers files cached before validation existed.
        if os.path.getsize(path) <= LIMIT_IMAGE:
            os.utime(path, None)
            return "file://" + path
        os.remove(path)
    except OSError:
        pass
    IMAGE_QUEUE.append(url)
    return url if urllib.parse.urlparse(url).hostname in DIRECT_IMAGE_HOSTS else ""


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
        if fetch_image(url):
            fetched += 1
    # Prune artwork nobody asked for in a while.
    cutoff = time.time() - IMAGE_MAX_AGE
    for name in os.listdir(IMAGE_DIR) if os.path.isdir(IMAGE_DIR) else []:
        full = os.path.join(IMAGE_DIR, name)
        try:
            if os.path.getatime(full) < cutoff and os.path.getmtime(full) < cutoff:
                os.remove(full)
        except OSError:
            pass
    return {"fetched": fetched}


def fetch_image(url):
    path = os.path.join(IMAGE_DIR, hashlib.sha1(url.encode()).hexdigest())
    with state_lock("image-key:" + path):
        with state_lock("cache-epochs"):
            epoch = cache_epoch("images")
            if os.path.exists(path):
                return False
        try:
            request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(request, timeout=20) as response:
                data = read_limited(response, LIMIT_IMAGE, "Artwork")
        except (urllib.error.URLError, OSError, HelperError):
            return False
        if not acceptable_image(data):
            return False
        with state_lock("cache-epochs"):
            if epoch != cache_epoch("images"):
                return False
            atomic_write(path, data)
        return True


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
    cid = str(config.get("clientId") or "").strip()
    if token and token.get("client_id", cid) != cid:
        token = None
    granted = set(((token or {}).get("scope") or "").split())
    return {
        "hasClientId": bool(cid),
        "signedIn": bool(cid and token and token.get("refresh_token")),
        "session": api_session() if token and token.get("refresh_token") and cid else "",
        # Scopes added in later versions need one more sign-in.
        "missingScopes": sorted(set(SCOPES.split()) - granted) if token else [],
        "configFile": CONFIG_FILE,
        "redirectUri": REDIRECT_URI,
    }


def cmd_set_client_id(args):
    if not args or not args[0].strip():
        raise HelperError("Usage: set-client-id <client id>")
    config = read_json(CONFIG_FILE, {})
    with state_lock("authentication"):
        if str(config.get("clientId") or "").strip() != args[0].strip():
            cmd_logout([])
        config["clientId"] = args[0].strip()
        write_private_json(CONFIG_FILE, config)
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

    payload = post_form(TOKEN_URL, {
        "grant_type": "authorization_code",
        "code": result["code"],
        "redirect_uri": REDIRECT_URI,
        "client_id": cid,
        "code_verifier": verifier,
    })
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    with state_lock("authentication"):
        with open(TOKEN_FILE + ".lock", "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if cid != client_id():
                raise HelperError("Spotify client ID changed. Sign in again.")
            store_token(payload)
    return cmd_status([])


def cmd_logout(_args):
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    with open(TOKEN_FILE + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
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


def cmd_saved_albums(args):
    """saved-albums [offset]: albums in Your Library, newest first."""
    offset = int(args[0]) if args else 0
    data = api("GET", "/me/albums", {"limit": PAGE_SIZE, "offset": offset})
    items = [x for x in (shape_album(entry.get("album")) for entry in data.get("items") or [] if entry) if x]
    return page(items, data.get("total", len(items)), offset)


def cmd_followed_artists(args):
    """followed-artists [cursor]: artists you follow. Spotify pages these by
    cursor (the last artist id), not offset; "cursor" is the next one."""
    params = {"type": "artist", "limit": PAGE_SIZE}
    if args and args[0]:
        params["after"] = args[0]
    data = api("GET", "/me/following", params).get("artists") or {}
    items = [x for x in (shape_artist(a) for a in data.get("items") or []) if x]
    cursor = (data.get("cursors") or {}).get("after") or ""
    return {"items": items, "total": data.get("total", len(items)), "next": bool(data.get("next") and cursor),
            "cursor": cursor}


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
                return spotify_playlist_tracks(args[0], offset)
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
    forget_cached("/me/player/devices")
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
            "artists": [{"name": a.get("name") or "", "uri": a.get("uri") or ""} for a in album.get("artists") or [] if a],
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


def public_playlist(entity):
    """A playlist from its public page, in shape_playlist's format."""
    if not entity or not entity.get("uri"):
        return None
    owner = (entity.get("ownerV2") or {}).get("data") or {}
    return {"kind": "playlist", "uri": entity["uri"], "id": entity.get("id") or entity["uri"].split(":")[-1],
            "name": entity.get("name") or "", "owner": owner.get("name") or "Spotify",
            "owner_id": owner.get("username") or "", "collaborative": False,
            "description": re.sub(r"<[^>]+>", "", entity.get("description") or ""),
            "cover": gql_image(((entity.get("images") or {}).get("items") or [{}])[0], 300),
            "count": (entity.get("content") or {}).get("totalCount") or 0}


def spotify_playlist_tracks(ident, offset):
    """Spotify's own playlists (Daily Mix, radios, Discover Weekly) are hidden
    from development-mode apps; their public page lists the first 30 or so
    songs. The whole playlist still plays through Soloist."""
    entity = public_page_entity("playlist", ident)
    if not entity:
        raise HelperError("Spotify doesn't let third-party apps list the songs of its own playlists. "
                          "Press play to listen to it.")
    items = []
    for entry in (entity.get("content") or {}).get("items") or []:
        data = (entry.get("itemV2") or {}).get("data") or {}
        track = gql_track(data)
        if track:
            track["duration_ms"] = (data.get("duration") or {}).get("totalMilliseconds") or 0
            items.append(track)
    if offset:
        return page([], len(items), offset)
    return dict(page(items, len(items), 0), meta=public_playlist(entity))


def cmd_artist(args):
    """artist <id>: header, stats, popular tracks, releases, related artists."""
    if not args:
        raise HelperError("Usage: artist <artist id>")
    artist_id = urllib.parse.quote(args[0], safe="")
    raw = api("GET", f"/artists/{artist_id}")
    artist = shape_artist(raw) or {}
    if artist:
        # The page's hero is ~420 px tall: use the big photo.
        artist["hero"] = pick_image(raw.get("images"), 640)
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
        with state_lock("spotify-public-pages"):
            limit_file = os.path.join(CACHE_DIR, "rate-limited", "public-pages")
            wait = limit_record(limit_file).get("deadline", 0) - time.time()
            if wait > 0:
                raise rate_limit_error(wait)
            try:
                with urllib.request.urlopen(request, timeout=15) as response:
                    html = read_limited(response, LIMIT_PAGE, "Spotify page").decode("utf-8", errors="replace")
            except urllib.error.HTTPError as error:
                if error.code != 429:
                    raise
                try:
                    seconds = max(1, int(error.headers.get("Retry-After", "30")))
                except ValueError:
                    seconds = 30
                error.close()
                write_private_json(limit_file, {"deadline": time.time() + seconds, "scope": "public",
                                               "reason": "", "endpoint": "open.spotify.com"})
                raise rate_limit_error(seconds) from None
        start = html.index(">", html.index('id="initialState"')) + 1
        state = json.loads(base64.b64decode(html[start:html.index("<", start)]))
        return state["entities"]["items"][f"spotify:{kind}:{ident}"]

    try:
        return cached("overview", f"{kind}:{ident}", 86400, fetch)
    except RateLimited:
        RESPONSE_META["limits"] = active_limits()
        return None
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


def gql_track(track, fallback_artist=None):
    """A top track from a public artist page, in shape_track's format."""
    uri = (track or {}).get("uri") or ""
    if not uri.startswith("spotify:track:"):
        return None
    album = track.get("albumOfTrack") or {}
    artists = [(a.get("profile") or {}).get("name", "") for a in (track.get("artists") or {}).get("items") or []]
    artist_uris = [a.get("uri", "") for a in (track.get("artists") or {}).get("items") or []]
    return {
        "uri": uri, "name": track.get("name") or "",
        "artists": ", ".join(a for a in artists if a) or fallback_artist or "",
        "album": album.get("name") or "", "album_uri": album.get("uri") or "",
        "artist_uri": artist_uris[0] if artist_uris else "",
        "cover": gql_image(album.get("coverArt"), 64), "cover_large": gql_image(album.get("coverArt"), 300),
        # The public pages carry no track length.
        "duration_ms": 0,
        "explicit": ((track.get("contentRating") or {}).get("label") == "EXPLICIT"),
        "playable": True, "added_at": "",
    }


def cmd_radio(args):
    """radio <track|artist> <id>: a song or artist radio to show as a list.

    Spotify doesn't expose its radio stations' tracks to third-party apps
    (no recommendations endpoint, station pages render client-side), so
    this builds a similar mix from the public artist pages: the seed track,
    then the top tracks of the seed artist and its "Fans also like" artists,
    taken in turns. The station itself (spotify:station:…) still plays
    through Soloist for an endless, Spotify-picked radio.
    """
    if len(args) < 2 or args[0] not in ("track", "artist"):
        raise HelperError("Usage: radio <track|artist> <id>")
    kind, ident = args[0], args[1]
    seed_track = None
    if kind == "track":
        seed_track = shape_track(api("GET", "/tracks/" + urllib.parse.quote(ident, safe="")))
        if not seed_track:
            raise HelperError("Track not found.")
        artist_id = seed_track["artist_uri"].split(":")[-1]
    else:
        artist_id = ident
    seed_overview = public_page_entity("artist", artist_id) or {}
    seed_name = (seed_overview.get("profile") or {}).get("name") or ""
    related = [a.get("uri", "").split(":")[-1]
               for a in ((seed_overview.get("relatedContent") or {}).get("relatedArtists") or {}).get("items") or []
               if a.get("uri", "").startswith("spotify:artist:")][:8]

    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(max_workers=2) as pool:
        overviews = [seed_overview] + list(pool.map(lambda a: public_page_entity("artist", a) or {}, related))

    pools, names = [], []
    for overview in overviews:
        name = (overview.get("profile") or {}).get("name") or ""
        tracks = [gql_track((e or {}).get("track"), name)
                  for e in ((overview.get("discography") or {}).get("topTracks") or {}).get("items") or []]
        pools.append([t for t in tracks if t])
        if name:
            names.append(name)

    items, seen = [], set()
    if seed_track:
        items.append(seed_track)
        seen.add(seed_track["uri"])
    for round_index in range(max((len(p) for p in pools), default=0)):
        for pool_tracks in pools:
            if round_index < len(pool_tracks) and pool_tracks[round_index]["uri"] not in seen:
                seen.add(pool_tracks[round_index]["uri"])
                items.append(pool_tracks[round_index])

    title = (seed_track["name"] if seed_track else seed_name) + " Radio"
    with_names = names[:3]
    subtitle = ("With " + ", ".join(with_names) + (" and more" if len(names) > 3 else "")) if with_names else ""
    cover = (seed_track or {}).get("cover_large") or gql_image((seed_overview.get("visuals") or {}).get("avatarImage"), 300)
    station = f"spotify:station:{kind}:{ident}"
    meta = {"kind": "radio", "uri": station, "id": f"{kind}:{ident}", "name": title,
            "owner": subtitle, "cover": cover}
    return dict(page(items, len(items), 0), meta=meta)


def recent_contexts(plays):
    """What each recently-played entry was played from, as a URI, and the
    albums already embedded in the answer (saves a request per album).

    Entries carry a context only when a Spotify app started the playback
    (Soloist doesn't report one); those fall back to the album of the track.
    """
    uris, albums = [], {}
    for entry in plays:
        track = entry.get("track") or {}
        uri = (entry.get("context") or {}).get("uri") or ((track.get("album") or {}).get("uri")) or ""
        if uri.split(":")[1:2] and uri.split(":")[1] in ("album", "playlist", "artist"):
            uris.append(uri)
            if track.get("album") and track["album"].get("uri") == uri:
                albums[uri] = shape_album(track["album"])
        else:
            uris.append("")
    return uris, albums


def resolve_context(uri, albums):
    """A card for an album, artist or playlist URI; None if it's gone.
    Spotify's own playlists come from their public pages, since the Web API
    hides them from development-mode apps."""
    kind, ident = uri.split(":")[1], uri.split(":")[2]
    try:
        if kind == "album":
            return albums.get(uri) or shape_album(api("GET", "/albums/" + ident))
        if kind == "artist":
            return shape_artist(api("GET", "/artists/" + ident))
        if ident.startswith("37i9"):
            return public_playlist(public_page_entity("playlist", ident))
        return shape_playlist(api("GET", "/playlists/" + ident,
                                  {"fields": "uri,id,name,description,images,owner(display_name,id),collaborative"}))
    except HelperError:
        return None


def artist_station(uri, name):
    """Spotify's artist station, with the station artwork its apps show."""
    ident = uri.split(":")[-1]
    return {"kind": "radio", "uri": "spotify:station:artist:" + ident, "id": "artist:" + ident,
            "name": name + " Radio", "owner": "", "subtitle": "With " + name,
            "cover": local_image("https://pickasso.spotifycdn.com/image/ab67c0de0000deef/dt/v1/img/radio/artist/"
                                 + ident + "/en")}


def cmd_home(_args):
    """Home page, close to Spotify's: shortcut tiles, "Jump back in" (what you
    played, as albums, playlists, radios and artists), stations from your top
    artists and from artists their fans also like, and your top artists and
    tracks.
    """
    from concurrent.futures import ThreadPoolExecutor

    # A section Spotify is holding back stays empty instead of failing the page.
    def section(path, params):
        try:
            return api("GET", path, params).get("items") or []
        except RateLimited:
            return []

    plays = section("/me/player/recently-played", {"limit": 50})
    try:
        history_record(plays)
    except HelperError:
        pass  # history is a bonus; Home still loads
    uris, albums = recent_contexts(plays)
    order = list(dict.fromkeys(u for u in uris if u))

    with ThreadPoolExecutor(max_workers=6) as pool:
        recents = [x for x in pool.map(lambda u: resolve_context(u, albums), order[:20]) if x]

    playlists = [x for x in (shape_playlist(p) for p in section("/me/playlists", {"limit": 10})) if x]
    liked = {"kind": "liked", "uri": "", "name": "Liked Songs", "owner": "Playlist", "cover": ""}
    shortcuts = [liked]
    for item in recents + playlists:
        if len(shortcuts) >= 8:
            break
        if item["uri"] not in (x["uri"] for x in shortcuts):
            shortcuts.append(item)

    top_artists = [x for x in (shape_artist(a) for a in section("/me/top/artists", {"limit": 20})) if x]
    top_tracks = [x for x in (shape_track(t) for t in section("/me/top/tracks", {"limit": 20})) if x]
    stations = [artist_station(a["uri"], a["name"]) for a in top_artists]

    # "Popular radio": stations of the artists fans of your top three also
    # like (from their public pages), skipping ones you already have.
    with ThreadPoolExecutor(max_workers=2) as pool:
        overviews = list(pool.map(lambda a: public_page_entity("artist", a["id"]) or {}, top_artists[:3]))
    known = {a["uri"] for a in top_artists}
    related = [[a for a in ((o.get("relatedContent") or {}).get("relatedArtists") or {}).get("items") or []
                if (a.get("uri") or "").startswith("spotify:artist:")] for o in overviews]
    popular = []
    for round_index in range(max((len(r) for r in related), default=0)):
        for artists in related:
            if round_index < len(artists) and artists[round_index]["uri"] not in known:
                known.add(artists[round_index]["uri"])
                name = (artists[round_index].get("profile") or {}).get("name") or ""
                if name:
                    popular.append(artist_station(artists[round_index]["uri"], name))
    return {"shortcuts": shortcuts, "recents": recents, "stations": stations, "popularRadio": popular[:20],
            "topArtists": top_artists, "topTracks": top_tracks}


# ----------------------------------------------------- listening history
#
# Spotify only keeps your last 50 plays for apps. Every answer from
# /me/player/recently-played is merged into a log on disk, one JSON line
# per play in a file per month (UTC), per Spotify account:
# $XDG_STATE_HOME/omasoloist/history/<user id>/2026-09.jsonl. The shell
# syncs every 30 minutes, so nothing is lost unless you play more than 50
# songs in between. contexts.json keeps the album, artist and playlist cards
# the plays came from, so old pages need no requests.

HISTORY_PAGE = 200            # plays per page, rounded up to a whole day
HISTORY_CONTEXT_AGE = 7 * 86400
HISTORY_TRACK_FIELDS = ("uri", "name", "artists", "album", "album_uri", "artist_uri",
                        "cover", "cover_large", "duration_ms", "explicit")


def history_folder():
    user = str(api("GET", "/me").get("id") or "")
    if not re.fullmatch(r"[A-Za-z0-9._-]+", user):
        raise HelperError("Spotify didn't say which account this is.")
    return os.path.join(STATE_DIR, "history", user)


def history_months(folder):
    """Month files, newest first."""
    try:
        names = os.listdir(folder)
    except OSError:
        return []
    return sorted((n for n in names if re.fullmatch(r"\d{4}-\d{2}\.jsonl", n)), reverse=True)


def history_read(path):
    plays = []
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                try:
                    plays.append(json.loads(line))
                except ValueError:
                    continue  # a line cut short by a crash
    except OSError:
        pass
    return plays


def played_ms(played_at):
    from datetime import datetime
    return int(datetime.fromisoformat(played_at.replace("Z", "+00:00")).timestamp() * 1000)


def history_record(plays):
    """Append the recently-played entries newer than the log's last play.
    Returns the number of new plays."""
    from datetime import datetime, timezone
    folder = history_folder()
    uris, albums = recent_contexts(plays)
    with state_lock("history:" + folder):
        months = history_months(folder)
        last = max((p.get("t", 0) for p in history_read(os.path.join(folder, months[0]))), default=0) if months else 0
        fresh = []
        for entry, uri in zip(plays, uris):
            track = shape_track(entry.get("track"))
            try:
                t = played_ms(entry.get("played_at") or "")
            except ValueError:
                continue
            if track and t > last:
                fresh.append({"t": t, "context": uri, "track": {k: track[k] for k in HISTORY_TRACK_FIELDS}})
        if not fresh:
            return 0
        os.makedirs(os.path.dirname(folder), mode=0o700, exist_ok=True)
        os.makedirs(folder, mode=0o700, exist_ok=True)
        for play in sorted(fresh, key=lambda p: p["t"]):
            month = datetime.fromtimestamp(play["t"] / 1000, timezone.utc).strftime("%Y-%m")
            fd = os.open(os.path.join(folder, month + ".jsonl"), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            with os.fdopen(fd, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(play, ensure_ascii=False) + "\n")
        # Albums come with the plays: keep their cards for free.
        contexts_path = os.path.join(folder, "contexts.json")
        contexts = read_json(contexts_path, {})
        for uri, album in albums.items():
            if album and uri not in contexts:
                contexts[uri] = dict(album, savedAt=time.time())
        write_private_json(contexts_path, contexts)
    return len(fresh)


def history_sync():
    """Merge Spotify's latest plays into the log. Never fatal: a held-back
    endpoint just means the log catches up next time."""
    try:
        return history_record(api("GET", "/me/player/recently-played", {"limit": 50}).get("items") or [])
    except RateLimited:
        return 0


def cmd_history_sync(_args):
    """history-sync -> {"recorded": n}: run by the shell every 30 minutes."""
    return {"recorded": history_sync()}


def cmd_history(args):
    """history [before] -> {"days": [{"date", "groups": [{"item", "tracks"}]}], "next"}

    Your listening history, like Spotify's Recents page: plays from the log,
    newest first, grouped by day in local time and, within a day, by what
    they were played from. `before` (ms since epoch, from "next") pages back;
    "next" is 0 on the last page.
    """
    from concurrent.futures import ThreadPoolExecutor
    from datetime import datetime

    before = int(args[0]) if args and args[0].isdigit() else 0
    if not before:
        history_sync()
    folder = history_folder()

    picked, cut_date = [], None
    for month in history_months(folder):
        done = False
        for play in sorted(history_read(os.path.join(folder, month)), key=lambda p: p.get("t", 0), reverse=True):
            if before and play.get("t", 0) >= before:
                continue
            date = datetime.fromtimestamp(play["t"] / 1000).date().isoformat()
            if cut_date and date != cut_date:
                done = True
                break
            picked.append(dict(play, date=date))
            if len(picked) >= HISTORY_PAGE and not cut_date:
                cut_date = date
        if done:
            break
    else:
        cut_date = None  # ran out of plays: this is the last page

    # Cards for the contexts, from contexts.json; missing or old ones are
    # fetched (and saved) now.
    contexts_path = os.path.join(folder, "contexts.json")
    contexts = read_json(contexts_path, {})
    wanted = list(dict.fromkeys(p["context"] for p in picked if p.get("context")))
    stale = [u for u in wanted if time.time() - (contexts.get(u) or {}).get("savedAt", 0) > HISTORY_CONTEXT_AGE]
    if stale:
        with ThreadPoolExecutor(max_workers=6) as pool:
            found = dict(zip(stale, pool.map(lambda u: resolve_context(u, {}), stale)))
        with state_lock("history:" + folder):
            contexts = read_json(contexts_path, {})
            for uri, item in found.items():
                if item:
                    contexts[uri] = dict(item, savedAt=time.time())
            write_private_json(contexts_path, contexts)

    days = []
    for play in picked:
        track = dict(play["track"], played_at=datetime.fromtimestamp(play["t"] / 1000).astimezone().isoformat())
        if not days or days[-1]["date"] != play["date"]:
            days.append({"date": play["date"], "groups": [], "_index": {}})
        day = days[-1]
        key = play.get("context") or track["uri"]
        if key not in day["_index"]:
            day["_index"][key] = len(day["groups"])
            item = contexts.get(play.get("context") or "")
            day["groups"].append({"item": {k: v for k, v in item.items() if k != "savedAt"} if item else None,
                                  "tracks": []})
        day["groups"][day["_index"][key]]["tracks"].append(track)
    for day in days:
        del day["_index"]
    return {"days": days, "next": picked[-1]["t"] if picked and cut_date else 0}


def cmd_history_info(_args):
    """history-info -> {"plays", "since", "bytes", "dir"}: for Settings."""
    folder = history_folder()
    months = history_months(folder)
    plays = size = 0
    for month in months:
        path = os.path.join(folder, month)
        size += os.path.getsize(path)
        with open(path, "rb") as handle:
            plays += sum(1 for _ in handle)
    oldest = history_read(os.path.join(folder, months[-1])) if months else []
    return {"plays": plays, "since": min((p.get("t", 0) for p in oldest), default=0),
            "bytes": size, "dir": folder}


def cmd_history_clear(_args):
    """history-clear: forget this account's listening history on this computer."""
    folder = history_folder()
    with state_lock("history:" + folder):
        shutil.rmtree(folder, ignore_errors=True)
    return cmd_history_info([])


# The older /me/tracks/contains endpoints answer 403 for development-mode
# apps; /me/library takes Spotify URIs instead of ids.

def cmd_liked_contains(args):
    """liked-contains <uri>... -> {"liked": {uri: bool}}

    Works for tracks, albums, playlists and artists. Types are checked
    separately so one refused type (artists need the follow scopes) doesn't
    fail the rest.
    """
    api_session()
    by_type = {}
    for uri in dict.fromkeys(u for u in args if u.startswith("spotify:")):
        by_type.setdefault(uri.split(":")[1], []).append(uri)
    liked = {}
    for uris in by_type.values():
        for start in range(0, len(uris), 40):
            chunk = uris[start:start + 40]
            try:
                answer = api("GET", "/me/library/contains", {"uris": ",".join(chunk)})
            except RateLimited as error:
                RESPONSE_META.update({"limits": active_limits(), "retryAfter": max(1, int(error.seconds + 1)),
                                      "partial": True})
                continue
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
    forget_cached("/me/library/contains")
    kind = args[0].split(":")[1] if ":" in args[0] else ""
    prefix = {"track": "/me/tracks", "playlist": "/me/playlists",
              "album": "/me/albums", "artist": "/me/following"}.get(kind)
    if prefix:
        forget_cached(prefix)
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
    # A cached list can predate a Soloist restart; ask again before giving up.
    for attempt in range(2):
        if attempt:
            forget_cached("/me/player/devices")
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

# What Settings > Cache lists and can clear: (id, label, detail, folders).
CACHE_GROUPS = [
    ("api", "Spotify data", "Library, playlists, albums, artists and search answers", ["api"]),
    ("images", "Artwork", "Covers and artist pictures", ["images"]),
    ("lyrics", "Lyrics", "Synced and plain lyrics from LRCLIB", ["lyrics"]),
    ("pages", "Artist and playlist pages", "Public Spotify pages and artist bios", ["overview", "artists"]),
]


def folder_usage(path):
    size = files = 0
    for folder, _dirs, names in os.walk(path):
        for name in names:
            try:
                size += os.path.getsize(os.path.join(folder, name))
                files += 1
            except OSError:
                pass
    return size, files


def cmd_cache_info(_args):
    """cache-info: size of each cache group, and endpoints Spotify is holding back."""
    groups = []
    for ident, label, detail, folders in CACHE_GROUPS:
        size = files = 0
        for folder in folders:
            s, f = folder_usage(os.path.join(CACHE_DIR, folder))
            size, files = size + s, files + f
        groups.append({"id": ident, "label": label, "detail": detail, "bytes": size, "files": files})
    total, _files = folder_usage(CACHE_DIR)
    return {"dir": CACHE_DIR, "bytes": total, "groups": groups, "limits": active_limits(),
            "stats": read_json(os.path.join(STATE_DIR, "request-stats.json"), {})}


# What each held-back endpoint group means to someone using the app.
LIMIT_LABELS = {
    "/me": "your profile", "/me/albums": "saved albums", "/me/following": "followed artists",
    "/me/library/contains": "likes", "/me/player/recently-played": "recents",
    "/me/top": "top artists and tracks", "/me/tracks": "Liked Songs", "/me/playlists": "your playlists",
    "/me/player/devices": "devices", "/me/player": "playback",
}


def active_limits():
    limits = []
    limit_dir = os.path.join(CACHE_DIR, "rate-limited")
    for name in sorted(os.listdir(limit_dir)) if os.path.isdir(limit_dir) else []:
        if name.endswith(".tmp") or name.startswith("."):
            continue
        record = limit_record(os.path.join(limit_dir, name))
        left = record.get("deadline", 0) - time.time()
        if left > 0:
            endpoint = "all" if name == "global" else "/" + name.replace("_", "/")
            if name == "public-pages":
                endpoint = "open.spotify.com"
            reason = record.get("reason", "")
            label = ("Spotify API quota" if reason == "QUOTA_EXCEEDED" else "all Spotify requests") if name == "global" else LIMIT_LABELS.get(endpoint, endpoint)
            if name == "public-pages":
                label = "public Spotify pages"
            limits.append({"endpoint": endpoint, "label": label, "seconds": max(1, int(left + 1)),
                           "scope": record.get("scope", "endpoint"), "reason": reason})
    return limits


def cmd_rate_limits(_args):
    """rate-limits: endpoints Spotify is holding back, from local files only."""
    return {"limits": active_limits()}


def cmd_cache_clear(args):
    """cache-clear <group id|all>. Never clears the rate-limit waits: those
    stop the app from asking Spotify again before it allows."""
    wanted = args[0] if args else ""
    folders = [f for ident, _l, _d, fs in CACHE_GROUPS if wanted in (ident, "all") for f in fs]
    if wanted == "all":
        folders.append("update")
    if not folders:
        raise HelperError("Usage: cache-clear <" + "|".join(g[0] for g in CACHE_GROUPS) + "|all>")
    with state_lock("cache-epochs"):
        for folder in folders:
            bump_cache_epoch(folder)
            shutil.rmtree(os.path.join(CACHE_DIR, folder), ignore_errors=True)
    return cmd_cache_info([])


def cached(kind, key, max_age, fetch):
    digest = hashlib.sha1(key.encode()).hexdigest()
    path = os.path.join(CACHE_DIR, kind, digest + ".json")
    with state_lock("public-key:" + path):
        with state_lock("cache-epochs"):
            epoch = cache_epoch(kind)
            value = fresh_json(path, max_age)
            if value is not None:
                return value
        try:
            value = fetch()
        except RateLimited:
            with state_lock("cache-epochs"):
                value = read_json(path, None) if epoch == cache_epoch(kind) else None
            if value is None:
                raise
            RESPONSE_META.update({"stale": True, "limits": active_limits()})
            return value
        with state_lock("cache-epochs"):
            if epoch == cache_epoch(kind):
                write_private_json(path, value)
        return value


def get_public_json(url, retry=True):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.loads(read_limited(response, LIMIT_PUBLIC_JSON, urllib.parse.urlparse(url).netloc + " response"))
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


# ------------------------------------------------------------ file quality
#
# Soloist doesn't report which audio file it streams. Its cache files are
# encrypted, but their size is the full file size from the start, and
# Soloist keeps the playing file open. Size / duration gives the average
# bitrate, which separates Spotify's tiers cleanly: Ogg Vorbis tops out at
# 320 kbit/s, 16-bit FLAC averages ~600-1400, 24-bit FLAC more.

QUALITY_TIERS = [
    # (max average kbit/s, tier id, label, format line, data per hour)
    (60, "low", "Low", "24 kbit/s • Ogg Vorbis", "About 0.01 GB/hour"),
    (130, "normal", "Normal", "96 kbit/s • Ogg Vorbis", "About 0.04 GB/hour"),
    (240, "high", "High", "160 kbit/s • Ogg Vorbis", "About 0.07 GB/hour"),
    (480, "very_high", "Very high", "320 kbit/s • Ogg Vorbis", "About 0.15 GB/hour"),
    (1600, "lossless", "Lossless 16-bit", "Up to 16-bit/44.1 kHz • FLAC", "Up to 0.7 GB/hour"),
    (10 ** 9, "lossless24", "Lossless 24-bit", "Up to 24-bit/44.1 kHz • FLAC", "Up to 1 GB/hour"),
]


def soloist_open_audio_files(data_dir):
    try:
        with open(os.path.join(data_dir, "soloist.pid"), encoding="utf-8") as handle:
            pid = handle.read().strip()
        fd_dir = f"/proc/{pid}/fd"
        targets = [os.readlink(os.path.join(fd_dir, fd)) for fd in os.listdir(fd_dir)]
    except OSError:
        return []
    return sorted({t for t in targets if t.endswith(".file") and "/soloist/" in t})


def cmd_quality(args):
    """quality <data dir> <duration ms>: estimated quality of the playing file."""
    if len(args) < 2:
        raise HelperError("Usage: quality <data dir> <duration ms>")
    duration = int(args[1]) / 1000
    files = soloist_open_audio_files(args[0])
    if not files or duration <= 0:
        return {"found": False}
    # Normally only the playing file is open. With two (the next track
    # preloading) we can't tell which is which; the widget asks again later.
    if len(files) > 1:
        return {"found": False, "ambiguous": True}
    size = os.path.getsize(files[0])
    kbps = size * 8 / duration / 1000
    for limit, tier, label, fmt, per_hour in QUALITY_TIERS:
        if kbps < limit:
            break
    return {"found": True, "tier": tier, "label": label, "format": fmt, "perHour": per_hour,
            "lossless": tier.startswith("lossless"), "kbps": round(kbps), "bytes": size}


# ----------------------------------------------------------- audio path
#
# What happens after Soloist decodes: its PipeWire stream format and the
# device it plays on (rate, sample format, Bluetooth codec), from pw-dump.

SAMPLE_BITS = {"S16": 16, "S24": 24, "S24_32": 24, "S32": 32, "F32": 32, "F64": 64, "U8": 8}
BLUETOOTH_CODECS = {
    "sbc": "SBC", "sbc_xq": "SBC-XQ", "aac": "AAC", "aac_eld": "AAC-ELD", "aptx": "aptX",
    "aptx_hd": "aptX HD", "aptx_ll": "aptX LL", "ldac": "LDAC", "lc3": "LC3", "lc3plus_h3": "LC3plus",
    "opus_05": "Opus", "opus_g": "Opus", "faststream": "FastStream", "msbc": "mSBC", "cvsd": "CVSD",
}


def sample_format(fmt):
    """("F32LE" -> ("32-bit float", 32)), ("S16LE" -> ("16-bit", 16))."""
    base = (fmt or "").upper().rstrip("P")
    for suffix in ("LE", "BE"):
        if base.endswith(suffix):
            base = base[:-2]
    bits = SAMPLE_BITS.get(base, 0)
    if not bits:
        return fmt or "", 0
    return (f"{bits}-bit float" if base.startswith("F") else f"{bits}-bit"), bits


def cmd_audio_path(args):
    """audio-path [data dir]: Soloist's PipeWire stream and output device."""
    data_dir = args[0] if args else os.path.join(HOME, ".local", "share", "soloist")
    try:
        dump = json.loads(run_quiet(["pw-dump"]).stdout or "[]")
    except (OSError, ValueError, subprocess.SubprocessError):
        return {"found": False, "error": "pw-dump is not available"}
    by_id = {o.get("id"): o for o in dump}
    try:
        with open(os.path.join(data_dir, "soloist.pid"), encoding="utf-8") as handle:
            soloist_pid = handle.read().strip()
    except OSError:
        soloist_pid = ""

    def props(obj):
        return ((obj or {}).get("info") or {}).get("props") or {}

    def fmt_of(obj):
        formats = (((obj or {}).get("info") or {}).get("params") or {}).get("Format") or []
        return formats[0] if formats else {}

    # Soloist's stream: the output stream whose client is the Soloist process
    # (it names itself "spotify"/"Spotify").
    stream = None
    for obj in dump:
        p = props(obj)
        if obj.get("type") != "PipeWire:Interface:Node" or not p.get("media.class", "").startswith("Stream/Output/Audio"):
            continue
        client = props(by_id.get(p.get("client.id")))
        if soloist_pid and str(client.get("application.process.id", "")) == soloist_pid:
            stream = obj
            break
        if stream is None and p.get("node.name") == "spotify":
            stream = obj
    if stream is None:
        return {"found": False}

    f = fmt_of(stream)
    fmt_label, bits = sample_format(f.get("format"))
    rate, channels = int(f.get("rate") or 0), int(f.get("channels") or 0)
    result = {"found": True, "stream": {
        "rate": rate, "channels": channels, "format": fmt_label,
        "pcmKbps": round(rate * bits * channels / 1000) if bits else 0}}

    # Follow links to the first Audio/Sink (through filters, if any).
    seen, frontier, sink = set(), [stream.get("id")], None
    while frontier and sink is None:
        node_id = frontier.pop(0)
        if node_id in seen:
            continue
        seen.add(node_id)
        for obj in dump:
            info = obj.get("info") or {}
            if obj.get("type") == "PipeWire:Interface:Link" and info.get("output-node-id") == node_id:
                target = by_id.get(info.get("input-node-id"))
                if "Audio/Sink" in props(target).get("media.class", ""):
                    sink = target
                    break
                frontier.append(info.get("input-node-id"))
    if sink is not None:
        p = props(sink)
        sf = fmt_of(sink)
        sink_fmt, _ = sample_format(sf.get("format"))
        bluetooth = p.get("device.api") == "bluez5"
        codec = p.get("api.bluez5.codec", "")
        result["output"] = {
            "name": p.get("node.description") or p.get("node.nick") or p.get("node.name", ""),
            "kind": "Bluetooth" if bluetooth else "HDMI" if "hdmi" in p.get("node.name", "") else
                    "USB" if "usb" in p.get("node.name", "") else "Speakers/headphones",
            "bluetooth": bluetooth,
            "codec": BLUETOOTH_CODECS.get(codec, codec.upper()) if bluetooth else "",
            "rate": int(sf.get("rate") or 0), "format": sink_fmt,
        }
    return result


# ---------------------------------------------------------- update check

REPOSITORY = "vleeuwenmenno/omasoloist"
UPDATE_STATE = os.path.join(STATE_DIR, "update.json")


def version_key(tag):
    """"v0.3.10" -> (0, 3, 10); anything unparsable sorts first."""
    parts = re.findall(r"\d+", tag or "")
    return tuple(int(p) for p in parts[:4]) if parts else (-1,)


def cmd_update_check(args):
    """update-check <installed version>

    Newest release tag on GitHub (cached for 6 hours, anonymous API), and
    whether a desktop notification is due: once per newer version.
    """
    installed = args[0] if args else "0"

    def fetch():
        tags = get_public_json(f"https://api.github.com/repos/{REPOSITORY}/tags?per_page=100") or []
        names = [t.get("name", "") for t in tags if re.match(r"^v?\d+(\.\d+)*$", t.get("name", ""))]
        return {"latest": max(names, key=version_key) if names else ""}

    latest = cached("update", REPOSITORY, 6 * 3600, fetch).get("latest", "")
    outdated = bool(latest) and version_key(latest) > version_key(installed)
    state = read_json(UPDATE_STATE, {})
    notify = outdated and state.get("notified") != latest
    if notify:
        write_private_json(UPDATE_STATE, dict(state, notified=latest))
    return {"installed": installed, "latest": latest.lstrip("v"), "outdated": outdated, "notify": notify,
            "releasesUrl": f"https://github.com/{REPOSITORY}/releases"}


COMMANDS = {
    "status": cmd_status,
    "set-client-id": cmd_set_client_id,
    "login": cmd_login,
    "logout": cmd_logout,
    "me": cmd_me,
    "playlists": cmd_playlists,
    "saved-albums": cmd_saved_albums,
    "followed-artists": cmd_followed_artists,
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
    "history": cmd_history,
    "history-sync": cmd_history_sync,
    "history-info": cmd_history_info,
    "history-clear": cmd_history_clear,
    "artist": cmd_artist,
    "profile": cmd_profile,
    "radio": cmd_radio,
    "update-check": cmd_update_check,
    "quality": cmd_quality,
    "audio-path": cmd_audio_path,
    "lyrics": cmd_lyrics,
    "cache-info": cmd_cache_info,
    "rate-limits": cmd_rate_limits,
    "cache-clear": cmd_cache_clear,
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
    RESPONSE_META.clear()
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
        if RESPONSE_META.get("session") and RESPONSE_META["session"] != api_session():
            raise HelperError("Spotify sign-in changed. Try again.")
    except HelperError as error:
        result = {"ok": False, "error": str(error)}
        if isinstance(error, RateLimited):
            result.update({"rateLimited": True, "retryAfter": max(1, int(error.seconds + 1)),
                           "reason": error.reason, "limits": active_limits()})
        print(json.dumps(result))
        return 1
    except Exception as error:  # noqa: BLE001 - always answer the widget in JSON
        print(json.dumps({"ok": False, "error": f"{type(error).__name__}: {error}"}))
        return 1
    print(json.dumps(dict(result, **RESPONSE_META, ok=True)))
    sys.stdout.flush()
    flush_image_queue()
    return 0


if __name__ == "__main__":
    sys.exit(main())
