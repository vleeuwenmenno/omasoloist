import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui

Ui.BarWidget {
    id: root
    moduleName: "vleeuwenmenno.omasoloist"

    property bool popupOpen: false
    property string view: "player"
    readonly property bool opened: popupOpen
    readonly property color foreground: bar ? bar.foreground : Color.foreground
    readonly property string spotifyGlyph: String.fromCodePoint(0xf1bc)
    readonly property real maxLabelWidth: setting("maxLabelWidth", 180)
    readonly property bool showTitle: setting("showTitle", true)

    function open() { popupOpen = true; }
    function close() { popupOpen = false; }
    function toggle() { popupOpen = !popupOpen; }

    // Close the popup and show `uri` in the app window; collections scroll
    // to the playing song.
    function openInApp(uri, name) {
        if (!svc || !uri) return;
        close();
        svc.openApp({ uri: uri, name: name || "", highlight: player && player.item ? player.item.uri : "" });
    }

    function formatTime(ms) {
        var total = Math.max(0, Math.floor(ms / 1000));
        var seconds = total % 60;
        return Math.floor(total / 60) + ":" + (seconds < 10 ? "0" : "") + seconds;
    }

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    // The IPC target lives on whichever bar instance registered first; route
    // popup calls to the instance on the focused monitor instead.
    function focusedInstance() {
        var items = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : [root];
        var monitor = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "";
        for (var i = 0; i < items.length; i++) {
            var win = items[i] ? items[i].QsWindow.window : null;
            if (win && win.screen && win.screen.name === monitor) return items[i];
        }
        return root;
    }

    IpcHandler {
        target: "omasoloist"
        function toggle(): void { root.focusedInstance().toggle(); }
        function open(): void { root.focusedInstance().open(); }
        function close(): void { root.broadcast("close"); }
        function playPause(): void { root.player.togglePlay(); }
        function next(): void { root.player.next(); }
        function previous(): void { root.player.previous(); }
        function likedSongs(): void { root.player.playLikedSongs(); }
    }

    // State lives in the plugin's service (Service.qml), shared across
    // monitors and with the app window.
    readonly property var svc: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null
    readonly property var soloist: svc ? svc.soloist : null
    readonly property var remote: svc ? svc.remote : null
    readonly property var spotifyApi: svc ? svc.api : null
    readonly property var player: svc ? svc.player : null
    readonly property bool remoteActive: svc ? svc.remoteActive : false
    readonly property bool ready: svc ? svc.ready : false

    property var openedCollection: null

    Binding { when: root.svc !== null; target: root.svc; property: "dataDir"; value: root.setting("dataDir", "") }
    Binding { when: root.svc !== null; target: root.svc; property: "serviceName"; value: root.setting("serviceName", "soloist.service") }

    // Tell the service when this popup shows the queue or anything at all.
    readonly property bool showsQueue: popupOpen && view === "queue"
    property bool countedQueue: false
    property bool countedActive: false
    function syncViewers() {
        if (!svc) return;
        if (showsQueue !== countedQueue) { svc.queueViewers += showsQueue ? 1 : -1; countedQueue = showsQueue; }
        if (popupOpen !== countedActive) { svc.activeViewers += popupOpen ? 1 : -1; countedActive = popupOpen; }
    }
    onShowsQueueChanged: syncViewers()
    onPopupOpenChanged: syncViewers()
    onSvcChanged: syncViewers()
    Component.onDestruction: { popupOpen = false; syncViewers(); }

    Ui.WidgetButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        dimmed: !root.ready
        text: root.spotifyGlyph + (root.showTitle && !root.vertical && root.player.hasItem
            ? "  " + (root.player.title.length > 40 ? root.player.title.slice(0, 39) + "…" : root.player.title) : "")
        tooltipText: root.remoteActive
                ? (remote.hasItem ? remote.title + (remote.artist ? " — " + remote.artist : "") + "\n" : "")
                  + "Playing on " + remote.deviceName
            : soloist.serviceState === "missing" ? "Soloist: not installed"
            : !soloist.connected ? "Soloist: service not running"
            : !soloist.loggedIn ? "Soloist: not logged in — pick this device in a Spotify app"
            : soloist.hasItem ? soloist.title + (soloist.artist ? " — " + soloist.artist : "")
            : "Soloist: nothing playing"
        onPressed: function(mouseButton) {
            if (mouseButton === Qt.LeftButton) root.toggle();
            else if (mouseButton === Qt.MiddleButton) root.player.togglePlay();
            else if (mouseButton === Qt.RightButton) root.player.next();
        }
        onWheelMoved: function(delta) {
            root.player.setVolume(Math.max(0, Math.min(100, root.player.volume + (delta > 0 ? 5 : -5))));
        }
    }

    Ui.PopupCard {
        id: popup
        anchorItem: button
        bar: root.bar
        owner: root
        open: root.popupOpen
        contentWidth: popup.fittedContentWidth(Style.space(340))
        contentHeight: popup.fittedContentHeight(column.visible ? column.implicitHeight : Style.space(560))

        QueueView {
            id: queueView
            visible: root.view === "queue" && root.ready
            anchors.fill: parent
            bar: root.bar
            controller: root.player
            api: spotifyApi
            foreground: root.foreground
            glyph: root.spotifyGlyph
            onBack: root.view = "player"
        }

        LibraryView {
            id: libraryView
            visible: root.view === "library" && root.ready
            anchors.fill: parent
            bar: root.bar
            api: spotifyApi
            controller: root.player
            foreground: root.foreground
            glyph: root.spotifyGlyph
            onBack: root.view = "player"
            onOpenCollection: function(collection) {
                root.openedCollection = collection;
                root.view = "collection";
            }
        }

        CollectionView {
            id: collectionView
            visible: root.view === "collection" && root.ready
            anchors.fill: parent
            bar: root.bar
            api: spotifyApi
            controller: root.player
            collection: root.openedCollection
            foreground: root.foreground
            glyph: root.spotifyGlyph
            onBack: root.view = "library"
        }

        DevicesView {
            id: devicesView
            visible: root.view === "devices"
            anchors.fill: parent
            bar: root.bar
            api: spotifyApi
            soloist: soloist
            foreground: root.foreground
            onBack: root.view = "player"
        }

        Column {
            id: column
            visible: !queueView.visible && !libraryView.visible && !collectionView.visible && !devicesView.visible
            anchors.fill: parent
            spacing: Style.space(12)

            // Setup, stopped and pairing states
            StatusView {
                visible: !root.ready
                width: parent.width
                bar: root.bar
                foreground: root.foreground
                glyph: root.spotifyGlyph
                controller: soloist
                installUrl: root.svc ? root.svc.installUrl : ""
            }

            // Cover art
            Ui.BorderSurface {
                visible: root.ready
                width: parent.width
                height: width
                radius: Style.spacing.labelGap
                color: Style.normalFillFor(root.foreground, Color.accent)
                borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

                Image {
                    anchors.fill: parent
                    anchors.margins: Style.space(2)
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    source: root.player.coverUrl
                    visible: source !== ""
                }

                Text {
                    anchors.centerIn: parent
                    visible: root.player.coverUrl === ""
                    text: root.spotifyGlyph
                    color: root.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.displayLarge
                }
            }

            // Title / artist / context, with the like button on the right
            Item {
                visible: root.ready
                width: parent.width
                height: titleColumn.implicitHeight

                Ui.Button {
                    id: likeButton
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.player.hasItem && root.spotifyApi.signedIn
                        && root.player.item.uri.indexOf("spotify:track:") === 0
                    iconText: root.svc.likes.currentLiked ? "󰋑" : "󰋕"
                    iconSize: Style.font.iconLarge
                    foreground: root.svc.likes.currentLiked ? Color.accent : root.foreground
                    tooltipText: root.svc.likes.currentLiked ? "Remove from Liked Songs" : "Save to Liked Songs"
                    onClicked: root.svc.likes.toggle(root.player.item.uri)
                }

                Column {
                    id: titleColumn
                    anchors.left: parent.left
                    anchors.right: likeButton.visible ? likeButton.left : parent.right
                    anchors.rightMargin: likeButton.visible ? Style.space(6) : 0
                    spacing: Style.space(3)

                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        text: root.player.title || "Nothing playing"
                        color: root.foreground
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.subtitle
                        font.bold: true
                        font.underline: popupTitleMouse.containsMouse && root.svc.albumUri() !== ""

                        // Open the album in the app window, scrolled to this song.
                        MouseArea {
                            id: popupTitleMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: root.svc && root.svc.albumUri() !== ""
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.openInApp(root.svc.albumUri(), root.player.album)
                        }
                    }

                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        visible: text !== ""
                        text: root.player.artist
                        color: Qt.darker(root.foreground, popupArtistMouse.containsMouse ? 1.0 : 1.3)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.underline: popupArtistMouse.containsMouse

                        MouseArea {
                            id: popupArtistMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: root.svc && root.svc.artistUri() !== ""
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.openInApp(root.svc.artistUri(), "")
                        }
                    }

                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        visible: text !== ""
                        text: root.player.contextName ? "Playing from " + root.player.contextName : ""
                        color: Qt.darker(root.foreground, 1.6)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                        font.underline: popupContextMouse.containsMouse

                        MouseArea {
                            id: popupContextMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: !!root.player.context
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.openInApp(root.player.context.uri, root.player.contextName)
                        }
                    }
                }
            }

            // Progress
            Column {
                visible: root.ready && root.player.durationMs > 0
                width: parent.width
                spacing: Style.space(2)

                Ui.PanelSlider {
                    width: parent.width
                    bar: root.bar
                    minimum: 0
                    maximum: Math.max(1, root.player.durationMs)
                    step: 1000
                    value: root.player.estimatedPositionMs
                    enabled: root.player.can("seek")
                    onReleased: function(value) { root.player.seek(value); }
                }

                Item {
                    width: parent.width
                    height: elapsed.implicitHeight

                    Text {
                        id: elapsed
                        anchors.left: parent.left
                        text: root.formatTime(root.player.estimatedPositionMs)
                        color: Qt.darker(root.foreground, 1.5)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                    }

                    Text {
                        anchors.right: parent.right
                        text: root.formatTime(root.player.durationMs)
                        color: Qt.darker(root.foreground, 1.5)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                    }
                }
            }

            // Transport controls
            Row {
                visible: root.ready
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(6)

                Ui.Button {
                    iconText: "󰒝"
                    foreground: root.player.shuffle ? Color.accent : root.foreground
                    selected: root.player.shuffle
                    tooltipText: root.player.shuffle ? "Disable shuffle" : "Enable shuffle"
                    onClicked: root.player.setShuffle(!root.player.shuffle)
                }

                Ui.Button {
                    iconText: "󰒮"
                    foreground: root.foreground
                    enabled: root.player.can("skip_prev") || root.player.can("seek")
                    opacity: enabled ? 1 : 0.4
                    onClicked: root.player.previous()
                }

                Ui.Button {
                    iconText: root.player.playing ? "󰏤" : "󰐊"
                    foreground: root.foreground
                    iconSize: Style.font.iconLarge
                    horizontalPadding: Style.spacing.panelGap
                    onClicked: root.player.togglePlay()
                }

                Ui.Button {
                    iconText: "󰒭"
                    foreground: root.foreground
                    enabled: root.player.can("skip_next")
                    opacity: enabled ? 1 : 0.4
                    onClicked: root.player.next()
                }

                Ui.Button {
                    iconText: root.player.repeat === "track" ? "󰑘" : "󰑖"
                    foreground: root.player.repeat !== "off" ? Color.accent : root.foreground
                    selected: root.player.repeat !== "off"
                    tooltipText: "Repeat: " + root.player.repeat
                    onClicked: root.player.cycleRepeat()
                }
            }

            // Volume (some remote devices, e.g. iPhones, refuse remote volume)
            Row {
                visible: root.ready && (!root.remoteActive || remote.supportsVolume)
                width: parent.width
                spacing: Style.space(8)

                Text {
                    id: volumeGlyph
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.player.volume === 0 ? "󰝟" : root.player.volume < 50 ? "󰖀" : "󰕾"
                    color: root.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                }

                Ui.PanelSlider {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - volumeGlyph.width - parent.spacing
                    bar: root.bar
                    minimum: 0
                    maximum: 100
                    step: 1
                    integer: true
                    value: root.player.volume
                    onReleased: function(value) { root.player.setVolume(value); }
                }
            }

            // "Playing on iPhone" bar, like Spotify's green device strip.
            Rectangle {
                visible: root.remoteActive
                width: parent.width
                height: Style.space(30)
                radius: Style.spacing.labelGap
                color: Style.selectedFillFor(root.foreground, Color.accent)

                Text {
                    anchors.centerIn: parent
                    width: parent.width - Style.space(16)
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: "󰓃  Playing on " + remote.deviceName
                    color: Color.accent
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                }

                HoverHandler { cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: root.view = "devices" }
            }

            Ui.PanelSeparator {
                visible: root.ready
                foreground: root.foreground
            }

            Row {
                visible: root.ready
                width: parent.width
                spacing: Style.space(6)

                Ui.Button {
                    width: parent.width - queueButton.width - devicesButton.width - appButton.width - parent.spacing * 3
                    leftAlign: true
                    iconText: "󰌱"
                    text: "Your Library"
                    foreground: root.foreground
                    onClicked: root.view = "library"
                }

                Ui.Button {
                    id: appButton
                    iconText: "󰏌"
                    foreground: root.foreground
                    tooltipText: "Open Soloist"
                    onClicked: {
                        root.close();
                        if (root.svc) root.svc.openApp("");
                    }
                }

                Ui.Button {
                    id: devicesButton
                    iconText: "󰓃"
                    foreground: root.remoteActive ? Color.accent : root.foreground
                    selected: root.remoteActive
                    tooltipText: "Connect to a device"
                    onClicked: root.view = "devices"
                }

                Ui.Button {
                    id: queueButton
                    iconText: "󰲸"
                    foreground: root.foreground
                    tooltipText: "Queue"
                    onClicked: root.view = "queue"
                }
            }
        }
    }
}
