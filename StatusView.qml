import QtQuick
import Quickshell
import qs.Commons
import qs.Ui as Ui

// Empty state shown while Soloist can't play yet: not installed, service
// stopped, connecting, or waiting for a Spotify Connect login.
Column {
    id: root

    required property QtObject bar
    required property var controller
    property color foreground: Color.foreground
    property string glyph: ""
    property string installUrl: ""

    readonly property string mode: !controller.binaryInstalled || controller.serviceState === "missing" ? "install"
        : controller.starting || controller.serviceState === "starting" ? "starting"
        : controller.serviceState === "failed" ? "failed"
        : controller.serviceState === "stopped" ? "stopped"
        : !controller.connected ? "connecting"
        : "pair"
    readonly property color dim: Qt.darker(foreground, 1.45)

    readonly property var copy: ({
        install: {
            title: "Set up Soloist",
            body: "Soloist is Spotify's official headless player. Install it as a user service to play music "
                + "here without the desktop app.",
            action: "Installation guide", icon: "󰏌"
        },
        stopped: {
            title: "Soloist is stopped",
            body: "The " + controller.serviceName + " user service is installed but not running.",
            action: "Start Soloist", icon: "󰐊"
        },
        failed: {
            title: "Soloist failed to start",
            body: "Check the logs with journalctl --user -u " + controller.serviceName + ", then try again.",
            action: "Try again", icon: "󰑐"
        },
        starting: {
            title: "Starting Soloist…",
            body: "Waiting for the player to come online.",
            action: "", icon: ""
        },
        connecting: {
            title: "Connecting…",
            body: "The service is running. Waiting for its control socket.",
            action: "", icon: ""
        },
        pair: {
            title: "Connect from Spotify",
            body: "Open Spotify on your phone or the web player, tap the devices icon and pick “"
                + (controller.deviceName || "this device") + "”. You only need to do this once.",
            action: "Open web player", icon: "󰖟"
        }
    })
    readonly property var current: copy[mode]

    function act() {
        if (mode === "install") Qt.openUrlExternally(installUrl);
        else if (mode === "stopped" || mode === "failed") controller.startService();
        else if (mode === "pair") Qt.openUrlExternally("https://open.spotify.com");
    }

    spacing: Style.space(14)
    topPadding: Style.space(8)
    bottomPadding: Style.space(4)

    Ui.BorderSurface {
        anchors.horizontalCenter: parent.horizontalCenter
        width: Style.space(64)
        height: width
        radius: width / 2
        color: Style.normalFillFor(root.foreground, Color.accent)
        borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

        Text {
            anchors.centerIn: parent
            text: root.glyph
            color: root.mode === "pair" || root.mode === "starting" || root.mode === "connecting"
                ? Color.accent : root.dim
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.displayLarge

            SequentialAnimation on opacity {
                running: root.visible && (root.mode === "starting" || root.mode === "connecting")
                loops: Animation.Infinite
                onRunningChanged: if (!running) parent.opacity = 1
                NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
            }
        }
    }

    Column {
        width: parent.width
        spacing: Style.space(6)

        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: root.current.title
            color: root.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
        }

        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            lineHeight: 1.15
            textFormat: Text.PlainText
            text: root.current.body
            color: root.dim
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
        }
    }

    Ui.Button {
        visible: root.current.action !== ""
        anchors.horizontalCenter: parent.horizontalCenter
        bordered: true
        iconText: root.current.icon
        text: root.current.action
        foreground: root.foreground
        horizontalPadding: Style.spacing.panelGap
        onClicked: root.act()
    }
}
