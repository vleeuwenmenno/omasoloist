import QtQuick
import "Entity.js" as Entity

// Playback on another Spotify Connect device (phone, speaker, desktop app),
// observed by polling the Web API and controlled through it. Exposes the
// same surface as SoloistController so the player UI can bind to either.
Item {
    id: root
    visible: false

    required property var api
    // Poll while this is true (Soloist isn't the active device).
    property bool polling: false
    property bool fast: false
    property string likedSongsUri: ""

    property bool active: false
    property var device: null
    readonly property string deviceName: device ? device.name : ""
    readonly property string deviceId: device ? device.id : ""
    readonly property bool loggedIn: active

    property bool playing: false
    readonly property string status: playing ? "playing" : "paused"
    property var item: null
    property var context: null
    property string contextName: ""
    property int volume: 0
    readonly property bool supportsVolume: device ? device.supportsVolume : false
    property bool shuffle: false
    property bool smartShuffle: false
    property string repeat: "off"
    property var disallows: []
    property real positionMs: 0
    property real positionTimestamp: 0
    property real now: Date.now()

    readonly property bool hasItem: item !== null && item.uri !== ""
    readonly property string title: Entity.name(item)
    readonly property string artist: Entity.creators(item)
    readonly property string album: item && item.decorations.parent ? Entity.name(item.decorations.parent.entity) : ""
    readonly property string coverUrl: Entity.cover(item, "large")
    readonly property real durationMs: Entity.duration(item)
    readonly property real estimatedPositionMs: Math.max(0, Math.min(durationMs || Infinity,
        positionMs + (playing ? now - positionTimestamp : 0)))

    // Queue (read from the Web API; it has no source labels).
    property var queueUpcoming: []
    property bool queueWanted: false
    property string skipTarget: ""

    function name(entity) { return Entity.name(entity); }
    function creators(entity) { return Entity.creators(entity); }
    function cover(entity, size) { return Entity.cover(entity, size); }

    function can(action) {
        var blocked = { pause: "pausing", play: "resuming", seek: "seeking", skip_next: "skipping_next",
            skip_prev: "skipping_prev", shuffle: "toggling_shuffle", set_repeat: "toggling_repeat_context" };
        return !blocked[action] || disallows.indexOf(blocked[action]) < 0;
    }

    function apply(result) {
        if (!result.ok) return;
        active = !!result.active;
        if (!active) { device = null; item = null; playing = false; return; }
        device = result.device;
        volume = device.volume !== null && device.volume !== undefined ? device.volume : 0;
        playing = result.playing;
        shuffle = result.shuffle;
        smartShuffle = !!result.smart_shuffle;
        repeat = result.repeat;
        disallows = result.disallows || [];
        positionMs = result.progress_ms;
        positionTimestamp = result.timestamp;
        now = Date.now();
        var next = Entity.fromTrack(result.item);
        if (!item || !next || item.uri !== next.uri) item = next;
        if (!context || context.uri !== result.context_uri) {
            context = result.context_uri ? { uri: result.context_uri } : null;
            contextName = "";
            if (result.context_uri) {
                var uri = result.context_uri;
                api.call(["context-name", uri], function(r) {
                    if (r.ok && root.context && root.context.uri === uri) root.contextName = r.name;
                });
            }
        }
        if (skipTarget !== "" && item && item.uri === skipTarget) skipTarget = "";
    }

    function poll() {
        if (pollBusy) return;
        pollBusy = true;
        api.call(["player"], function(result) {
            root.pollBusy = false;
            root.apply(result);
        });
        if (queueWanted) refreshQueue();
    }
    property bool pollBusy: false

    function refreshQueue() {
        api.call(["queue"], function(result) {
            if (!result.ok) return;
            root.queueUpcoming = result.upcoming.map(function(t) {
                return { source: "context", item: Entity.fromTrack(t) };
            });
        });
    }
    onQueueWantedChanged: if (queueWanted && polling) refreshQueue()

    // Run a control command, then re-read the state so the UI catches up.
    function control(action, value) {
        var args = ["control", deviceId, action];
        if (value !== undefined) args.push(String(value));
        api.call(args, function() { settle.restart(); });
    }

    function play(uri) {
        if (!uri) { playing = true; control("play"); return; }
        var body = uri.indexOf("spotify:track:") === 0 || uri.indexOf("spotify:episode:") === 0
            ? { uris: [uri] } : { context_uri: uri };
        control("play", JSON.stringify(body));
    }
    function pause() { playing = false; control("pause"); }
    function togglePlay() { playing ? pause() : play(); }
    function next() { control("next"); }
    function previous() { control("previous"); }
    function seek(ms) { positionMs = ms; positionTimestamp = Date.now(); control("seek", Math.round(ms)); }
    function setVolume(value) { volume = Math.round(value); control("volume", volume); }
    function setShuffle(enabled) { shuffle = enabled; control("shuffle", enabled ? "on" : "off"); }
    function setRepeat(mode) { repeat = mode; control("repeat", mode); }
    function cycleRepeat() { setRepeat(repeat === "off" ? "context" : repeat === "context" ? "track" : "off"); }
    function playLikedSongs() { if (likedSongsUri !== "") play(likedSongsUri); }
    function skipTo(uri, upcomingIndex) {
        skipTarget = uri;
        control("next", upcomingIndex + 1);
    }

    onPollingChanged: if (polling) poll()

    Timer {
        interval: root.fast ? 1500 : 5000
        repeat: true
        running: root.polling
        onTriggered: root.poll()
    }

    Timer {
        id: settle
        interval: 400
        onTriggered: root.poll()
    }

    Timer {
        interval: 1000
        repeat: true
        running: root.polling && root.playing
        onTriggered: root.now = Date.now()
    }
}
