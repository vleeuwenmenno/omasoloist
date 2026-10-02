import QtQuick

// Loads the tracks of one playlist, album or Liked Songs page by page and
// starts playback from a chosen track. Shared by the bar popup and the app
// window.
Item {
    id: root
    visible: false

    required property var api
    property var collection: null
    property bool active: true

    property var tracks: []
    // Name/art/owner from the helper, for collections opened by URI only.
    property var meta: null
    property int total: 0
    property bool loading: false
    property bool loadedAll: false
    property string error: ""
    property string pendingUri: ""
    property int revision: 0
    property bool initialized: false
    property int nextOffset: 0
    property string playlistSnapshot: ""
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
        if (reset) {
            revision++;
            loading = false;
            tracks = []; total = 0; loadedAll = false; error = ""; meta = null;
            initialized = false; nextOffset = 0; playlistSnapshot = "";
        }
        if (!active || !collection || loading || (!reset && loadedAll) || !api.signedIn) return;
        var requestedRevision = revision;
        loading = true;
        var requested = collection;
        var kind = collection.kind;
        var args = kind === "radio" ? ["radio"].concat(String(collection.id).split(":"))
            : kind === "liked" ? ["liked", String(nextOffset)]
            : kind === "album" ? ["album-tracks", collection.id, String(nextOffset)]
            : ["playlist-tracks", collection.id, String(nextOffset)];
        api.call(args, function(result) {
            if (requestedRevision !== root.revision || requested !== root.collection) return;
            root.loading = false;
            if (!result.ok) { root.error = result.error; return; }
            if (root.playlistSnapshot !== "" && result.snapshot && result.snapshot !== root.playlistSnapshot) {
                root.error = "This playlist changed while loading. Reopen it to load the updated order.";
                root.loadedAll = true;
                return;
            }
            if (result.snapshot) root.playlistSnapshot = result.snapshot;
            if (result.meta) root.meta = result.meta;
            root.initialized = true;
            var offset = result.nextOffset !== undefined ? result.nextOffset : root.nextOffset + result.items.length;
            root.loadedAll = !result.next || offset <= root.nextOffset;
            root.nextOffset = offset;
            root.tracks = root.tracks.concat(result.items);
            root.total = result.total;
            if ((root.wantAll || result.items.length === 0) && !root.loadedAll && root.nextOffset < 5000) Qt.callLater(function() {
                if (requestedRevision === root.revision) root.load(false);
            });
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
    onActiveChanged: if (active && (!initialized || wantAll || (!loadedAll && tracks.length === 0))) load(!initialized)

    Connections {
        target: root.api
        function onSessionReset() { root.load(true); }
        function onSignedInChanged() { if (root.api.signedIn) root.load(true); }
        function onCacheCleared(group) { if (group !== "lyrics") root.load(true); }
        function onLibraryChanged(uri) {
            if (root.isLiked || (root.collection && root.collection.uri === uri)) root.load(true);
        }
    }
}
