pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import qs.Commons

// Spotify's "Now playing view" sidebar: artwork, title, a lyrics preview,
// the next track, and an "About the artist" card.
Item {
    id: root

    required property var app
    required property var info

    readonly property var player: app.service.player
    readonly property var upcoming: player.queueUpcoming || []

    signal closeRequested()

    // Header
    Item {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        height: 40

        Text {
            id: closeIcon
            anchors.left: parent.left
            anchors.leftMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            text: "󰅖"
            color: closeMouse.containsMouse ? root.app.fg : root.app.dim
            font.family: Style.font.family
            font.pixelSize: 18

            MouseArea {
                id: closeMouse
                anchors.fill: parent
                anchors.margins: -6
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.closeRequested()
            }
        }

        Text {
            anchors.left: closeIcon.right
            anchors.leftMargin: 12
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: root.player.contextName || root.player.album || "Now playing"
            color: root.app.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true

            MouseArea {
                anchors.fill: parent
                cursorShape: root.player.context ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.app.openPlayingContext()
            }
        }
    }

    Flickable {
        id: flick
        anchors.top: header.bottom
        anchors.topMargin: 8
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        contentHeight: column.implicitHeight + 16
        boundsBehavior: Flickable.StopAtBounds
        Controls.ScrollBar.vertical: Controls.ScrollBar {}

        Column {
            id: column
            width: flick.width
            spacing: 20

            Cover {
                width: parent.width
                height: width
                radius: 8
                source: root.player.coverUrl
                foreground: root.app.fg
            }

            Item {
                width: parent.width
                height: titleBlock.implicitHeight

                Text {
                    id: panelHeart
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.player.hasItem && root.app.service.api.signedIn
                        && root.player.item.uri.indexOf("spotify:track:") === 0
                    text: root.app.service.likes.currentLiked ? "󰋑" : "󰋕"
                    color: root.app.service.likes.currentLiked ? root.app.accent
                        : panelHeartMouse.containsMouse ? root.app.fg : root.app.dim
                    font.family: Style.font.family
                    font.pixelSize: 26

                    MouseArea {
                        id: panelHeartMouse
                        anchors.fill: parent
                        anchors.margins: -6
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.app.service.likes.toggle(root.player.item.uri)
                    }
                }

                Column {
                    id: titleBlock
                    anchors.left: parent.left
                    anchors.right: panelHeart.visible ? panelHeart.left : parent.right
                    anchors.rightMargin: panelHeart.visible ? 12 : 0
                    spacing: 4

                    Text {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        text: root.player.title || "Nothing playing"
                        color: root.app.fg
                        font.family: Style.font.family
                        font.pixelSize: Style.font.display
                        font.bold: true
                        font.underline: npTitleMouse.containsMouse && root.app.service.albumUri() !== ""

                        MouseArea {
                            id: npTitleMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: root.app.service.albumUri() !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: root.app.openPlayingAlbum()
                        }
                    }

                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        text: root.player.artist
                        color: root.app.dim
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: root.info.artistUri ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: if (root.info.artistUri) root.app.openUri(root.info.artistUri, root.player.artist)
                        }
                    }
                }
            }

            // Lyrics preview
            Rectangle {
                visible: root.info.lyrics !== null && root.info.lyrics.found && !root.info.lyrics.instrumental
                width: parent.width
                height: 180
                radius: 8
                clip: true
                color: Qt.darker(root.app.accent, 1.6)

                Text {
                    id: previewTitle
                    x: 16
                    y: 14
                    text: "Lyrics preview"
                    color: "white"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                }

                Column {
                    x: 16
                    anchors.top: previewTitle.bottom
                    anchors.topMargin: 10
                    width: parent.width - 32
                    spacing: 6

                    Repeater {
                        model: {
                            if (root.info.hasSynced) {
                                var start = Math.max(0, root.info.currentLine);
                                // Skip the blank instrumental-break lines in the preview.
                                return root.info.synced.slice(start).map(function(l) { return l.text; })
                                    .filter(function(t) { return t && t.trim() !== ""; }).slice(0, 3);
                            }
                            return root.info.plainLines.filter(function(l) { return l.trim() !== ""; }).slice(0, 3);
                        }

                        Text {
                            required property string modelData
                            required property int index
                            width: parent.width
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                            text: modelData
                            color: index === 0 && root.info.hasSynced && root.info.currentLine >= 0 ? "white" : Qt.rgba(1, 1, 1, 0.55)
                            font.family: Style.font.family
                            font.pixelSize: Style.font.heading
                            font.bold: true
                        }
                    }
                }

                // Fade the bottom like Spotify's card.
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 40
                    gradient: Gradient {
                        GradientStop { position: 0; color: "transparent" }
                        GradientStop { position: 1; color: Qt.darker(root.app.accent, 1.6) }
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.app.navigate({ kind: "lyrics" })
                }
            }

            // About the artist
            Rectangle {
                visible: root.info.about !== null && (root.info.about.bio !== "" || root.info.about.artist)
                width: parent.width
                height: aboutColumn.implicitHeight
                radius: 8
                clip: true
                color: Qt.rgba(root.app.fg.r, root.app.fg.g, root.app.fg.b, 0.07)

                Column {
                    id: aboutColumn
                    width: parent.width

                    Item {
                        width: parent.width
                        height: Math.round(width * 0.62)

                        Image {
                            anchors.fill: parent
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            sourceSize.width: 800
                            source: root.info.about
                                ? (root.info.about.artist && root.info.about.artist.cover ? root.info.about.artist.cover : root.info.about.image || "")
                                : ""
                        }

                        Rectangle {
                            anchors.fill: parent
                            gradient: Gradient {
                                GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0.55) }
                                GradientStop { position: 0.4; color: "transparent" }
                            }
                        }

                        Text {
                            x: 16
                            y: 14
                            text: "About the artist"
                            color: "white"
                            font.family: Style.font.family
                            font.pixelSize: Style.font.body
                            font.bold: true
                        }
                    }

                    Column {
                        width: parent.width
                        padding: 16
                        spacing: 8

                        Text {
                            width: parent.width - 32
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                            text: root.info.about && root.info.about.artist ? root.info.about.artist.name : ""
                            color: root.app.fg
                            font.family: Style.font.family
                            font.pixelSize: Style.font.heading
                            font.bold: true

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.app.openItem(root.info.about.artist)
                            }
                        }

                        Text {
                            visible: text !== ""
                            width: parent.width - 32
                            wrapMode: Text.WordWrap
                            maximumLineCount: 5
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                            text: root.info.about ? root.info.about.bio : ""
                            color: root.app.dim
                            font.family: Style.font.family
                            font.pixelSize: Style.font.bodySmall
                            lineHeight: 1.2
                        }

                        Text {
                            visible: root.info.about !== null && root.info.about.url !== ""
                            text: "Read more on Wikipedia"
                            color: root.app.fg
                            font.family: Style.font.family
                            font.pixelSize: Style.font.bodySmall
                            font.bold: true
                            font.underline: wikiMouse.containsMouse

                            MouseArea {
                                id: wikiMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: Qt.openUrlExternally(root.info.about.url)
                            }
                        }
                    }
                }
            }

            // Next in queue
            Rectangle {
                visible: root.upcoming.length > 0 && root.upcoming[0].item
                width: parent.width
                height: 124
                radius: 8
                color: Qt.rgba(root.app.fg.r, root.app.fg.g, root.app.fg.b, 0.07)

                Text {
                    x: 16
                    y: 14
                    text: "Next in queue"
                    color: root.app.fg
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                }

                Text {
                    anchors.right: parent.right
                    anchors.rightMargin: 16
                    y: 14
                    text: "Open queue"
                    color: root.app.dim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.app.rightPanel = "queue"
                    }
                }

                Row {
                    id: nextRow
                    x: 16
                    y: 52
                    width: parent.width - 32
                    spacing: 12
                    readonly property var entity: root.upcoming.length > 0 ? root.upcoming[0].item : null

                    Cover {
                        width: 56
                        height: 56
                        source: root.player.cover(nextRow.entity, "small")
                        foreground: root.app.fg
                    }

                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 68
                        spacing: 2

                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                            text: root.player.name(nextRow.entity)
                            color: root.app.fg
                            font.family: Style.font.family
                            font.pixelSize: Style.font.body
                        }

                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                            text: root.player.creators(nextRow.entity)
                            color: root.app.dim
                            font.family: Style.font.family
                            font.pixelSize: Style.font.bodySmall
                        }
                    }
                }
            }
        }
    }
}
