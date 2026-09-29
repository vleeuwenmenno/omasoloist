import QtQuick

// Loads the tracks of one playlist, album or Liked Songs page by page and
// starts playback from a chosen track. Shared by the bar popup and the app
// window.
QtObject {
    id: root

    required property var api
    property var collection: null

    property var tracks: []
    // Name/art/owner from the helper, for collections opened by URI only.
    property var meta: null
    property int total: 0
    property bool loading: false
    property bool loadedAll: false
    property string error: ""
    property string pendingUri: ""
    // Keep loading pages until everything is in (sorting and filtering need
    // the whole list). Capped at 5000 songs.
    property bool wantAll: false
    onWantAllChanged: if (wantAll && !loadedAll) load(false)
    readonly property real totalMs: {
        var sum = 0;
        for (var i = 0; i < tracks.length; i++) sum += tracks[i].duration_ms || 0;
        return sum;
    }

    readonly property bool isLiked: collection !== null && collection.kind === "liked"

    function load(reset) {
        if (!collection || loading || (!reset && loadedAll)) return;
        if (reset) { tracks = []; total = 0; loadedAll = false; error = ""; meta = null; }
        loading = true;
        var requested = collection;
        var kind = collection.kind;
        var args = kind === "liked" ? ["liked", String(tracks.length)]
            : kind === "album" ? ["album-tracks", collection.id, String(tracks.length)]
            : ["playlist-tracks", collection.id, String(tracks.length)];
        api.call(args, function(result) {
            if (requested !== root.collection) return;
            root.loading = false;
            if (!result.ok) { root.error = result.error; return; }
            if (result.meta) root.meta = result.meta;
            root.tracks = root.tracks.concat(result.items);
            root.total = result.total;
            root.loadedAll = !result.next;
            if (root.wantAll && !root.loadedAll && root.tracks.length < 5000) Qt.callLater(function() { root.load(false); });
        });
    }

    // Play the collection from `track` on `player`'s device.
    function playFrom(player, track, index) {
        pendingUri = track.uri;
        var body = { context_uri: collection.uri, offset: { uri: track.uri } };
        api.play(player.deviceName, body, function(result) {
            if (result.ok || !root.isLiked) { root.pendingUri = ""; return; }
            // Some accounts refuse the collection as a context; fall back to
            // the loaded tracks as a plain list.
            var uris = root.tracks.slice(index, index + 100).map(function(t) { return t.uri; });
            root.api.play(player.deviceName, { uris: uris }, function() { root.pendingUri = ""; });
        });
    }

    onCollectionChanged: load(true)
}
