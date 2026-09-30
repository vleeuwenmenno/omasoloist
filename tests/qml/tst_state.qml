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
