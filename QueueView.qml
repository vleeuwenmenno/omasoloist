pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Ui as Ui

// Spotify-style queue: what's playing now, tracks queued by the user, then
// what comes next from the current context (and autoplay after that).
//
// Tracks can be dragged to reorder them (mouse: drag the row; touch: drag
// the grip) and removed with the × button. Neither Soloist nor the Web API
// can edit the queue, so an edited order is applied by replaying
// [current track, ...upcoming] as a track list at the current position
// (see replace-queue in bin/spotify.py). Edits are batched for a moment so
// several drags cost a single replay.
Item {
    id: root

    required property QtObject bar
    required property var controller
    required property var api
    property color foreground: Color.foreground
    property string glyph: ""

    // The app window embeds these views without the popup's back button.
    property bool showBack: true

    signal back()

    readonly property color dim: Qt.darker(foreground, 1.45)
    readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

    // Edited order waiting to be (or being) applied; null when following the
    // player's own queue.
    property var localOrder: null
    property bool applying: false
    property string error: ""
    readonly property var upcoming: localOrder || controller.queueUpcoming || []
    readonly property int upcomingCount: upcoming.length

    // Drag state. dragFrom/dropAt are indexes into `upcoming`; dropAt is an
    // insertion point (0..length).
    property int dragFrom: -1
    property int dropAt: -1
    property real dragY: 0
    property real indicatorY: -1
    readonly property bool dragging: dragFrom >= 0

    // Flat list of section headers and track rows, e.g.
    // [{header: "Now playing"}, {entity, current: true}, {header: "Next in queue"}, ...]
    readonly property var rows: {
        var list = [];
        if (controller.hasItem) {
            list.push({ header: "Now playing" });
            list.push({ entity: controller.item, current: true });
        }
        var contextLabel = controller.contextName ? "Next from: " + controller.contextName : "Next up";
        // With Smart Shuffle on, anything that isn't from the context or your
        // own queue is a recommendation.
        var labels = { queue: "Next in queue", context: contextLabel,
                       autoplay: controller.smartShuffle ? "Recommended by Smart Shuffle" : "Autoplay" };
        var lastHeader = "";
        upcoming.forEach(function(entry, index) {
            if (!entry || !entry.item) return;
            // An edited queue is one flat list once applied.
            var header = localOrder ? "Next up" : (labels[entry.source] || contextLabel);
            if (header !== lastHeader) list.push({ header: header });
            lastHeader = header;
            list.push({ entity: entry.item, current: false, upcomingIndex: index,
                        recommended: !!controller.smartShuffle && entry.source !== "context" && entry.source !== "queue" });
        });
        return list;
    }

    function formatTime(ms) {
        if (!ms) return "";
        var total = Math.floor(ms / 1000);
        var seconds = total % 60;
        return Math.floor(total / 60) + ":" + (seconds < 10 ? "0" : "") + seconds;
    }

    // ------------------------------------------------------------ editing

    function edit(order) {
        localOrder = order;
        error = "";
        applyTimer.restart();
    }

    function removeAt(index) {
        var order = upcoming.slice();
        order.splice(index, 1);
        edit(order);
    }

    function move(from, insertAt) {
        if (from < 0 || insertAt < 0 || insertAt === from || insertAt === from + 1) return;
        var order = upcoming.slice();
        var entry = order.splice(from, 1)[0];
        order.splice(insertAt > from ? insertAt - 1 : insertAt, 0, entry);
        edit(order);
    }

    // Replay the edited order. `startIndex` >= 0 jumps to that upcoming track
    // instead of continuing the current one.
    function apply(startIndex) {
        applyTimer.stop();
        if (!localOrder) return;
        var uris = localOrder.map(function(e) { return e.item ? e.item.uri : ""; })
            .filter(function(u) { return u !== ""; });
        var request;
        if (startIndex >= 0) {
            request = { uris: uris, offset: startIndex };
        } else {
            if (!controller.hasItem) return;
            request = { uris: [controller.item.uri].concat(uris), offset: 0,
                // Small lead so the replay lands where playback will be.
                position_ms: Math.round(controller.estimatedPositionMs + 300) };
        }
        applying = true;
        api.call(["replace-queue", controller.deviceName, JSON.stringify(request)], function(result) {
            root.applying = false;
            if (!result.ok) {
                root.error = result.error;
                root.localOrder = null;
                return;
            }
            // Keep showing our order until the player reports the new queue.
            releaseTimer.restart();
        });
    }

    function playAt(entry, index) {
        if (localOrder) apply(index);
        else controller.skipTo(entry.uri, index);
    }

    Timer {
        id: applyTimer
        interval: 1200
        onTriggered: root.apply(-1)
    }

    Timer {
        id: releaseTimer
        interval: 2500
        onTriggered: {
            root.localOrder = null;
            if (root.controller.refreshQueue) root.controller.refreshQueue();
        }
    }

    // ------------------------------------------------------------ dragging

    function beginDrag(index) {
        dragFrom = index;
        dropAt = index;
        applyTimer.stop();
    }

    function updateDrag(scenePoint) {
        if (!dragging) return;
        var p = list.mapFromItem(null, scenePoint.x, scenePoint.y);
        dragY = p.y;
        var contentPos = p.y + list.contentY;
        var i = list.indexAt(list.width / 2, contentPos);
        var item = i >= 0 ? list.itemAtIndex(i) : null;
        if (!item) {
            // Past either end of the list.
            var last = list.itemAtIndex(root.rows.length - 1);
            var atEnd = p.y > 0;
            dropAt = atEnd ? upcoming.length : 0;
            indicatorY = atEnd && last ? last.y + last.height - list.contentY : -1;
            return;
        }
        var row = rows[i];
        if (row.current) {
            dropAt = 0;
            indicatorY = item.y + item.height - list.contentY;
        } else if (row.header !== undefined) {
            // Dropping on a section header inserts before the next track.
            var nextIndex = i + 1;
            while (nextIndex < rows.length && rows[nextIndex].upcomingIndex === undefined) nextIndex++;
            dropAt = nextIndex < rows.length ? rows[nextIndex].upcomingIndex : upcoming.length;
            indicatorY = item.y + item.height - list.contentY;
        } else {
            var after = contentPos > item.y + item.height / 2;
            dropAt = row.upcomingIndex + (after ? 1 : 0);
            indicatorY = (after ? item.y + item.height : item.y) - list.contentY;
        }
    }

    function endDrag() {
        if (!dragging) return;
        var from = dragFrom;
        var to = dropAt;
        dragFrom = -1;
        dropAt = -1;
        indicatorY = -1;
        move(from, to);
        // A no-op drop still has to save any edit that was waiting.
        if (localOrder && !applyTimer.running && !applying) applyTimer.restart();
    }

    // Scroll while dragging near the top or bottom edge.
    Timer {
        interval: 16
        repeat: true
        running: root.dragging
        onTriggered: {
            var edge = Style.space(36);
            var step = 0;
            if (root.dragY < edge) step = -Math.ceil((edge - root.dragY) / 4);
            else if (root.dragY > list.height - edge) step = Math.ceil((root.dragY - list.height + edge) / 4);
            if (step === 0) return;
            list.contentY = Math.max(0, Math.min(list.contentHeight - list.height, list.contentY + step));
        }
    }

    // ------------------------------------------------------------ layout

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
            text: "Queue"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
        }

        Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.applying || applyTimer.running ? "Saving order…"
                : root.upcomingCount === 1 ? "1 track" : root.upcomingCount + " tracks"
            color: root.applying || applyTimer.running ? Color.accent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
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
        id: errorText
        visible: root.error !== ""
        anchors.top: separator.bottom
        anchors.topMargin: visible ? Style.space(6) : 0
        anchors.left: parent.left
        anchors.right: parent.right
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: "Couldn't reorder: " + root.error
        color: Color.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
    }

    ListView {
        id: list
        anchors.top: errorText.visible ? errorText.bottom : separator.bottom
        anchors.topMargin: Style.space(4)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        spacing: Style.space(2)
        boundsBehavior: Flickable.StopAtBounds
        interactive: !root.dragging
        model: root.rows

        Controls.ScrollBar.vertical: Controls.ScrollBar {
            policy: list.contentHeight > list.height ? Controls.ScrollBar.AsNeeded : Controls.ScrollBar.AlwaysOff
        }

        delegate: Rectangle {
            id: row
            required property var modelData
            readonly property bool isHeader: modelData.header !== undefined
            readonly property var entity: modelData.entity || null
            readonly property bool current: !!modelData.current
            readonly property bool movable: !isHeader && !current
            readonly property bool beingDragged: movable && root.dragFrom === modelData.upcomingIndex
            readonly property bool pending: movable && entity && root.controller.skipTarget === entity.uri

            width: list.width
            height: isHeader ? sectionLabel.implicitHeight : Style.space(52)
            radius: Style.spacing.labelGap
            opacity: beingDragged ? 0.3 : 1
            color: hover.hovered && !root.dragging ? Style.normalFillFor(root.foreground, Color.accent) : "transparent"

            HoverHandler {
                id: hover
                enabled: !row.isHeader
                cursorShape: row.current ? Qt.ArrowCursor
                    : root.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
            }

            TapHandler {
                enabled: row.movable
                onTapped: root.playAt(row.entity, row.modelData.upcomingIndex)
            }

            // Mouse: drag anywhere on the row. Touch keeps scrolling the list
            // and reorders through the grip instead.
            DragHandler {
                enabled: row.movable
                target: null
                xAxis.enabled: false
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                grabPermissions: PointerHandler.CanTakeOverFromAnything
                onActiveChanged: active ? root.beginDrag(row.modelData.upcomingIndex) : root.endDrag()
                onCentroidChanged: if (active) root.updateDrag(centroid.scenePosition)
            }

            Text {
                id: sectionLabel
                visible: row.isHeader
                width: parent.width
                topPadding: Style.space(12)
                bottomPadding: Style.space(6)
                leftPadding: Style.space(4)
                textFormat: Text.PlainText
                text: row.modelData.header || ""
                elide: Text.ElideRight
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
            }

            Rectangle {
                id: art
                visible: !row.isHeader
                anchors.left: parent.left
                anchors.leftMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(40)
                height: width
                radius: Style.space(3)
                color: Style.normalFillFor(root.foreground, Color.accent)
                clip: true

                Image {
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    sourceSize.width: 128
                    sourceSize.height: 128
                    source: root.controller.cover(row.entity, "small")
                    visible: status === Image.Ready
                }

                Text {
                    anchors.centerIn: parent
                    visible: root.controller.cover(row.entity, "small") === ""
                    text: root.glyph
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                }

                // Play marker on the playing track and on hover, like Spotify.
                Rectangle {
                    anchors.fill: parent
                    visible: row.current || (hover.hovered && !root.dragging) || row.pending
                    color: Qt.rgba(0, 0, 0, 0.45)

                    Text {
                        anchors.centerIn: parent
                        text: row.pending ? "󰔟" : !row.current ? "󰐊" : root.controller.playing ? "󰝚" : "󰏤"
                        color: Color.accent
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                    }
                }
            }

            // Touch reorder handle.
            Text {
                id: grip
                visible: row.movable
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(28)
                height: parent.height
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: "󰇙"
                color: hover.hovered ? root.foreground : Qt.darker(root.foreground, 2.2)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body

                DragHandler {
                    enabled: row.movable
                    target: null
                    xAxis.enabled: false
                    acceptedDevices: PointerDevice.TouchScreen
                    grabPermissions: PointerHandler.CanTakeOverFromAnything
                    onActiveChanged: active ? root.beginDrag(row.modelData.upcomingIndex) : root.endDrag()
                    onCentroidChanged: if (active) root.updateDrag(centroid.scenePosition)
                }
            }

            Text {
                id: duration
                visible: !row.isHeader
                anchors.right: row.movable ? grip.left : parent.right
                anchors.rightMargin: row.movable ? 0 : Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: row.entity && row.entity.decorations && row.entity.decorations.playback
                    ? root.formatTime(row.entity.decorations.playback.duration_ms) : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
            }

            Ui.Button {
                id: removeButton
                visible: row.movable && hover.hovered && !root.dragging
                anchors.right: duration.left
                anchors.rightMargin: Style.space(2)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅖"
                foreground: root.dim
                tooltipText: "Remove from queue"
                onClicked: root.removeAt(row.modelData.upcomingIndex)
            }

            Column {
                visible: !row.isHeader
                anchors.left: art.right
                anchors.leftMargin: Style.space(10)
                anchors.right: removeButton.visible ? removeButton.left : duration.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                    width: parent.width
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: root.controller.name(row.entity) || "Unknown track"
                    color: row.current ? Color.accent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: row.current
                }

                Text {
                    width: parent.width
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    visible: text !== ""
                    text: (row.modelData.recommended ? "✦ " : "") + root.controller.creators(row.entity)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                }
            }
        }

        Text {
            anchors.centerIn: parent
            visible: root.rows.length === 0
            textFormat: Text.PlainText
            text: "Your queue is empty"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
        }

        // Insertion line.
        Rectangle {
            visible: root.dragging && root.indicatorY >= 0
            x: Style.space(4)
            y: root.indicatorY - height / 2
            z: 10
            width: list.width - Style.space(8)
            height: Math.max(2, Style.space(2))
            radius: height / 2
            color: Color.accent
        }
    }

    // Floating copy of the dragged track.
    Rectangle {
        id: ghost
        readonly property var entry: root.dragging ? root.upcoming[root.dragFrom] : null
        visible: entry !== null && entry !== undefined
        z: 20
        x: Style.space(8)
        y: list.y + Math.max(0, Math.min(list.height, root.dragY)) - height / 2
        width: root.width - Style.space(16)
        height: Style.space(48)
        radius: Style.spacing.labelGap
        color: Style.selectedFillFor(root.foreground, Color.accent)
        border.color: Color.accent
        border.width: 1
        opacity: 0.95

        Rectangle {
            id: ghostArt
            anchors.left: parent.left
            anchors.leftMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(36)
            height: width
            radius: Style.space(3)
            clip: true
            color: Style.normalFillFor(root.foreground, Color.accent)

            Image {
                anchors.fill: parent
                fillMode: Image.PreserveAspectCrop
                source: ghost.entry ? root.controller.cover(ghost.entry.item, "small") : ""
            }
        }

        Text {
            anchors.left: ghostArt.right
            anchors.leftMargin: Style.space(10)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: ghost.entry ? root.controller.name(ghost.entry.item) : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
        }
    }
}
