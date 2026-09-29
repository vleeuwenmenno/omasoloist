pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import qs.Commons

// Full-page lyrics on a tinted background. Synced lyrics highlight the
// current line and follow playback; clicking a line seeks to it.
Rectangle {
    id: root

    required property var app
    required property var info

    readonly property var player: app.service.player
    readonly property color tint: Qt.darker(app.accent, 1.8)
    // Stop auto-scrolling for a few seconds after the user scrolls.
    property bool userScrolled: false

    color: tint

    Timer {
        id: resumeFollow
        interval: 4000
        onTriggered: root.userScrolled = false
    }

    function follow() {
        if (userScrolled || !visible || !info.hasSynced || info.currentLine < 0) return;
        var item = list.itemAtIndex(info.currentLine);
        if (!item) { list.positionViewAtIndex(info.currentLine, ListView.Center); return; }
        var target = Math.max(0, Math.min(list.contentHeight - list.height, item.y - list.height * 0.35));
        scrollAnim.to = target;
        scrollAnim.restart();
    }

    Connections {
        target: root.info
        function onCurrentLineChanged() { root.follow(); }
    }
    onVisibleChanged: if (visible) Qt.callLater(follow)

    ListView {
        id: list
        anchors.fill: parent
        anchors.leftMargin: 48
        anchors.rightMargin: 48
        clip: true
        spacing: 14
        boundsBehavior: Flickable.StopAtBounds
        model: root.info.hasSynced ? root.info.synced : root.info.plainLines
        header: Item { width: 1; height: 48 }
        footer: Column {
            width: list.width
            topPadding: 48
            bottomPadding: 64
            spacing: 4

            Text {
                visible: root.info.lyrics !== null && root.info.lyrics.found
                text: "Lyrics provided by LRCLIB"
                color: Qt.rgba(1, 1, 1, 0.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
            }
        }
        onMovementStarted: { root.userScrolled = true; resumeFollow.restart(); }
        Controls.ScrollBar.vertical: Controls.ScrollBar {}

        NumberAnimation on contentY {
            id: scrollAnim
            running: false
            duration: 450
            easing.type: Easing.OutCubic
        }

        delegate: Text {
            id: line
            required property var modelData
            required property int index
            readonly property bool synced: root.info.hasSynced
            readonly property string lineText: synced ? (modelData.text || "♪") : String(modelData)
            readonly property bool past: synced && index < root.info.currentLine
            readonly property bool current: synced && index === root.info.currentLine

            width: list.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: lineText
            color: !synced ? "white" : current ? "white" : past ? Qt.rgba(1, 1, 1, 0.75) : Qt.rgba(0, 0, 0, 0.55)
            font.family: Style.font.family
            font.pixelSize: 32
            font.bold: true
            Behavior on color { ColorAnimation { duration: 200 } }

            MouseArea {
                anchors.fill: parent
                enabled: line.synced
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    root.userScrolled = false;
                    root.player.seek(line.modelData.t);
                }
            }
        }
    }

    Text {
        anchors.centerIn: parent
        visible: root.info.lyrics === null || !root.info.lyrics.found || root.info.lyrics.instrumental
        width: parent.width - 96
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        text: !root.player.hasItem ? "Play something to see its lyrics."
            : root.info.lyricsLoading || root.info.lyrics === null ? "Loading lyrics…"
            : root.info.lyrics.instrumental ? "♪ Instrumental ♪"
            : root.info.lyrics.error ? "Couldn't load lyrics: " + root.info.lyrics.error
            : "Lyrics aren't available for this song yet."
        color: "white"
        font.family: Style.font.family
        font.pixelSize: Style.font.display
        font.bold: true
    }
}
