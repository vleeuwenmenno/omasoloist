import QtQuick

// Which tracks are in Liked Songs, cached per URI and shared by every view.
// `known` is replaced (not mutated) on each change so bindings re-run.
QtObject {
    id: root

    required property var api

    // Saved/removed something other than a track (album, playlist, artist).
    signal libraryChanged(string uri)
    // The playing track, always kept up to date.
    property string currentUri: ""

    property var known: ({})
    property var pending: ({})

    readonly property bool currentLiked: currentUri !== "" && known[currentUri] === true

    function isLiked(uri) { return known[uri] === true; }

    function set(values) {
        var next = Object.assign({}, known);
        for (var uri in values) next[uri] = values[uri];
        known = next;
    }

    // Look up any URIs we don't know yet.
    function query(uris) {
        if (!api || !api.signedIn) return;
        var missing = (uris || []).filter(function(u) {
            return u && u.indexOf("spotify:") === 0 && !(u in root.known);
        });
        if (missing.length === 0) return;
        api.call(["liked-contains"].concat(missing), function(result) {
            if (result.ok) root.set(result.liked);
        });
    }

    // Tracks from a Liked Songs page are liked by definition.
    function markLiked(uris) {
        var values = {};
        (uris || []).forEach(function(u) { values[u] = true; });
        set(values);
    }

    function toggle(uri) {
        if (!uri || pending[uri]) return;
        var on = !isLiked(uri);
        var change = {};
        change[uri] = on;
        set(change);                       // optimistic
        var busy = Object.assign({}, pending);
        busy[uri] = true;
        pending = busy;
        api.call(["like", uri, on ? "on" : "off"], function(result) {
            var done = Object.assign({}, root.pending);
            delete done[uri];
            root.pending = done;
            if (!result.ok) {
                var revert = {};
                revert[uri] = !on;
                root.set(revert);
            } else if (uri.indexOf("spotify:track:") !== 0) {
                root.libraryChanged(uri);
            }
        });
    }

    onCurrentUriChanged: if (currentUri !== "") query([currentUri])
    // Liked state may have changed elsewhere; recheck the playing track.
    function refreshCurrent() {
        if (currentUri === "" || !api || !api.signedIn) return;
        api.call(["liked-contains", currentUri], function(result) { if (result.ok) root.set(result.liked); });
    }
}
