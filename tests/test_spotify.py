"""Offline regression checks for cache isolation, invalidation and request limits.

Run: python3 -I -m unittest discover -s tests -v
"""
import importlib.util
import io
import json
import multiprocessing
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

SOURCE = Path(__file__).resolve().parents[1] / "bin" / "spotify.py"
spec = importlib.util.spec_from_file_location("spotify", SOURCE)
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)


class Response(io.BytesIO):
    headers = {}

    def __init__(self, value):
        super().__init__(json.dumps(value).encode())


class CacheTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.folder = temporary.name
        for name, value in {
            "CACHE_DIR": self.folder + "/cache",
            "IMAGE_DIR": self.folder + "/cache/images",
            "STATE_DIR": self.folder + "/state",
            "TOKEN_FILE": self.folder + "/state/token.json",
            "CONFIG_DIR": self.folder + "/config",
            "CONFIG_FILE": self.folder + "/config/config.json",
        }.items():
            self.start(patch.object(s, name, value))
        self.start(patch.dict(os.environ, {}, clear=True))
        self.start(patch.object(s.urllib.request, "urlopen", side_effect=AssertionError("Live network is forbidden")))
        s.RESPONSE_META.clear()
        s.cmd_set_client_id(["test-client"])
        s.store_token({"access_token": "test-access", "refresh_token": "test-refresh"})

    def start(self, mock):
        value = mock.start()
        self.addCleanup(mock.stop)
        return value

    def seed(self, path, value, age=0, params=None):
        url = s.API_URL + path
        if params:
            url += "?" + s.urllib.parse.urlencode(sorted(params.items()))
        slot, _ = s.api_cache_slot("GET", path, url)
        s.write_private_json(slot, value)
        os.utime(slot, (time.time() - age, time.time() - age))
        return slot

    def error(self, status=429, seconds=5, reason=""):
        body = io.BytesIO(json.dumps({"error": {"message": "Too many requests", "reason": reason}}).encode())
        error = HTTPError(s.API_URL + "/me/player", status, "HTTP error", {"Retry-After": str(seconds)}, body)
        self.addCleanup(error.close)
        return error

    def test_cache_reuses_fresh_values_and_refetches_expired_values(self):
        slot = self.seed("/me/playlists", {"old": True})
        with patch.object(s, "api_request", return_value={"new": True}) as fetch:
            self.assertEqual(s.api("GET", "/me/playlists"), {"old": True})
            fetch.assert_not_called()
            os.utime(slot, (0, 0))
            self.assertEqual(s.api("GET", "/me/playlists"), {"new": True})
            fetch.assert_called_once()

    def test_fresh_bypass_updates_cache(self):
        self.seed("/me/playlists", {"old": True})
        with patch.dict(os.environ, {"OMASOLOIST_FRESH": "1"}), patch.object(s, "api_request", return_value={"new": True}):
            self.assertEqual(s.api("GET", "/me/playlists"), {"new": True})
        self.assertEqual(s.api("GET", "/me/playlists"), {"new": True})

    def test_parameter_order_does_not_duplicate_cache_entries(self):
        with patch.object(s, "api_request", return_value={}) as fetch:
            s.api("GET", "/me/playlists", {"limit": 50, "offset": 0})
            s.api("GET", "/me/playlists", {"offset": 0, "limit": 50})
            fetch.assert_called_once()

    def test_writes_and_live_player_are_not_cached(self):
        with patch.object(s, "api_request", return_value={}) as fetch:
            for _ in range(2):
                s.api("PUT", "/me/library")
                s.api("GET", "/me/player")
            self.assertEqual(fetch.call_count, 4)

    def test_new_login_cannot_read_previous_account_cache(self):
        self.seed("/me", {"id": "A"})
        s.store_token({"access_token": "B", "refresh_token": "B"})
        with patch.object(s, "api_request", return_value={"id": "B"}) as fetch:
            self.assertEqual(s.api("GET", "/me"), {"id": "B"})
            fetch.assert_called_once()

    def test_logout_blocks_cache_access(self):
        self.seed("/me", {"id": "A"})
        s.cmd_logout([])
        with self.assertRaisesRegex(s.HelperError, "Not signed in"):
            s.api("GET", "/me")

    def test_client_id_change_invalidates_legacy_token(self):
        token = s.read_json(s.TOKEN_FILE, {})
        token.pop("client_id")
        s.write_private_json(s.TOKEN_FILE, token)
        s.cmd_set_client_id(["different-client"])
        self.assertFalse(s.cmd_status([])["signedIn"])

    def test_refresh_preserves_cache_namespace(self):
        session = s.api_session()
        previous = s.read_json(s.TOKEN_FILE, {})
        s.store_token({"access_token": "new", "refresh_token": "rotated"}, previous)
        self.assertEqual(s.api_session(), session)

    def test_aggregate_cannot_mix_accounts_between_requests(self):
        self.seed("/me", {"id": "A"})
        s.api("GET", "/me")
        s.store_token({"access_token": "B", "refresh_token": "B"})
        with self.assertRaisesRegex(s.HelperError, "sign-in changed"):
            s.api("GET", "/me/playlists")

    def test_cache_hit_reports_original_age(self):
        self.seed("/me/library/contains", [True], age=25)
        self.assertEqual(s.api("GET", "/me/library/contains"), [True])
        self.assertGreaterEqual(s.RESPONSE_META["cacheAge"], 25)

    def test_changed_session_during_read_is_rejected(self):
        def fetch(*_):
            s.store_token({"access_token": "B", "refresh_token": "B"})
            return {"id": "A"}
        with patch.object(s, "api_request", side_effect=fetch), self.assertRaisesRegex(s.HelperError, "sign-in changed"):
            s.api("GET", "/me")

    def test_single_flight_across_processes(self):
        self.check_single_flight(False)

    def test_single_flight_includes_simultaneous_fresh_requests(self):
        self.seed("/me/player/devices", {"old": True})
        self.check_single_flight(True)

    def check_single_flight(self, fresh):
        ctx = multiprocessing.get_context("fork")
        ready = ctx.Barrier(2)
        count = ctx.Value("i", 0)
        def fetch(*_):
            with count.get_lock():
                count.value += 1
            time.sleep(0.05)
            return {"devices": []}
        def worker():
            ready.wait(timeout=5)
            s.api("GET", "/me/player/devices")
        with patch.object(s, "api_request", side_effect=fetch), patch.dict(os.environ, {"OMASOLOIST_FRESH": "1"} if fresh else {}):
            workers = [ctx.Process(target=worker) for _ in range(2)]
            for process in workers:
                process.start()
            for process in workers:
                process.join(8)
                if process.is_alive():
                    process.terminate()
                self.assertEqual(process.exitcode, 0)
        self.assertEqual(count.value, 1)
        slot, _ = s.api_cache_slot("GET", "/me/player/devices", s.API_URL + "/me/player/devices")
        self.assertEqual(s.read_json(slot, None), {"devices": []})

    def test_invalidation_discards_inflight_snapshot(self):
        fetched = 0
        def fetch(method, *_):
            nonlocal fetched
            if method != "GET":
                return {}
            fetched += 1
            if fetched == 1:
                s.cmd_like(["spotify:track:A"])
                return [False]
            return [True]
        with patch.object(s, "api_request", side_effect=fetch):
            self.assertEqual(s.api("GET", "/me/library/contains", {"uris": "spotify:track:A"}), [True])
        self.assertEqual(fetched, 2)

    def test_clear_api_discards_inflight_snapshot(self):
        calls = 0
        def fetch(*_):
            nonlocal calls
            calls += 1
            if calls == 1:
                s.cmd_cache_clear(["api"])
            return {"version": calls}
        with patch.object(s, "api_request", side_effect=fetch):
            self.assertEqual(s.api("GET", "/me/playlists"), {"version": 2})

    def test_public_cache_clear_does_not_restore_pending_write(self):
        def fetch():
            s.cmd_cache_clear(["lyrics"])
            return {"plain": "old"}
        self.assertEqual(s.cached("lyrics", "A", 100, fetch), {"plain": "old"})
        self.assertFalse(Path(s.CACHE_DIR, "lyrics").exists())

    def test_like_invalidates_only_related_library_groups(self):
        contains = self.seed("/me/library/contains", [False])
        tracks = self.seed("/me/tracks", {})
        playlists = self.seed("/me/playlists", {})
        following = self.seed("/me/following", {})
        with patch.object(s, "api_request", return_value={}):
            s.cmd_like(["spotify:track:A"])
        self.assertFalse(Path(contains).exists())
        self.assertFalse(Path(tracks).exists())
        self.assertTrue(Path(playlists).exists())
        self.assertTrue(Path(following).exists())
        with patch.object(s, "api_request", return_value={}):
            s.cmd_like(["spotify:artist:A"])
        self.assertFalse(Path(following).exists())

    def test_transfer_invalidates_devices(self):
        slot = self.seed("/me/player/devices", {})
        with patch.object(s, "api_request", return_value={}):
            s.cmd_transfer(["A"])
        self.assertFalse(Path(slot).exists())

    def test_playlist_mutation_invalidates_items_and_library(self):
        slots = [self.seed(path, {}) for path in ["/playlists/A/items", "/me/playlists"]]
        with patch.object(s, "api_request", return_value={}):
            s.cmd_add_to_playlist(["A", "spotify:track:B"])
        self.assertTrue(all(not Path(slot).exists() for slot in slots))

    def test_short_429_is_persisted_without_retry(self):
        with patch.object(s.urllib.request, "urlopen", side_effect=self.error()) as network:
            for path in ["/me/player", "/me/playlists"]:
                with self.assertRaises(s.RateLimited):
                    s.api("GET", path)
            self.assertEqual(network.call_count, 1)
        self.assertGreater(s.rate_limit_wait("/search"), 0)

    def test_quota_reason_and_global_scope_are_exposed(self):
        with patch.object(s.urllib.request, "urlopen", side_effect=self.error(seconds=3600, reason="QUOTA_EXCEEDED")):
            with self.assertRaises(s.RateLimited) as raised:
                s.api("GET", "/me/player")
        self.assertEqual(raised.exception.reason, "QUOTA_EXCEEDED")
        limit = s.active_limits()[0]
        self.assertEqual(limit["scope"], "global")
        self.assertEqual(limit["label"], "Spotify API quota")

    def test_later_response_cannot_shorten_deadline(self):
        s.note_rate_limit("/me/player", 3600)
        s.note_rate_limit("/me/playlists", 1)
        self.assertGreater(s.rate_limit_wait("/search"), 3590)

    def test_stale_fallback_is_marked_and_does_not_send_request(self):
        self.seed("/me/playlists", {"items": []}, age=301)
        s.note_rate_limit("/me/player", 60)
        self.assertEqual(s.api("GET", "/me/playlists"), {"items": []})
        self.assertTrue(s.RESPONSE_META["stale"])
        self.assertEqual(len(s.RESPONSE_META["limits"]), 1)

    def test_clear_all_preserves_cooldowns_signin_and_metrics(self):
        slot = self.seed("/me/playlists", {})
        s.note_rate_limit("/me/player", 3600)
        s.request_stat("requests")
        result = s.cmd_cache_clear(["all"])
        self.assertFalse(Path(slot).exists())
        self.assertTrue(s.cmd_status([])["signedIn"])
        self.assertGreater(s.rate_limit_wait("/me/player"), 3590)
        self.assertEqual(result["stats"]["requests"], 1)
        self.assertEqual(len(result["limits"]), 1)

    def test_legacy_endpoint_wait_is_honored(self):
        file = s.rate_limit_file("/me/player")
        s.atomic_write(file, str(time.time() + 60).encode())
        self.assertGreater(s.rate_limit_wait("/me/player/queue"), 59)
        self.assertEqual(s.active_limits()[0]["label"], "playback")

    def test_expired_cooldown_does_not_prevent_requests(self):
        s.note_rate_limit("/me/player", -1)
        with patch.object(s.urllib.request, "urlopen", return_value=Response({"active": True})) as network:
            self.assertEqual(s.api("GET", "/me/player"), {"active": True})
            network.assert_called_once()
        self.assertEqual(s.active_limits(), [])

    def test_pacing_window_reserves_capacity_for_controls(self):
        clock = [1000.0]
        starts = []
        def network(*_, **__):
            starts.append(clock[0])
            return Response({})
        with patch.object(s.time, "time", side_effect=lambda: clock[0]), patch.object(s.time, "sleep", side_effect=lambda delay: clock.__setitem__(0, clock[0] + delay)), patch.object(s.urllib.request, "urlopen", side_effect=network):
            for _ in range(s.REQUEST_LIMIT - s.CONTROL_RESERVE - 2):
                s.api("GET", "/me/player")
            for _ in range(2):
                s.api("POST", "/me/player/queue")
            for _ in range(s.CONTROL_RESERVE):
                s.api("PUT", "/me/player/play")
            self.assertLess(starts[-1] - starts[0], s.REQUEST_WINDOW)
            s.api("GET", "/me/player")
        self.assertGreaterEqual(starts[-1] - starts[0], s.REQUEST_WINDOW)
        self.assertTrue(all(b - a >= s.REQUEST_INTERVAL - 0.0001 for a, b in zip(starts, starts[1:])))

    def test_editorial_playlist_capability_failure_is_cached(self):
        with patch.object(s.urllib.request, "urlopen", side_effect=[self.error(status=403), self.error(status=403)]), patch.object(s, "spotify_playlist_tracks", return_value={"items": []}) as fallback:
            with patch.object(s, "REQUEST_INTERVAL", 0):
                network = s.urllib.request.urlopen
                s.cmd_playlist_tracks(["37i9test"])
                s.cmd_playlist_tracks(["37i9test"])
            self.assertEqual(network.call_count, 2)
            self.assertEqual(fallback.call_count, 2)

    def test_like_refresh_observes_external_changes_after_thirty_seconds(self):
        self.seed("/me/library/contains", [False], age=31, params={"uris": "spotify:track:A"})
        with patch.object(s, "api_request", return_value=[True]):
            self.assertTrue(s.cmd_liked_contains(["spotify:track:A"])["liked"]["spotify:track:A"])

    def test_partial_likes_expose_cooldown_without_false_values(self):
        s.note_rate_limit("/me/player", 60)
        self.assertEqual(s.cmd_liked_contains(["spotify:track:A"]), {"liked": {}})
        self.assertTrue(s.RESPONSE_META["partial"])
        self.assertGreater(s.RESPONSE_META["retryAfter"], 0)

    def test_missing_retry_after_uses_conservative_cooldown(self):
        error = self.error()
        error.headers = {}
        with patch.object(s.urllib.request, "urlopen", side_effect=error), self.assertRaises(s.RateLimited):
            s.api("GET", "/me/player")
        self.assertGreater(s.rate_limit_wait("/search"), 29)

    def test_public_page_cooldown_does_not_block_web_api(self):
        with patch.object(s.urllib.request, "urlopen", side_effect=self.error(seconds=60)) as network:
            self.assertIsNone(s.public_page_entity("playlist", "A"))
            self.assertIsNone(s.public_page_entity("playlist", "B"))
            network.assert_called_once()
        self.assertEqual(s.rate_limit_wait("/me/player"), 0)
        self.assertEqual(s.active_limits()[0]["scope"], "public")

    def test_public_cache_stale_fallback_during_cooldown(self):
        value = {"name": "old"}
        s.cached("overview", "playlist:A", 1, lambda: value)
        for path in Path(s.CACHE_DIR, "overview").glob("*.json"):
            os.utime(path, (0, 0))
        def fetch():
            raise s.rate_limit_error(60)
        self.assertEqual(s.cached("overview", "playlist:A", 1, fetch), value)
        self.assertTrue(s.RESPONSE_META["stale"])

    def test_image_clear_discards_inflight_artwork(self):
        data = b"valid-image-for-test"
        def network(*_, **__):
            s.cmd_cache_clear(["images"])
            response = io.BytesIO(data)
            response.headers = {}
            return response
        with patch.object(s.urllib.request, "urlopen", side_effect=network), patch.object(s, "acceptable_image", return_value=True):
            self.assertFalse(s.fetch_image("https://i.scdn.co/image/test"))
        self.assertFalse(Path(s.IMAGE_DIR).exists())

    def test_atomic_writes_never_mix_concurrent_payloads(self):
        path = self.folder + "/value.json"
        values = [{"value": "A" * 10000}, {"value": "B"}]
        barrier = threading.Barrier(2)
        def write(value):
            barrier.wait(timeout=5)
            s.write_private_json(path, value)
        threads = [threading.Thread(target=write, args=(value,)) for value in values]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(5)
            self.assertFalse(thread.is_alive())
        self.assertIn(s.read_json(path, None), values)
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)


