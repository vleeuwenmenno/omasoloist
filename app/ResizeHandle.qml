import QtQuick

// Vertical drag handle for a sidebar edge. Emits the new width while
// dragging; double-click asks for the default back.
MouseArea {
    id: handle

    // Width of the panel being resized when the drag starts.
    property real currentWidth: 0
    // true: the panel is to the left of the handle (grows when dragging right).
    property bool panelOnLeft: true
    property color lineColor: "white"

    signal resized(real width)
    signal resetRequested()

    property real startWidth: 0
    property real startX: 0

    width: 8
    hoverEnabled: true
    cursorShape: Qt.SplitHCursor
    preventStealing: true

    onPressed: function(mouse) {
        startWidth = currentWidth;
        startX = mapToItem(null, mouse.x, 0).x;
    }
    onPositionChanged: function(mouse) {
        if (!pressed) return;
        var dx = mapToItem(null, mouse.x, 0).x - startX;
        resized(panelOnLeft ? startWidth + dx : startWidth - dx);
    }
    onDoubleClicked: resetRequested()

    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: 8
        anchors.bottomMargin: 8
        width: 2
        radius: 1
        color: handle.lineColor
        opacity: handle.pressed ? 0.5 : handle.containsMouse ? 0.25 : 0
        Behavior on opacity { NumberAnimation { duration: 120 } }
    }
}
