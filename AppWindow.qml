pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.Commons
import "app"

// The Soloist app window: a Spotify-desktop layout drawn with the Omarchy
// theme tokens, so switching themes restyles it like every shell surface.
//
// Summon: omarchy-shell shell summon vleeuwenmenno.omasoloist '{"page":"settings"}'
// Hyprland floats it through a rule on class org.quickshell, title "Soloist".
Item {
    id: root

    // Injected by the shell's panel loader.
    property var shell: null
    property var manifest: null
    property var service: null
    property string omarchyPath: ""

    property bool closingFromHost: false

    // ------------------------------------------------------------- palette
    readonly property color bg: Color.background
    readonly property color fg: Color.foreground
    readonly property color accent: Color.accent
    readonly property color dim: Qt.rgba(fg.r, fg.g, fg.b, 0.6)
    readonly property color surface: Qt.rgba(fg.r, fg.g, fg.b, 0.045)
    readonly property color surfaceHover: Qt.rgba(fg.r, fg.g, fg.b, 0.09)

    // ---------------------------------------------------------- navigation
    // Pages: {kind: "home"|"search"|"settings"|"collection"|"artist", item}
    property var history: [{ kind: "home" }]
    property int historyIndex: 0
    readonly property var page: history[historyIndex]
    // "nowplaying" (Spotify's default), "queue", "devices" or "" (closed).
    property string rightPanel: "nowplaying"
    // The collection/artist pages keep their last item while hidden so going
    // back doesn't reload them.
    property var lastCollection: null
    property var lastArtist: null
    property string lastHighlight: ""
    onPageChanged: {
        if (page.kind === "collection") {
            lastHighlight = page.highlight || "";
            lastCollection = page.item;
        }
        else if (page.kind === "artist") lastArtist = page.item;
    }

    function navigate(next) {
        var cur = page;
        if (cur.kind === next.kind && (cur.item || null) === (next.item || null)) return;
        var trimmed = history.slice(0, historyIndex + 1);
        trimmed.push(next);
        history = trimmed.slice(-50);
        historyIndex = history.length - 1;
    }
    function back() { if (historyIndex > 0) historyIndex--; }
    function forward() { if (historyIndex < history.length - 1) historyIndex++; }

    function resolveUri(item) {
        if (!item) return "";
        if (item.kind === "liked") return service.soloist.likedSongsUri;
        if (item.kind === "track") return item.uri;
        return item.uri || "";
    }

    function isPlayingUri(uri) {
        var player = service.player;
        return uri !== "" && player.context && player.context.uri === uri;
    }

    // `highlight`: a track URI to scroll to and flash on the collection page.
    function openItem(item, highlight) {
        if (!item) return;
        if (item.kind === "artist") {
            navigate({ kind: "artist", item: item });
        } else if (item.kind === "track") {
            if (item.album_uri) openUri(item.album_uri, "", item.uri);
        } else {
            var collection = Object.assign({}, item);
            if (collection.kind === "liked") {
                collection.uri = service.soloist.likedSongsUri;
                collection.name = "Liked Songs";
            }
            navigate({ kind: "collection", item: collection, highlight: highlight || "" });
        }
    }

    // Open a spotify: URI, e.g. the playing context from the player bar.
    function openUri(uri, name, highlight) {
        var parts = String(uri || "").split(":");
        if (parts.length >= 4 && parts[parts.length - 1] === "collection") openItem({ kind: "liked" }, highlight);
        else if (parts.length === 3 && (parts[1] === "playlist" || parts[1] === "album" || parts[1] === "artist"))
            openItem({ kind: parts[1], uri: uri, id: parts[2], name: name || "", cover: "", owner: "" }, highlight);
    }

    // The playing track's album / artist / context, e.g. from the player bar.
    function openPlayingAlbum() {
        var p = service.player;
        if (service.albumUri()) openUri(service.albumUri(), p.album, p.item ? p.item.uri : "");
    }
    function openPlayingArtist() { if (service.artistUri()) openUri(service.artistUri(), ""); }
    function openPlayingContext() {
        var p = service.player;
        if (p.context) openUri(p.context.uri, p.contextName, p.item ? p.item.uri : "");
    }

    function playItem(item) {
        var uri = resolveUri(item);
        if (!uri) return;
        if (isPlayingUri(uri)) service.player.togglePlay();
        else service.player.play(uri);
    }

    function toggleRightPanel(name) { rightPanel = rightPanel === name ? "" : name; }

    // ------------------------------------------------------ context menus
    // Set from inside the window content once it exists.
    property var menuPopup: null
    property var menuItem: null
    property var toastPopup: null
    // Playlists you can add to (yours or collaborative), for "Add to playlist".
    property var ownPlaylists: []

    function loadOwnPlaylists() {
        if (!service || !service.api.signedIn) return;
        service.api.call(["playlists", "0"], function(result) {
            if (!result.ok) return;
            var me = root.service.soloist.userId;
            root.ownPlaylists = result.items.filter(function(p) { return p.owner_id === me || p.collaborative; });
        });
    }

    function kindOf(item) {
        if (item.kind) return item.kind;
        var uri = item.uri || "";
        return uri.indexOf("spotify:track:") === 0 ? "track" : uri.split(":")[1] || "";
    }

    function playlistSubmenu(uri) {
        return function() {
            if (root.ownPlaylists.length === 0) return [{ label: "No playlists of your own yet", enabled: false }];
            return root.ownPlaylists.map(function(p) {
                return { label: p.name, icon: "󰲸", action: function() { root.service.addToPlaylist(p, uri); } };
            });
        };
    }

    function libraryEntry(uri, savedLabel, saveLabel) {
        var likes = service.likes;
        var saved = likes.isLiked(uri);
        return { label: saved ? savedLabel : saveLabel, icon: saved ? "󰄬" : "󰐕", accent: saved,
                 action: function() { likes.toggle(uri); } };
    }

    function menuFor(item) {
        var kind = kindOf(item);
        var uri = resolveUri(item);
        var entries = [];
        var link = { label: "Copy link", icon: "󰌷", action: function() { root.service.copyLink(uri); } };
        var web = { label: "Open in web player", icon: "󰖟",
                    action: function() { Qt.openUrlExternally(root.service.webUrl(uri)); } };
        var queue = { label: "Add to queue", icon: "󰐑", action: function() { root.service.addToQueue(uri); } };
        var sep = { separator: true };

        if (kind === "track") {
            var liked = service.likes.isLiked(uri);
            entries.push({ label: "Add to playlist", icon: "󰐕", submenu: playlistSubmenu(uri) });
            entries.push({ label: liked ? "Remove from your Liked Songs" : "Save to your Liked Songs",
                           icon: liked ? "󰋑" : "󰋕", accent: liked,
                           action: function() { root.service.likes.toggle(uri); } });
            entries.push(queue, sep);
            if (item.artist_uri) entries.push({ label: "Go to artist", icon: "󰀄",
                action: function() { root.openUri(item.artist_uri, ""); } });
            if (item.album_uri) entries.push({ label: "Go to album", icon: "󰀥",
                action: function() { root.openUri(item.album_uri, item.album || ""); } });
            link.label = "Copy song link";
        } else if (kind === "album") {
            entries.push(libraryEntry(uri, "Remove from Your Library", "Save to Your Library"));
            entries.push(queue);
            entries.push({ label: "Add to playlist", icon: "󰐕", submenu: playlistSubmenu(uri) });
            if (item.artist_uri) entries.push(sep, { label: "Go to artist", icon: "󰀄",
                action: function() { root.openUri(item.artist_uri, ""); } });
            link.label = "Copy album link";
        } else if (kind === "playlist") {
            var mine = item.owner_id && item.owner_id === service.soloist.userId;
            if (!mine) entries.push(libraryEntry(uri, "Remove from Your Library", "Add to Your Library"));
            entries.push(queue);
            link.label = "Copy link to playlist";
        } else if (kind === "liked") {
            entries.push(queue);
        } else if (kind === "artist") {
            if (service.api.missingScopes.indexOf("user-follow-modify") >= 0)
                entries.push({ label: "Follow (sign in again in Settings)", icon: "󰐕", enabled: false });
            else entries.push(libraryEntry(uri, "Unfollow", "Follow"));
            link.label = "Copy link to artist";
        }
        entries.push(sep, link, web);
        return entries;
    }

    // Sort/view choice per collection URI, for this session.
    property var collectionPrefs: ({})

    // Open a ready-made list of menu entries (shuffle / sort menus).
    function showEntries(entries, source, x, y) {
        if (!menuPopup) return;
        menuItem = null;
        var p = source.mapToItem(menuPopup.parent, x, y);
        menuPopup.show(entries, p.x, p.y);
    }

    // Right-click (or ⋯) on something: `source` and x/y locate the pointer.
    function showMenu(item, source, x, y) {
        if (!item || !menuPopup || !service) return;
        menuItem = item;
        var uri = resolveUri(item);
        if (uri) service.likes.query([uri]);
        if (ownPlaylists.length === 0) loadOwnPlaylists();
        var p = source.mapToItem(menuPopup.parent, x, y);
        menuPopup.show(menuFor(item), p.x, p.y);
    }

    Connections {
        target: root.service ? root.service.likes : null
        // Library state arrives after the menu opened; refresh its labels.
        function onKnownChanged() {
            if (root.menuPopup && root.menuPopup.opened && root.menuItem)
                root.menuPopup.entries = root.menuFor(root.menuItem);
        }
    }

    Connections {
        target: root.service
        function onToast(text) { if (root.toastPopup && window.visible) root.toastPopup.show(text); }
    }

    // --------------------------------------------------------- lifecycle
    // Shell lifecycle: open(payload) on summon, close() on hide.
    function open(payloadJson) {
        closingFromHost = false;
        window.visible = true;
        var payload = {};
        try { payload = JSON.parse(String(payloadJson || "{}")) || {}; } catch (e) {}
        if (payload.page === "settings") navigate({ kind: "settings" });
        else if (payload.page === "search") navigate({ kind: "search" });
        else if (payload.uri) openUri(payload.uri, payload.name || "", payload.highlight || "");
    }

    function close() {
        closingFromHost = true;
        window.visible = false;
        closingFromHost = false;
    }

    // Viewer bookkeeping for the service's pollers.
    readonly property bool showsWindow: window.visible
    readonly property bool showsQueue: window.visible && (rightPanel === "queue" || rightPanel === "nowplaying")
    property bool countedWindow: false
    property bool countedQueue: false
    function syncViewers() {
        if (!service) return;
        if (showsWindow !== countedWindow) { service.activeViewers += showsWindow ? 1 : -1; countedWindow = showsWindow; }
        if (showsQueue !== countedQueue) { service.queueViewers += showsQueue ? 1 : -1; countedQueue = showsQueue; }
    }
    onShowsWindowChanged: syncViewers()
    onShowsQueueChanged: syncViewers()
    onServiceChanged: syncViewers()
    Component.onDestruction: {
        window.visible = false;
        syncViewers();
    }

    // Lyrics and artist info for the playing track.
    TrackInfo {
        id: trackInfo
        api: root.service ? root.service.api : null
        player: root.service ? root.service.player : null
        // Always look lyrics up while the window is open, so the lyrics
        // button can hide itself for songs without any (answers are cached).
        active: window.visible
    }

    readonly property var info: trackInfo

    function toggleLyrics() {
        if (page.kind === "lyrics") back();
        else navigate({ kind: "lyrics" });
    }

    FloatingWindow {
        id: window
        visible: false
        title: "Soloist"
        color: root.bg
        implicitWidth: 1280
        implicitHeight: 800
        minimumSize: Qt.size(900, 600)

        onVisibleChanged: {
            if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
                root.shell.hide("vleeuwenmenno.omasoloist");
        }

        // Built once the shell has injected the service.
        Loader {
            anchors.fill: parent
            focus: true
            active: root.service !== null
            sourceComponent: windowContent
        }

        Component {
            id: windowContent

            Item {
                id: content
                anchors.fill: parent
                focus: true

                Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Space && !search.activeFocus) {
                        root.service.player.togglePlay();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_L && (event.modifiers & Qt.ControlModifier)) {
                        search.forceActiveFocus();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Left && (event.modifiers & Qt.AltModifier)) {
                        root.back();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Right && (event.modifiers & Qt.AltModifier)) {
                        root.forward();
                        event.accepted = true;
                    }
                }

                // ---------------------------------------------------- top bar
                Item {
                    id: topBar
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 64

                    Text {
                        id: logo
                        anchors.left: parent.left
                        anchors.leftMargin: 24
                        anchors.verticalCenter: parent.verticalCenter
                        text: String.fromCodePoint(0xf1bc)
                        color: root.fg
                        font.family: Style.font.family
                        font.pixelSize: 30
                    }

                    Row {
                        anchors.left: logo.right
                        anchors.leftMargin: 20
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 8

                        Repeater {
                            model: [
                                { glyph: "󰅁", enabled: root.historyIndex > 0, action: "back" },
                                { glyph: "󰅂", enabled: root.historyIndex < root.history.length - 1, action: "forward" }
                            ]

                            Rectangle {
                                id: navButton
                                required property var modelData
                                width: 32
                                height: 32
                                radius: 16
                                color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
                                opacity: modelData.enabled ? 1 : 0.4

                                Text {
                                    anchors.centerIn: parent
                                    text: navButton.modelData.glyph
                                    color: root.fg
                                    font.family: Style.font.family
                                    font.pixelSize: 18
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    enabled: navButton.modelData.enabled
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: navButton.modelData.action === "back" ? root.back() : root.forward()
                                }
                            }
                        }
                    }

                    Row {
                        anchors.centerIn: parent
                        spacing: 8

                        Rectangle {
                            width: 48
                            height: 48
                            radius: 24
                            color: homeMouse.containsMouse ? root.surfaceHover : root.surface

                            Text {
                                anchors.centerIn: parent
                                text: root.page.kind === "home" ? "󰋜" : "󰋜"
                                color: root.page.kind === "home" ? root.fg : root.dim
                                font.family: Style.font.family
                                font.pixelSize: 22
                            }

                            MouseArea {
                                id: homeMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.navigate({ kind: "home" })
                            }
                        }

                        Rectangle {
                            width: Math.min(480, topBar.width - 520)
                            height: 48
                            radius: 24
                            color: search.activeFocus || searchMouse.containsMouse ? root.surfaceHover : root.surface
                            border.width: search.activeFocus ? 2 : 0
                            border.color: root.fg

                            Text {
                                id: searchIcon
                                anchors.left: parent.left
                                anchors.leftMargin: 16
                                anchors.verticalCenter: parent.verticalCenter
                                text: "󰍉"
                                color: root.dim
                                font.family: Style.font.family
                                font.pixelSize: 20
                            }

                            MouseArea {
                                id: searchMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.IBeamCursor
                                onClicked: search.forceActiveFocus()
                            }

                            TextInput {
                                id: search
                                anchors.left: searchIcon.right
                                anchors.leftMargin: 12
                                anchors.right: clearSearch.visible ? clearSearch.left : parent.right
                                anchors.rightMargin: clearSearch.visible ? 8 : 16
                                anchors.verticalCenter: parent.verticalCenter
                                clip: true
                                color: root.fg
                                selectionColor: root.accent
                                selectedTextColor: root.bg
                                font.family: Style.font.family
                                font.pixelSize: Style.font.body
                                onTextEdited: {
                                // Clearing the box leaves search, like Spotify.
                                if (text === "") { if (root.page.kind === "search") root.navigate({ kind: "home" }); }
                                else if (root.page.kind !== "search") root.navigate({ kind: "search" });
                            }
                                onActiveFocusChanged: if (activeFocus && text !== "" && root.page.kind !== "search") root.navigate({ kind: "search" })
                                Keys.onEscapePressed: {
                                text = "";
                                if (root.page.kind === "search") root.navigate({ kind: "home" });
                                content.forceActiveFocus();
                            }

                                Text {
                                    visible: search.text === ""
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "What do you want to play?"
                                    color: root.dim
                                    font: search.font
                                }
                            }

                            Text {
                                id: clearSearch
                                anchors.right: parent.right
                                anchors.rightMargin: 16
                                anchors.verticalCenter: parent.verticalCenter
                                visible: search.text !== ""
                                text: "󰅖"
                                color: root.dim
                                font.family: Style.font.family
                                font.pixelSize: 18

                                MouseArea {
                                    anchors.fill: parent
                                    anchors.margins: -6
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                    search.text = "";
                                    if (root.page.kind === "search") root.navigate({ kind: "home" });
                                }
                                }
                            }
                        }
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.rightMargin: 16
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 12

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "󰒓"
                            color: root.page.kind === "settings" ? root.fg : root.dim
                            font.family: Style.font.family
                            font.pixelSize: 22

                            MouseArea {
                                anchors.fill: parent
                                anchors.margins: -8
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.navigate({ kind: "settings" })
                            }
                        }
                    }
                }

                // -------------------------------------------------- body
                Item {
                    id: body
                    anchors.top: topBar.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: playerBar.top
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8

                    // Library sidebar
                    Rectangle {
                        id: sidebar
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: Math.max(260, Math.min(360, body.width * 0.24))
                        radius: 8
                        color: root.surface

                        LibraryView {
                            anchors.fill: parent
                            anchors.margins: 12
                            showBack: false
                            visible: root.service !== null
                            bar: null
                            api: root.service.api
                            controller: root.service.player
                            foreground: root.fg
                            onOpenCollection: function(collection) { root.openItem(collection); }
                            onRowMenuRequested: function(entry, source, x, y) { root.showMenu(entry, source, x, y); }
                        }
                    }

                    // Queue / devices
                    Rectangle {
                        id: side
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: root.rightPanel !== "" ? Math.max(320, Math.min(420, body.width * 0.26)) : 0
                        visible: width > 0
                        radius: 8
                        color: root.surface

                        NowPlayingPanel {
                            anchors.fill: parent
                            anchors.margins: 16
                            visible: root.rightPanel === "nowplaying"
                            app: root
                            info: trackInfo
                            onCloseRequested: root.rightPanel = ""
                        }

                        QueueView {
                            anchors.fill: parent
                            anchors.margins: 12
                            visible: root.rightPanel === "queue"
                            showBack: false
                            bar: null
                            controller: root.service.player
                            api: root.service.api
                            foreground: root.fg
                            glyph: String.fromCodePoint(0xf1bc)
                        }

                        DevicesView {
                            anchors.fill: parent
                            anchors.margins: 12
                            visible: root.rightPanel === "devices"
                            showBack: false
                            bar: null
                            api: root.service.api
                            soloist: root.service.soloist
                            foreground: root.fg
                        }
                    }

                    // Pages
                    Rectangle {
                        id: main
                        anchors.left: sidebar.right
                        anchors.leftMargin: 8
                        anchors.right: side.visible ? side.left : parent.right
                        anchors.rightMargin: side.visible ? 8 : 0
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        radius: 8
                        clip: true
                        color: root.surface

                        HomePage {
                            anchors.fill: parent
                            visible: root.page.kind === "home"
                            app: root
                        }

                        SearchPage {
                            anchors.fill: parent
                            visible: root.page.kind === "search"
                            app: root
                            query: search.text
                        }

                        LyricsPage {
                            anchors.fill: parent
                            visible: root.page.kind === "lyrics"
                            app: root
                            info: trackInfo
                        }

                        SettingsPage {
                            anchors.fill: parent
                            visible: root.page.kind === "settings"
                            app: root
                        }

                        CollectionPage {
                            anchors.fill: parent
                            visible: root.page.kind === "collection"
                            app: root
                            collection: root.lastCollection
                            highlightUri: root.lastHighlight
                        }

                        ArtistPage {
                            anchors.fill: parent
                            visible: root.page.kind === "artist"
                            app: root
                            artist: root.lastArtist
                        }
                    }
                }

                PlayerBar {
                    id: playerBar
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: deviceStrip.top
                    height: 88
                    app: root
                }

                Toast {
                    id: toast
                    app: root
                    z: 20
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: playerBar.top
                    anchors.bottomMargin: 16
                }

                ContextMenu {
                    id: contextMenu
                    app: root
                    parent: content
                }

                Component.onCompleted: {
                    root.menuPopup = contextMenu;
                    root.toastPopup = toast;
                }

                // "Playing on …" strip, like Spotify's green device bar.
                Rectangle {
                    id: deviceStrip
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: root.service && root.service.remoteActive ? 8 : 0
                    anchors.topMargin: 0
                    height: root.service && root.service.remoteActive ? 28 : 0
                    visible: height > 0
                    radius: 4
                    color: root.accent

                    Text {
                        anchors.right: parent.right
                        anchors.rightMargin: 16
                        anchors.verticalCenter: parent.verticalCenter
                        text: "󰓃  Playing on " + (root.service ? root.service.remote.deviceName : "")
                        color: root.bg
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        font.bold: true
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.rightPanel = "devices"
                    }
                }
            }
        }
    }
}
