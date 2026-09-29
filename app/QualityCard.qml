import QtQuick
import qs.Commons

// Contents of Spotify's "File quality" card: the playing file's tier, its
// data rate, and the signal path to the output device. Used by the app
// window's popover and the bar popup's Sound quality view.
//
// `app` needs service, fg, dim and accent. Fetches the signal path while
// `active`.
Column {
    id: root

    required property var app
    property bool active: false
    property real innerWidth: 324
    readonly property var quality: app.service.quality

    signal settingsRequested()

    // Soloist's PipeWire stream and output device (bin/spotify.py audio-path),
    // refreshed while the card is open.
    property var path: null
    function loadPath() {
        app.service.api.call(["audio-path", app.service.soloist.resolvedDataDir], function(result) {
            root.path = result.ok && result.found ? result : null;
        });
    }
    onActiveChanged: if (active) loadPath()

    Timer {
        interval: 3000
        repeat: true
        running: root.active
        onTriggered: root.loadPath()
    }

    function khz(rate) { return rate ? (rate / 1000).toLocaleString(Qt.locale("en_US"), "f", rate % 1000 ? 1 : 0) + " kHz" : ""; }
    function kbps(n) { return Number(n).toLocaleString(Qt.locale("en_US"), "f", 0) + " kbit/s"; }

    readonly property var stream: path ? path.stream : null
    readonly property var output: path && path.output ? path.output : null
    // Plain-language notes on what the path does to the sound.
    readonly property var notes: {
        var list = [];
        if (output && output.bluetooth && output.codec)
            list.push("Bluetooth re-encodes the audio to " + output.codec + ", a lossy codec"
                      + (quality && quality.lossless ? ", so the lossless detail doesn't reach your headphones." : "."));
        if (stream && output && output.rate && stream.rate && output.rate !== stream.rate)
            list.push("PipeWire resamples " + khz(stream.rate) + " to " + khz(output.rate) + " for this device.");
        return list;
    }


    padding: 18
    spacing: 6


    Text {
        text: "File quality"
        color: root.app.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
    }

    Text {
        text: root.quality ? root.quality.label : "Unknown"
        color: root.quality && root.quality.lossless ? root.app.accent : root.app.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.display
        font.bold: true
    }

    Text {
        visible: root.quality !== null
        text: root.quality ? root.quality.perHour : ""
        color: root.quality && root.quality.lossless ? root.app.accent : root.app.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
    }

    Text {
        visible: root.quality !== null
        text: root.quality ? root.quality.format : ""
        color: root.quality && root.quality.lossless ? root.app.accent : root.app.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
    }

    Text {
        width: root.innerWidth
        topPadding: 6
        wrapMode: Text.WordWrap
        text: root.quality
            ? "This song averages about " + Number(root.quality.kbps).toLocaleString(Qt.locale("en_US"), "f", 0)
              + " kbit/s (estimated from Soloist's download)."
            : "Soloist doesn't report the stream format; it's estimated once the song has started."
        color: root.app.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
    }

    Rectangle {
        width: root.innerWidth
        height: 1
        color: Qt.rgba(root.app.fg.r, root.app.fg.g, root.app.fg.b, 0.1)
    }

    // Signal path: source file → Soloist's output → device.
    Text {
        visible: root.stream !== null
        topPadding: 4
        text: "Signal path"
        color: root.app.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
    }

    Repeater {
        model: {
            var rows = [];
            if (root.quality)
                rows.push({ icon: "󰈣", title: "Source", detail: root.quality.label + " • about " + root.kbps(root.quality.kbps) });
            if (root.stream)
                rows.push({ icon: "󰕾", title: "Soloist output",
                            detail: [root.khz(root.stream.rate), root.stream.format,
                                     root.stream.channels === 2 ? "stereo" : root.stream.channels + " ch"].join(" • ")
                                    + " (" + root.kbps(root.stream.pcmKbps) + " PCM)" });
            if (root.output)
                rows.push({ icon: root.output.bluetooth ? "󰂯" : "󰓃", title: root.output.name,
                            detail: [root.output.bluetooth ? "Bluetooth " + root.output.codec : root.output.kind,
                                     root.khz(root.output.rate), root.output.format].filter(function(x) { return x; }).join(" • ") });
            return rows;
        }

        Row {
            id: pathRow
            required property var modelData
            spacing: 10

            Text {
                width: 18
                text: pathRow.modelData.icon
                color: root.app.dim
                font.family: Style.font.family
                font.pixelSize: 15
            }

            Column {
                width: root.innerWidth - 28

                Text {
                    width: parent.width
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: pathRow.modelData.title
                    color: root.app.fg
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                }

                Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    textFormat: Text.PlainText
                    text: pathRow.modelData.detail
                    color: root.app.dim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                }
            }
        }
    }

    Repeater {
        model: root.notes

        Text {
            required property string modelData
            width: root.innerWidth
            wrapMode: Text.WordWrap
            text: "󰀦  " + modelData
            color: root.app.fg
            opacity: 0.85
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
        }
    }

    Rectangle {
        visible: root.stream !== null
        width: root.innerWidth
        height: 1
        color: Qt.rgba(root.app.fg.r, root.app.fg.g, root.app.fg.b, 0.1)
    }

    Item {
        width: root.innerWidth
        height: 36

        Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 10

            Text {
                text: "󰒓"
                color: settingsMouse.containsMouse ? root.app.fg : root.app.dim
                font.family: Style.font.family
                font.pixelSize: 16
            }

            Text {
                text: "Change quality settings"
                color: root.app.fg
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.underline: settingsMouse.containsMouse
            }
        }

        MouseArea {
            id: settingsMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.settingsRequested()
        }
    }
}
