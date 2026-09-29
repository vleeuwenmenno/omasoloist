pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Ui as Ui

// Track list of one playlist or Liked Songs. Clicking a track plays the
// collection starting from that track, like the Spotify client.
Item {
    id: root

    required property QtObject bar
    required property var api
    required property var controller
    property var collection: null
    property color foreground: Color.foreground
    property string glyph: ""

    signal back()

    readonly property color dim: Qt.darker(foreground, 1.45)
    readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
    readonly property bool isLiked: collectionModel.isLiked

    CollectionModel {
        id: collectionModel
        api: root.api
        collection: root.collection
    }
    readonly property alias tracks: collectionModel.tracks
    readonly property alias total: collectionModel.total
    readonly property alias loading: collectionModel.loading
    readonly property alias error: collectionModel.error
    readonly property alias pendingUri: collectionModel.pendingUri

    function load(reset) { collectionModel.load(reset); }
    function playFrom(track, index) { collectionModel.playFrom(root.controller, track, index); }

    function formatTime(ms) {
        var total = Math.floor((ms || 0) / 1000);
        var seconds = total % 60;
        return Math.floor(total / 60) + ":" + (seconds < 10 ? "0" : "") + seconds;
    }


    // Header: back, cover, title, play
    Item {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        height: Style.space(64)

        Ui.Button {
            id: backButton
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰁍"
            foreground: root.foreground
            tooltipText: "Back to library"
            onClicked: root.back()
        }

        Rectangle {
            id: headerArt
            anchors.left: backButton.right
            anchors.leftMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(56)
            height: width
            radius: Style.space(4)
            clip: true
            gradient: root.isLiked ? likedGradient : null
            color: Style.normalFillFor(root.foreground, Color.accent)

            Gradient {
                id: likedGradient
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: "#450af5" }
                GradientStop { position: 1; color: "#8e8ee5" }
            }

            Image {
                anchors.fill: parent
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                source: root.collection && root.collection.cover ? root.collection.cover : ""
                visible: status === Image.Ready
            }

            Text {
                anchors.centerIn: parent
                visible: root.isLiked
                text: "󰋑"
                color: "white"
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
            }
        }

        Ui.Button {
            id: playAll
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            bordered: true
            iconText: "󰐊"
            iconSize: Style.font.iconLarge
            foreground: Color.accent
            tooltipText: "Play"
            enabled: root.collection !== null
            onClicked: root.controller.play(root.collection.uri)
        }

        Column {
            anchors.left: headerArt.right
            anchors.leftMargin: Style.space(10)
            anchors.right: playAll.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: root.collection ? root.collection.name : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
            }

            Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: root.total > 0 ? root.total + " songs" : (root.loading ? "Loading…" : "")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
            }
        }
    }

    Ui.PanelSeparator {
        id: separator
        anchors.top: header.bottom
        anchors.topMargin: Style.space(8)
        anchors.left: parent.left
        anchors.right: parent.right
        foreground: root.foreground
    }

    ListView {
        id: list
        anchors.top: separator.bottom
        anchors.topMargin: Style.space(4)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        spacing: Style.space(2)
        boundsBehavior: Flickable.StopAtBounds
        model: root.tracks

        onAtYEndChanged: if (atYEnd && contentHeight > height) root.load(false)

        Controls.ScrollBar.vertical: Controls.ScrollBar {
            policy: list.contentHeight > list.height ? Controls.ScrollBar.AsNeeded : Controls.ScrollBar.AlwaysOff
        }

        delegate: Rectangle {
            id: row
            required property var modelData
            required property int index
            readonly property bool current: root.controller.item && root.controller.item.uri === modelData.uri
            readonly property bool pending: root.pendingUri === modelData.uri

            width: list.width
            height: Style.space(52)
            radius: Style.spacing.labelGap
            opacity: modelData.playable ? 1 : 0.4
            color: hover.hovered ? Style.normalFillFor(root.foreground, Color.accent) : "transparent"

            HoverHandler { id: hover; cursorShape: row.modelData.playable ? Qt.PointingHandCursor : Qt.ArrowCursor }
            TapHandler {
                enabled: row.modelData.playable
                onTapped: root.playFrom(row.modelData, row.index)
            }

            Rectangle {
                id: art
                anchors.left: parent.left
                anchors.leftMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(40)
                height: width
                radius: Style.space(3)
                clip: true
                color: Style.normalFillFor(root.foreground, Color.accent)

                Image {
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    sourceSize.width: 128
                    sourceSize.height: 128
                    source: row.modelData.cover || ""
                    visible: status === Image.Ready
                }

                Rectangle {
                    anchors.fill: parent
                    visible: row.current || row.pending || hover.hovered
                    color: Qt.rgba(0, 0, 0, 0.45)

                    Text {
                        anchors.centerIn: parent
                        text: row.pending ? "󰔟" : !row.current ? "󰐊"
                            : root.controller.playing ? "󰝚" : "󰏤"
                        color: Color.accent
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                    }
                }
            }

            Text {
                id: duration
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.formatTime(row.modelData.duration_ms)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
            }

            Column {
                anchors.left: art.right
                anchors.leftMargin: Style.space(10)
                anchors.right: duration.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                    width: parent.width
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: row.modelData.name
                    color: row.current ? Color.accent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: row.current
                }

                Text {
                    width: parent.width
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: row.modelData.artists
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                }
            }
        }

        // Wrapped in an Item: sizing a Text footer by its own visibility loops.
        footer: Item {
            width: list.width
            height: footerNote.visible ? footerNote.implicitHeight : 0

            Text {
                id: footerNote
                width: parent.width
                visible: root.loading || root.error !== ""
                horizontalAlignment: Text.AlignHCenter
                topPadding: Style.space(10)
                bottomPadding: Style.space(10)
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: root.error !== "" ? root.error : "Loading…"
                color: root.error !== "" ? Color.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
            }
        }
    }
}
