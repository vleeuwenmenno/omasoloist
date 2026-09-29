import QtQuick
import "../Entity.js" as Entity

// Lyrics and artist info for whatever is playing, shared by the Now Playing
// panel and the lyrics page. Only fetches while `active`.
QtObject {
    id: root

    required property var api
    required property var player
    property bool active: false

    readonly property var item: player ? player.item : null
    readonly property string trackUri: item ? item.uri || "" : ""
    readonly property string artistUri: Entity.artistUri(item)
    readonly property string artistId: artistUri.split(":")[2] || ""

    // {found, instrumental, synced: [{t, text}], plain}
    property var lyrics: null
    property bool lyricsLoading: false
    property string lyricsFor: ""

    // {artist: {name, cover}, bio, url, image}
    property var about: null
    property bool aboutLoading: false
    property string aboutFor: ""

    readonly property var synced: lyrics && lyrics.synced ? lyrics.synced : []
    readonly property var plainLines: lyrics && lyrics.plain ? lyrics.plain.split("\n") : []
    readonly property bool hasSynced: synced.length > 0
    // Lyrics we can actually show (not missing, not instrumental).
    readonly property bool lyricsAvailable: lyrics !== null && !!lyrics.found && !lyrics.instrumental
        && (synced.length > 0 || plainLines.some(function(l) { return l.trim() !== ""; }))

    // Index of the synced line being sung, -1 before the first.
    readonly property int currentLine: {
        var position = player ? player.estimatedPositionMs + 250 : 0;
        var index = -1;
        for (var i = 0; i < synced.length && synced[i].t <= position; i++) index = i;
        return index;
    }

    function refresh() {
        if (!active || !item) return;
        if (trackUri !== "" && trackUri !== lyricsFor) {
            var uri = trackUri;
            lyricsFor = uri;
            lyrics = null;
            lyricsLoading = true;
            api.call(["lyrics", Entity.firstArtist(item), Entity.name(item), player.album,
                      String(Math.round(player.durationMs))], function(result) {
                if (uri !== root.lyricsFor) return;
                root.lyricsLoading = false;
                root.lyrics = result.ok ? result : { found: false, error: result.error };
                // LRCLIB fails intermittently (503); ask again shortly.
                if (!result.ok) root.retryLyrics.restart();
            });
        }
        if (artistId !== "" && artistId !== aboutFor) {
            var id = artistId;
            aboutFor = id;
            about = null;
            aboutLoading = true;
            api.call(["artist-about", id], function(result) {
                if (id !== root.aboutFor) return;
                root.aboutLoading = false;
                root.about = result.ok ? result : null;
            });
        }
    }

    property Timer retryLyrics: Timer {
        interval: 30000
        onTriggered: {
            root.lyricsFor = "";
            root.refresh();
        }
    }

    onActiveChanged: refresh()
    onTrackUriChanged: refresh()
    onArtistIdChanged: refresh()
}