class HistoryTests(unittest.TestCase):
    # Same isolated folders and no-network guard as CacheTests.
    setUp = CacheTests.setUp
    start = CacheTests.start
    album = {"uri": "spotify:album:A", "id": "A", "name": "Album", "images": [], "artists": []}

    def play(self, track, when, context=None):
        return {"track": {"uri": "spotify:track:" + track, "name": track, "album": self.album, "artists": []},
                "played_at": when, "context": context}

    def history(self, plays, *args):
        def api(method, path, params=None):
            if path == "/me":
                return {"id": "me"}
            if path == "/me/player/recently-played":
                return {"items": plays}
            return {"uri": "spotify:playlist:P", "id": "P", "name": "Mine", "images": [], "owner": {}}
        with patch.object(s, "api", side_effect=api), patch.dict(os.environ, {"TZ": "UTC"}):
            time.tzset()
            try:
                return s.cmd_history(list(args))
            finally:
                os.environ.pop("TZ", None)
                time.tzset()

    def test_history_groups_plays_by_day_and_context(self):
        playlist = {"uri": "spotify:playlist:P"}
        plays = [self.play("1", "2026-09-30T12:00:00.000Z", playlist), self.play("2", "2026-09-30T11:00:00.000Z"),
                 self.play("3", "2026-09-30T10:00:00.000Z", playlist), self.play("4", "2026-08-28T12:00:00.000Z")]
        days = self.history(plays)["days"]
        self.assertEqual([d["date"] for d in days], ["2026-09-30", "2026-08-28"])
        groups = days[0]["groups"]
        self.assertEqual([g["item"]["uri"] for g in groups], ["spotify:playlist:P", "spotify:album:A"])
        self.assertEqual([t["name"] for t in groups[0]["tracks"]], ["1", "3"])
        self.assertTrue(groups[0]["tracks"][0]["played_at"].startswith("2026-09-30T12:00:00"))

    def test_history_keeps_plays_spotify_forgot_and_skips_duplicates(self):
        self.history([self.play("old", "2026-09-29T08:00:00.000Z")])
        self.history([self.play("new", "2026-09-30T08:00:00.000Z"), self.play("old", "2026-09-29T08:00:00.000Z")])
        result = self.history([self.play("newer", "2026-09-30T09:00:00.000Z")])
        names = [t["name"] for d in result["days"] for g in d["groups"] for t in g["tracks"]]
        self.assertEqual(names, ["newer", "new", "old"])
        self.assertEqual(result["next"], 0)

    def test_history_pages_end_on_whole_days(self):
        plays = [self.play(str(i), "2026-09-%02dT%02d:00:00.000Z" % (30 - i // 20, i % 20)) for i in range(300)]
        with patch.object(s, "HISTORY_PAGE", 50):
            first = self.history(plays)
            self.assertEqual(sum(len(g["tracks"]) for d in first["days"] for g in d["groups"]), 60)
            second = self.history([], str(first["next"]))
        self.assertEqual(second["days"][0]["date"], "2026-09-27")
        self.assertNotIn(second["days"][0]["date"], [d["date"] for d in first["days"]])


if __name__ == "__main__":
    unittest.main()
