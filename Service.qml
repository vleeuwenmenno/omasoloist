import QtQuick
import Quickshell
import Quickshell.Io
import "Entity.js" as Entity
import "app"

// Shared state for the bar widget and the app window: one Soloist
// connection, one Web API client and one remote-playback poller, no matter
// how many monitors show the bar.
Item {
    id: root
    visible: false

    property var shell: null
    property var manifest: null

    // Per-widget settings are read from shell.json by the bar widget and
    // pushed here; these are the defaults until then.
    property string dataDir: ""
    property string serviceName: "soloist.service"
    property string installUrl: "https://github.com/vleeuwenmenno/omasoloist/blob/main/docs/install-soloist-systemd.md"

    // Anything showing the queue (bar popup or app window) bumps this while
    // it is visible so the controllers fetch the long list.
    property int queueViewers: 0
    // Bumped while a UI is visible so remote state is polled faster.
    property int activeViewers: 0

    readonly property alias api: spotifyApi
    readonly property alias soloist: soloistController
    readonly property alias remote: remotePlayer
    readonly property alias likes: likeState
    readonly property alias trackInfo: trackInfoState

    // The bar widget's shell.json entry, pushed here by the widget so the
    // app window's Settings page can edit it (see saveWidgetSettings).
    property var widgetSettings: ({})
    readonly property string labelMode: {
        var mode = widgetSettings.labelMode;
        if (mode) return mode;
        // Default: the current lyric line (falls back to the title for
        // songs without synced lyrics).
        return widgetSettings.showTitle === false ? "icon" : "lyrics";
    }
    // Bar popup options (widget settings):
    //   popupHidden      buttons to hide: library, lyrics, app, devices, queue
    //                    (default: library)
    //   popupLyricsMode  "cover" (in place of the cover, default) or "view"
    //   popupResetView   back to the player view whenever the popup reopens
    // An older `popupLyrics: false` still hides the lyrics button.
    readonly property var popupHidden: Array.isArray(widgetSettings.popupHidden) ? widgetSettings.popupHidden
        : widgetSettings.popupLyrics === false ? ["library", "lyrics"] : ["library"]
    function popupShows(button) { return popupHidden.indexOf(button) < 0; }
    readonly property string popupLyricsMode: widgetSettings.popupLyricsMode === "view" ? "view" : "cover"
    readonly property bool popupResetView: widgetSettings.popupResetView === true

    function setPopupButton(button, shown) {
        var hidden = popupHidden.filter(function(b) { return b !== button; });
        if (!shown) hidden.push(button);
        saveWidgetSettings({ popupHidden: hidden });
    }
    // Set by the app window while it's open.
    property bool windowOpen: false

    // Replace the widget's entry with its current settings plus `changes`.
    function saveWidgetSettings(changes) {
        if (!shell || typeof shell.updateEntryInline !== "function") return false;
        var next = Object.assign({}, widgetSettings, changes);
        delete next.id;
        delete next.showTitle;          // superseded by labelMode
        if ("popupHidden" in changes) delete next.popupLyrics;   // superseded by popupHidden
        return shell.updateEntryInline("vleeuwenmenno.omasoloist", next);
    }

    readonly property bool remoteActive: remote.active && !soloist.isActive
        && remote.deviceId !== "" && remote.deviceId !== soloist.deviceId
    // Whatever is playing right now: Soloist here, or a remote device.
    readonly property var player: remoteActive ? remote : soloist
    readonly property bool ready: soloist.loggedIn || remoteActive

    // Transient messages ("Added to queue"); the app window shows them.
    signal toast(string text)

    function addToQueue(uri, label) {
        if (!uri) return;
        spotifyApi.call(["add-to-queue", root.player.deviceName, uri], function(result) {
            if (!result.ok) { root.toast("Couldn't add to queue: " + result.error); return; }
            root.toast(result.queued === 1 ? "Added to queue" : "Added " + result.queued + " songs to queue");
            if (root.player.refreshQueue) root.player.refreshQueue();
        });
    }

    // Song / artist radio. The Web API rejects station URIs ("Non supported
    // context uri"), but Soloist's player plays them, so radio always starts
    // on this computer, moving playback here if another device was playing.
    // Spotify's endless station for a track or artist URI, or a
    // spotify:station:… URI itself. `name` labels it ("… Radio").
    function startRadio(uri, name) {
        var parts = String(uri).split(":");
        var station = parts[1] === "station" ? uri
            : parts.length === 3 && (parts[1] === "track" || parts[1] === "artist")
            ? "spotify:station:" + parts[1] + ":" + parts[2] : "";
        if (station === "") return;
        var labels = Object.assign({}, soloist.contextLabels);
        labels[station] = /Radio$/.test(name || "") ? name : (name ? name + " " : "") + "Radio";
        soloist.contextLabels = labels;
        var moved = remoteActive;
        soloist.play(station);
        toast((moved ? "Playing on this computer: " : "Playing ") + labels[station]);
    }

    // Radio page for a track or artist ("Go to song radio").
    function radioItem(uri, name, cover) {
        var parts = String(uri).split(":");
        return { kind: "radio", uri: "spotify:station:" + parts[1] + ":" + parts[2],
                 id: parts[1] + ":" + parts[2], name: (name ? name + " " : "") + "Radio",
                 cover: cover || "", owner: "" };
    }

    function addToPlaylist(playlist, uri) {
        spotifyApi.call(["add-to-playlist", playlist.id, uri], function(result) {
            root.toast(result.ok ? "Added to " + playlist.name : "Couldn't add to playlist: " + result.error);
        });
    }

    function copyLink(uri) {
        Quickshell.execDetached(["wl-copy", webUrl(uri)]);
        root.toast("Link copied to clipboard");
    }

    function webUrl(uri) {
        var parts = String(uri).split(":");
        return parts[parts.length - 1] === "collection" ? "https://open.spotify.com/collection/tracks"
            : parts[1] === "station" ? "https://open.spotify.com/station/" + parts[2] + "/" + parts[3]
            : "https://open.spotify.com/" + parts[1] + "/" + parts[2];
    }

    // Open the app window. `payload` may be a page name ("settings") or
    // {uri, name, highlight} to open an album/artist/playlist (and scroll
    // to the `highlight` track in it).
    function openApp(payload) {
        if (!shell || typeof shell.summon !== "function") return;
        var data = typeof payload === "string" ? { page: payload } : (payload || {});
        shell.summon("vleeuwenmenno.omasoloist", JSON.stringify(data));
    }

    // Links for the playing track, used by both UIs.
    function albumUri() { return Entity.albumUri(player ? player.item : null); }
    function artistUri() { return Entity.artistUri(player ? player.item : null); }

    SpotifyApi { id: spotifyApi }

    // Lyrics and artist info for the playing track: needed by the app
    // window, and by the bar when it shows the current lyric line.
    TrackInfo {
        id: trackInfoState
        api: spotifyApi
        player: root.player
        active: root.windowOpen || root.activeViewers > 0 || root.labelMode === "lyrics"
    }

    Likes {
        id: likeState
        api: spotifyApi
        currentUri: root.player && root.player.item ? root.player.item.uri || "" : ""
    }

    // ------------------------------------------------------------ quality
    // Estimated file quality of what Soloist plays ("Lossless 16-bit"),
    // measured once per track (bin/spotify.py quality). Unknown for remote
    // devices.
    property var qualityByUri: ({})
    property int qualityTries: 0
    readonly property string qualityUri: !remoteActive && soloist.item ? soloist.item.uri || "" : ""
    readonly property var quality: qualityUri !== "" ? qualityByUri[qualityUri] || null : null

    onQualityUriChanged: {
        qualityTries = 0;
        qualityTimer.interval = 2500;
        if (qualityUri !== "" && !qualityByUri[qualityUri]) qualityTimer.restart();
    }

    Timer {
        id: qualityTimer
        // Give Soloist a moment to open the new file.
        interval: 2500
        onTriggered: {
            var uri = root.qualityUri;
            if (uri === "" || root.soloist.durationMs <= 0) { if (root.qualityTries++ < 5) restart(); return; }
            spotifyApi.call(["quality", root.soloist.resolvedDataDir, String(Math.round(root.soloist.durationMs))], function(result) {
                if (uri !== root.qualityUri) return;
                if (result.ok && result.found) {
                    var next = Object.assign({}, root.qualityByUri);
                    next[uri] = result;
                    root.qualityByUri = next;
                } else if (root.qualityTries++ < 5) {
                    qualityTimer.interval = 5000;
                    qualityTimer.restart();
                }
            });
        }
    }

    // ------------------------------------------------------ version check
    // Installed version from our manifest; newest release from the GitHub
    // tags (bin/spotify.py update-check, cached 6 h). A desktop notification
    // is sent once per newer version.
    property string version: ""
    property string latestVersion: ""
    property bool updateOutdated: false
    readonly property bool updateAvailable: updateOutdated && latestVersion !== ""
    readonly property string releasesUrl: "https://github.com/vleeuwenmenno/omasoloist/releases"

    FileView {
        path: decodeURIComponent(Qt.resolvedUrl("manifest.json").toString().replace(/^file:\/\//, ""))
        printErrors: false
        onLoaded: {
            try { root.version = JSON.parse(text()).version || ""; } catch (e) {}
            updateTimer.restart();
        }
    }

    function checkForUpdate() {
        if (version === "") return;
        spotifyApi.call(["update-check", version], function(result) {
            if (!result.ok) return;
            root.latestVersion = result.latest;
            root.updateOutdated = result.outdated;
            if (result.notify)
                Quickshell.execDetached(["notify-send", "--app-name=OmaSoloist", "--icon=software-update-available",
                    "OmaSoloist " + result.latest + " is available",
                    "You have " + root.version + ". Update from the avatar menu in the OmaSoloist window."]);
        });
    }

    // Let the shell settle after start, then check every 6 hours.
    Timer {
        id: updateTimer
        interval: 30000
        onTriggered: {
            root.checkForUpdate();
            interval = 6 * 3600 * 1000;
            restart();
        }
    }

    // Update in a floating terminal, so its output and any prompt are visible.
    function runUpdate() {
        Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
            "omarchy plugin update vleeuwenmenno.omasoloist && echo && echo 'Restart the shell to finish: omarchy restart shell'"]);
    }

    // Spotify keeps only the last 50 plays; save them to the local history
    // log (bin/spotify.py) often enough that none fall off in between.
    Timer {
        // Plays on your phone count too, so this doesn't wait for Soloist.
        interval: 60000
        repeat: true
        running: spotifyApi.signedIn
        onTriggered: {
            interval = 30 * 60 * 1000;
            spotifyApi.call(["history-sync"], function() {});
        }
    }

    // Catch likes made in other Spotify apps.
    Timer {
        interval: 30000
        repeat: true
        running: spotifyApi.signedIn && root.ready
        onTriggered: likeState.refreshCurrent()
    }
    Connections {
        target: spotifyApi
        function onSignedInChanged() { if (spotifyApi.signedIn) likeState.refreshCurrent(); }
    }

    SoloistController {
        id: soloistController
        dataDir: root.dataDir
        serviceName: root.serviceName
        queueWanted: root.queueViewers > 0 && loggedIn && !root.remoteActive
    }

    RemotePlayer {
        id: remotePlayer
        api: spotifyApi
        polling: spotifyApi.signedIn && !soloistController.isActive
        fast: root.activeViewers > 0
        likedSongsUri: soloistController.likedSongsUri
        queueWanted: root.queueViewers > 0 && root.remoteActive
    }
}
