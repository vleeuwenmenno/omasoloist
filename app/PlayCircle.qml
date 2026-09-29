import QtQuick
import qs.Commons

// Spotify's round accent play button.
Rectangle {
    id: root

    property bool playing: false
    property color accent: Color.accent
    property color glyphColor: Color.background
    signal clicked()

    width: 48
    height: width
    radius: width / 2
    color: mouse.pressed ? Qt.darker(accent, 1.15) : accent
    scale: mouse.containsMouse ? 1.05 : 1

    Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

    Text {
        anchors.centerIn: parent
        // The play triangle reads off-centre; nudge it right like Spotify.
        anchors.horizontalCenterOffset: root.playing ? 0 : Math.round(root.width * 0.04)
        text: root.playing ? "󰏤" : "󰐊"
        color: root.glyphColor
        font.family: Style.font.family
        font.pixelSize: Math.round(root.width * 0.5)
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
