import QtQuick
import qs.Commons

// One row of Spotify's track table: #, title/artist with art, album, date
// added, duration. Columns collapse as the row gets narrower.
Rectangle {
    id: root

    required property var track
    required property int number
    property bool current: false
    property bool playing: false
    property bool pending: false
    property bool showAlbum: width > 640
    property bool showAdded: width > 860 && (track.added_at || "") !== ""
    // Optional pill before the duration, e.g. "Song" in mixed search results.
    property string tag: ""
    // Replaces the album column, e.g. an artist's play counts.
    property string detail: ""
    property color foreground: Color.foreground
    property color accent: Color.accent

    // Like column: filled heart when saved, outline on hover.
    property bool likeable: false
    property bool liked: false

    signal activated()
    signal likeToggled()
    signal menuRequested(var source, real x, real y)

    readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.6)
    readonly property bool hovered: hover.hovered

    function formatTime(ms) {
        var total = Math.floor((ms || 0) / 1000);
        var seconds = total % 60;
        return Math.floor(total / 60) + ":" + (seconds < 10 ? "0" : "") + seconds;
    }

    function formatDate(iso) {
        if (!iso) return "";
        var date = new Date(iso);
        var days = Math.floor((Date.now() - date.getTime()) / 86400000);
        if (days < 1) return "Today";
        if (days < 7) return days === 1 ? "1 day ago" : days + " days ago";
        if (days < 28) return Math.floor(days / 7) === 1 ? "1 week ago" : Math.floor(days / 7) + " weeks ago";
        return Qt.formatDate(date, "d MMM yyyy");
    }

    // Briefly tinted when the page scrolled here to show this track.
    property bool flash: false
    // Compact view: one line, no artwork (Spotify's "View as: Compact").
    property bool compact: false

    height: compact ? 36 : 56
    radius: 4
    opacity: track.playable === false ? 0.4 : 1
    color: flash ? Qt.rgba(accent.r, accent.g, accent.b, 0.25)
        : hover.hovered ? Qt.rgba(foreground.r, foreground.g, foreground.b, 0.08) : "transparent"
    Behavior on color { ColorAnimation { duration: 400 } }

    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    TapHandler {
        enabled: root.track.playable !== false
        onTapped: root.activated()
    }
    TapHandler {
        acceptedButtons: Qt.RightButton
        onTapped: function(point) { root.menuRequested(root, point.position.x, point.position.y); }
    }

    Item {
        id: numberCell
        anchors.left: parent.left
        anchors.leftMargin: 16
        width: 24
        height: parent.height

        Text {
            anchors.centerIn: parent
            text: root.pending ? "󰔟"
                : hover.hovered ? (root.current && root.playing ? "󰏤" : "󰐊")
                : root.current && root.playing ? "󰝚"
                : String(root.number)
            color: root.current ? root.accent : root.dim
            font.family: Style.font.family
            font.pixelSize: hover.hovered || root.current || root.pending ? Style.font.heading : Style.font.body
        }
    }

    Cover {
        id: art
        anchors.left: numberCell.right
        anchors.leftMargin: root.compact ? 0 : 16
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.compact
        width: root.compact ? 0 : 40
        height: 40
        source: root.track.cover || ""
        foreground: root.foreground
    }

    // "…" menu button, shown on hover like Spotify.
    Text {
        id: more
        anchors.right: parent.right
        anchors.rightMargin: 4
        anchors.verticalCenter: parent.verticalCenter
        width: 20
        horizontalAlignment: Text.AlignHCenter
        visible: hover.hovered
        text: "󰇘"
        color: moreMouse.containsMouse ? root.foreground : root.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.heading

        MouseArea {
            id: moreMouse
            anchors.fill: parent
            anchors.margins: -6
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.menuRequested(more, more.width / 2, more.height)
        }
    }

    Text {
        id: duration
        anchors.right: parent.right
        anchors.rightMargin: 24
        anchors.verticalCenter: parent.verticalCenter
        width: 48
        horizontalAlignment: Text.AlignRight
        // Radio tracks from public pages have no length.
        text: root.track.duration_ms ? root.formatTime(root.track.duration_ms) : ""
        color: root.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
    }

    Text {
        id: heart
        anchors.right: duration.left
        anchors.rightMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        width: root.likeable ? 24 : 0
        horizontalAlignment: Text.AlignHCenter
        visible: root.likeable && (root.liked || hover.hovered)
        text: root.liked ? "󰋑" : "󰋕"
        color: root.liked ? root.accent : heartMouse.containsMouse ? root.foreground : root.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.heading

        MouseArea {
            id: heartMouse
            anchors.fill: parent
            anchors.margins: -6
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.likeToggled()
        }
    }

    Row {
        visible: root.compact
        anchors.left: art.right
        anchors.leftMargin: 16
        anchors.right: album.left
        anchors.rightMargin: 16
        anchors.verticalCenter: parent.verticalCenter
        spacing: 12
        clip: true

        Text {
            id: compactTitle
            width: Math.min(implicitWidth, parent.width * 0.6)
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: root.track.name || ""
            color: root.current ? root.accent : root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
        }

        Text {
            width: parent.width - compactTitle.width - 12
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: root.track.artists || ""
            color: root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    Rectangle {
        id: tagPill
        visible: root.tag !== ""
        anchors.right: root.likeable ? heart.left : duration.left
        anchors.rightMargin: 24
        anchors.verticalCenter: parent.verticalCenter
        width: visible ? tagText.implicitWidth + 12 : 0
        height: tagText.implicitHeight + 4
        radius: 3
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)

        Text {
            id: tagText
            anchors.centerIn: parent
            text: root.tag
            color: root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
        }
    }

    Text {
        id: added
        visible: root.showAdded
        anchors.right: tagPill.visible ? tagPill.left : root.likeable ? heart.left : duration.left
        anchors.rightMargin: 24
        anchors.verticalCenter: parent.verticalCenter
        width: visible ? 130 : 0
        elide: Text.ElideRight
        text: root.formatDate(root.track.added_at)
        color: root.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
    }

    Text {
        id: album
        visible: root.showAlbum
        anchors.right: added.left
        anchors.rightMargin: visible ? 24 : 0
        anchors.verticalCenter: parent.verticalCenter
        width: visible ? Math.round((root.width - 180) * 0.3) : 0
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: root.detail !== "" ? root.detail : root.track.album || ""
        color: root.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
    }

    Column {
        anchors.left: art.right
        anchors.leftMargin: root.compact ? 16 : 12
        anchors.right: album.left
        anchors.rightMargin: 16
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2
        visible: !root.compact

        Text {
            width: parent.width
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: root.track.name || ""
            color: root.current ? root.accent : root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
        }

        Row {
            width: parent.width
            spacing: 6

            Rectangle {
                visible: !!root.track.explicit
                anchors.verticalCenter: parent.verticalCenter
                width: 16
                height: 16
                radius: 2
                color: root.dim

                Text {
                    anchors.centerIn: parent
                    text: "E"
                    color: Color.background
                    font.family: Style.font.family
                    font.pixelSize: 10
                    font.bold: true
                }
            }

            Text {
                width: parent.width - (root.track.explicit ? 22 : 0)
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: root.track.artists || ""
                color: root.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
            }
        }
    }
}
