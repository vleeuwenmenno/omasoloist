import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui
import "app"

Ui.BarWidget {
    id: root
    moduleName: "vleeuwenmenno.omasoloist"

    property bool popupOpen: false
    property string view: "player"
    // Lyrics shown in place of the cover (popupLyricsMode "cover").
    property bool coverLyrics: false
    readonly property bool showsCoverLyrics: coverLyrics && svc !== null && svc.trackInfo.lyricsAvailable
    readonly property bool opened: popupOpen
    readonly property color foreground: bar ? bar.foreground : Color.foreground
    readonly property string spotifyGlyph: String.fromCodePoint(0xf1bc)
    // Label next to the icon: "icon", "title", "title-artist",
    // "artist-title" or "lyrics" (current lyric line); editable in the app
    // window's Settings. `labelLength` caps it in characters.
    readonly property string labelMode: svc ? svc.labelMode : "lyrics"
    readonly property int labelLength: setting("labelLength", 72)
    // Bar label only: show each lyric line this many ms early (0–2000), so
    // it can be read as it's sung. The popup and window stay in sync.
    readonly property int lyricsOffset: Math.max(0, Math.min(2000, setting("lyricsOffset", 250)))

    function clip(text) {
        return text.length > labelLength ? text.slice(0, labelLength - 1) + "…" : text;
    }

    readonly property string label: {
        if (!player || !player.hasItem || vertical) return "";
        var title = player.title, artist = player.artist;
        switch (labelMode) {
        case "icon": return "";
        case "title-artist": return artist ? title + " – " + artist : title;
        case "artist-title": return artist ? artist + " – " + title : title;
        case "lyrics": {
            var info = svc.trackInfo;
            var position = player.estimatedPositionMs + 250 + lyricsOffset;
            var index = -1;
            for (var i = 0; i < info.synced.length && info.synced[i].t <= position; i++) index = i;
            var line = index >= 0 ? info.synced[index].text : "";
            // Between lines (instrumental breaks) show a note; no synced
            // lyrics at all falls back to the title.
            if (info.hasSynced) return line && line.trim() !== "" ? line : "♪";
            return title;
        }
        default: return title;
        }
    }

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
    Binding { when: root.svc !== null; target: root.svc; property: "widgetSettings"; value: root.settings || ({}) }
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
    onPopupOpenChanged: {
        syncViewers();
        // Optionally start from the player view every time the popup opens.
        if (!popupOpen && svc && svc.popupResetView) {
            view = "player";
            coverLyrics = false;
        }
    }
    onSvcChanged: syncViewers()
    Component.onDestruction: { popupOpen = false; syncViewers(); }

    Ui.WidgetButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        dimmed: !root.ready
        text: root.spotifyGlyph + (root.label !== "" ? "  " + root.clip(root.label) : "")
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

        // Lyrics, reusing the app window's lyrics page at popup size.
        Item {
            id: lyricsView
            visible: root.view === "lyrics" && root.ready
            anchors.fill: parent

            // What the reused app-window components (LyricsPage,
            // QualityCard) expect from `app`.
            QtObject {
                id: popupApp
                readonly property color accent: Color.accent
                readonly property color fg: root.foreground
                readonly property color dim: Qt.darker(root.foreground, 1.45)
                readonly property color bg: Color.background
                readonly property var service: root.svc
            }

            Item {
                id: lyricsHeader
                anchors.left: parent.left
                anchors.right: parent.right
                height: lyricsBack.implicitHeight

                Ui.Button {
                    id: lyricsBack
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    iconText: "󰁍"
                    foreground: root.foreground
                    tooltipText: "Back to player"
                    onClicked: root.view = "player"
                }

                Column {
                    anchors.left: lyricsBack.right
                    anchors.leftMargin: Style.space(6)
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                        text: "Lyrics"
                        color: root.foreground
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.subtitle
                        font.bold: true
                    }

                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        text: root.player ? root.player.title + (root.player.artist ? " · " + root.player.artist : "") : ""
                        color: Qt.darker(root.foreground, 1.45)
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.caption
                    }
                }
            }

            LyricsPage {
                anchors.top: lyricsHeader.bottom
                anchors.topMargin: Style.space(8)
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                radius: Style.spacing.labelGap
                clip: true
                app: popupApp
                info: root.svc ? root.svc.trackInfo : null
                lineSize: Style.font.heading + 4
                sideMargin: Style.space(16)
                visible: root.svc !== null
            }
        }

        // Sound quality: the app window's File quality card.
        Item {
            id: qualityView
            visible: root.view === "quality" && root.ready
            anchors.fill: parent

            Item {
                id: qualityHeader
                anchors.left: parent.left
                anchors.right: parent.right
                height: qualityBack.implicitHeight

                Ui.Button {
                    id: qualityBack
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    iconText: "󰁍"
                    foreground: root.foreground
                    tooltipText: "Back to player"
                    onClicked: root.view = "player"
                }

                Text {
                    anchors.left: qualityBack.right
                    anchors.leftMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Sound quality"
                    color: root.foreground
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.subtitle
                    font.bold: true
                }
            }

            Flickable {
                anchors.top: qualityHeader.bottom
                anchors.topMargin: Style.space(8)
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                clip: true
                contentHeight: qualityCard.implicitHeight
                boundsBehavior: Flickable.StopAtBounds

                QualityCard {
                    id: qualityCard
                    width: parent.width
                    padding: Style.space(4)
                    innerWidth: width - Style.space(8)
                    app: popupApp
                    active: qualityView.visible && root.popupOpen
                    onSettingsRequested: {
                        root.close();
                        root.svc.openApp("settings");
                    }
                }
            }
        }

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
            visible: !queueView.visible && !lyricsView.visible && !qualityView.visible && !libraryView.visible && !collectionView.visible && !devicesView.visible
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
                    visible: source !== "" && !root.showsCoverLyrics
                }

                // Lyrics in place of the cover, same size, controls stay put.
                LyricsPage {
                    anchors.fill: parent
                    anchors.margins: Style.space(2)
                    visible: root.showsCoverLyrics
                    radius: Style.spacing.labelGap
                    clip: true
                    app: popupApp
                    info: root.svc ? root.svc.trackInfo : null
                    lineSize: Style.font.heading + 2
                    sideMargin: Style.space(14)
                }

                Text {
                    anchors.centerIn: parent
                    visible: root.player.coverUrl === "" && !root.showsCoverLyrics
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

                    // File quality of the playing song ("Lossless" like Spotify).
                    Text {
                        visible: root.svc !== null && root.svc.quality !== null
                        textFormat: Text.PlainText
                        text: visible ? (root.svc.quality.lossless ? "Lossless" : root.svc.quality.label + " quality") : ""
                        color: visible && root.svc.quality.lossless ? Color.accent : Qt.darker(root.foreground, 1.45)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                        font.underline: popupQualityMouse.containsMouse

                        // Opens the Sound quality view (tier and signal path).
                        MouseArea {
                            id: popupQualityMouse
                            anchors.fill: parent
                            anchors.margins: -2
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.view = "quality"
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

            // Bottom buttons; each can be hidden in Settings → Bar widget.
            RowLayout {
                visible: root.ready
                width: parent.width
                spacing: Style.space(6)

                Ui.Button {
                    visible: root.svc !== null && root.svc.popupShows("library")
                    Layout.fillWidth: true
                    leftAlign: true
                    iconText: "󰌱"
                    text: "Your Library"
                    foreground: root.foreground
                    onClicked: root.view = "library"
                }

                // Keeps the icons right-aligned when the library button is hidden.
                Item {
                    visible: root.svc === null || !root.svc.popupShows("library")
                    Layout.fillWidth: true
                }

                Ui.Button {
                    id: lyricsButton
                    // Only for songs with lyrics.
                    visible: root.svc !== null && root.svc.popupShows("lyrics") && root.svc.trackInfo.lyricsAvailable
                    iconText: "󰍬"
                    foreground: root.showsCoverLyrics ? Color.accent : root.foreground
                    selected: root.showsCoverLyrics
                    tooltipText: root.showsCoverLyrics ? "Show cover" : "Lyrics"
                    onClicked: {
                        if (root.svc.popupLyricsMode === "cover") root.coverLyrics = !root.coverLyrics;
                        else root.view = "lyrics";
                    }
                }

                Ui.Button {
                    id: appButton
                    visible: root.svc !== null && root.svc.popupShows("app")
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
                    visible: root.svc !== null && root.svc.popupShows("devices")
                    iconText: "󰓃"
                    foreground: root.remoteActive ? Color.accent : root.foreground
                    selected: root.remoteActive
                    tooltipText: "Connect to a device"
                    onClicked: root.view = "devices"
                }

                Ui.Button {
                    id: queueButton
                    visible: root.svc !== null && root.svc.popupShows("queue")
                    iconText: "󰲸"
                    foreground: root.foreground
                    tooltipText: "Queue"
                    onClicked: root.view = "queue"
                }
            }
        }
    }
}
