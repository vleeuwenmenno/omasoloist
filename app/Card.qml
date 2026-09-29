import QtQuick
import qs.Commons

// Grid card: artwork, title, subtitle, and a play button that rises in on
// hover (Spotify's shelf item).
Rectangle {
    id: root

    required property var item
    property bool playingThis: false
    property bool playing: false
    property color foreground: Color.foreground
    property color accent: Color.accent

    signal opened()
    signal played()
    signal menuRequested(var source, real x, real y)

    implicitWidth: 180
    implicitHeight: column.implicitHeight + 24
    radius: 8
    color: hover.hovered ? Qt.rgba(foreground.r, foreground.g, foreground.b, 0.07) : "transparent"

    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: root.opened() }
    TapHandler {
        acceptedButtons: Qt.RightButton
        onTapped: function(point) { root.menuRequested(root, point.position.x, point.position.y); }
    }

    Column {
        id: column
        x: 12
        y: 12
        width: root.width - 24
        spacing: 8

        Item {
            width: parent.width
            height: width

            Cover {
                anchors.fill: parent
                source: root.item.cover || ""
                kind: root.item.kind || ""
                foreground: root.foreground
            }

            PlayCircle {
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 8
                width: 44
                accent: root.accent
                playing: root.playingThis && root.playing
                opacity: hover.hovered || root.playingThis ? 1 : 0
                anchors.bottomMargin: hover.hovered || root.playingThis ? 8 : 0
                Behavior on opacity { NumberAnimation { duration: 150 } }
                Behavior on anchors.bottomMargin { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                onClicked: root.played()
            }
        }

        Text {
            width: parent.width
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: root.item.name || ""
            color: root.playingThis ? root.accent : root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
        }

        Text {
            width: parent.width
            maximumLineCount: 2
            wrapMode: Text.WordWrap
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: root.item.subtitle !== undefined ? root.item.subtitle
                : root.item.kind === "artist" ? "Artist"
                : root.item.kind === "album" ? [root.item.year, root.item.owner].filter(function(x) { return x; }).join(" • ")
                : root.item.owner ? "By " + root.item.owner : ""
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.6)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
        }
    }
}
