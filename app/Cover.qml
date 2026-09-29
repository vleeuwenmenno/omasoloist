import QtQuick
import QtQuick.Effects
import qs.Commons

// Square artwork with Spotify's fallbacks: the purple Liked Songs tile, a
// round crop for artists, and a glyph when there is no image.
Rectangle {
    id: root

    property string source: ""
    property string kind: ""
    property string fallbackGlyph: "󰝚"
    property color foreground: Color.foreground

    readonly property bool liked: kind === "liked"
    radius: kind === "artist" ? width / 2 : Math.max(2, Math.round(width * 0.04))
    clip: true

    // `clip` only cuts a rectangle; mask the image to the rounded shape so
    // artist photos and avatars are really round.
    layer.enabled: radius > 0
    layer.smooth: true
    layer.effect: MultiEffect {
        maskEnabled: true
        maskSource: coverMask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
    }

    Item {
        id: coverMask
        width: root.width
        height: root.height
        visible: false
        layer.enabled: true
        layer.smooth: true

        Rectangle {
            anchors.fill: parent
            radius: root.radius
            color: "black"
        }
    }
    color: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.08)
    gradient: liked ? likedGradient : null

    Gradient {
        id: likedGradient
        orientation: Gradient.Horizontal
        GradientStop { position: 0; color: "#450af5" }
        GradientStop { position: 1; color: "#8e8ee5" }
    }

    // Decode at a fixed bucket so resizing or animating the cover doesn't
    // re-request the image (Spotify's CDN throttles repeated fetches).
    readonly property int decodeSize: width <= 48 ? 128 : width <= 160 ? 320 : 640

    Image {
        id: image
        anchors.fill: parent
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        sourceSize: Qt.size(root.decodeSize, root.decodeSize)
        source: root.source
        visible: status === Image.Ready
    }

    Text {
        anchors.centerIn: parent
        visible: image.status !== Image.Ready
        text: root.liked ? "󰋑" : root.kind === "artist" ? "󰀄" : root.fallbackGlyph
        color: root.liked ? "white" : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.5)
        font.family: Style.font.family
        font.pixelSize: Math.max(12, root.width * 0.36)
    }
}
