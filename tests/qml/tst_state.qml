import QtQuick
import QtTest
import "../.." as Oma

TestCase {
    id: test
    name: "CacheState"

    property var subject: null

    QtObject {
        id: api
        property bool signedIn: true
        property var requests: []
        signal sessionReset()
        signal cacheCleared(string group)
        signal libraryChanged(string uri)
        function waitFor(path) { return 0; }
        function call(args, callback) { requests = requests.concat([{args: args, callback: callback}]); }
    }

    Component { id: likes; Oma.Likes {} }
    Component { id: collection; Oma.CollectionModel {} }
    Component { id: remote; Oma.RemotePlayer {} }

    function init() { api.requests = []; api.signedIn = true; }
    function cleanup() { if (subject) subject.destroy(); subject = null; }

    function test_likes_reset_rejects_old_callback() {
        subject = likes.createObject(test, {api: api});
        verify(subject !== null);
        subject.query(["spotify:track:A"]);
        compare(api.requests.length, 1);
        var old = api.requests[0];
        api.sessionReset();
        old.callback({ok: true, liked: {"spotify:track:A": true}});
        compare(subject.isLiked("spotify:track:A"), false);
        compare(Object.keys(subject.known).length, 0);
    }

    function test_hidden_current_track_does_not_query_until_shown() {
        subject = likes.createObject(test, {api: api});
        subject.currentUri = "spotify:track:A";
        subject.refreshCurrent();
        compare(api.requests.length, 0);
        subject.currentWanted = true;
        compare(api.requests.length, 1);
        api.requests[0].callback({ok: true, liked: {"spotify:track:A": true}});
        subject.refreshCurrent();
        compare(api.requests.length, 1);
        subject.currentWanted = false;
        subject.currentUri = "spotify:track:B";
        compare(api.requests.length, 1);
        subject.currentWanted = true;
        compare(api.requests.length, 2);
    }

    function test_remote_poll_cadence_recovers_from_long_cooldown() {
        subject = remote.createObject(test, {api: api});
        compare(subject.pollInterval, 300000);
        subject.active = true;
        subject.playing = true;
        compare(subject.pollInterval, 60000);
        subject.fast = true;
        compare(subject.pollInterval, 15000);
        subject.retryUntil = Date.now() + 12 * 3600000;
        compare(subject.pollInterval, 15000);
        subject.retryUntil = Date.now() - 1;
        subject.polling = true;
        compare(api.requests.length, 1);
        api.requests[0].callback({ok: true, active: false});
        compare(subject.retryUntil, 0);
        compare(subject.pollInterval, 60000);
        subject.fast = false;
        compare(subject.pollInterval, 300000);
    }

    function test_likes_clear_resets_known_state() {
        subject = likes.createObject(test, {api: api});
        subject.set({"spotify:track:A": true});
        compare(subject.isLiked("spotify:track:A"), true);
        api.cacheCleared("api");
        compare(subject.isLiked("spotify:track:A"), false);
    }

    function test_like_read_cannot_undo_successful_toggle() {
        subject = likes.createObject(test, {api: api});
        subject.query(["spotify:track:A"]);
        subject.toggle("spotify:track:A");
        compare(api.requests.length, 2);
        api.requests[1].callback({ok: true});
        api.requests[0].callback({ok: true, liked: {"spotify:track:A": false}});
        compare(subject.isLiked("spotify:track:A"), true);
    }

    function test_collection_mutation_rejects_pending_page() {
        subject = collection.createObject(test, {api: api});
        subject.collection = {kind: "liked", uri: "spotify:user:A:collection"};
        compare(api.requests.length, 1);
        var old = api.requests[0];
        api.libraryChanged("spotify:track:A");
        compare(api.requests.length, 2);
        old.callback({ok: true, items: [{uri: "old"}], total: 1, next: false});
        compare(subject.tracks.length, 0);
        compare(subject.loading, true);
        api.requests[1].callback({ok: true, items: [{uri: "new"}], total: 1, next: false});
        compare(subject.tracks[0].uri, "new");
        compare(subject.loading, false);
    }

    function test_collection_stops_hidden_paging_and_resumes_past_removed_items() {
        subject = collection.createObject(test, {api: api});
        subject.collection = {kind: "playlist", id: "A"};
        compare(api.requests.length, 1);
        subject.active = false;
        api.requests[0].callback({ok: true, items: [], total: 100, next: true, nextOffset: 50, snapshot: "one"});
        wait(1);
        compare(api.requests.length, 1);
        subject.active = true;
        compare(api.requests.length, 2);
        compare(api.requests[1].args, ["playlist-tracks", "A", "50"]);
        api.requests[1].callback({ok: true, items: [{uri: "last"}], total: 100, next: false, nextOffset: 100, snapshot: "one"});
        compare(subject.tracks.length, 1);
        compare(subject.loadedAll, true);
    }

    function test_collection_does_not_mix_known_playlist_versions() {
        subject = collection.createObject(test, {api: api});
        subject.collection = {kind: "playlist", id: "A"};
        api.requests[0].callback({ok: true, items: [{uri: "first"}], total: 2, next: true, nextOffset: 1, snapshot: "one"});
        subject.load(false);
        api.requests[1].callback({ok: true, items: [{uri: "changed"}], total: 2, next: false, nextOffset: 2, snapshot: "two"});
        compare(subject.tracks.length, 1);
        verify(subject.error.indexOf("changed while loading") >= 0);
        compare(subject.loadedAll, true);
    }

    function test_remote_reset_clears_queue_and_device() {
        subject = remote.createObject(test, {api: api});
        subject.active = true;
        subject.device = {id: "A", name: "Test device", supportsVolume: false};
        subject.queueUpcoming = [{item: {uri: "spotify:track:A"}}];
        api.sessionReset();
        compare(subject.active, false);
        compare(subject.deviceId, "");
        compare(subject.queueUpcoming.length, 0);
    }
}
