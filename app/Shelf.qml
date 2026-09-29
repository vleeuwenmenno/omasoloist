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

    Text {
        leftPadding: 12
        bottomPadding: 4
        textFormat: Text.PlainText
        text: root.title
        color: root.app.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.display
        font.bold: true
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
