pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import qs.Commons

// A shelf's "Show all": every card of it as a grid.
Flickable {
    id: root

    required property var app
    // { title, subtitle, items } from Shelf.
    property var shelf: null

    readonly property var items: shelf ? shelf.items || [] : []
    readonly property int columns: Math.max(2, Math.floor(content.width / 168))

    onShelfChanged: contentY = 0

    clip: true
    contentHeight: content.implicitHeight + 48
    boundsBehavior: Flickable.StopAtBounds
    Controls.ScrollBar.vertical: Controls.ScrollBar {}

    Column {
        id: content
        x: 20
        y: 20
        width: root.width - 40
        spacing: 4

        Text {
            visible: text !== ""
            leftPadding: 12
            text: root.shelf ? root.shelf.subtitle || "" : ""
            color: root.app.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
        }

        Text {
            leftPadding: 12
            bottomPadding: 12
            width: parent.width
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: root.shelf ? root.shelf.title : ""
            color: root.app.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.display
            font.bold: true
        }

        Grid {
            columns: root.columns

            Repeater {
                model: root.items

                Card {
                    required property var modelData
                    width: content.width / root.columns
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
}
