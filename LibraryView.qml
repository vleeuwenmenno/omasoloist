pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Ui as Ui

// "Your Library": Liked Songs first, then the user's playlists. Selecting an
// entry opens it in `openCollection`; the play button starts it directly.
Item {
    id: root

    required property QtObject bar
    required property var api
    required property var controller
    property color foreground: Color.foreground
    property string glyph: ""

    // The app window embeds these views without the popup's back button.
    property bool showBack: true

    signal back()
    signal openCollection(var collection)
    signal rowMenuRequested(var entry, var source, real x, real y)

    readonly property color dim: Qt.darker(foreground, 1.45)
    readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

    property var playlists: []
    property bool loading: false
    property bool loadedAll: false
    property string error: ""
    property int retries: 0

    Timer {
        id: retryTimer
        interval: 3000
        onTriggered: root.load(true)
    }

    readonly property var likedSongs: ({
        kind: "liked", name: "Liked Songs", uri: root.controller.likedSongsUri,
        owner: "Playlist", cover: "", count: -1
    })
    readonly property var rows: [likedSongs].concat(playlists)

    function load(reset, fresh) {
        if (!api || loading || (!reset && loadedAll) || !api.signedIn) return;
        if (reset) { playlists = []; loadedAll = false; }
        loading = true;
        error = "";
        api.call((fresh ? ["--fresh"] : []).concat(["playlists", String(playlists.length)]), function(result) {
            root.loading = false;
            if (!result.ok) {
                root.error = result.error;
                if (root.playlists.length === 0 && root.retries < 3) { root.retries++; retryTimer.restart(); }
                return;
            }
            root.retries = 0;
            root.playlists = root.playlists.concat(result.items.map(function(p) {
                return Object.assign({ kind: "playlist" }, p);
            }));
            root.loadedAll = !result.next;
        });
    }

    // The app window creates this view already visible, so load on
    // completion too; the popup loads when it is first opened.
    // Load as soon as sign-in is known, visible or not: the app window
    // builds this view hidden at shell start, often before the sign-in
    // check finishes, and a hidden item may never see a visibility change.
    // Answers are cached, so an early load costs nothing.
    onVisibleChanged: ensureLoaded()
    Component.onCompleted: ensureLoaded()
    function ensureLoaded() { if (playlists.length === 0 && !loading) load(true); }
    Connections {
        target: root.api
        function onSignedInChanged() { if (root.api.signedIn) root.load(true); }
        function onCheckedChanged() { root.ensureLoaded(); }
    }

    Item {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        height: backButton.implicitHeight

        Ui.Button {
            id: backButton
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            visible: root.showBack
            width: visible ? implicitWidth : 0
            iconText: "󰁍"
            foreground: root.foreground
            tooltipText: "Back to player"
            onClicked: root.back()
        }

        Text {
            anchors.left: backButton.right
            anchors.leftMargin: root.showBack ? Style.space(6) : Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "Your Library"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
        }

        // Reload, skipping the on-disk cache (new playlists from other apps).
        Ui.Button {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.api && root.api.signedIn
            iconText: "󰑐"
            iconSpinning: root.loading
            foreground: root.dim
            tooltipText: "Refresh library"
            onClicked: root.load(true, true)
        }
    }

    Ui.PanelSeparator {
        id: separator
        anchors.top: header.bottom
        anchors.topMargin: Style.space(8)
        anchors.left: parent.left
        anchors.right: parent.right
        foreground: root.foreground
    }

    // Web API sign-in
    Column {
        visible: !root.api.signedIn
        anchors.top: separator.bottom
        anchors.topMargin: Style.space(24)
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(12)

        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: "Connect your Spotify account"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
        }

        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: !root.api.hasClientId
                ? "Browsing your library needs a Spotify app Client ID. Add {\"clientId\": \"…\"} to "
                  + root.api.configFile + " (redirect URI " + root.api.redirectUri + ")."
                : root.api.signingIn ? "Finish signing in in your browser…"
                : "Sign in once to browse your playlists and Liked Songs."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
        }

        Ui.Button {
            visible: root.api.hasClientId
            anchors.horizontalCenter: parent.horizontalCenter
            bordered: true
            enabled: !root.api.signingIn
            iconText: "󰍂"
            text: root.api.signingIn ? "Waiting for browser…" : "Sign in with Spotify"
            foreground: root.foreground
            horizontalPadding: Style.spacing.panelGap
            onClicked: root.api.login()
        }

        Text {
            visible: root.api.error !== ""
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.api.error
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
        }
    }

    ListView {
        id: list
        visible: root.api.signedIn
        anchors.top: separator.bottom
        anchors.topMargin: Style.space(4)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        spacing: Style.space(2)
        boundsBehavior: Flickable.StopAtBounds
        model: root.rows

        onAtYEndChanged: if (atYEnd && contentHeight > height) root.load(false)

        Controls.ScrollBar.vertical: Controls.ScrollBar {
            policy: list.contentHeight > list.height ? Controls.ScrollBar.AsNeeded : Controls.ScrollBar.AlwaysOff
        }

        delegate: Rectangle {
            id: row
            required property var modelData
            // Delegates can briefly outlive their row while the list rebinds.
            readonly property var entry: modelData || ({})
            readonly property bool playingThis: !!root.controller && !!root.controller.context
                && root.controller.context.uri === entry.uri

            width: list.width
            height: Style.space(56)
            radius: Style.spacing.labelGap
            color: hover.hovered ? Style.normalFillFor(root.foreground, Color.accent) : "transparent"

            HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: root.openCollection(row.entry) }
            TapHandler {
                acceptedButtons: Qt.RightButton
                onTapped: function(point) { root.rowMenuRequested(row.entry, row, point.position.x, point.position.y); }
            }

            Rectangle {
                id: art
                anchors.left: parent.left
                anchors.leftMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(44)
                height: width
                radius: Style.space(3)
                clip: true
                // Liked Songs gets Spotify's purple-to-blue tile.
                gradient: row.entry.kind === "liked" ? likedGradient : null
                color: Style.normalFillFor(root.foreground, Color.accent)

                Gradient {
                    id: likedGradient
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: "#450af5" }
                    GradientStop { position: 1; color: "#8e8ee5" }
                }

                Image {
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    sourceSize.width: 128
                    sourceSize.height: 128
                    source: row.entry.cover || ""
                    visible: status === Image.Ready
                }

                Text {
                    anchors.centerIn: parent
                    visible: !row.entry.cover
                    text: row.entry.kind === "liked" ? "󰋑" : "󰲸"
                    color: row.entry.kind === "liked" ? "white" : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                }
            }

            Ui.Button {
                id: playButton
                anchors.right: parent.right
                anchors.rightMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                visible: hover.hovered || row.playingThis
                iconText: row.playingThis && root.controller.playing ? "󰝚" : "󰐊"
                foreground: row.playingThis ? Color.accent : root.foreground
                tooltipText: "Play"
                onClicked: root.controller.play(row.entry.uri)
            }

            Column {
                anchors.left: art.right
                anchors.leftMargin: Style.space(10)
                anchors.right: playButton.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                    width: parent.width
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: row.entry.name || ""
                    color: row.playingThis ? Color.accent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: row.playingThis
                }

                Text {
                    width: parent.width
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: row.entry.kind === "liked" ? "Playlist"
                        : "Playlist · " + row.entry.owner
                          + (row.entry.count > 0 ? " · " + row.entry.count + " songs" : "")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                }
            }
        }

        // Wrapped in an Item: sizing a Text footer by its own visibility loops.
        footer: Item {
            width: list.width
            height: footerNote.visible ? footerNote.implicitHeight : 0

            Text {
                id: footerNote
                width: parent.width
                visible: root.loading || root.error !== ""
                horizontalAlignment: Text.AlignHCenter
                topPadding: Style.space(10)
                bottomPadding: Style.space(10)
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: root.error !== "" ? root.error : "Loading…"
                color: root.error !== "" ? Color.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
            }
        }
    }
}
