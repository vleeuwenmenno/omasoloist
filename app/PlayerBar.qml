import QtQuick
import qs.Commons
import qs.Ui as Ui

// Spotify's bottom bar: now playing on the left, transport and progress in
// the middle, queue / devices / volume on the right.
Item {
    id: root

    required property var app
    readonly property var player: app.service.player

    function formatTime(ms) {
        var total = Math.max(0, Math.floor((ms || 0) / 1000));
        var seconds = total % 60;
        return Math.floor(total / 60) + ":" + (seconds < 10 ? "0" : "") + seconds;
    }

    implicitHeight: 88

    component IconButton: Text {
        id: icon
        property bool active: false
        property bool dot: false
        signal clicked()
        width: 32
        height: 32
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        color: !enabled ? Qt.rgba(root.app.fg.r, root.app.fg.g, root.app.fg.b, 0.3)
            : active ? root.app.accent : iconMouse.containsMouse ? root.app.fg : root.app.dim
        font.family: Style.font.family
        font.pixelSize: 18

        Rectangle {
            visible: icon.dot
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            width: 4
            height: 4
            radius: 2
            color: root.app.accent
        }

        MouseArea {
            id: iconMouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: icon.enabled
            cursorShape: Qt.PointingHandCursor
            onClicked: icon.clicked()
        }
    }

    // Now playing
    Row {
        id: nowPlaying
        anchors.left: parent.left
        anchors.leftMargin: 16
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(360, parent.width * 0.3)
        spacing: 12

        Cover {
            width: 56
            height: 56
            source: root.player.coverUrl
            foreground: root.app.fg
            visible: root.player.hasItem
        }

        Column {
            anchors.verticalCenter: parent.verticalCenter
            // Room for the cover (56 + spacing) and the heart button.
            width: parent.width - 68 - 44
            spacing: 2

            Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: root.player.title
                color: root.app.fg
                font.family: Style.font.family
                font.pixelSize: Style.font.body

                font.underline: titleMouse.containsMouse && root.app.service.albumUri() !== ""

                // Title opens the album (scrolled to this song), like Spotify.
                MouseArea {
                    id: titleMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: root.app.service.albumUri() !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: root.app.openPlayingAlbum()
                }
            }

            Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: root.player.artist
                color: artistMouse.containsMouse ? root.app.fg : root.app.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.underline: artistMouse.containsMouse && root.app.service.artistUri() !== ""

                MouseArea {
                    id: artistMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: root.app.service.artistUri() !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: root.app.openPlayingArtist()
                }
            }
        }

        IconButton {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.player.hasItem && root.app.service.api.signedIn
                && root.player.item.uri.indexOf("spotify:track:") === 0
            text: root.app.service.likes.currentLiked ? "󰋑" : "󰋕"
            active: root.app.service.likes.currentLiked
            onClicked: root.app.service.likes.toggle(root.player.item.uri)
        }
    }

    // Transport + progress
    Column {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(720, parent.width * 0.4)
        spacing: 6

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 16

            IconButton {
                text: "󰒝"
                active: root.player.shuffle || root.player.smartShuffle
                dot: active
                enabled: root.app.service.ready
                // Smart Shuffle can't be switched from here; plain shuffle can.
                onClicked: root.player.setShuffle(!root.player.shuffle)

                Text {
                    visible: root.player.smartShuffle
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.topMargin: 2
                    text: "✦"
                    color: root.app.accent
                    font.pixelSize: 9
                }
            }
            IconButton {
                text: "󰒮"
                enabled: root.app.service.ready
                onClicked: root.player.previous()
            }

            Rectangle {
                width: 32
                height: 32
                radius: 16
                color: playMouse.containsMouse ? Qt.lighter(root.app.fg, 1.1) : root.app.fg
                scale: playMouse.containsMouse ? 1.06 : 1
                opacity: root.app.service.ready ? 1 : 0.4

                Text {
                    anchors.centerIn: parent
                    anchors.horizontalCenterOffset: root.player.playing ? 0 : 1
                    text: root.player.playing ? "󰏤" : "󰐊"
                    color: root.app.bg
                    font.family: Style.font.family
                    font.pixelSize: 18
                }

                MouseArea {
                    id: playMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: root.app.service.ready
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.player.togglePlay()
                }
            }

            IconButton {
                text: "󰒭"
                enabled: root.app.service.ready && root.player.can("skip_next")
                onClicked: root.player.next()
            }
            IconButton {
                text: root.player.repeat === "track" ? "󰑘" : "󰑖"
                active: root.player.repeat !== "off"
                dot: root.player.repeat !== "off"
                enabled: root.app.service.ready
                onClicked: root.player.cycleRepeat()
            }
        }

        Row {
            width: parent.width
            spacing: 8

            Text {
                id: elapsed
                width: 40
                horizontalAlignment: Text.AlignRight
                anchors.verticalCenter: parent.verticalCenter
                text: root.formatTime(root.player.estimatedPositionMs)
                color: root.app.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
            }

            Ui.PanelSlider {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 96
                bar: null
                minimum: 0
                maximum: Math.max(1, root.player.durationMs)
                step: 1000
                value: root.player.estimatedPositionMs
                enabled: root.player.durationMs > 0 && root.player.can("seek")
                fillColor: root.app.fg
                knobColor: root.app.fg
                onReleased: function(v) { root.player.seek(v); }
            }

            Text {
                width: 40
                anchors.verticalCenter: parent.verticalCenter
                text: root.formatTime(root.player.durationMs)
                color: root.app.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
            }
        }
    }

    // Right side
    Row {
        anchors.right: parent.right
        anchors.rightMargin: 16
        anchors.verticalCenter: parent.verticalCenter
        spacing: 8

        // "Now playing view": drawn, a panel with its right column filled.
        Item {
            id: nowPlayingButton
            readonly property bool active: root.app.rightPanel === "nowplaying"
            readonly property color tone: active ? root.app.accent : npMouse.containsMouse ? root.app.fg : root.app.dim
            width: 32
            height: 32

            Rectangle {
                anchors.centerIn: parent
                width: 18
                height: 16
                radius: 3
                color: "transparent"
                border.width: 2
                border.color: nowPlayingButton.tone

                Rectangle {
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: 7
                    radius: 2
                    color: nowPlayingButton.tone
                }
            }

            Rectangle {
                visible: nowPlayingButton.active
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                width: 4
                height: 4
                radius: 2
                color: root.app.accent
            }

            MouseArea {
                id: npMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.app.toggleRightPanel("nowplaying")
            }
        }

        IconButton {
            text: "󰍬"
            active: root.app.page.kind === "lyrics"
            dot: active
            // Hidden when LRCLIB has nothing for this song, like Spotify.
            visible: root.app.info.lyricsAvailable || active
            onClicked: root.app.toggleLyrics()
        }

        IconButton {
            text: "󰲸"
            active: root.app.rightPanel === "queue"
            dot: active
            onClicked: root.app.toggleRightPanel("queue")
        }
        IconButton {
            text: "󰓃"
            active: root.app.rightPanel === "devices" || root.app.service.remoteActive
            dot: root.app.rightPanel === "devices"
            onClicked: root.app.toggleRightPanel("devices")
        }
        IconButton {
            anchors.verticalCenter: parent.verticalCenter
            text: root.player.volume === 0 ? "󰝟" : root.player.volume < 50 ? "󰖀" : "󰕾"
            enabled: !root.app.service.remoteActive || root.app.service.remote.supportsVolume
            onClicked: root.player.setVolume(root.player.volume === 0 ? 50 : 0)
        }
        Ui.PanelSlider {
            anchors.verticalCenter: parent.verticalCenter
            width: 110
            bar: null
            minimum: 0
            maximum: 100
            step: 1
            integer: true
            value: root.player.volume
            enabled: !root.app.service.remoteActive || root.app.service.remote.supportsVolume
            opacity: enabled ? 1 : 0.4
            fillColor: root.app.fg
            knobColor: root.app.fg
            onReleased: function(v) { root.player.setVolume(v); }
        }
    }
}
