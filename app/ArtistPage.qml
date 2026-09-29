pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import qs.Commons

// Artist page: photo hero with monthly listeners, play/follow, Popular with
// play counts, releases, "Featuring", "Fans also like" and About.
//
// Listeners, play counts, the bio and related artists come from Spotify's
// public artist page (see artist_overview in bin/spotify.py); the Web API
// no longer exposes them to development-mode apps.
Flickable {
    id: root

    required property var app
    property var artist: null

    property var artistData: null
    property bool loading: false
    property string error: ""
    property string pendingUri: ""
    property bool showAllPopular: false

    readonly property var player: app.service.player
    readonly property bool playingThis: artist !== null && player.context && player.context.uri === artist.uri
    readonly property var info: artistData ? artistData.artist : artist
    readonly property string heroImage: info && info.cover ? info.cover : ""
    readonly property bool canFollow: app.service.api.missingScopes.indexOf("user-follow-modify") < 0
    readonly property bool following: artist !== null && app.service.likes.isLiked(artist.uri)

    function formatNumber(n) {
        return Number(n || 0).toLocaleString(Qt.locale("en_US"), "f", 0);
    }

    onArtistChanged: {
        artistData = null;
        error = "";
        showAllPopular = false;
        contentY = 0;
        if (!artist) return;
        loading = true;
        var requested = artist;
        app.service.likes.query([artist.uri]);
        app.service.api.call(["artist", artist.id], function(result) {
            if (requested !== root.artist) return;
            root.loading = false;
            if (!result.ok) { root.error = result.error; return; }
            root.artistData = result;
        });
    }

    onArtistDataChanged: if (artistData)
        app.service.likes.query(artistData.popular.map(function(t) { return t.uri; }))

    function playTrack(track, index) {
        pendingUri = track.uri;
        var uris = artistData.popular.slice(index).map(function(t) { return t.uri; });
        app.service.api.play(player.deviceName, { uris: uris }, function() { root.pendingUri = ""; });
    }

    clip: true
    contentHeight: content.implicitHeight + 48
    boundsBehavior: Flickable.StopAtBounds
    Controls.ScrollBar.vertical: Controls.ScrollBar {}

    component Heading: Text {
        x: 24
        topPadding: 8
        bottomPadding: 12
        textFormat: Text.PlainText
        color: root.app.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.display
        font.bold: true
    }

    Column {
        id: content
        width: root.width

        // Hero: the artist photo, darkened towards the bottom.
        Item {
            width: parent.width
            height: Math.max(300, Math.min(420, root.width * 0.42))
            clip: true

            Rectangle {
                anchors.fill: parent
                color: Qt.rgba(root.app.accent.r, root.app.accent.g, root.app.accent.b, 0.35)
            }

            Image {
                anchors.fill: parent
                fillMode: Image.PreserveAspectCrop
                verticalAlignment: Image.AlignTop
                asynchronous: true
                source: root.heroImage
                sourceSize.width: 1280
            }

            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    GradientStop { position: 0.35; color: "transparent" }
                    GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.72) }
                }
            }

            Column {
                anchors.left: parent.left
                anchors.leftMargin: 24
                anchors.right: parent.right
                anchors.rightMargin: 24
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 24
                spacing: 10

                Text {
                    width: parent.width
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: root.info ? root.info.name : ""
                    color: "white"
                    font.family: Style.font.family
                    font.pixelSize: text.length > 18 ? 56 : 88
                    font.bold: true
                }

                Text {
                    visible: root.artistData !== null && root.artistData.monthlyListeners > 0
                    text: root.artistData ? root.formatNumber(root.artistData.monthlyListeners) + " monthly listeners" : ""
                    color: "white"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                }
            }
        }

        // Actions
        Item {
            width: parent.width
            height: 104

            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    GradientStop { position: 0; color: Qt.rgba(root.app.accent.r, root.app.accent.g, root.app.accent.b, 0.12) }
                    GradientStop { position: 1; color: "transparent" }
                }
            }

            Row {
                anchors.left: parent.left
                anchors.leftMargin: 24
                anchors.verticalCenter: parent.verticalCenter
                spacing: 24

                PlayCircle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 56
                    accent: root.app.accent
                    glyphColor: root.app.bg
                    playing: root.playingThis && root.player.playing
                    onClicked: root.playingThis ? root.player.togglePlay() : root.player.play(root.artist.uri)
                }

                Rectangle {
                    visible: root.canFollow
                    anchors.verticalCenter: parent.verticalCenter
                    width: followText.implicitWidth + 32
                    height: 32
                    radius: 16
                    color: "transparent"
                    border.width: 1
                    border.color: followMouse.containsMouse ? root.app.fg : root.app.dim

                    Text {
                        id: followText
                        anchors.centerIn: parent
                        text: root.following ? "Following" : "Follow"
                        color: root.app.fg
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        font.bold: true
                    }

                    MouseArea {
                        id: followMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.app.service.likes.toggle(root.artist.uri)
                    }
                }

                Text {
                    id: moreButton
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰇘"
                    color: moreMouse.containsMouse ? root.app.fg : root.app.dim
                    font.family: Style.font.family
                    font.pixelSize: 26

                    MouseArea {
                        id: moreMouse
                        anchors.fill: parent
                        anchors.margins: -8
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.app.showMenu(root.info, moreButton, 0, moreButton.height)
                    }
                }
            }
        }

        Heading {
            visible: root.artistData !== null && root.artistData.popular.length > 0
            text: "Popular"
        }

        Repeater {
            model: root.artistData ? root.artistData.popular.slice(0, root.showAllPopular ? 10 : 5) : []

            TrackRow {
                required property var modelData
                required property int index
                x: 16
                width: root.width - 32
                track: modelData
                number: index + 1
                detail: modelData.playcount ? root.formatNumber(modelData.playcount) : ""
                showAlbum: detail !== ""
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
                onActivated: current ? root.player.togglePlay() : root.playTrack(modelData, index)
            }
        }

        Text {
            x: 40
            topPadding: 12
            visible: root.artistData !== null && root.artistData.popular.length > 5
            text: root.showAllPopular ? "Show less" : "See more"
            color: root.app.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: true

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.showAllPopular = !root.showAllPopular
            }
        }

        Item { width: 1; height: 32 }

        Column {
            x: 12
            width: root.width - 24
            spacing: 32

            Shelf {
                width: parent.width
                app: root.app
                title: "Popular releases"
                items: root.artistData ? root.artistData.popularReleases : []
            }

            Shelf {
                width: parent.width
                app: root.app
                title: "Discography"
                items: root.artistData ? root.artistData.albums : []
            }

            Shelf {
                width: parent.width
                app: root.app
                title: root.info ? "Featuring " + root.info.name : ""
                items: root.artistData ? root.artistData.featuring : []
            }

            Shelf {
                width: parent.width
                app: root.app
                title: "Fans also like"
                items: root.artistData ? root.artistData.related : []
            }

            // About
            Column {
                visible: root.artistData !== null && root.artistData.bio !== ""
                width: parent.width
                spacing: 12

                Text {
                    leftPadding: 12
                    text: "About"
                    color: root.app.fg
                    font.family: Style.font.family
                    font.pixelSize: Style.font.display
                    font.bold: true
                }

                Rectangle {
                    x: 12
                    width: Math.min(parent.width - 24, 820)
                    height: aboutText.implicitHeight + 48 + aboutImage.height
                    radius: 8
                    clip: true
                    color: Qt.rgba(root.app.fg.r, root.app.fg.g, root.app.fg.b, aboutMouse.containsMouse ? 0.1 : 0.06)

                    Image {
                        id: aboutImage
                        width: parent.width
                        height: Math.round(width * 0.45)
                        fillMode: Image.PreserveAspectCrop
                        verticalAlignment: Image.AlignTop
                        asynchronous: true
                        source: root.heroImage
                        sourceSize.width: 1000
                    }

                    Column {
                        id: aboutText
                        anchors.top: aboutImage.bottom
                        anchors.topMargin: 24
                        x: 24
                        width: parent.width - 48
                        spacing: 12

                        Text {
                            visible: root.artistData !== null && root.artistData.monthlyListeners > 0
                            text: root.artistData ? root.formatNumber(root.artistData.monthlyListeners) + " monthly listeners" : ""
                            color: root.app.fg
                            font.family: Style.font.family
                            font.pixelSize: Style.font.body
                            font.bold: true
                        }

                        Text {
                            width: parent.width
                            wrapMode: Text.WordWrap
                            maximumLineCount: root.bioExpanded ? 100 : 4
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                            text: root.artistData ? root.artistData.bio : ""
                            color: root.app.dim
                            font.family: Style.font.family
                            font.pixelSize: Style.font.body
                            lineHeight: 1.25
                        }
                    }

                    MouseArea {
                        id: aboutMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.bioExpanded = !root.bioExpanded
                    }
                }
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

    property bool bioExpanded: false
}
