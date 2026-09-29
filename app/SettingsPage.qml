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

    onVisibleChanged: if (visible) load()

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

        SettingRow {
            label: "Lyrics in the popup"
            detail: "Show a lyrics button in the bar popup for songs that have lyrics"

            Ui.ToggleSwitch {
                checked: root.service.popupLyrics
                onToggled: root.service.saveWidgetSettings({ popupLyrics: !root.service.popupLyrics })
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
    }
}
