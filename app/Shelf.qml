pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons

// A titled row of cards that shows as many items as fit the width, like
// Spotify's home shelves.
Column {
    id: root

    required property var app
    property string title: ""
    property string subtitle: ""
    // Small line under the title, e.g. "Only visible to you".
    property string caption: ""
    property var items: []

    // Spotify keeps cards around 160-200 px and fits as many as possible.
    readonly property int minCardWidth: 168
    readonly property int columns: Math.max(2, Math.floor(width / minCardWidth))
    readonly property real cellWidth: width / columns

    visible: items.length > 0
    spacing: 4

    Text {
        visible: root.subtitle !== ""
        leftPadding: 12
        text: root.subtitle
        color: root.app.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
    }

    Item {
        width: root.width
        height: titleText.implicitHeight

        Text {
            id: titleText
            anchors.left: parent.left
            anchors.right: showAll.visible ? showAll.left : parent.right
            anchors.rightMargin: 12
            leftPadding: 12
            bottomPadding: 4
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: root.title
            color: root.app.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.display
            font.bold: true
        }

        // Only when some cards don't fit, like Spotify.
        Text {
            id: showAll
            visible: root.items.length > root.columns
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: titleText.verticalCenter
            text: "Show all"
            color: showAllMouse.containsMouse ? root.app.fg : root.app.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            font.underline: showAllMouse.containsMouse

            MouseArea {
                id: showAllMouse
                anchors.fill: parent
                anchors.margins: -6
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.app.navigate({ kind: "shelf", item: { title: root.title, subtitle: root.subtitle, items: root.items } })
            }
        }
    }

    Text {
        visible: root.caption !== ""
        leftPadding: 12
        bottomPadding: 8
        text: root.caption
        color: root.app.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
    }

    Row {
        Repeater {
            model: root.items.slice(0, root.columns)

            Card {
                required property var modelData
                width: root.cellWidth
                item: modelData
                foreground: root.app.fg
                accent: root.app.accent
                playingThis: root.app.isPlayingUri(root.app.resolveUri(modelData))
                playing: root.app.service.player.playing
                onOpened: root.app.openItem(modelData)
                onPlayed: root.app.playItem(modelData)
                onMenuRequested: function(source, x, y) { root.app.showMenu(modelData, source, x, y); }
            }
        }
    }
}
