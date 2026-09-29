import QtQuick
import qs.Commons

// Short confirmation above the player bar ("Added to queue").
Rectangle {
    id: root

    required property var app

    function show(text) {
        label.text = text;
        opacity = 1;
        hide.restart();
    }

    width: label.implicitWidth + 32
    height: 40
    radius: 6
    color: root.app.fg
    opacity: 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: 180 } }

    Timer {
        id: hide
        interval: 2600
        onTriggered: root.opacity = 0
    }

    Text {
        id: label
        anchors.centerIn: parent
        color: root.app.bg
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
    }
}
