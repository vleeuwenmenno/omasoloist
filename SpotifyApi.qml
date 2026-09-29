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

    function call(args, callback) {
        var process = runner.createObject(root, { command: ["python3", "-I", root.helper].concat(args) });
        process.done.connect(function(result) {
            if (!result.ok && /Not signed in/.test(result.error || "")) root.signedIn = false;
            if (callback) callback(result);
            process.destroy();
        });
        process.running = true;
    }

    function refreshStatus() {
        call(["status"], function(result) {
            if (!result.ok) return;
            root.hasClientId = result.hasClientId;
            root.signedIn = result.signedIn;
            root.configFile = result.configFile;
            root.redirectUri = result.redirectUri;
            root.missingScopes = result.missingScopes || [];
            root.checked = true;
        });
    }

    function setClientId(id) {
        call(["set-client-id", id], function(result) {
            if (result.ok) root.hasClientId = result.hasClientId;
            else root.error = result.error;
        });
    }

    function login() {
        if (signingIn) return;
        signingIn = true;
        error = "";
        call(["login"], function(result) {
            root.signingIn = false;
            if (result.ok) {
                root.signedIn = result.signedIn;
                root.missingScopes = result.missingScopes || [];
            }
            else root.error = result.error;
        });
    }

    function logout() { call(["logout"], function() { root.signedIn = false; }); }

    // Play `body` (as for PUT /me/player/play) on the Soloist device.
    function play(deviceName, body, callback) {
        call(["play", deviceName, JSON.stringify(body)], function(result) {
            if (!result.ok) root.error = result.error;
            if (callback) callback(result);
        });
    }

    Component.onCompleted: refreshStatus()

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
