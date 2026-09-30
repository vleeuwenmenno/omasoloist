pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import qs.Commons

// Your profile, like open.spotify.com/user/<id>: avatar hero tinted with the
// avatar's colour, top artists and tracks this month, public playlists.
Flickable {
    id: root

    required property var app

    property var profile: null
    property bool loading: false
    property string error: ""
    property string pendingUri: ""
    property bool showAllTracks: false
    property int revision: 0

    readonly property var player: app.service.player
    // Spotify's colour extracted from the avatar; theme accent otherwise.
    readonly property color heroColor: profile && profile.color ? profile.color : app.accent

    function load(reset) {
        if (reset) { revision++; loading = false; profile = null; error = ""; }
        if (loading || !app.service.api.signedIn) return;
        loading = true;
        var requestedRevision = revision;
        app.service.api.call(["profile"], function(result) {
            if (requestedRevision !== root.revision) return;
            root.loading = false;
            if (!result.ok) { root.error = result.error; return; }
            root.error = "";
            root.profile = result;
            root.app.service.likes.query(result.topTracks.map(function(t) { return t.uri; }));
        });
    }

    function playTrack(index) {
        var tracks = profile.topTracks;
        pendingUri = tracks[index].uri;
        app.service.api.play(player.deviceName, { uris: tracks.slice(index).map(function(t) { return t.uri; }) },
                             function() { root.pendingUri = ""; });
    }

    onVisibleChanged: if (visible && !profile) load()

    Connections {
        target: root.app.service.api
        function onSessionReset() { root.revision++; root.loading = false; root.profile = null; }
        function onSignedInChanged() { if (root.visible && root.app.service.api.signedIn) root.load(); }
        function onCacheCleared(group) { if (group !== "lyrics") root.load(true); }
        function onLibraryChanged(uri) { if (uri.indexOf("spotify:track:") !== 0) root.load(true); }
    }

    clip: true
    contentHeight: content.implicitHeight + 48
    boundsBehavior: Flickable.StopAtBounds
    Controls.ScrollBar.vertical: Controls.ScrollBar {}

    Column {
        id: content
        width: root.width

        // Hero
        Rectangle {
            width: parent.width
            height: 300
            gradient: Gradient {
                GradientStop { position: 0; color: Qt.lighter(root.heroColor, 1.2) }
                GradientStop { position: 1; color: Qt.darker(root.heroColor, 1.6) }
            }

            Cover {
                id: avatar
                anchors.left: parent.left
                anchors.leftMargin: 24
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 24
                width: 232
                height: 232
                kind: "artist"
                source: root.profile ? root.profile.image : ""
                foreground: root.app.fg
            }

            Column {
                anchors.left: avatar.right
                anchors.leftMargin: 24
                anchors.right: parent.right
                anchors.rightMargin: 24
                anchors.bottom: avatar.bottom
                spacing: 8

                Text {
                    text: "Profile"
                    color: "white"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                }

                Text {
                    width: parent.width
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: root.profile ? root.profile.name : ""
                    color: "white"
                    font.family: Style.font.family
                    font.pixelSize: text.length > 16 ? 48 : 72
                    font.bold: true
                }

                Text {
                    text: !root.profile ? "" : [
                        root.profile.publicPlaylistCount + " Public Playlists",
                        root.profile.following >= 0 ? root.profile.following + " Following" : ""
                    ].filter(function(x) { return x; }).join(" • ")
                    color: "white"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                }
            }
        }

        // Actions
        Item {
            width: parent.width
            height: 80

            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    GradientStop { position: 0; color: Qt.rgba(root.heroColor.r, root.heroColor.g, root.heroColor.b, 0.25) }
                    GradientStop { position: 1; color: "transparent" }
                }
            }

            Text {
                id: moreButton
                x: 24
                anchors.verticalCenter: parent.verticalCenter
                text: "󰇘"
                color: moreMouse.containsMouse ? root.app.fg : root.app.dim
                font.family: Style.font.family
                font.pixelSize: 28

                MouseArea {
                    id: moreMouse
                    anchors.fill: parent
                    anchors.margins: -8
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.app.showEntries([
                        { label: "Copy link to profile", icon: "󰌷",
                          action: function() { root.app.service.copyLink(root.profile.uri); } },
                        { label: "Open in web player", icon: "󰖟", external: true,
                          action: function() { Qt.openUrlExternally(root.app.service.webUrl(root.profile.uri)); } }
                    ], moreButton, 0, moreButton.height + 4)
                }
            }
        }

        Column {
            x: 12
            width: root.width - 24
            spacing: 32

            Shelf {
                width: parent.width
                app: root.app
                title: "Top artists this month"
                caption: "Only visible to you"
                items: root.profile ? root.profile.topArtists : []
            }

            Column {
                width: parent.width
                visible: root.profile !== null && root.profile.topTracks.length > 0

                Text {
                    leftPadding: 12
                    text: "Top tracks this month"
                    color: root.app.fg
                    font.family: Style.font.family
                    font.pixelSize: Style.font.display
                    font.bold: true
                }

                Text {
                    leftPadding: 12
                    bottomPadding: 12
                    text: "Only visible to you"
                    color: root.app.dim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                }

                Repeater {
                    model: root.profile ? root.profile.topTracks.slice(0, root.showAllTracks ? 10 : 4) : []

                    TrackRow {
                        required property var modelData
                        required property int index
                        x: 4
                        width: parent.width - 8
                        track: modelData
                        number: index + 1
                        showAdded: false
                        current: root.player.item && root.player.item.uri === modelData.uri
                        playing: root.player.playing
                        pending: root.pendingUri === modelData.uri
                        foreground: root.app.fg
                        accent: root.app.accent
                        likeable: root.app.service.api.signedIn
                        liked: root.app.service.likes.isLiked(modelData.uri)
                        onLikeToggled: root.app.service.likes.toggle(modelData.uri)
                        onMenuRequested: function(source, x, y) { root.app.showMenu(modelData, source, x, y); }
                        onActivated: current ? root.player.togglePlay() : root.playTrack(index)
                    }
                }

                Text {
                    visible: root.profile !== null && root.profile.topTracks.length > 4
                    leftPadding: 28
                    topPadding: 12
                    text: root.showAllTracks ? "Show less" : "Show all"
                    color: root.app.dim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.showAllTracks = !root.showAllTracks
                    }
                }
            }

            Shelf {
                width: parent.width
                app: root.app
                title: "Public Playlists"
                items: root.profile ? root.profile.playlists : []
            }
        }

        Text {
            x: 24
            topPadding: 16
            visible: root.loading || root.error !== ""
            text: root.error !== "" ? root.error : "Loading…"
            color: root.error !== "" ? Color.urgent : root.app.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
        }
    }
}
