pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Ui as Ui

// Spotify's "Connect to a device" list. Selecting a device transfers
// playback to it; Soloist on this machine is always listed first.
Item {
    id: root

    required property QtObject bar
    required property var api
    required property var soloist
    property color foreground: Color.foreground

    // The app window embeds these views without the popup's back button.
    property bool showBack: true
    property bool active: visible

    signal back()

    readonly property color dim: Qt.darker(foreground, 1.45)
    readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

    property var devices: []
    property bool loading: false
    property string error: ""
    property string transferringId: ""
    property int revision: 0

    readonly property var current: devices.filter(function(d) { return d.active; })[0] || null
    readonly property var others: devices.filter(function(d) { return !d.active; })

    function isSoloist(device) {
        return device && (device.id === soloist.deviceId || device.name === soloist.deviceName);
    }

    function label(device) { return isSoloist(device) ? "This computer" : device.name; }

    function glyph(device) {
        if (isSoloist(device)) return "󰌢";
        switch (device.type) {
        case "Computer": return "󰍹";
        case "Smartphone": return "󰄜";
        case "Tablet": return "󰓶";
        case "TV": return "󰔂";
        case "CastVideo": return "󰐹";
        case "CastAudio": return "󰐹";
        case "Automobile": return "󰄋";
        case "GameConsole": return "󰊴";
        default: return "󰓃";
        }
    }

    function refresh() {
        if (!active || !api.signedIn || loading) return;
        loading = true;
        var requestedRevision = revision;
        api.call(["devices"], function(result) {
            if (requestedRevision !== root.revision) return;
            root.loading = false;
            if (!result.ok) { root.error = result.error; return; }
            root.error = "";
            // Soloist first, then alphabetical.
            root.devices = result.devices.sort(function(a, b) {
                if (root.isSoloist(a) !== root.isSoloist(b)) return root.isSoloist(a) ? -1 : 1;
                return a.name.localeCompare(b.name);
            });
        });
    }

    function transfer(device) {
        if (device.active || device.restricted) return;
        transferringId = device.id;
        api.call(["transfer", device.id, "play"], function(result) {
            root.transferringId = "";
            if (!result.ok) root.error = result.error;
            refreshSoon.restart();
        });
    }

    onActiveChanged: if (active) refresh()
    Component.onCompleted: if (active) refresh()

    Connections {
        target: root.api
        function onSessionReset() {
            root.revision++;
            root.devices = [];
            root.loading = false;
            root.error = "";
            root.transferringId = "";
        }
        function onSignedInChanged() { if (root.active && root.api.signedIn) root.refresh(); }
        function onCacheCleared(group) {
            if (group === "api" || group === "all") {
                root.revision++;
                root.loading = false;
                root.devices = [];
                if (root.active) root.refresh();
            }
        }
    }

    Timer {
        interval: 60000
        repeat: true
        running: root.active && root.api.signedIn
        onTriggered: root.refresh()
    }

    Timer {
        id: refreshSoon
        interval: 800
        onTriggered: root.refresh()
    }

    Item {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        height: backButton.implicitHeight

        Ui.Button {
            id: backButton
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            visible: root.showBack
            width: visible ? implicitWidth : 0
            iconText: "󰁍"
            foreground: root.foreground
            tooltipText: "Back to player"
            onClicked: root.back()
        }

        Text {
            anchors.left: backButton.right
            anchors.leftMargin: root.showBack ? Style.space(6) : Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "Connect to a device"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
        }

        Ui.Button {
            id: restartButton
            anchors.right: refreshButton.left
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰜉"
            iconSpinning: root.soloist.starting
            foreground: root.dim
            tooltipText: "Restart Soloist (playback stops for a few seconds)"
            onClicked: if (!root.soloist.starting) root.soloist.restartService()
        }

        Ui.Button {
            id: refreshButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰑐"
            iconSpinning: root.loading
            foreground: root.dim
            tooltipText: "Refresh"
            onClicked: root.refresh()
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

    Text {
        visible: !root.api.signedIn
        anchors.top: separator.bottom
        anchors.topMargin: Style.space(24)
        anchors.left: parent.left
        anchors.right: parent.right
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: "Sign in under Your Library to see your other devices."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
    }

    Flickable {
        id: flick
        visible: root.api.signedIn
        anchors.top: separator.bottom
        anchors.topMargin: Style.space(8)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        contentHeight: content.implicitHeight
        boundsBehavior: Flickable.StopAtBounds

        Controls.ScrollBar.vertical: Controls.ScrollBar {
            policy: flick.contentHeight > flick.height ? Controls.ScrollBar.AsNeeded : Controls.ScrollBar.AlwaysOff
        }

        Column {
            id: content
            width: flick.width
            spacing: Style.space(4)

            // Current device: large accent card, like Spotify's green block.
            Rectangle {
                visible: root.current !== null
                width: parent.width
                height: Style.space(64)
                radius: Style.spacing.labelGap
                color: Style.selectedFillFor(root.foreground, Color.accent)

                Text {
                    id: currentGlyph
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(14)
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.current ? root.glyph(root.current) : ""
                    color: Color.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.displayLarge
                }

                Column {
                    anchors.left: currentGlyph.right
                    anchors.leftMargin: Style.space(12)
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(12)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(2)

                    Text {
                        textFormat: Text.PlainText
                        text: "Current device"
                        color: Color.accent
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                    }

                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        text: root.current ? root.label(root.current) : ""
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        font.bold: true
                    }
                }
            }

            Text {
                visible: root.others.length > 0
                topPadding: Style.space(10)
                bottomPadding: Style.space(4)
                leftPadding: Style.space(4)
                textFormat: Text.PlainText
                text: root.current ? "Select another device" : "Select a device"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
            }

            Repeater {
                model: root.others

                Rectangle {
                    id: row
                    required property var modelData
                    readonly property bool transferring: root.transferringId === modelData.id

                    width: content.width
                    height: Style.space(48)
                    radius: Style.spacing.labelGap
                    opacity: modelData.restricted ? 0.4 : 1
                    color: hover.hovered && !modelData.restricted
                        ? Style.normalFillFor(root.foreground, Color.accent) : "transparent"

                    HoverHandler {
                        id: hover
                        cursorShape: row.modelData.restricted ? Qt.ArrowCursor : Qt.PointingHandCursor
                    }
                    TapHandler { onTapped: root.transfer(row.modelData) }

                    Text {
                        id: rowGlyph
                        anchors.left: parent.left
                        anchors.leftMargin: Style.space(12)
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(24)
                        horizontalAlignment: Text.AlignHCenter
                        text: row.transferring ? "󰔟" : root.glyph(row.modelData)
                        color: row.transferring ? Color.accent : root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.subtitle
                    }

                    Column {
                        anchors.left: rowGlyph.right
                        anchors.leftMargin: Style.space(12)
                        anchors.right: parent.right
                        anchors.rightMargin: Style.space(12)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(1)

                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                            text: root.label(row.modelData)
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                        }

                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                            text: root.isSoloist(row.modelData) ? "Soloist · " + row.modelData.name
                                : row.modelData.restricted ? "Can't be controlled from here"
                                : "Spotify Connect · " + row.modelData.type
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                        }
                    }
                }
            }

            Text {
                visible: root.error !== ""
                width: parent.width
                topPadding: Style.space(8)
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: root.error
                color: Color.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
            }

            Text {
                width: parent.width
                topPadding: Style.space(14)
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: "Don't see a device? Open Spotify on it, or make sure it's on the same network."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
            }
        }
    }
}
