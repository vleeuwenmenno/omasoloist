pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Ui as Ui

// Settings: Spotify account, Soloist playback preferences, about.
//
// Soloist has no settings API; these write Spotify's own preference keys in
// Soloist's prefs file and restart the service (bin/spotify.py prefs-apply).
// They only affect playback on this computer, so they grey out while
// another device is playing.
Flickable {
    id: root

    required property var app

    readonly property var service: app.service
    readonly property bool remote: service.remoteActive

    property var prefs: ({})
    property var pending: ({})
    property var about: null
    property var me: null
    property bool loading: false
    property bool applying: false
    property string error: ""
    readonly property bool dirty: Object.keys(pending).length > 0

    readonly property var labelModes: [
        { id: "icon", label: "Icon only" },
        { id: "title", label: "Song title" },
        { id: "title-artist", label: "Title – Artist" },
        { id: "artist-title", label: "Artist – Title" },
        { id: "lyrics", label: "Current lyric line" }
    ]

    readonly property var qualities: [
        { label: "Automatic", value: null },
        { label: "Low", value: "1" },
        { label: "Normal", value: "2" },
        { label: "High", value: "3" },
        { label: "Very high", value: "4" },
        { label: "Lossless", value: "5" }
    ]

    function value(key, fallback) {
        if (key in pending) return pending[key];
        return key in prefs ? prefs[key] : fallback;
    }
    function flag(key, fallback) { return String(value(key, fallback ? "true" : "false")) === "true"; }
    function set(key, v) {
        var next = Object.assign({}, pending);
        var original = key in prefs ? prefs[key] : null;
        if (v === original) delete next[key]; else next[key] = v;
        pending = next;
    }
    function setQuality(label) {
        var q = qualities.filter(function(x) { return x.label === label; })[0];
        set("audio.play_bitrate_enumeration", q.value);
        set("audio.play_bitrate_non_metered_enumeration", q.value);
    }
    readonly property string qualityLabel: {
        var v = value("audio.play_bitrate_non_metered_enumeration", value("audio.play_bitrate_enumeration", null));
        var q = qualities.filter(function(x) { return x.value === (v === null ? null : String(v)); })[0];
        return q ? q.label : "Automatic";
    }

    function load() {
        loading = true;
        service.api.call(["prefs-get", service.soloist.resolvedDataDir, service.serviceName], function(result) {
            root.loading = false;
            if (!result.ok) { root.error = result.error; return; }
            root.prefs = result.prefs;
            root.about = result.about;
            root.pending = {};
        });
        if (service.api.signedIn)
            service.api.call(["me"], function(result) { if (result.ok) root.me = result; });
    }

    function apply() {
        applying = true;
        error = "";
        service.api.call(["prefs-apply", service.soloist.resolvedDataDir, service.serviceName,
                          JSON.stringify(pending)], function(result) {
            root.applying = false;
            if (!result.ok) { root.error = result.error; return; }
            root.prefs = result.prefs;
            root.about = result.about;
            root.pending = {};
        });
    }

    // Settings > Cache (bin/spotify.py cache-info / cache-clear).
    property var cache: null
    property string clearing: ""
    function loadCache() {
        service.api.call(["cache-info"], function(result) { if (result.ok) root.cache = result; });
    }
    function clearCache(id) {
        clearing = id;
        service.api.call(["cache-clear", id], function(result) {
            root.clearing = "";
            if (result.ok) root.cache = result;
            else root.error = result.error;
        });
    }
    // Settings > Listening history (bin/spotify.py history-info / history-clear).
    property var history: null
    property bool confirmHistoryClear: false
    function loadHistory() {
        if (!service.api.signedIn) { history = null; return; }
        service.api.call(["history-info"], function(result) { if (result.ok) root.history = result; });
    }
    function clearHistory() {
        if (!confirmHistoryClear) { confirmHistoryClear = true; return; }
        confirmHistoryClear = false;
        service.api.call(["history-clear"], function(result) {
            if (result.ok) root.history = result;
            else root.error = result.error;
        });
    }

    function formatBytes(n) {
        return n >= 1048576 ? (n / 1048576).toFixed(1) + " MB" : n >= 1024 ? Math.round(n / 1024) + " KB" : n + " B";
    }
    function formatWait(seconds) {
        var minutes = Math.max(1, Math.round(seconds / 60));
        return minutes >= 60 ? Math.floor(minutes / 60) + " h " + (minutes % 60) + " min" : minutes + " min";
    }

    Connections {
        target: root.service.api
        function onSessionReset() { root.me = null; }
        function onSignedInChanged() { if (root.service.api.signedIn && root.visible) root.load(); }
        function onCacheCleared(group) { if (root.visible && (group === "api" || group === "all" || group === "images")) root.load(); }
    }

    onVisibleChanged: if (visible) { load(); loadCache(); loadHistory(); service.api.refreshLimits(); }
        else confirmHistoryClear = false

    clip: true
    contentHeight: content.implicitHeight + 64
    boundsBehavior: Flickable.StopAtBounds
    Controls.ScrollBar.vertical: Controls.ScrollBar {}

    component SectionTitle: Text {
        topPadding: 16
        bottomPadding: 4
        color: root.app.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
    }

    component SettingRow: Item {
        id: settingRow
        property string label: ""
        property string detail: ""
        default property alias control: slot.data
        width: parent ? parent.width : 0
        height: Math.max(56, labels.implicitHeight + 16)

        Column {
            id: labels
            anchors.left: parent.left
            anchors.right: slot.left
            anchors.rightMargin: 24
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: settingRow.label
                color: root.app.fg
                font.family: Style.font.family
                font.pixelSize: Style.font.body
            }

            Text {
                visible: text !== ""
                width: parent.width
                wrapMode: Text.WordWrap
                text: settingRow.detail
                color: root.app.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
            }
        }

        Item {
            id: slot
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: childrenRect.width
            height: childrenRect.height
        }
    }

    Column {
        id: content
        x: 32
        y: 24
        width: Math.min(760, root.width - 64)
        spacing: 4

        Text {
            text: "Settings"
            color: root.app.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.displayLarge
            font.bold: true
        }

        // ---------------------------------------------------------- account
        SectionTitle { text: "Account" }

        SettingRow {
            label: root.service.api.signedIn ? (root.me ? root.me.name : "Signed in") : "Not signed in"
            detail: root.service.api.signedIn && root.service.api.missingScopes.length > 0
                ? "Sign in again to allow following artists (new permission)"
                : root.service.api.signedIn
                ? (root.me && root.me.product ? "Spotify " + root.me.product.charAt(0).toUpperCase() + root.me.product.slice(1) + " • " : "")
                  + "Used for your library, search and other devices"
                : root.service.api.hasClientId ? "Sign in to browse your library and control other devices"
                : "Add a Spotify app Client ID to " + root.service.api.configFile

            Ui.Button {
                bordered: true
                enabled: root.service.api.hasClientId && !root.service.api.signingIn
                readonly property bool reauth: root.service.api.signedIn && root.service.api.missingScopes.length > 0
                text: root.service.api.signingIn ? "Waiting for browser…"
                    : reauth ? "Sign in again"
                    : root.service.api.signedIn ? "Sign out" : "Sign in with Spotify"
                foreground: reauth ? root.app.accent : root.app.fg
                onClicked: reauth || !root.service.api.signedIn ? root.service.api.login() : root.service.api.logout()
            }
        }

        // --------------------------------------------------------- playback
        SectionTitle { text: "Playback on this computer" }

        Rectangle {
            visible: root.remote
            width: parent.width
            height: remoteNote.implicitHeight + 20
            radius: 6
            color: Qt.rgba(root.app.accent.r, root.app.accent.g, root.app.accent.b, 0.15)

            Text {
                id: remoteNote
                anchors.centerIn: parent
                width: parent.width - 24
                wrapMode: Text.WordWrap
                text: "Playing on " + root.service.remote.deviceName + ". These settings only apply when Soloist on "
                    + "this computer is playing, and are set on that device itself otherwise."
                color: root.app.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
            }
        }

        Column {
            width: parent.width
            enabled: !root.remote && !root.applying && root.service.soloist.userId !== ""
            opacity: enabled ? 1 : 0.45

            SettingRow {
                label: "Audio quality"
                detail: "Streaming quality. Lossless needs a plan that includes it."

                Ui.Dropdown {
                    width: 180
                    showLabel: false
                    options: root.qualities.map(function(q) { return q.label; })
                    value: root.qualityLabel
                    onChanged: function(v) { root.setQuality(v); }
                }
            }

            SettingRow {
                label: "Normalize volume"
                detail: "Set the same volume level for all songs"

                Ui.ToggleSwitch {
                    checked: root.flag("audio.normalize_v2", true)
                    onToggled: root.set("audio.normalize_v2", checked ? "false" : "true")
                }
            }

            SettingRow {
                label: "Crossfade songs"
                detail: root.flag("audio.crossfade_v2", false)
                    ? Math.round(Number(root.value("audio.crossfade.time_v2", "5000")) / 1000) + " s overlap between songs"
                    : "Fade between songs"

                Ui.ToggleSwitch {
                    checked: root.flag("audio.crossfade_v2", false)
                    onToggled: root.set("audio.crossfade_v2", checked ? "false" : "true")
                }
            }

            SettingRow {
                visible: root.flag("audio.crossfade_v2", false)
                label: "Crossfade duration"

                Ui.PanelSlider {
                    width: 240
                    bar: null
                    minimum: 1
                    maximum: 12
                    step: 1
                    integer: true
                    value: Math.round(Number(root.value("audio.crossfade.time_v2", "5000")) / 1000)
                    onReleased: function(v) { root.set("audio.crossfade.time_v2", String(Math.round(v) * 1000)); }
                }
            }

            SettingRow {
                label: "Gapless playback"
                detail: "No silence between tracks on albums that flow together"

                Ui.ToggleSwitch {
                    checked: root.flag("audio.gapless_v2", true)
                    onToggled: root.set("audio.gapless_v2", checked ? "false" : "true")
                }
            }

            SettingRow {
                label: "Automix"
                detail: "Seamless transitions on playlists that support it"

                Ui.ToggleSwitch {
                    checked: root.flag("audio.automix", true)
                    onToggled: root.set("audio.automix", checked ? "false" : "true")
                }
            }

            Row {
                topPadding: 12
                spacing: 12

                Ui.Button {
                    bordered: true
                    enabled: root.dirty
                    selected: root.dirty
                    iconText: root.applying ? "󰔟" : "󰑐"
                    text: root.applying ? "Restarting Soloist…" : "Save and restart Soloist"
                    foreground: root.dirty ? root.app.accent : root.app.fg
                    onClicked: root.apply()
                }

                Ui.Button {
                    visible: root.dirty && !root.applying
                    text: "Discard"
                    foreground: root.app.dim
                    onClicked: root.pending = {}
                }
            }

            Text {
                topPadding: 8
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Saving restarts the Soloist service, so playback stops for a few seconds. These are Spotify's "
                    + "internal preferences; Soloist doesn't document them, so some may have no effect."
                color: root.app.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
            }
        }

        Text {
            visible: root.error !== ""
            topPadding: 8
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.error
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
        }

        // ------------------------------------------------------- bar widget
        SectionTitle { text: "Bar widget" }

        SettingRow {
            label: "Label next to the icon"
            detail: root.service.labelMode === "lyrics"
                ? "Shows the line being sung; songs without synced lyrics show the title"
                : "What the bar shows while music plays"

            Ui.Dropdown {
                width: 220
                showLabel: false
                options: root.labelModes.map(function(m) { return m.label; })
                value: (root.labelModes.filter(function(m) { return m.id === root.service.labelMode; })[0] || root.labelModes[1]).label
                onChanged: function(v) {
                    var mode = root.labelModes.filter(function(m) { return m.label === v; })[0];
                    if (mode) root.service.saveWidgetSettings({ labelMode: mode.id });
                }
            }
        }

        SettingRow {
            visible: root.service.labelMode !== "icon"
            label: "Maximum length"
            detail: (root.service.widgetSettings.labelLength || 72) + " characters, longer text is cut off with …"

            Ui.PanelSlider {
                width: 240
                bar: null
                minimum: 15
                maximum: 150
                step: 5
                integer: true
                value: root.service.widgetSettings.labelLength || 72
                onReleased: function(v) { root.service.saveWidgetSettings({ labelLength: Math.round(v) }); }
            }
        }

        SettingRow {
            visible: root.service.labelMode === "lyrics"
            label: "Show lyrics early"
            detail: ((root.service.widgetSettings.lyricsOffset ?? 250)) + " ms ahead of the song, in the bar only"

            Ui.PanelSlider {
                width: 240
                bar: null
                minimum: 0
                maximum: 2000
                step: 50
                integer: true
                value: (root.service.widgetSettings.lyricsOffset ?? 250)
                onReleased: function(v) { root.service.saveWidgetSettings({ lyricsOffset: Math.round(v / 50) * 50 }); }
            }
        }

        // Popup buttons, each can be hidden.
        Repeater {
            model: [
                { id: "library", label: "Your Library button", detail: "Opens your playlists in the popup" },
                { id: "lyrics", label: "Lyrics button", detail: "Shown for songs that have lyrics" },
                { id: "app", label: "Open app button", detail: "Opens this window" },
                { id: "devices", label: "Devices button", detail: "Switch playback to another device" },
                { id: "queue", label: "Queue button", detail: "Shows what plays next" }
            ]

            SettingRow {
                id: buttonRow
                required property var modelData
                label: modelData.label
                detail: modelData.detail

                Ui.ToggleSwitch {
                    checked: root.service.popupShows(buttonRow.modelData.id)
                    onToggled: root.service.setPopupButton(buttonRow.modelData.id, !checked)
                }
            }
        }

        SettingRow {
            visible: root.service.popupShows("lyrics")
            label: "Lyrics in the popup"
            detail: root.service.popupLyricsMode === "cover"
                ? "The lyrics button swaps the cover for the lyrics; the controls stay visible"
                : "The lyrics button opens a lyrics view with a back button"

            Ui.Dropdown {
                width: 220
                showLabel: false
                options: ["Own view", "In place of the cover"]
                value: root.service.popupLyricsMode === "cover" ? "In place of the cover" : "Own view"
                onChanged: function(v) { root.service.saveWidgetSettings({ popupLyricsMode: v === "Own view" ? "view" : "cover" }); }
            }
        }

        SettingRow {
            label: "Reopen on the player"
            detail: "When the popup opens again, show the player instead of the last view you had open (lyrics, queue, library…)"

            Ui.ToggleSwitch {
                checked: root.service.popupResetView
                onToggled: root.service.saveWidgetSettings({ popupResetView: !root.service.popupResetView })
            }
        }

        SectionTitle { text: "App window" }

        SettingRow {
            label: "Open as a floating window"
            detail: "Float, size and center this window each time it opens. Turn off to let Hyprland tile it"

            Ui.ToggleSwitch {
                checked: root.app.floatWindow
                onToggled: root.app.floatWindow = !root.app.floatWindow
            }
        }

        // ------------------------------------------------------------ about
        SectionTitle { text: "About" }

        SettingRow {
            label: "Device name"
            detail: "How this computer shows up in Spotify Connect"
            Text {
                text: root.service.soloist.deviceName || "—"
                color: root.app.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.body
            }
        }

        SettingRow {
            label: "Soloist"
            detail: root.about && root.about.expiresInDays >= 0
                ? "This build expires in " + root.about.expiresInDays + " days; update Soloist before then"
                : ""
            Text {
                text: root.about && root.about.version ? root.about.version.split(" ").slice(0, 2).join(" ") : "—"
                color: root.app.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.body
            }
        }

        // ------------------------------------------------ listening history
        SectionTitle { text: "Listening history"; visible: root.history !== null }

        SettingRow {
            visible: root.history !== null
            label: root.history && root.history.plays
                ? root.history.plays.toLocaleString(Qt.locale("en_US"), "f", 0) + " plays since "
                    + new Date(root.history.since).toLocaleDateString(Qt.locale(), Locale.LongFormat)
                : "No plays saved yet"
            detail: "Spotify only keeps your last 50 plays, so this computer saves them for Recents"
                + (root.history ? " · " + root.formatBytes(root.history.bytes) + " in " + root.history.dir : "")

            Ui.Button {
                bordered: true
                enabled: root.history !== null && root.history.plays > 0
                text: root.confirmHistoryClear ? "Click again to delete" : "Clear"
                foreground: Color.urgent
                onClicked: root.clearHistory()
            }
        }

        // ------------------------------------------------------------ cache
        SectionTitle { text: "Cache" }

        Text {
            visible: root.cache !== null && root.cache.stats !== undefined
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.cache && root.cache.stats ? "Spotify requests: " + (root.cache.stats.requests || 0)
                + " · Served from cache: " + (root.cache.stats.cacheHits || 0)
                + " · Rate-limit responses: " + (root.cache.stats.rateLimited || 0)
                + " · Blocked locally during cooldown: " + (root.cache.stats.cooldownSkips || 0)
                + "\nCounts since " + (root.cache.stats.since ? new Date(root.cache.stats.since * 1000).toLocaleDateString() : "first request") : ""
            color: root.app.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
        }

        Text {
            visible: root.cache !== null && !!root.cache.stats && !!root.cache.stats.endpoints
            width: parent.width
            wrapMode: Text.WordWrap
            text: {
                var stats = root.cache ? root.cache.stats : null;
                if (!stats || !stats.endpoints) return "";
                var endpoints = stats.endpoints;
                var busiest = Object.keys(endpoints).sort(function(a, b) {
                    return (endpoints[b].requests || 0) - (endpoints[a].requests || 0);
                }).filter(function(key) { return endpoints[key].requests > 0; }).slice(0, 5);
                var hour = Math.floor(Date.now() / 3600000) * 3600;
                var current = (stats.hours || []).filter(function(h) { return h.start === hour; });
                return "Requests this hour: " + (current.length ? current[0].requests : 0)
                    + "\nBusiest endpoints since " + new Date(stats.breakdownSince * 1000).toLocaleString()
                    + busiest.map(function(key) { return "\n" + key + ": " + endpoints[key].requests; }).join("");
            }
            color: root.app.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
        }

        Text {
            width: parent.width
            bottomPadding: 4
            wrapMode: Text.WordWrap
            text: (root.cache ? root.formatBytes(root.cache.bytes) + " in " + root.cache.dir + ". " : "")
                + "Cached answers keep Spotify's request limits at bay and fill in while Spotify holds an endpoint back, "
                + "so clearing Spotify data while it is limited leaves those views empty until it lifts."
            color: root.app.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
        }

        Repeater {
            model: root.cache ? root.cache.groups : []

            SettingRow {
                id: cacheRow
                required property var modelData
                label: modelData.label
                detail: modelData.detail + " · " + root.formatBytes(modelData.bytes)
                    + " · " + modelData.files.toLocaleString(Qt.locale("en_US"), "f", 0) + " files"

                Ui.Button {
                    bordered: true
                    enabled: root.clearing === "" && cacheRow.modelData.files > 0
                    text: root.clearing === cacheRow.modelData.id || root.clearing === "all" ? "Clearing…" : "Clear"
                    foreground: root.app.fg
                    onClicked: root.clearCache(cacheRow.modelData.id)
                }
            }
        }

        SettingRow {
            label: "Everything"
            detail: "All of the above. Your sign-in and settings stay"

            Ui.Button {
                bordered: true
                enabled: root.clearing === "" && root.cache !== null && root.cache.bytes > 0
                text: root.clearing === "all" ? "Clearing…" : "Clear all"
                foreground: Color.urgent
                onClicked: root.clearCache("all")
            }
        }

        // Active Spotify cooldowns, including the shared Web API limit.
        Item { width: 1; height: 8; visible: limitBox.visible }

        Rectangle {
            id: limitBox
            visible: root.service.api.limits.length > 0
            width: parent.width
            height: limitText.implicitHeight + 24
            radius: 6
            color: Qt.rgba(root.app.warning.r, root.app.warning.g, root.app.warning.b, 0.12)
            border.width: 1
            border.color: Qt.rgba(root.app.warning.r, root.app.warning.g, root.app.warning.b, 0.6)

            Text {
                id: limitText
                x: 12
                y: 12
                width: parent.width - 24
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: "Spotify is limiting requests\n"
                    + root.service.api.limits.map(function(l) {
                          return l.label + " (" + l.endpoint + "): " + root.formatWait(l.seconds);
                      }).join("\n")
                    + "\n\nThese waits aren't cleared with the cache, so the app doesn't ask again early."
                color: root.app.warning
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
            }
        }
    }
}
