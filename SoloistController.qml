import QtQuick
import Quickshell
import Quickshell.Io
import "Entity.js" as Entity

// Talks to the Soloist daemon through `soloist ctl`. A long-lived
// `soloist ctl trace` process streams every WebSocket event; control
// commands are fire-and-forget `soloist ctl <command>` invocations whose
// effects arrive back through the trace stream.
Item {
    id: root
    visible: false

    property string dataDir: ""
    readonly property string resolvedDataDir: dataDir !== "" ? dataDir
        : (Quickshell.env("XDG_DATA_HOME") || (Quickshell.env("HOME") + "/.local/share")) + "/soloist"

    property string serviceName: "soloist.service"
    // "unknown" until the first check, then "missing", "stopped", "failed",
    // "starting" or "running" (systemd's view of the user unit).
    property string serviceState: "unknown"
    property bool starting: false

    property bool binaryInstalled: true
    property bool connected: false
    property bool loggedIn: false
    property bool isActive: false
    property string deviceName: ""
    property string userId: ""
    property string deviceId: ""

    property string status: "idle"
    property var item: null
    property var context: null
    property int volume: 0
    property bool shuffle: false
    // Smart Shuffle (Spotify's "context enhancement"). Read-only: Soloist
    // has no command to switch it, but reports it when a Spotify app does.
    property bool smartShuffle: false
    property string repeat: "off"
    property var availableActions: ({})
    property real positionMs: 0
    property real positionTimestamp: 0
    property real positionSpeed: 0
    property real now: Date.now()

    // Queue. Broadcast queue_changed events are capped at 10 entries, so while
    // someone is looking at the queue we fetch a longer list on every change.
    property var queuePrevious: []
    property var queueUpcoming: []
    property bool queueWanted: false
    property int queueLimit: 100

    readonly property bool playing: status === "playing"
    readonly property bool hasItem: item !== null && item.uri !== undefined && item.uri !== ""
    readonly property string title: name(item)
    readonly property string artist: creators(item)
    readonly property string album: item && item.decorations && item.decorations.parent
        ? name(item.decorations.parent.entity) : ""
    readonly property string contextName: name(context)
    readonly property string coverUrl: cover(item, "large")
    readonly property real durationMs: item && item.decorations && item.decorations.playback
        ? (item.decorations.playback.duration_ms || 0) : 0
    readonly property real estimatedPositionMs: Math.max(0, Math.min(durationMs || Infinity,
        positionMs + (now - positionTimestamp) * positionSpeed))
    readonly property string likedSongsUri: userId !== "" ? "spotify:user:" + userId + ":collection" : ""

    function name(entity) { return Entity.name(entity); }
    function creators(entity) { return Entity.creators(entity); }
    function cover(entity, size) { return Entity.cover(entity, size); }

    function can(action) { return availableActions && availableActions[action] !== undefined; }

    function ctl(args) {
        Quickshell.execDetached(["soloist", "ctl", "-D", root.resolvedDataDir].concat(args));
    }

    function startService() {
        starting = true;
        Quickshell.execDetached(["systemctl", "--user", "start", serviceName]);
        serviceCheck.running = true;
        startTimeout.restart();
    }

    function play(uri) { ctl(uri ? ["play", uri] : ["play"]); }
    function pause() { ctl(["pause"]); }
    function togglePlay() { playing ? pause() : play(); }
    function next() { ctl(["next"]); }
    function previous() { ctl(["prev"]); }
    function seek(ms) { ctl(["seek", String(Math.round(ms))]); }
    function setVolume(value) { ctl(["volume", String(Math.round(value))]); }
    function setShuffle(enabled) { ctl(["shuffle", enabled ? "on" : "off"]); }
    function setRepeat(mode) { ctl(["repeat", mode]); }
    function cycleRepeat() { setRepeat(repeat === "off" ? "context" : repeat === "context" ? "track" : "off"); }
    function playLikedSongs() { if (likedSongsUri !== "") play(likedSongsUri); }

    // Soloist has no skip-to command, so jumping to a queued track sends
    // skip_next once per track_changed until the target is playing. Each skip
    // waits for the previous one to land so the player can't coalesce them.
    property string skipTarget: ""
    property int skipsLeft: 0
    property string skipFrom: ""

    function skipTo(uri, upcomingIndex) {
        if (!uri || upcomingIndex < 0) return;
        skipTarget = uri;
        skipsLeft = upcomingIndex;
        skipFrom = item ? item.uri : "";
        skipGuard.restart();
        next();
    }

    function continueSkip() {
        // Snapshots can repeat the current track; only act on a real change.
        if (skipTarget === "" || !item || item.uri === skipFrom) return;
        if ((item && item.uri === skipTarget) || skipsLeft <= 0) {
            skipTarget = "";
            skipsLeft = 0;
            skipGuard.stop();
            return;
        }
        skipsLeft--;
        skipFrom = item.uri;
        skipGuard.restart();
        next();
    }

    function refreshQueue() { if (loggedIn) fetchQueue.running = true; }
    onQueueWantedChanged: if (queueWanted) refreshQueue()

    function applyQueue(event) {
        queuePrevious = event.previous || [];
        queueUpcoming = event.upcoming || [];
    }

    function syncPosition(position) {
        if (!position) return;
        positionMs = position.position_ms || 0;
        positionTimestamp = position.timestamp_ms || Date.now();
        positionSpeed = position.speed || 0;
        now = Date.now();
    }

    function handle(event) {
        switch (event.type) {
        case "auth_state":
            loggedIn = !!event.logged_in;
            isActive = !!event.is_active;
            deviceName = event.device_name || "";
            if (loggedIn) findUser.running = true;
            break;
        case "playback_state":
            status = event.status || "idle";
            item = event.item || null;
            context = event.context || null;
            volume = event.volume || 0;
            isActive = !!event.is_active;
            if (event.options) {
                shuffle = !!event.options.shuffle;
                smartShuffle = !!event.options.modes && event.options.modes.context_enhancement === "RECOMMENDATION";
                repeat = event.options.repeat || "off";
            }
            availableActions = event.available_actions || {};
            syncPosition(event.position);
            continueSkip();
            break;
        case "track_changed":
            item = event.item || null;
            continueSkip();
            break;
        case "context_changed": context = event.context || null; break;
        case "playback_changed": status = event.status || "idle"; break;
        case "volume_changed": volume = event.volume || 0; break;
        case "device_changed":
            isActive = !!event.is_active;
            deviceName = event.device_name || deviceName;
            break;
        case "options_changed":
            if (event.options) {
                shuffle = !!event.options.shuffle;
                smartShuffle = !!event.options.modes && event.options.modes.context_enhancement === "RECOMMENDATION";
                repeat = event.options.repeat || "off";
            }
            break;
        case "position_sync": syncPosition(event.position); break;
        case "queue_changed":
            applyQueue(event);
            if (queueWanted) refreshQueue();
            break;
        }
        // Granular events don't carry available_actions; refresh the snapshot.
        if (event.type === "track_changed" || event.type === "context_changed"
            || event.type === "playback_changed" || event.type === "options_changed") {
            refreshState.running = true;
        }
    }

    function parseLine(line) {
        // trace prints "<unix_ms> <json>"; other lines are status chatter.
        var text = String(line);
        var space = text.indexOf(" ");
        if (space < 0 || text.charAt(space + 1) !== "{") {
            if (text.indexOf("connected to") === 0) {
                connected = true;
                starting = false;
                serviceState = "running";
            }
            return;
        }
        var event;
        try { event = JSON.parse(text.slice(space + 1)); } catch (e) { return; }
        // The "connected to ws://…" banner goes to stderr, so any event
        // counts as proof the socket is up.
        if (!connected) {
            connected = true;
            starting = false;
            serviceState = "running";
        }
        handle(event);
    }

    Process {
        id: trace
        command: ["soloist", "ctl", "-D", root.resolvedDataDir, "trace"]
        running: true
        stdout: SplitParser { onRead: function(line) { root.parseLine(line); } }
        onExited: {
            root.connected = false;
            root.loggedIn = false;
            root.status = "idle";
            root.item = null;
            root.context = null;
            serviceCheck.running = true;
            reconnect.start();
        }
    }

    Timer {
        id: reconnect
        interval: 3000
        onTriggered: trace.running = true
    }

    Process {
        id: serviceCheck
        command: ["sh", "-c", "command -v soloist >/dev/null && echo binary=yes || echo binary=no; "
            + "systemctl --user show \"$1\" -p LoadState -p ActiveState", "sh", root.serviceName]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                var values = {};
                text.split("\n").forEach(function(line) {
                    var eq = line.indexOf("=");
                    if (eq > 0) values[line.slice(0, eq)] = line.slice(eq + 1);
                });
                root.binaryInstalled = values.binary === "yes";
                var active = values.ActiveState || "";
                if (values.LoadState !== "loaded") root.serviceState = "missing";
                else if (active === "active") root.serviceState = "running";
                else if (active === "activating" || active === "reloading") root.serviceState = "starting";
                else if (active === "failed") root.serviceState = "failed";
                else root.serviceState = "stopped";
                if (root.serviceState === "running" || root.serviceState === "failed") root.starting = false;
            }
        }
    }

    // Poll the unit only while the trace stream is down.
    Timer {
        interval: root.starting ? 1000 : 5000
        repeat: true
        running: !root.connected
        onTriggered: serviceCheck.running = true
    }

    Timer {
        id: startTimeout
        interval: 15000
        onTriggered: root.starting = false
    }

    // Give up on a skip chain if the player stops reporting track changes.
    Timer {
        id: skipGuard
        interval: 4000
        onTriggered: {
            root.skipTarget = "";
            root.skipsLeft = 0;
        }
    }

    Process {
        id: fetchQueue
        command: ["soloist", "ctl", "-D", root.resolvedDataDir, "queue", String(root.queueLimit), "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.applyQueue(JSON.parse(text)); } catch (e) {}
            }
        }
    }

    Process {
        id: refreshState
        command: ["soloist", "ctl", "-D", root.resolvedDataDir, "now", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.handle(JSON.parse(text)); } catch (e) {}
            }
        }
    }

    Process {
        id: readDeviceId
        command: ["cat", root.resolvedDataDir + "/.device_id"]
        running: true
        stdout: StdioCollector { onStreamFinished: root.deviceId = text.trim() }
    }

    // Soloist keeps per-user settings under settings/Users/<id>-user; the id
    // is what the Liked Songs collection URI needs.
    Process {
        id: findUser
        command: ["ls", root.resolvedDataDir + "/settings/Users"]
        stdout: StdioCollector {
            onStreamFinished: {
                var entries = text.split("\n").filter(function(e) { return /-user$/.test(e); });
                root.userId = entries.length > 0 ? entries[0].replace(/-user$/, "") : "";
            }
        }
    }

    // Position ticks 4× a second so synced lyrics (and the bar's early
    // offset) land close to the beat.
    Timer {
        interval: 250
        repeat: true
        running: root.playing
        onTriggered: root.now = Date.now()
    }
}
