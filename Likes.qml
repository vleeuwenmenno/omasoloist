import QtQuick

// Which tracks are in Liked Songs, cached per URI and shared by every view.
// `known` is replaced (not mutated) on each change so bindings re-run.
Item {
    id: root
    visible: false

    required property var api

    // Saved/removed something other than a track (album, playlist, artist).
    signal libraryChanged(string uri)
    // The playing track only needs a lookup while a like button is visible.
    property string currentUri: ""
    property bool currentWanted: false
    readonly property int freshnessMs: 15 * 60 * 1000

    property var known: ({})
    property var pending: ({})
    property var checking: ({})
    property var checkedAt: ({})
    property var versions: ({})
    property int revision: 0
    property int nextQuery: 0

    readonly property bool currentLiked: currentUri !== "" && known[currentUri] === true

    function isLiked(uri) { return known[uri] === true; }

    function set(values, fresh, age) {
        var next = Object.assign({}, known);
        var times = Object.assign({}, checkedAt);
        for (var uri in values) {
            next[uri] = values[uri];
            var seconds = age && typeof age === "object" ? age[uri] || 0 : age || 0;
            times[uri] = fresh === false ? 0 : Date.now() - seconds * 1000;
        }
        checkedAt = times;
        known = next;
    }

    // Look up any URIs we don't know yet.
    function query(uris) {
        if (!api || !api.signedIn) return;
        if (api.waitFor("/me/library/contains") > 0) return;
        var missing = (uris || []).filter(function(u) {
            return u && u.indexOf("spotify:") === 0 && !root.pending[u] && !root.checking[u]
                && (!(u in root.known) || Date.now() - (root.checkedAt[u] || 0) >= root.freshnessMs);
        });
        missing = missing.filter(function(u, i) { return missing.indexOf(u) === i; });
        if (missing.length === 0) return;
        var requestedRevision = revision;
        var requestedVersions = Object.assign({}, versions);
        var queryId = ++nextQuery;
        var busy = Object.assign({}, checking);
        missing.forEach(function(u) { busy[u] = queryId; });
        checking = busy;
        api.call(["liked-contains"].concat(missing), function(result) {
            if (requestedRevision !== root.revision) return;
            var done = Object.assign({}, root.checking);
            missing.forEach(function(u) { if (done[u] === queryId) delete done[u]; });
            root.checking = done;
            if (!result.ok) return;
            var values = {};
            for (var uri in result.liked) {
                if (!root.pending[uri] && (root.versions[uri] || 0) === (requestedVersions[uri] || 0))
                    values[uri] = result.liked[uri];
            }
            root.set(values, !result.stale, result.ages || result.cacheAge || 0);
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
        var requestedRevision = revision;
        var nextVersions = Object.assign({}, versions);
        nextVersions[uri] = (nextVersions[uri] || 0) + 1;
        versions = nextVersions;
        var change = {};
        change[uri] = on;
        set(change);                       // optimistic
        var busy = Object.assign({}, pending);
        busy[uri] = true;
        pending = busy;
        api.call(["like", uri, on ? "on" : "off"], function(result) {
            if (requestedRevision !== root.revision) return;
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

    onCurrentUriChanged: refreshCurrent()
    onCurrentWantedChanged: refreshCurrent()
    // Liked state may have changed elsewhere; recheck the playing track.
    function refreshCurrent() {
        if (!currentWanted || currentUri === "" || !api || !api.signedIn) return;
        query([currentUri]);
    }

    function reset() {
        revision++;
        known = {};
        pending = {};
        checking = {};
        checkedAt = {};
        versions = {};
    }

    Connections {
        target: root.api
        function onSessionReset() { root.reset(); }
        function onCacheCleared(group) {
            if (group === "api" || group === "all") { root.reset(); root.refreshCurrent(); }
        }
        function onLibraryChanged(uri) {
            var times = Object.assign({}, root.checkedAt);
            delete times[uri];
            root.checkedAt = times;
        }
    }
}
