import QtQuick
import Quickshell.Io

// Runs bin/spotify.py for Spotify Web API calls: library, playlists and
// playback with an offset. Each call gets its own process so a slow page
// load never blocks a play request.
Item {
    id: root
    visible: false

    readonly property string helper: decodeURIComponent(Qt.resolvedUrl("bin/spotify.py").toString().replace(/^file:\/\//, ""))

    property bool checked: false
    property bool hasClientId: false
    property bool signedIn: false
    property bool signingIn: false
    property string configFile: ""
    property string redirectUri: ""
    // Permissions added in newer versions; signing in again grants them.
    property var missingScopes: []
    property string error: ""
    property string session: ""
    property int sessionRevision: 0
    property int statusRevision: 0
    signal sessionReset()
    signal cacheCleared(string group)
    signal libraryChanged(string uri)
    // Endpoints Spotify is holding back: [{endpoint, label, seconds}], read
    // from the helper's local wait files (no network).
    property var limits: []
    property real limitsUpdatedAt: Date.now()
    onLimitsChanged: limitsUpdatedAt = Date.now()
    readonly property int limitSeconds: limits.reduce(function(m, l) { return Math.max(m, l.seconds); }, 0)

    function call(args, callback) {
        var revision = sessionRevision;
        var commandName = args[0] === "--fresh" ? args[1] : args[0];
        var local = ["status", "set-client-id", "login", "logout", "cache-clear", "cache-info", "rate-limits"].indexOf(commandName) >= 0;
        var process = runner.createObject(root, { command: ["python3", "-I", root.helper].concat(args) });
        process.done.connect(function(result) {
            if (!local && revision !== root.sessionRevision)
                result = { ok: false, cancelled: true, error: "Spotify sign-in changed. Try again." };
            if (!local && result.session && root.session && result.session !== root.session) {
                result = { ok: false, cancelled: true, error: "Spotify sign-in changed. Try again." };
                root.refreshStatus();
            }
            if (result.limits !== undefined) root.limits = result.limits;
            if (!result.ok && /Not signed in/.test(result.error || ""))
                root.applyStatus({session: "", signedIn: false, hasClientId: root.hasClientId,
                                  configFile: root.configFile, redirectUri: root.redirectUri, missingScopes: []});
            if (result.rateLimited || /limiting requests/.test(result.error || "")) limitsSoon.restart();
            if (result.ok && commandName === "cache-clear") root.cacheCleared(args[1]);
            if (result.ok && commandName === "like") root.libraryChanged(args[1]);
            if (result.ok && commandName === "add-to-playlist") root.libraryChanged("spotify:playlist:" + args[1]);
            if (callback) callback(result);
            process.destroy();
        });
        process.running = true;
    }

    function refreshStatus() {
        var requestedRevision = ++statusRevision;
        call(["status"], function(result) {
            if (!result.ok || requestedRevision !== root.statusRevision) return;
            root.applyStatus(result);
        });
    }

    function applyStatus(result) {
        var nextSession = result.session || "";
        if (nextSession !== session) {
            signedIn = false;
            sessionRevision++;
            session = nextSession;
            sessionReset();
        }
        hasClientId = result.hasClientId;
        configFile = result.configFile;
        redirectUri = result.redirectUri;
        missingScopes = result.missingScopes || [];
        signedIn = result.signedIn;
        checked = true;
    }

    function setClientId(id) {
        var requestedRevision = ++statusRevision;
        call(["set-client-id", id], function(result) {
            if (requestedRevision !== root.statusRevision) return;
            if (result.ok) root.applyStatus(result);
            else root.error = result.error;
        });
    }

    function login() {
        if (signingIn) return;
        signingIn = true;
        error = "";
        var requestedRevision = ++statusRevision;
        call(["login"], function(result) {
            root.signingIn = false;
            if (requestedRevision !== root.statusRevision) return;
            if (result.ok) {
                root.applyStatus(result);
            }
            else root.error = result.error;
        });
    }

    function logout() {
        var requestedRevision = ++statusRevision;
        call(["logout"], function(result) {
            if (result.ok && requestedRevision === root.statusRevision) root.applyStatus(result);
        });
    }

    function waitFor(path) {
        var elapsed = Math.floor((Date.now() - limitsUpdatedAt) / 1000);
        return limits.reduce(function(seconds, limit) {
            return limit.scope === "global" || limit.endpoint === "all" || path.indexOf(limit.endpoint) === 0
                ? Math.max(seconds, limit.seconds - elapsed) : seconds;
        }, 0);
    }

    // Play `body` (as for PUT /me/player/play) on the Soloist device.
    function play(deviceName, body, callback) {
        call(["play", deviceName, JSON.stringify(body)], function(result) {
            if (!result.ok) root.error = result.error;
            if (callback) callback(result);
        });
    }

    function refreshLimits() {
        call(["rate-limits"], function(result) { if (result.ok) root.limits = result.limits; });
    }

    Timer {
        id: limitsSoon
        interval: 500
        onTriggered: root.refreshLimits()
    }

    // Count down while something is held back, so the notice clears itself.
    Timer {
        interval: Math.min(60000, Math.max(1000, root.limitSeconds * 1000))
        repeat: true
        running: root.limits.length > 0
        onTriggered: root.refreshLimits()
    }

    Component.onCompleted: { refreshStatus(); refreshLimits(); }

    Component {
        id: runner

        Process {
            id: process
            signal done(var result)

            stdout: StdioCollector { id: output; waitForEnd: true }
            onExited: {
                var result;
                try { result = JSON.parse(output.text); }
                catch (e) { result = { ok: false, error: "Spotify helper failed. Is python3 installed?" }; }
                process.done(result);
            }
        }
    }
}
