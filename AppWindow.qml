pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import "app"

// The Soloist app window: a Spotify-desktop layout drawn with the Omarchy
// theme tokens, so switching themes restyles it like every shell surface.
//
// Summon: omarchy-shell shell summon vleeuwenmenno.omasoloist '{"page":"settings"}'
// It floats itself when it opens (Settings > App window turns that off), so
// no Hyprland window rule is needed.
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
    // Omarchy themes have no warning colour; orange reads as "degraded" on all of them.
    readonly property color warning: "#e8a33d"
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

    // ------------------------------------------------ layout, remembered
    // Sidebar widths (drag the gaps) and the open side panel persist in
    // ~/.local/state/omasoloist/ui.json.
    readonly property int defaultLeftWidth: 300
    readonly property int defaultRightWidth: 360
    property real leftWidth: defaultLeftWidth
    property real rightWidth: defaultRightWidth
    property bool layoutLoaded: false
    // Float, size and center the window each time it opens.
    property bool floatWindow: true

    function clampLeft(w, bodyWidth) { return Math.max(220, Math.min(w, bodyWidth * 0.4)); }
    function clampRight(w, bodyWidth) { return Math.max(280, Math.min(w, bodyWidth * 0.45)); }

    function saveLayout() { if (layoutLoaded) saveLayoutTimer.restart(); }
    onLeftWidthChanged: saveLayout()
    onRightWidthChanged: saveLayout()
    onRightPanelChanged: saveLayout()
    onFloatWindowChanged: saveLayout()

    Timer {
        id: saveLayoutTimer
        interval: 600
        onTriggered: layoutFile.setText(JSON.stringify({
            leftWidth: Math.round(root.leftWidth), rightWidth: Math.round(root.rightWidth), rightPanel: root.rightPanel,
            floatWindow: root.floatWindow
        }, null, 2) + "\n")
    }

    FileView {
        id: layoutFile
        path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omasoloist/ui.json"
        printErrors: false
        onLoaded: {
            try {
                var saved = JSON.parse(text());
                if (saved.leftWidth > 0) root.leftWidth = saved.leftWidth;
                if (saved.rightWidth > 0) root.rightWidth = saved.rightWidth;
                if (typeof saved.rightPanel === "string") root.rightPanel = saved.rightPanel;
                if (saved.floatWindow === false) root.floatWindow = false;
            } catch (e) {}
            root.layoutLoaded = true;
        }
        onLoadFailed: root.layoutLoaded = true
    }
    // The collection/artist pages keep their last item while hidden so going
    // back doesn't reload them.
    property var lastCollection: null
    property var lastArtist: null
    property var lastShelf: null
    property string lastHighlight: ""
    onPageChanged: {
        if (page.kind === "collection") {
            lastHighlight = page.highlight || "";
            lastCollection = page.item;
        }
        else if (page.kind === "artist") lastArtist = page.item;
        else if (page.kind === "shelf") lastShelf = page.item;
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
        if (parts.length === 4 && parts[1] === "station")
            openItem(service.radioItem("spotify:" + parts[2] + ":" + parts[3], String(name || "").replace(/ Radio$/, ""), ""), highlight);
        else if (parts.length >= 4 && parts[parts.length - 1] === "collection") openItem({ kind: "liked" }, highlight);
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
        var web = { label: "Open in web player", icon: "󰖟", external: true,
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
            entries.push({ label: "Go to song radio", icon: "󰐹",
                action: function() { root.openItem(root.service.radioItem(uri, item.name, item.cover_large || item.cover)); } });
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
        } else if (kind === "radio") {
            entries.push({ label: "Start endless radio", icon: "󰐹",
                action: function() { root.service.startRadio(uri, item.name || ""); } });
            link.label = "Copy link to radio";
        } else if (kind === "artist") {
            if (service.api.missingScopes.indexOf("user-follow-modify") >= 0)
                entries.push({ label: "Follow (sign in again in Settings)", icon: "󰐕", enabled: false });
            else entries.push(libraryEntry(uri, "Unfollow", "Follow"));
            entries.push({ label: "Go to artist radio", icon: "󰐹",
                action: function() { root.openItem(root.service.radioItem(uri, item.name, item.cover)); } });
            link.label = "Copy link to artist";
        }
        entries.push(sep, link, web);
        return entries;
    }

    // ------------------------------------------------------ account menu
    property var me: null
    function loadMe() {
        if (!service || !service.api.signedIn) return;
        service.api.call(["me"], function(result) { if (result.ok) root.me = result; });
    }
    Connections {
        target: root.service ? root.service.api : null
        function onSignedInChanged() { if (root.service.api.signedIn) root.loadMe(); else root.me = null; }
        function onCacheCleared(group) { if (group === "api" || group === "all" || group === "images") root.loadMe(); }
    }

    // Spotify's avatar menu, minus what the public API can't do (private
    // session, "Your Updates").
    function accountMenu() {
        var web = function(url) { return function() { Qt.openUrlExternally(url); }; };
        return [
            { header: me ? me.name : "Spotify" },
            { label: "Account", icon: "󰀄", external: true, action: web("https://www.spotify.com/account/overview/") },
            { label: "Profile", icon: "󰋜", action: function() { root.navigate({ kind: "profile" }); } },
            { label: "Recents", icon: "󰋚", action: function() { root.navigate({ kind: "history" }); } },
            { label: "Support", icon: "󰋖", external: true, action: web("https://support.spotify.com/") },
            { separator: true },
            { label: "Settings", icon: "󰒓", action: function() { root.navigate({ kind: "settings" }); } },
            { label: "Log out", icon: "󰍃", action: function() { root.service.api.logout(); } },
            { separator: true }
        ].concat(service.updateAvailable ? [
            { label: "Update to " + service.latestVersion, icon: "󰚰", accent: true,
              action: function() { root.service.runUpdate(); } },
            { label: "What's new", icon: "󰋼", external: true,
              action: function() { Qt.openUrlExternally(root.service.releasesUrl); } }
        ] : []).concat([
            { note: "OmaSoloist " + (service.version || "") + (service.updateAvailable ? " • " + service.latestVersion + " available" : "") }
        ]);
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
        else if (payload.page === "history") navigate({ kind: "history" });
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
    onShowsWindowChanged: {
        syncViewers();
        if (showsWindow && !me) loadMe();
    }
    onShowsQueueChanged: syncViewers()
    onServiceChanged: syncViewers()
    Component.onDestruction: {
        window.visible = false;
        syncViewers();
    }

    // Lyrics and artist info for the playing track.
    // Lyrics/artist info live in the service (the bar can show lyrics too).
    readonly property var trackInfo: service ? service.trackInfo : null
    Binding {
        when: root.service !== null
        target: root.service
        property: "windowOpen"
        value: window.visible
    }

    readonly property var info: trackInfo

    function toggleLyrics() {
        if (page.kind === "lyrics") back();
        else navigate({ kind: "lyrics" });
    }

    // Hiding the window unmaps it, so Hyprland tiles it again on every open.
    // openwindow carries "address,workspace,class,title".
    Connections {
        target: Hyprland
        enabled: root.floatWindow
        function onRawEvent(event) {
            if (!event || event.name !== "openwindow") return;
            var fields = String(event.data).split(",");
            if (fields.length < 4 || fields[2] !== "org.quickshell" || fields.slice(3).join(",") !== window.title) return;
            var address = "address:0x" + fields[0].replace(/^0x/, "");
            var w = window.implicitWidth, h = window.implicitHeight;
            if (Hyprland.usingLua) {
                var sel = '{ window = "' + address + '"';
                Hyprland.dispatch("hl.dsp.window.float(" + sel + ', action = "enable" })');
                Hyprland.dispatch("hl.dsp.window.resize(" + sel + ", x = " + w + ", y = " + h + " })");
                Hyprland.dispatch("hl.dsp.window.center(" + sel + " })");
            } else {
                Hyprland.dispatch("setfloating " + address);
                Hyprland.dispatch("resizewindowpixel exact " + w + " " + h + "," + address);
                Hyprland.dispatch("centerwindow");
            }
        }
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

                        // Listening history (Spotify's Recents page).
                        Rectangle {
                            visible: root.service.api.signedIn
                            width: 48
                            height: 48
                            radius: 24
                            color: historyMouse.containsMouse ? root.surfaceHover : root.surface

                            Text {
                                anchors.centerIn: parent
                                text: "󰋚"
                                color: root.page.kind === "history" ? root.fg : root.dim
                                font.family: Style.font.family
                                font.pixelSize: 22
                            }

                            MouseArea {
                                id: historyMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.navigate({ kind: "history" })
                            }
                        }

                        Rectangle {
                            width: Math.min(480, topBar.width - 576)
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

                        // Update pill (like Spotify's "Install App"), when a newer
                        // release tag exists.
                        Rectangle {
                            id: updatePill
                            visible: root.service.updateAvailable
                            anchors.verticalCenter: parent.verticalCenter
                            width: updateText.implicitWidth + 28
                            height: 32
                            radius: 16
                            color: updateMouse.containsMouse ? Qt.lighter(root.accent, 1.1) : root.accent

                            Text {
                                id: updateText
                                anchors.centerIn: parent
                                text: "󰚰  Update to " + root.service.latestVersion
                                color: root.bg
                                font.family: Style.font.family
                                font.pixelSize: Style.font.bodySmall
                                font.bold: true
                            }

                            MouseArea {
                                id: updateMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.showEntries([
                                    { header: "OmaSoloist " + root.service.latestVersion + " is available" },
                                    { note: "You have " + root.service.version + "." },
                                    { label: "Update now", icon: "󰚰", accent: true,
                                      action: function() { root.service.runUpdate(); } },
                                    { label: "What's new", icon: "󰋼", external: true,
                                      action: function() { Qt.openUrlExternally(root.service.releasesUrl); } }
                                ], updatePill, updatePill.width - 280, updatePill.height + 8)
                            }
                        }

                        // Spotify is holding some endpoints back: a short explanation.
                        Rectangle {
                            id: limitBadge
                            readonly property var limits: root.service.api.limits
                            visible: limits.length > 0
                            anchors.verticalCenter: parent.verticalCenter
                            width: 30
                            height: 30
                            radius: 15
                            color: Qt.rgba(root.warning.r, root.warning.g, root.warning.b, limitMouse.containsMouse ? 0.3 : 0.18)
                            border.width: 1
                            border.color: root.warning

                            Text {
                                anchors.centerIn: parent
                                text: "?"
                                color: root.warning
                                font.family: Style.font.family
                                font.pixelSize: 16
                                font.bold: true
                            }

                            MouseArea {
                                id: limitMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    var minutes = Math.max(1, Math.round(root.service.api.limitSeconds / 60));
                                    var wait = minutes >= 60 ? Math.floor(minutes / 60) + " h " + (minutes % 60) + " min" : minutes + " min";
                                    var names = limitBadge.limits.map(function(l) { return l.label; });
                                    root.showEntries([
                                        { header: "Spotify is limiting requests" },
                                        { note: "Spotify asked the app to wait before refreshing "
                                            + names.join(", ") + ". Back in about " + wait
                                            + ". Until then you see the last saved copy. Soloist on this computer can still play; remote controls may need to wait." },
                                        { label: "Details in Settings", icon: "󰒓",
                                          action: function() { root.navigate({ kind: "settings" }); } }
                                    ], limitBadge, limitBadge.width - 280, limitBadge.height + 8);
                                }
                            }
                        }

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

                        // Account avatar with Spotify's profile menu.
                        Rectangle {
                            id: avatar
                            anchors.verticalCenter: parent.verticalCenter
                            visible: root.service.api.signedIn
                            width: 40
                            height: 40
                            radius: 20
                            color: avatarMouse.containsMouse ? root.surfaceHover : root.surface

                            Cover {
                                anchors.centerIn: parent
                                width: 32
                                height: 32
                                kind: "artist"
                                source: root.me ? root.me.image || "" : ""
                                foreground: root.fg
                            }

                            // Update available.
                            Rectangle {
                                visible: root.service.updateAvailable
                                anchors.top: parent.top
                                anchors.right: parent.right
                                width: 12
                                height: 12
                                radius: 6
                                color: root.accent
                                border.width: 2
                                border.color: root.bg
                            }

                            MouseArea {
                                id: avatarMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.showEntries(root.accountMenu(), avatar, avatar.width - 280, avatar.height + 8)
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
                        width: root.clampLeft(root.leftWidth, body.width)
                        radius: 8
                        color: root.surface

                        LibraryView {
                            id: sidebarLibrary
                            anchors.fill: parent
                            anchors.margins: 12
                            showBack: false
                            active: root.showsWindow && visible
                            visible: root.service !== null
                            bar: null
                            api: root.service.api
                            controller: root.service.player
                            foreground: root.fg
                            onOpenCollection: function(collection) { root.openItem(collection); }
                            onRowMenuRequested: function(entry, source, x, y) { root.showMenu(entry, source, x, y); }

                            // Belt and braces: an empty library reloads whenever the window opens.
                            Connections {
                                target: window
                                function onVisibleChanged() { if (window.visible) sidebarLibrary.ensureLoaded(); }
                            }
                        }
                    }

                    // Queue / devices
                    Rectangle {
                        id: side
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: root.rightPanel !== "" ? root.clampRight(root.rightWidth, body.width) : 0
                        visible: width > 0
                        radius: 8
                        color: root.surface

                        NowPlayingPanel {
                            anchors.fill: parent
                            anchors.margins: 16
                            visible: root.rightPanel === "nowplaying"
                            app: root
                            info: root.trackInfo
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
                            onContextRequested: root.openPlayingContext()
                        }

                        DevicesView {
                            anchors.fill: parent
                            anchors.margins: 12
                            active: root.showsWindow && visible
                            visible: root.rightPanel === "devices"
                            showBack: false
                            bar: null
                            api: root.service.api
                            soloist: root.service.soloist
                            foreground: root.fg
                        }
                    }

                    // Drag handles in the gaps beside the sidebars; double-click
                    // resets the width.
                    ResizeHandle {
                        x: sidebar.width
                        z: 5
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        panelOnLeft: true
                        currentWidth: sidebar.width
                        lineColor: root.fg
                        onResized: function(w) { root.leftWidth = root.clampLeft(w, body.width); }
                        onResetRequested: root.leftWidth = root.defaultLeftWidth
                    }

                    ResizeHandle {
                        visible: side.visible
                        x: side.x - width
                        z: 5
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        panelOnLeft: false
                        currentWidth: side.width
                        lineColor: root.fg
                        onResized: function(w) { root.rightWidth = root.clampRight(w, body.width); }
                        onResetRequested: root.rightWidth = root.defaultRightWidth
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

                        // Floating "Now playing view" toggle in the corner of the
                        // page area (drawn: a panel with its right column filled).
                        Rectangle {
                            id: nowPlayingToggle
                            readonly property bool active: root.rightPanel === "nowplaying"
                            readonly property color tone: active ? root.accent : npToggleMouse.containsMouse ? root.fg : root.dim
                            z: 10
                            anchors.top: parent.top
                            anchors.right: parent.right
                            anchors.margins: 12
                            width: 36
                            height: 36
                            radius: 18
                            color: Qt.rgba(root.bg.r, root.bg.g, root.bg.b, npToggleMouse.containsMouse ? 0.85 : 0.6)

                            Rectangle {
                                anchors.centerIn: parent
                                width: 18
                                height: 16
                                radius: 3
                                color: "transparent"
                                border.width: 2
                                border.color: nowPlayingToggle.tone

                                Rectangle {
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    anchors.bottom: parent.bottom
                                    width: 7
                                    radius: 2
                                    color: nowPlayingToggle.tone
                                }
                            }

                            MouseArea {
                                id: npToggleMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.toggleRightPanel("nowplaying")
                            }
                        }

                        HomePage {
                            anchors.fill: parent
                            visible: root.page.kind === "home"
                            app: root
                        }

                        HistoryPage {
                            anchors.fill: parent
                            visible: root.page.kind === "history"
                            app: root
                        }

                        ShelfPage {
                            anchors.fill: parent
                            visible: root.page.kind === "shelf"
                            app: root
                            shelf: root.lastShelf
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
                            info: root.trackInfo
                        }

                        ProfilePage {
                            anchors.fill: parent
                            visible: root.page.kind === "profile"
                            app: root
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
