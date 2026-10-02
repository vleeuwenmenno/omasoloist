pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import qs.Commons

// Home: greeting, shortcut tiles, then shelves.
Flickable {
    id: root

    required property var app
    readonly property bool active: visible && app.showsWindow

    property var home: null
    property bool loading: false
    property string error: ""
    property int revision: 0
    // Loaded while Spotify held something back: sections may be empty or old.
    property bool partial: false
    property real loadedAt: 0

    function load(reset) {
        if (reset) { revision++; loading = false; home = null; error = ""; }
        if (!active || loading || !app.service.api.signedIn) return;
        loading = true;
        var requestedRevision = revision;
        app.service.api.call(["home"], function(result) {
            if (requestedRevision !== root.revision) return;
            root.loading = false;
            if (!result.ok) { root.error = result.error; return; }
            root.error = "";
            root.home = result;
            root.loadedAt = Date.now();
            root.partial = !!result.stale || root.app.service.api.limits.length > 0;
        });
    }

    readonly property string greeting: {
        var hour = new Date().getHours();
        return hour < 5 ? "Good night" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening";
    }

    Component.onCompleted: load()
    // Load only when Home is shown, including the first time the window opens.
    onActiveChanged: if (active && (!home || partial || Date.now() - loadedAt > 5 * 60 * 1000)) load()
    Connections {
        target: root.app.service.api
        function onSignedInChanged() { if (root.app.service.api.signedIn) root.load(); }
        // A limit just lifted: fill in what was missing, keeping the page up meanwhile.
        function onLimitsChanged() { if (root.partial && root.app.service.api.limits.length === 0) root.load(); }
        function onSessionReset() { root.load(true); }
        function onCacheCleared(group) { if (group !== "lyrics") root.load(true); }
        function onLibraryChanged(uri) {
            if (uri.indexOf("spotify:playlist:") === 0) root.load(true);
        }
    }

    clip: true
    contentHeight: content.implicitHeight + 48
    boundsBehavior: Flickable.StopAtBounds
    Controls.ScrollBar.vertical: Controls.ScrollBar {}

    Rectangle {
        width: root.width
        height: 280
        gradient: Gradient {
            GradientStop { position: 0; color: Qt.rgba(root.app.accent.r, root.app.accent.g, root.app.accent.b, 0.22) }
            GradientStop { position: 1; color: "transparent" }
        }
    }

    Column {
        id: content
        x: 20
        y: 20
        width: root.width - 40
        spacing: 32

        Text {
            leftPadding: 4
            text: root.greeting
            color: root.app.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.display
            font.bold: true
        }

        Text {
            visible: !root.app.service.api.signedIn
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Sign in with Spotify in Settings to see your library and recommendations."
            color: root.app.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.body
        }

        Text {
            visible: root.error !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.error
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
        }

        // Shortcut tiles
        Grid {
            id: shortcuts
            visible: root.home !== null
            width: parent.width
            columns: width > 1100 ? 4 : 2
            spacing: 8
            readonly property real tileWidth: (width - spacing * (columns - 1)) / columns

            Repeater {
                model: root.home ? root.home.shortcuts : []

                Rectangle {
                    id: tile
                    required property var modelData
                    readonly property bool playingThis: root.app.isPlayingUri(root.app.resolveUri(modelData))
                    width: shortcuts.tileWidth
                    height: 64
                    radius: 4
                    clip: true
                    color: Qt.rgba(root.app.fg.r, root.app.fg.g, root.app.fg.b, hover.hovered ? 0.16 : 0.08)

                    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.app.openItem(tile.modelData) }
                    TapHandler {
                        acceptedButtons: Qt.RightButton
                        onTapped: function(point) { root.app.showMenu(tile.modelData, tile, point.position.x, point.position.y); }
                    }

                    Cover {
                        id: tileArt
                        width: 64
                        height: 64
                        radius: 0
                        source: tile.modelData.cover || ""
                        kind: tile.modelData.kind
                        foreground: root.app.fg
                    }

                    Text {
                        anchors.left: tileArt.right
                        anchors.leftMargin: 12
                        anchors.right: tilePlay.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        text: tile.modelData.name
                        color: tile.playingThis ? root.app.accent : root.app.fg
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        font.bold: true
                    }

                    PlayCircle {
                        id: tilePlay
                        anchors.right: parent.right
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        width: 36
                        accent: root.app.accent
                        glyphColor: root.app.bg
                        playing: tile.playingThis && root.app.service.player.playing
                        opacity: hover.hovered || tile.playingThis ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 150 } }
                        onClicked: root.app.playItem(tile.modelData)
                    }
                }
            }
        }

        Shelf {
            width: parent.width
            app: root.app
            title: "Jump back in"
            items: root.home ? root.home.recents || root.home.recentAlbums || [] : []
        }

        Shelf {
            width: parent.width
            app: root.app
            subtitle: "Non-stop music based on your favorite artists"
            title: "Recommended stations"
            items: root.home ? root.home.stations || [] : []
        }

        Shelf {
            width: parent.width
            app: root.app
            title: "Popular radio"
            subtitle: "Stations of artists your favorites' fans also like"
            items: root.home ? root.home.popularRadio || [] : []
        }

        Shelf {
            width: parent.width
            app: root.app
            title: "Your top artists"
            items: root.home ? root.home.topArtists : []
        }

        Shelf {
            width: parent.width
            app: root.app
            title: "Your top tracks"
            items: root.home ? root.home.topTracks.map(function(t) {
                return { kind: "track", uri: t.uri, name: t.name, cover: t.cover_large || t.cover, subtitle: t.artists, album_uri: t.album_uri };
            }) : []
        }

        Text {
            visible: root.loading && root.home === null
            text: "Loading…"
            color: root.app.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.body
        }
    }
}
